(*
  ThunderRAG OCaml server

  Role in the system
  - Acts as the authoritative orchestrator for the RAG email assistant.
  - Owns session state (conversation tail + summaries), prompt construction, and calls to Ollama.
  - Performs a 2-phase query flow so that Thunderbird (not OCaml) fetches full email bodies/attachments.

  High-level flows
  - Ingestion:
    - Accept raw emails (RFC822), extract text (text/plain or HTML->text), build a "text_for_index" payload,
      embed chunks via Ollama /api/embed, and store embeddings + metadata in PostgreSQL/pgvector.
  - Query (2-phase):
    1) POST /query
       - Runs kNN vector retrieval via PostgreSQL/pgvector.
       - Returns status=need_messages + request_id + message_ids + email metadata.
    2) POST /query/evidence
       - Thunderbird uploads message/rfc822 evidence for each message id (header X-Thunderbird-Message-Id).
    3) POST /query/complete
       - Extracts body text again (same normalization as ingestion), builds the final prompt, calls
         Ollama /api/chat, updates session state, returns answer + metadata-only emails for UI.

  All configuration is in ~/.rag-o-mail/settings.json (no environment variable overrides).
  Debug flags: debug.ollama_embed, debug.retrieval, debug.ollama_chat in settings.json.
*)

open Eio.Std

let () = Tool_check.ensure ()

open Rag_lib.Config

let () = ensure_dir (rag_config_dir ())

(* Ingestion tracking is now in PostgreSQL via Rag_lib.Pg. *)

open Rag_lib.Text_util

let body_text_has_error_marker (body_text : string) : bool =
  contains_substring ~sub:"[ERROR:" body_text


let bulk_ingest_build_tag = "progress_bytes_v1"

open Rag_lib.Mime

(*
  I/O and HTTP helpers

  read_all: drain an Eio flow into a string (used for request/response bodies).
  post_json_uri: low-level HTTP POST with JSON content-type.
*)
let read_all (flow : Eio.Flow.source_ty Eio.Resource.t) : string =
  let buf = Buffer.create 16384 in
  let tmp = Cstruct.create 16384 in
  let rec loop () =
    match Eio.Flow.single_read flow tmp with
    | n ->
        Buffer.add_string buf (Cstruct.to_string (Cstruct.sub tmp 0 n));
        loop ()
    | exception End_of_file -> ()
  in
  loop ();
  Buffer.contents buf

open Rag_lib.Html
open Rag_lib.Body_extract

(* Eio timeout wrapper, initialised at server start once the clock is available.
   Must be a ref due to the OCaml value restriction. *)
let global_with_timeout : (float -> (unit -> 'a) -> 'a) ref =
  ref (fun _seconds fn -> fn ())

let is_ok_status (status : Http.Status.t) : bool =
  let code = Cohttp.Code.code_of_status status in
  code >= 200 && code < 300

let json_headers =
  Http.Header.init_with "content-type" "application/json"
  |> fun h -> Http.Header.add h "connection" "close"

let post_json_uri ~client ~sw:_ ~(uri : Uri.t) ~(body_json : string) : (Http.Response.t * string) =
  Eio.Switch.run @@ fun sw ->
  let body = Cohttp_eio.Body.of_string body_json in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers:json_headers ~body `POST uri
  in
  (resp, read_all resp_body)

let get_uri ~client ~sw:_ ~(uri : Uri.t) : (Http.Response.t * string) =
  Eio.Switch.run @@ fun sw ->
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw `GET uri
  in
  (resp, read_all resp_body)

(*
  Ollama integration

  - ollama_embed: used during ingestion (embedding chunks) and during retrieval (embedding the query).
  - ollama_chat: used only for final generation once all evidence has been uploaded.

  Debugging
  - debug.ollama_embed in settings.json prints the exact embeddings request JSON.
  - debug.ollama_chat in settings.json prints the exact chat request JSON.
*)
type call_stats = { mutable total : float; mutable count : int }
let make_stats () = { total = 0.; count = 0 }
let record s dt = s.total <- s.total +. dt; s.count <- s.count + 1

let stats_embed_ingest    = make_stats ()
let stats_embed_query     = make_stats ()
let stats_chat_triage     = make_stats ()
let stats_chat_summarize  = make_stats ()
let stats_chat_session    = make_stats ()
let stats_chat_rewrite    = make_stats ()
let stats_chat_select     = make_stats ()
let stats_chat_answer     = make_stats ()
let stats_pg_upsert       = make_stats ()
let stats_pg_insert       = make_stats ()
let stats_pg_query_knn    = make_stats ()

let all_stats = [
  ("embed.ingest",       stats_embed_ingest);
  ("embed.query",        stats_embed_query);
  ("chat.triage",        stats_chat_triage);
  ("chat.summarize",     stats_chat_summarize);
  ("chat.session",       stats_chat_session);
  ("chat.rewrite",       stats_chat_rewrite);
  ("chat.select",        stats_chat_select);
  ("chat.answer",        stats_chat_answer);
  ("pg.upsert_email",    stats_pg_upsert);
  ("pg.insert_chunks",   stats_pg_insert);
  ("pg.query_knn",       stats_pg_query_knn);
]

type embed_task = Search_document | Search_query

(* Models known to support task-prefixed embeddings.
   Checked case-insensitively against ollama_embed_model. *)
let embed_task_prefix (task : embed_task) : string option =
  let model_lower = String.lowercase_ascii !ollama_embed_model in
  let is_nomic    = contains_substring ~sub:"nomic" model_lower in
  let is_e5       = contains_substring ~sub:"e5"    model_lower in
  let is_arctic   = contains_substring ~sub:"snowflake-arctic-embed" model_lower in
  let is_mxbai    = contains_substring ~sub:"mxbai" model_lower in
  if is_nomic || is_e5 || is_arctic then
    match task with
    | Search_document -> Some "search_document: "
    | Search_query    -> Some "search_query: "
  else if is_mxbai then
    match task with
    | Search_document -> None
    | Search_query    -> Some "Represent this sentence for searching relevant passages: "
  else
    None

let embed_dim_probed = ref false

(* Sentinel prefix for truncation errors so callers can distinguish them. *)
let truncation_error_prefix = "TRUNCATED: "
let is_truncation_error (msg : string) : bool =
  let n = String.length truncation_error_prefix in
  String.length msg >= n && String.sub msg 0 n = truncation_error_prefix

let ollama_embed ~client ~sw ?(task : embed_task option) ?(label = "") ?(stats : call_stats option) ~(text : string) () : (float list, string) result =
  let t0 = Unix.gettimeofday () in
  let prompt =
    match task with
    | None -> text
    | Some t ->
        match embed_task_prefix t with
        | Some prefix -> prefix ^ text
        | None -> text
  in
  (* Use /api/embed (not the deprecated /api/embeddings) with truncate=false
     so that Ollama returns an error instead of silently truncating. *)
  let uri = Uri.of_string (!ollama_base_url ^ "/api/embed") in
  let body_obj : Yojson.Safe.t =
    `Assoc [ ("model", `String !ollama_embed_model)
           ; ("input", `String prompt)
           ; ("truncate", `Bool false) ]
  in
  if !rag_debug_ollama_embed then
    Printf.printf "\n[ollama.embed.request]\n%s\n%!" (Yojson.Safe.pretty_to_string body_obj);
  let body_json = Yojson.Safe.to_string body_obj in
  let call () = post_json_uri ~client ~sw ~uri ~body_json in
  let resp, resp_body = !global_with_timeout !ollama_timeout_seconds call in
  let is_truncation_response =
    (* Ollama returns HTTP 400 with an error message mentioning context length *)
    not (is_ok_status (Http.Response.status resp)) &&
    (contains_substring ~sub:"context length" (String.lowercase_ascii resp_body) ||
     contains_substring ~sub:"too long" (String.lowercase_ascii resp_body) ||
     contains_substring ~sub:"exceeds" (String.lowercase_ascii resp_body) ||
     contains_substring ~sub:"truncat" (String.lowercase_ascii resp_body))
  in
  let result =
    if is_truncation_response then (
      let chars = String.length prompt in
      Printf.eprintf "[embed.truncated] label=%s chars=%d body=%s\n%!" label chars
        (if String.length resp_body > 200 then String.sub resp_body 0 200 ^ "..." else resp_body);
      Error (truncation_error_prefix ^ resp_body))
    else if not (is_ok_status (Http.Response.status resp)) then Error resp_body
    else
      try
        let json = Yojson.Safe.from_string resp_body in
        let parse_vec xs =
          xs |> List.filter_map (function
            | `Float f -> Some f
            | `Int i -> Some (float_of_int i)
            | `Intlit s -> (try Some (float_of_string s) with _ -> None)
            | `String s -> (try Some (float_of_string s) with _ -> None)
            | _ -> None)
        in
        match json with
        | `Assoc kv -> (
            (* /api/embed returns {"embeddings": [[...]]} *)
            match List.assoc_opt "embeddings" kv with
            | Some (`List (`List xs :: _)) ->
                let vec = parse_vec xs in
                if vec = [] then Error "empty embedding" else Ok vec
            | Some (`List []) -> Error "empty embeddings array"
            (* Fallback: also accept legacy {"embedding": [...]} format *)
            | _ -> (
                match List.assoc_opt "embedding" kv with
                | Some (`List xs) ->
                    let vec = parse_vec xs in
                    if vec = [] then Error "empty embedding" else Ok vec
                | _ -> Error "missing embedding/embeddings field"))
        | _ -> Error "bad embedding response"
      with ex -> Error (Printexc.to_string ex)
  in
  let dt = Unix.gettimeofday () -. t0 in
  let tag = if label = "" then "embed" else "embed." ^ label in
  Printf.eprintf "[timer] %s: %.3fs\n%!" tag dt;
  (match stats with Some s -> record s dt | None -> ());
  (match result with
   | Ok vec when not !embed_dim_probed ->
       let dim = List.length vec in
       rag_vector_dimension := dim;
       embed_dim_probed := true;
       Printf.printf "[config] embed model=%s vector_dimension=%d (auto-detected)\n%!" !ollama_embed_model dim
   | _ -> ());
  result

let ollama_chat ~client ~sw ?(label = "") ?(stats : call_stats option) ?(model = "") ?(stop : string list = []) ~(messages : Yojson.Safe.t list) () : (string, string) result =
  let t0 = Unix.gettimeofday () in
  let effective_model = if String.trim model <> "" then String.trim model else !ollama_llm_model in
  let uri = Uri.of_string (!ollama_base_url ^ "/api/chat") in
  let max_retries = 2 in
  let rec attempt n =
    let base_opts =
      [ ("num_ctx", `Int !ollama_num_ctx) ]
      @ (if stop <> [] then [ ("stop", `List (List.map (fun s -> `String s) stop)) ] else [])
    in
    let options =
      if n = 0 then base_opts
      else (
        Printf.eprintf "[ollama.chat.retry] %s attempt %d/%d (adding temperature jitter)\n%!" label n max_retries;
        ("temperature", `Float (0.1 *. float_of_int n)) :: base_opts)
    in
    let body_obj : Yojson.Safe.t =
      `Assoc
        [ ("model", `String effective_model)
        ; ("messages", `List messages)
        ; ("stream", `Bool false)
        ; ("options", `Assoc options)
        ]
    in
    if !rag_debug_ollama_chat then
      Printf.printf "\n[ollama.chat.request]\n%s\n%!" (Yojson.Safe.pretty_to_string body_obj);
    let body_json = Yojson.Safe.to_string body_obj in
    let call () = post_json_uri ~client ~sw ~uri ~body_json in
    let resp, resp_body = !global_with_timeout !ollama_timeout_seconds call in
    if not (is_ok_status (Http.Response.status resp)) then (
      if n < max_retries then (
        Printf.eprintf "[ollama.chat.error] %s attempt %d — Ollama returned %d, retrying…\n%!"
          label n (Http.Response.status resp |> Http.Status.to_int);
        attempt (n + 1))
      else Error resp_body)
    else
      try
        let json = Yojson.Safe.from_string resp_body in
        match json with
        | `Assoc kv -> (
            match List.assoc_opt "message" kv with
            | Some (`Assoc mv) -> (
                match List.assoc_opt "content" mv with
                | Some (`String s) ->
                    if String.trim s = "" && n < max_retries then (
                      Printf.eprintf "[ollama.chat.empty] %s attempt %d — empty response (likely stop-sequence hit), retrying…\n%!" label n;
                      attempt (n + 1))
                    else Ok s
                | _ -> Error "missing chat content")
            | _ -> Error "missing chat message")
        | _ -> Error "bad chat response"
      with ex -> Error (Printexc.to_string ex)
  in
  let result = attempt 0 in
  let dt = Unix.gettimeofday () -. t0 in
  let tag = if label = "" then "chat" else "chat." ^ label in
  Printf.eprintf "[timer] %s (%s): %.3fs\n%!" tag effective_model dt;
  (match stats with Some s -> record s dt | None -> ());
  result

(* Helper: create a JSON log entry for an LLM call.
   Used by the quality harness to inspect every prompt sent to every LLM. *)
let make_llm_call_entry ~label ~model ~(messages : Yojson.Safe.t list)
    ~(response : string) : Yojson.Safe.t =
  `Assoc
    [ ("label", `String label)
    ; ("model", `String model)
    ; ("messages", `List messages)
    ; ("response", `String response)
    ]

(*
  Recursive chunked summarization — single factored-out implementation.

  summarize_to_fit guarantees the returned string is at most [max_chars] long.
  If the input already fits, it is returned unchanged.  Otherwise it is
  recursively split into [max_input_chars]-sized chunks, each chunk is
  summarized by the LLM, and the combined summaries are re-checked (and
  re-summarized if still too long).  A depth limit of 4 prevents runaway
  recursion; on exhaustion or LLM failure the text is hard-truncated as a
  last resort.
*)

let split_into_chunks (text : string) (chunk_size : int) : string list =
  let len = String.length text in
  let rec loop pos acc =
    if pos >= len then List.rev acc
    else
      let remaining = len - pos in
      let raw_end = pos + min chunk_size remaining in
      let chunk_end =
        if raw_end >= len then len
        else
          let last_nl = ref raw_end in
          let found = ref false in
          for i = raw_end - 1 downto (max pos (raw_end - 200)) do
            if (not !found) && String.get text i = '\n' then (
              last_nl := i + 1;
              found := true)
          done;
          if !found then !last_nl else raw_end
      in
      let chunk = String.sub text pos (chunk_end - pos) in
      loop chunk_end (chunk :: acc)
  in
  loop 0 []

let strip_summary_preamble (s : string) : string =
  let lines = String.split_on_char '\n' s in
  let is_preamble_line (l : string) : bool =
    let t = String.trim l in
    if t = "" then true
    else
      let lower = String.lowercase_ascii t in
      starts_with "here is" lower
      || starts_with "here's" lower
      || starts_with "summary" lower
      || starts_with "summarized" lower
      || starts_with "quoted context" lower
      || starts_with "important:" lower
      || starts_with "note:" lower
      || contains_substring ~sub:"i have compressed" lower
      || contains_substring ~sub:"compressed it to" lower
      || contains_substring ~sub:"key details preserved" lower
      || contains_substring ~sub:"key details:" lower
      || contains_substring ~sub:"downstream triage" lower
      || contains_substring ~sub:"losing these" lower
      || contains_substring ~sub:"roughly 50%" lower
      || contains_substring ~sub:"% of the original" lower
      || contains_substring ~sub:"do not exceed" lower
  in
  let rec drop = function
    | [] -> []
    | l :: rest -> if is_preamble_line l then drop rest else l :: rest
  in
  String.concat "\n" (drop lines)

let summarize_to_fit ~client ~sw ~system_prompt ~max_input_chars ~max_chars
    ~label ?(summarize_model : string option) ?(llm_log : Yojson.Safe.t list ref option) (text : string) : string =
  let effective_summarize_model =
    match summarize_model with
    | Some m when String.trim m <> "" -> m
    | _ -> !ollama_summarize_model
  in
  let clean = String.trim text in
  if String.length clean <= max_chars then clean
  else
    let summarize_one ~(target_chars : int) (chunk : string) : string option =
      let input_len = String.length chunk in
      (* Clamp effective target to 50–75% of input: never ask LLM to compress
         below half (wastes quality) or above 75% (wastes a pass). If the
         clamped target still exceeds max_chars, the recursion loop will
         call another pass. *)
      let effective_target =
        if input_len <= 0 then target_chars
        else
          let floor = input_len / 2 in          (* 50% *)
          let ceil  = input_len * 3 / 4 in      (* 75% *)
          max floor (min ceil target_chars)
      in
      let pct = if input_len > 0 then effective_target * 100 / input_len else 50 in
      let augmented_prompt =
        system_prompt
        ^ Printf.sprintf "\n\nIMPORTANT: The input is approximately %d characters. You MUST compress it to approximately %d characters (roughly %d%% of the original). Be aggressive — omit filler, merge related points, and use terse phrasing. Do NOT exceed %d characters."
            input_len effective_target pct effective_target
      in
      let messages : Yojson.Safe.t list =
        [ `Assoc [ ("role", `String "system"); ("content", `String augmented_prompt) ]
        ; `Assoc [ ("role", `String "user"); ("content", `String chunk) ]
        ]
      in
      match ollama_chat ~client ~sw ~label:("summarize." ^ label) ~stats:stats_chat_summarize ~model:effective_summarize_model ~messages () with
      | Ok s ->
          if !rag_debug_ollama_chat then Printf.printf "\n[%s.summary.response]\n%s\n%!" label s;
          (match llm_log with Some log ->
            log := !log @ [make_llm_call_entry ~label:("summarize:" ^ label)
              ~model:effective_summarize_model ~messages ~response:s]
          | None -> ());
          let s = strip_summary_preamble s |> String.trim in
          if s = "" then (
            Printf.eprintf "[%s.summary.error] empty response from ollama\n%!" label;
            None)
          else Some s
      | Error err ->
          (match llm_log with Some log ->
            log := !log @ [make_llm_call_entry ~label:("summarize:" ^ label)
              ~model:effective_summarize_model ~messages ~response:("ERROR: " ^ err)]
          | None -> ());
          let err = String.trim err in
          let err = if err = "" then "unknown error" else err in
          let err = truncate_chars err ~max_chars:400 |> String.trim in
          Printf.eprintf "[%s.summary.error] %s\n%!" label err;
          None
    in
    let rec chunk_and_summarize text depth =
      if String.length text <= max_chars then text
      else if depth > 4 then (
        Printf.eprintf "[%s.summary.warning] recursion depth limit reached, truncating\n%!" label;
        truncate_chars text ~max_chars)
      else if String.length text <= max_input_chars then (
        match summarize_one ~target_chars:max_chars text with
        | Some s -> chunk_and_summarize s (depth + 1)
        | None -> truncate_chars text ~max_chars)
      else
        let chunks = split_into_chunks text max_input_chars in
        let n = List.length chunks in
        let per_chunk_target = max 200 (max_chars / (max 1 n)) in
        Printf.printf "[%s.summary] depth=%d chunks=%d total_chars=%d target_per_chunk=%d\n%!" label depth n (String.length text) per_chunk_target;
        let summaries = List.filter_map (summarize_one ~target_chars:per_chunk_target) chunks in
        match summaries with
        | [] -> truncate_chars text ~max_chars
        | _ ->
            let combined = String.concat "\n\n" summaries in
            chunk_and_summarize combined (depth + 1)
    in
    chunk_and_summarize clean 0

let summarize_quoted_context ~client ~sw ~(quoted_text : string) : string option =
  if (not !rag_quoted_context_summarize) || String.trim quoted_text = "" then None
  else
    let quoted_clean = String.trim quoted_text in
    if String.length quoted_clean < 40 then None
    else
      let max_lines = !rag_quoted_context_max_lines in
      let max_chars = !rag_quoted_context_max_chars in
      let max_input = !rag_quoted_context_max_input_chars in
      let system_prompt =
        get_prompt "compress_quoted_context_ingest"
          ~default:"Compress quoted email thread history. Third person only. Preserve facts. No preamble."
          ~vars:[("{{max_lines}}", string_of_int max_lines)]
      in
      let result = summarize_to_fit ~client ~sw ~system_prompt ~max_input_chars:max_input
        ~max_chars ~label:"quoted_context" quoted_clean
      in
      let result = truncate_lines result ~max_lines |> String.trim in
      let lower = String.lowercase_ascii result in
      if result = "" then None
      else if starts_with "no quoted context" lower || starts_with "no quoted" lower || starts_with "please provide" lower then (
        Printf.eprintf "[quoted_context.summary.error] ollama claimed no quoted context (unexpected)\n%!";
        Some "[ERROR: quoted-context summary failed: model claimed no quoted context]")
      else Some result

(* Extract all email addresses from a free-text string (e.g., whoami textarea).
   Splits on whitespace/commas/semicolons, then keeps tokens containing '@' with
   a dot after the '@'.  Strips angle brackets: "<john@example.com>" → "john@example.com". *)
let extract_email_addresses (text : string) : string list =
  let is_sep c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = ',' || c = ';' in
  let tokens = ref [] in
  let buf = Buffer.create 64 in
  String.iter (fun c ->
    if is_sep c then begin
      if Buffer.length buf > 0 then (tokens := Buffer.contents buf :: !tokens; Buffer.clear buf)
    end else Buffer.add_char buf c) text;
  if Buffer.length buf > 0 then tokens := Buffer.contents buf :: !tokens;
  List.rev !tokens
  |> List.filter_map (fun tok ->
    let tok = String.trim tok in
    let tok = if String.length tok >= 2 && tok.[0] = '<' && tok.[String.length tok - 1] = '>'
      then String.sub tok 1 (String.length tok - 2) else tok in
    if String.contains tok '@' then
      let at_pos = String.index tok '@' in
      let after = String.sub tok (at_pos + 1) (String.length tok - at_pos - 1) in
      if String.contains after '.' then Some (String.lowercase_ascii tok) else None
    else None)

(* Build user-identity string for LLM prompts.
   ~long:true  → "The user (the email account owner) is: NAME (email: EMAIL).\n"
   ~long:false → "The user is: NAME (email: EMAIL). "                           *)
let build_user_identity ?(long = false) ~name ~email () : string =
  let name_part = String.trim name in
  let email_part = String.trim email in
  let prefix = if long then "The user (the email account owner)" else "The user" in
  let suffix = if long then ".\n" else ". " in
  match (name_part <> "", email_part <> "") with
  | true, true  -> Printf.sprintf "%s is: %s (email: %s)%s" prefix name_part email_part suffix
  | true, false -> Printf.sprintf "%s is: %s%s" prefix name_part suffix
  | false, true -> Printf.sprintf "%s email is: %s%s" prefix email_part suffix
  | false, false -> ""

(*
  Task proposal type — used by propose_tasks and process_task_proposals.
*)
type task_proposal =
  { tp_title       : string
  ; tp_description : string
  ; tp_importance  : int option
  ; tp_deadline    : string     (* YYYY-MM-DD or "" *)
  }

(*
  Symbolic rule evaluator for memory rules.

  Rules use MongoDB-style JSONB syntax:
  - Leaf:       {"field": "sender", "op": "contains", "value": "alice"}
  - Combinators: {"$and": [...]}, {"$or": [...]}, {"$not": <expr>}
*)
let evaluate_symbolic_rule (rule : Yojson.Safe.t)
    ~(sender : string) ~(recipient : string) ~(cc : string) ~(bcc : string)
    ~(subject : string) ~(date : string) ~(attachments : string list)
    : bool =
  let lower = String.lowercase_ascii in
  let field_value = function
    | "sender" | "from" -> lower sender
    | "recipient" | "to" -> lower recipient
    | "cc" -> lower cc
    | "bcc" -> lower bcc
    | "subject" -> lower subject
    | "date" -> date
    | "attachments" -> lower (String.concat ", " attachments)
    | _ -> ""
  in
  let rec eval (node : Yojson.Safe.t) : bool =
    match node with
    | `Assoc kv ->
        (* Check for combinators first *)
        (match List.assoc_opt "$and" kv with
        | Some (`List exprs) -> List.for_all eval exprs
        | _ ->
        match List.assoc_opt "$or" kv with
        | Some (`List exprs) -> List.exists eval exprs
        | _ ->
        match List.assoc_opt "$not" kv with
        | Some expr -> not (eval expr)
        | _ ->
        (* Leaf node: {field, op, value} *)
        let gs k = match List.assoc_opt k kv with Some (`String s) -> s | _ -> "" in
        let field = gs "field" in
        let op = gs "op" in
        let value = lower (gs "value") in
        let fv = field_value field in
        match op with
        | "contains"     -> contains_substring ~sub:value fv
        | "not_contains" -> not (contains_substring ~sub:value fv)
        | "equals"       -> fv = value
        | "not_equals"   -> fv <> value
        | "starts_with"  -> starts_with value fv
        | "ends_with"    -> ends_with value fv
        | "is_empty"     -> String.trim fv = ""
        | "is_not_empty" -> String.trim fv <> ""
        | "matches"      ->
            (* Fallback: treat regex pattern as a contains check *)
            contains_substring ~sub:value fv
        | _ -> false)
    | _ -> false
  in
  eval rule

(*
  Retrieve memories matching an email via symbolic rules.
  Returns list of (memory_id, memory_text) for memories whose rules match.
*)
let retrieve_memories_symbolic
    ~(sender : string) ~(recipient : string) ~(cc : string) ~(bcc : string)
    ~(subject : string) ~(date : string) ~(attachments : string list)
    () : (string * string) list =
  if not !memory_enabled then []
  else
  match Rag_lib.Pg.memories_with_rules () with
  | Error e ->
      Printf.eprintf "[memory_sym] error loading rules: %s\n%!" e; []
  | Ok rules ->
      List.filter_map (fun (memory_id, text, rule_str) ->
        match (try Some (Yojson.Safe.from_string rule_str) with _ -> None) with
        | None -> None
        | Some rule_json ->
            if evaluate_symbolic_rule rule_json
                ~sender ~recipient ~cc ~bcc ~subject ~date ~attachments
            then (
              Printf.printf "[memory_sym] MATCH memory %s for subject=%s\n%!" memory_id
                (truncate_chars subject ~max_chars:60);
              Some (memory_id, text))
            else None
      ) rules

(*
  Retrieve memories via embedding kNN across all three channels
  (templates, linked emails, linked tasks). Returns deduplicated
  (memory_id, memory_text) list, best distance per memory.
*)
let retrieve_memories_embedding ~(embedding : float list) ()
    : (string * string) list =
  if not !memory_enabled then []
  else
  let top_k = !memory_knn_top_k in
  (* Collect (memory_id, distance) from all three channels *)
  let ch1 = match Rag_lib.Pg.memory_templates_knn ~embedding ~top_k () with
    | Ok rows -> rows | Error _ -> [] in
  let ch2 = match Rag_lib.Pg.memory_emails_knn ~embedding ~top_k () with
    | Ok rows -> rows | Error _ -> [] in
  let ch3 = match Rag_lib.Pg.memory_tasks_knn ~embedding ~top_k () with
    | Ok rows -> rows | Error _ -> [] in
  (* Merge: keep best (lowest) distance per memory_id *)
  let tbl : (string, float) Hashtbl.t = Hashtbl.create 32 in
  let update (mid, dist) =
    match Hashtbl.find_opt tbl mid with
    | Some d when d <= dist -> ()
    | _ -> Hashtbl.replace tbl mid dist
  in
  List.iter update ch1;
  List.iter update ch2;
  List.iter update ch3;
  (* Sort by distance, take top_k *)
  let sorted = Hashtbl.fold (fun mid dist acc -> (mid, dist) :: acc) tbl []
    |> List.sort (fun (_, d1) (_, d2) -> compare d1 d2)
    |> List.filteri (fun i _ -> i < top_k)
  in
  (* Resolve memory texts *)
  List.filter_map (fun (mid, _dist) ->
    match Rag_lib.Pg.memory_text mid with
    | Ok (Some text) -> Some (mid, text)
    | _ -> None
  ) sorted

(*
  Combine symbolic + embedding retrieval, deduplicate, and build
  the {{user_memories}} text block for prompt injection.
*)
let retrieve_and_format_memories
    ~(sender : string) ~(recipient : string) ~(cc : string) ~(bcc : string)
    ~(subject : string) ~(date : string) ~(attachments : string list)
    ~(embedding : float list)
    () : string * (string * string) list =
  let sym = retrieve_memories_symbolic
    ~sender ~recipient ~cc ~bcc ~subject ~date ~attachments () in
  let emb = retrieve_memories_embedding ~embedding () in
  (* Merge: symbolic first, then embedding (deduped) *)
  let seen = Hashtbl.create 16 in
  let all = ref [] in
  let add (mid, text) =
    if not (Hashtbl.mem seen mid) then begin
      Hashtbl.replace seen mid true;
      all := (mid, text) :: !all
    end
  in
  List.iter add sym;
  List.iter add emb;
  let memories = List.rev !all in
  if memories <> [] then
    Printf.printf "[memory] retrieved %d memories (%d symbolic, %d embedding)\n%!"
      (List.length memories) (List.length sym) (List.length emb);
  (* Format as text block, capped at memory_max_chars *)
  let max_chars = !memory_max_chars in
  let buf = Buffer.create 512 in
  List.iteri (fun i (mid, text) ->
    let line = Printf.sprintf "- [%s] %s\n" mid text in
    if Buffer.length buf + String.length line <= max_chars then
      Buffer.add_string buf line
    else if i = 0 then
      (* Always include at least the first memory, even if over cap *)
      Buffer.add_string buf (truncate_chars line ~max_chars)
  ) memories;
  (Buffer.contents buf, memories)

(*
  propose_tasks — LLM call to generate task proposals from an email.

  Replaces triage. Called after email is stored in PG, with optional
  memory context injected into the prompt.
*)
let propose_tasks ~client ~sw ~(whoami : string)
    ~(from_ : string) ~(to_ : string) ~(cc_ : string) ~(bcc_ : string)
    ~(subject : string) ~(date_ : string) ~(body_text : string)
    ~(memories_text : string)
    : task_proposal list * Yojson.Safe.t option =
  if String.trim whoami = "" then (
    Printf.eprintf "[propose_tasks] skipped: whoami is empty\n%!";
    ([], None))
  else
  let user_identity =
    if String.trim whoami <> ""
    then Printf.sprintf "The user (the email account owner) is: %s. " (String.trim whoami)
    else ""
  in
  let memories_section =
    if String.trim memories_text = "" then ""
    else Printf.sprintf "\n\nUSER MEMORIES (persistent preferences and rules — follow these):\n%s" memories_text
  in
  let system =
    get_prompt "propose_tasks"
      ~default:("You are a task extraction assistant. " ^ user_identity ^
        "Given an email, propose tasks the user needs to do in response. " ^
        "Respond with ONLY a JSON object: {\"tasks\": [{\"title\": \"short task title\", " ^
        "\"description\": \"what needs to be done\", \"importance\": <int 0-100>, " ^
        "\"deadline\": \"YYYY-MM-DD\"}]}. " ^
        "Only propose tasks for emails that require user action. " ^
        "Newsletters, notifications, and FYI emails should have an empty tasks array. " ^
        "In 90%+ of cases, the answer is 0 or 1 tasks. " ^
        "Every task MUST have a deadline. If no explicit deadline, guess based on urgency cues and professional norms. " ^
        "Use the email Date as reference." ^ memories_section)
      ~vars:[("{{user_identity}}", user_identity); ("{{user_memories}}", memories_text)]
  in
  let user_msg =
    Printf.sprintf
      "EMAIL HEADERS:\n\
       From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nDate: %s\n\n\
       BODY:\n%s"
      from_ to_ cc_ bcc_ subject date_ body_text
  in
  let messages : Yojson.Safe.t list =
    [ `Assoc [ ("role", `String "system"); ("content", `String system) ]
    ; `Assoc [ ("role", `String "user"); ("content", `String user_msg) ]
    ]
  in
  let effective_model = !ollama_triage_model in
  let debug_json raw_resp = Some (`Assoc
    [ ("model", `String effective_model)
    ; ("messages", `List messages)
    ; ("raw_response", `String raw_resp)
    ]) in
  match ollama_chat ~client ~sw ~label:"propose_tasks" ~stats:stats_chat_triage ~model:effective_model ~messages () with
  | Ok raw_resp ->
      if !rag_debug_ollama_chat then Printf.printf "\n[propose_tasks.response]\n%s\n%!" raw_resp;
      let trimmed =
        let s = String.trim raw_resp in
        let s = if starts_with "```json" s then
          let after = String.sub s 7 (String.length s - 7) in
          if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
        else if starts_with "```" s then
          let after = String.sub s 3 (String.length s - 3) in
          if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
        else s
        in String.trim s
      in
      (try
        let json = Yojson.Safe.from_string trimmed in
        let task_proposals =
          match json with
          | `Assoc kv ->
              (match List.assoc_opt "tasks" kv with
              | Some (`List tasks) ->
                  List.filter_map (fun tj ->
                    let tkv = match tj with `Assoc kv -> kv | _ -> [] in
                    let ts k = match List.assoc_opt k tkv with Some (`String s) -> String.trim s | _ -> "" in
                    let ti k = match List.assoc_opt k tkv with
                      | Some (`Int n) -> Some (max 0 (min 100 n))
                      | Some (`Float f) -> Some (max 0 (min 100 (int_of_float f)))
                      | Some (`String s) -> (try Some (max 0 (min 100 (int_of_string (String.trim s)))) with _ -> None)
                      | _ -> None
                    in
                    let title = ts "title" in
                    if title = "" then None
                    else Some { tp_title = title
                              ; tp_description = ts "description"
                              ; tp_importance = ti "importance"
                              ; tp_deadline = let d = ts "deadline" in if d = "none" then "" else d
                              }
                  ) tasks
              | _ -> [])
          | _ -> []
        in
        Printf.printf "[propose_tasks] proposed %d tasks\n%!" (List.length task_proposals);
        (task_proposals, debug_json raw_resp)
      with ex ->
        Printf.eprintf "[propose_tasks.parse_error] %s — raw: %s\n%!" (Printexc.to_string ex)
          (truncate_chars raw_resp ~max_chars:200 |> String.trim);
        ([], debug_json raw_resp))
  | Error err ->
      Printf.eprintf "[propose_tasks.error] %s\n%!" (truncate_chars err ~max_chars:400 |> String.trim);
      ([], None)

(* Global hook for background prefetch notification — set at startup *)
let notify_prefetch : (unit -> unit) ref = ref (fun () -> ())

(* When > 0, the prefetch daemon defers to higher-priority work
   (email ingestion, user queries/chat).
   Counter rather than boolean so concurrent requests don't cancel each other. *)
let high_priority_count = Atomic.make 0

(* Pause flags — toggled via /admin/pause, reset on restart.
   tasks_paused  = true → daemon Phases 0-2 (triage, context, first msg) are skipped
   ingest_paused = true → daemon Phase -1 (async ingestion) is also skipped *)
let tasks_paused  = Atomic.make false
let ingest_paused = Atomic.make false

let with_high_priority f =
  Atomic.incr high_priority_count;
  Fun.protect f ~finally:(fun () -> Atomic.decr high_priority_count)

(* Generate a UUID v4 task ID using /dev/urandom for proper randomness. *)
let generate_task_id () =
  let buf = Bytes.create 16 in
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input ic buf 0 16);
  (* Set version 4 and variant bits per RFC 4122 *)
  Bytes.set buf 6 (Char.chr ((Char.code (Bytes.get buf 6) land 0x0F) lor 0x40));
  Bytes.set buf 8 (Char.chr ((Char.code (Bytes.get buf 8) land 0x3F) lor 0x80));
  Printf.sprintf "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
    (Char.code (Bytes.get buf 0)) (Char.code (Bytes.get buf 1))
    (Char.code (Bytes.get buf 2)) (Char.code (Bytes.get buf 3))
    (Char.code (Bytes.get buf 4)) (Char.code (Bytes.get buf 5))
    (Char.code (Bytes.get buf 6)) (Char.code (Bytes.get buf 7))
    (Char.code (Bytes.get buf 8)) (Char.code (Bytes.get buf 9))
    (Char.code (Bytes.get buf 10)) (Char.code (Bytes.get buf 11))
    (Char.code (Bytes.get buf 12)) (Char.code (Bytes.get buf 13))
    (Char.code (Bytes.get buf 14)) (Char.code (Bytes.get buf 15))

(*
  Task proposal processing (Phase D)

  After triage proposes tasks, for each proposal:
  1. Embed title + description
  2. kNN search against existing open/in_progress tasks
  3. If neighbors found, call dedup LLM to decide: new task or update existing
  4. Create or update accordingly, link the triggering email
*)
(* Retrieve similar done/dismissed tasks and format as prior-resolutions text *)
let format_prior_resolutions ~(embedding : float list) () : string =
  let top_k = !task_resolved_top_k in
  let max_dist = !task_resolved_max_distance in
  if top_k <= 0 then ""
  else
  match Rag_lib.Pg.task_knn_resolved ~embedding ~top_k () with
  | Error e ->
      Printf.eprintf "[prior_resolutions] kNN error: %s\n%!" e; ""
  | Ok rows ->
      let filtered = List.filter (fun (_, _, _, _, _, _, dist) -> dist <= max_dist) rows in
      if filtered = [] then ""
      else begin
        let buf = Buffer.create 1024 in
        List.iter (fun (_tid, title, _desc, status, notes, draft_body, dist) ->
          Buffer.add_string buf (Printf.sprintf "--- [%s, dist=%.3f] \"%s\"\n" status dist title);
          if String.trim notes <> "" then
            Buffer.add_string buf (Printf.sprintf "Resolution: %s\n" (String.trim notes));
          if String.trim draft_body <> "" then
            Buffer.add_string buf (Printf.sprintf "Draft sent:\n%s\n" (String.trim draft_body));
          Buffer.add_string buf "---\n\n"
        ) filtered;
        let text = String.trim (Buffer.contents buf) in
        let max_chars = 4000 in
        if String.length text > max_chars then String.sub text 0 max_chars else text
      end

let process_task_proposals ~client ~sw ~(doc_id : string)
    ~(body_text : string) ~(email_date : string)
    ~(proposals : task_proposal list) () : unit =
  if not !task_auto_create then ()
  else if proposals = [] then ()
  else
  let ndoc = Rag_lib.Pg.normalize_doc_id doc_id in
  Printf.printf "[process_task_proposals] doc_id=%s proposals=%d\n%!" ndoc (List.length proposals);
  (* Fallback deadline: email_date + 3 business days (skip weekends) *)
  let fallback_deadline =
    let parse_date s =
      try Scanf.sscanf s "%d-%d-%d" (fun y m d -> Some (y, m, d))
      with _ -> try Scanf.sscanf s "%d-%d-%dT" (fun y m d -> Some (y, m, d))
      with _ -> None
    in
    match parse_date (String.trim email_date) with
    | None -> ""
    | Some (y, m, d) ->
        let tm = Unix.{ tm_sec = 0; tm_min = 0; tm_hour = 12;
                        tm_mday = d; tm_mon = m - 1; tm_year = y - 1900;
                        tm_wday = 0; tm_yday = 0; tm_isdst = false } in
        let t, _ = Unix.mktime tm in
        (* Add 3 business days *)
        let rec add_bdays t n =
          if n <= 0 then t
          else
            let t' = t +. 86400.0 in
            let tm' = Unix.localtime t' in
            if tm'.Unix.tm_wday = 0 || tm'.Unix.tm_wday = 6
            then add_bdays t' n  (* weekend — advance without counting *)
            else add_bdays t' (n - 1)
        in
        let t' = add_bdays t 3 in
        let tm' = Unix.localtime t' in
        Printf.sprintf "%04d-%02d-%02d" (tm'.Unix.tm_year + 1900) (tm'.Unix.tm_mon + 1) tm'.Unix.tm_mday
  in
  let top_k = !task_dedup_top_k in
  List.iter (fun (tp : task_proposal) ->
    let tp = if tp.tp_deadline = "" && fallback_deadline <> "" then begin
      Printf.printf "[process_task_proposals] no deadline for '%s', using fallback %s\n%!" tp.tp_title fallback_deadline;
      { tp with tp_deadline = fallback_deadline }
    end else tp in
    (try
      let embed_text = Printf.sprintf "%s\n%s" tp.tp_title tp.tp_description in
      (* 1. Embed the proposal *)
      let embedding = match ollama_embed ~client ~sw ~task:Search_document
          ~label:"task_dedup" ~text:embed_text () with
        | Ok v -> l2_normalize v
        | Error msg ->
            Printf.eprintf "[task_dedup] embed failed for '%s': %s\n%!" tp.tp_title msg;
            raise Exit
      in
      (* 2. kNN search for similar existing tasks *)
      let neighbors = match Rag_lib.Pg.task_knn ~embedding ~top_k () with
        | Ok rows -> rows
        | Error e ->
            Printf.eprintf "[task_dedup] kNN error: %s\n%!" e;
            []
      in
      if neighbors = [] then begin
        (* No neighbors — create new task directly *)
        let task_id = generate_task_id () in
        let prior = format_prior_resolutions ~embedding () in
        if prior <> "" then
          Printf.printf "[task_dedup] found prior resolutions (%d chars) for '%s'\n%!" (String.length prior) tp.tp_title;
        (match Rag_lib.Pg.create_task ~task_id ~title:tp.tp_title
            ~description:tp.tp_description
            ~importance_score:tp.tp_importance
            ~deadline:tp.tp_deadline
            ~embedding ~conversation_json:"[]" ~drafts_json:"[]"
            ~prior_resolutions:prior () with
        | Ok () ->
            (match Rag_lib.Pg.link_email_to_task ~task_id ~doc_id:ndoc ~role:"trigger" ~compressed_body:body_text () with
            | Ok () -> ()
            | Error e -> Printf.eprintf "[task_dedup] link error: %s\n%!" e);
            Printf.printf "[task_dedup] NEW task %s: %s (no neighbors)\n%!" task_id tp.tp_title;
            !notify_prefetch ()
        | Error e ->
            Printf.eprintf "[task_dedup] create error: %s\n%!" e)
      end else begin
        (* 3. Call dedup LLM to decide: new or same-as-existing *)
        let neighbor_lines = List.mapi (fun i (tid, title, desc, imp, dl, dist) ->
          let imp_s = match imp with Some n -> string_of_int n | None -> "?" in
          let dl_s = if dl = "" then "none" else dl in
          Printf.sprintf "%d. [task_id=%s dist=%.4f importance=%s deadline=%s] %s — %s"
            (i + 1) tid dist imp_s dl_s title desc
        ) neighbors in
        let dedup_system =
          get_prompt "task_dedup"
            ~default:"You are a task deduplication assistant. Given a proposed new task and a list of existing tasks, \
              decide whether the proposed task is the same as an existing one or genuinely new. \
              Respond with ONLY a JSON object: \
              {\"decision\": \"new\" or \"same\", \"existing_task_id\": \"<id or empty>\", \
              \"update_description\": \"<revised merged description if merging, or empty>\", \
              \"importance\": <0-100 integer — reevaluated importance for the merged task>, \
              \"deadline\": \"<YYYY-MM-DD or empty — reevaluated deadline for the merged task>\"}. \
              Tasks are 'same' if they represent the same action item, even if worded differently. \
              Consider the subject matter, people involved, and required action. \
              When merging, reevaluate importance and deadline considering BOTH the existing task and the new information — \
              do not simply copy from either one."
            ~vars:[]
        in
        let prop_imp_s = match tp.tp_importance with Some n -> string_of_int n | None -> "?" in
        let prop_dl_s = if tp.tp_deadline = "" then "none" else tp.tp_deadline in
        let dedup_user = Printf.sprintf
          "PROPOSED TASK:\nTitle: %s\nDescription: %s\nImportance: %s\nDeadline: %s\n\nEXISTING TASKS:\n%s"
          tp.tp_title tp.tp_description prop_imp_s prop_dl_s
          (String.concat "\n" neighbor_lines)
        in
        let dedup_messages : Yojson.Safe.t list =
          [ `Assoc [ ("role", `String "system"); ("content", `String dedup_system) ]
          ; `Assoc [ ("role", `String "user"); ("content", `String dedup_user) ]
          ]
        in
        match ollama_chat ~client ~sw ~label:"task_dedup" ~model:!ollama_triage_model ~messages:dedup_messages () with
        | Error msg ->
            Printf.eprintf "[task_dedup] LLM error: %s — creating new task\n%!" msg;
            (* Fall back to creating new *)
            let task_id = generate_task_id () in
            let prior = format_prior_resolutions ~embedding () in
            (match Rag_lib.Pg.create_task ~task_id ~title:tp.tp_title
                ~description:tp.tp_description
                ~importance_score:tp.tp_importance
                ~deadline:tp.tp_deadline
                ~embedding ~conversation_json:"[]" ~drafts_json:"[]"
                ~prior_resolutions:prior () with
            | Ok () ->
                ignore (Rag_lib.Pg.link_email_to_task ~task_id ~doc_id:ndoc ~role:"trigger" ~compressed_body:body_text ());
                Printf.printf "[task_dedup] NEW task %s: %s (dedup LLM failed)\n%!" task_id tp.tp_title;
                !notify_prefetch ()
            | Error e -> Printf.eprintf "[task_dedup] create error: %s\n%!" e)
        | Ok raw_resp ->
            let trimmed =
              let s = String.trim raw_resp in
              let s = if starts_with "```json" s then
                let after = String.sub s 7 (String.length s - 7) in
                if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
              else if starts_with "```" s then
                let after = String.sub s 3 (String.length s - 3) in
                if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
              else s
              in String.trim s
            in
            let decision, existing_id, update_desc, merged_importance, merged_deadline =
              try
                let dj = Yojson.Safe.from_string trimmed in
                let dkv = match dj with `Assoc kv -> kv | _ -> [] in
                let ds k = match List.assoc_opt k dkv with Some (`String s) -> String.trim s | _ -> "" in
                let di k = match List.assoc_opt k dkv with
                  | Some (`Int n) -> Some (max 0 (min 100 n))
                  | Some (`Float f) -> Some (max 0 (min 100 (int_of_float f)))
                  | Some (`String s) -> (try Some (max 0 (min 100 (int_of_string (String.trim s)))) with _ -> None)
                  | _ -> None
                in
                let dl = let d = ds "deadline" in if d = "none" || d = "null" || d = "" then "" else d in
                (ds "decision", ds "existing_task_id", ds "update_description", di "importance", dl)
              with _ ->
                Printf.eprintf "[task_dedup] parse error — raw: %s\n%!"
                  (truncate_chars raw_resp ~max_chars:200 |> String.trim);
                ("new", "", "", None, "")
            in
            if decision = "same" && existing_id <> "" then begin
              (* Update existing task: link email, optionally revise description, update embedding *)
              (match Rag_lib.Pg.link_email_to_task ~task_id:existing_id ~doc_id:ndoc ~role:"trigger" ~compressed_body:body_text () with
              | Ok () -> ()
              | Error e -> Printf.eprintf "[task_dedup] link error: %s\n%!" e);
              let desc_update = if update_desc <> "" then Some update_desc else None in
              let imp_update = match merged_importance with
                | Some n -> Some (Some n) | None -> None
              in
              let dl_update = if merged_deadline <> "" then Some merged_deadline else None in
              (* Re-embed if description changed *)
              let emb_update =
                if update_desc <> "" then
                  let new_embed_text = Printf.sprintf "%s\n%s" tp.tp_title update_desc in
                  (match ollama_embed ~client ~sw ~task:Search_document
                      ~label:"task_reembed" ~text:new_embed_text () with
                  | Ok v -> Some (l2_normalize v)
                  | Error _ -> None)
                else None
              in
              (* Delete stale context/style selections and reset pipeline flags *)
              (match Rag_lib.Pg.delete_task_context_and_style existing_id with
              | Ok n when n > 0 -> Printf.printf "[task_dedup] cleared %d stale context/style rows for %s\n%!" n existing_id
              | _ -> ());
              (match Rag_lib.Pg.update_task ~task_id:existing_id
                  ?description:desc_update
                  ?importance_score:imp_update
                  ?deadline:dl_update
                  ?embedding:emb_update
                  ~context_prefetched:false ~context_ready:false
                  () with
              | Ok _ ->
                  Printf.printf "[task_dedup] MERGED into %s: %s\n%!" existing_id tp.tp_title;
                  !notify_prefetch ()
              | Error e ->
                  Printf.eprintf "[task_dedup] update error: %s\n%!" e)
            end else begin
              (* Create new task *)
              let task_id = generate_task_id () in
              let prior = format_prior_resolutions ~embedding () in
              if prior <> "" then
                Printf.printf "[task_dedup] found prior resolutions (%d chars) for '%s'\n%!" (String.length prior) tp.tp_title;
              (match Rag_lib.Pg.create_task ~task_id ~title:tp.tp_title
                  ~description:tp.tp_description
                  ~importance_score:tp.tp_importance
                  ~deadline:tp.tp_deadline
                  ~embedding ~conversation_json:"[]" ~drafts_json:"[]"
                  ~prior_resolutions:prior () with
              | Ok () ->
                  (match Rag_lib.Pg.link_email_to_task ~task_id ~doc_id:ndoc ~role:"trigger" ~compressed_body:body_text () with
                  | Ok () -> ()
                  | Error e -> Printf.eprintf "[task_dedup] link error: %s\n%!" e);
                  Printf.printf "[task_dedup] NEW task %s: %s\n%!" task_id tp.tp_title;
                  !notify_prefetch ()
              | Error e ->
                  Printf.eprintf "[task_dedup] create error: %s\n%!" e)
            end
      end
    with Exit ->
      Printf.eprintf "[process_task_proposals] SKIPPED '%s' for %s (embed failed)\n%!" tp.tp_title ndoc)
  ) proposals

(*
  Attachment extraction and summarization

  Attachments are extracted from MIME leaf parts, decoded (base64/QP),
  converted to text (pdftotext, pandoc, or strip_html), and optionally
  summarized by Ollama.  Results are stored as JSON in metadata and
  rendered into the index string as ATTACHMENTS (summaries).
*)
let run_shell_capture_stdout (cmd : string) : string option =
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 4096 in
    (try
       while true do
         let line = input_line ic in
         Buffer.add_string buf line;
         Buffer.add_char buf '\n'
       done
     with End_of_file -> ());
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> Some (Buffer.contents buf)
    | _ -> None
  with _ -> None

let decode_part_body (headers : (string, string) Hashtbl.t) (body : string) : string option =
  let cte = String.lowercase_ascii (header_or_empty headers "content-transfer-encoding") |> String.trim in
  let raw = body |> String.trim in
  if raw = "" then None
  else if cte = "base64" then decode_base64 raw
  else if cte = "quoted-printable" then Some (decode_quoted_printable raw)
  else Some raw

(* Heuristic: does this byte string look like readable text (not binary)?
   Scans up to the first 4096 bytes; returns false if >5% are non-text
   control characters (ASCII 0x00-0x08, 0x0E-0x1F except \t \n \r). *)
let looks_like_text (s : string) : bool =
  let len = min (String.length s) 4096 in
  if len = 0 then false
  else
    let bad = ref 0 in
    for i = 0 to len - 1 do
      let c = Char.code s.[i] in
      if c < 0x09 || (c > 0x0D && c < 0x20) || c = 0x7F then incr bad
    done;
    Float.of_int !bad /. Float.of_int len < 0.05

let attachment_text_of_part ~(filename : string) ~(content_type : string) ~(decoded : string) : string option =
  let ct_lower = String.lowercase_ascii (String.trim content_type) in
  let decoded =
    if String.length decoded > !rag_attachment_max_bytes then String.sub decoded 0 !rag_attachment_max_bytes
    else decoded
  in
  if starts_with "text/plain" ct_lower then Some (sanitize_utf8 decoded |> String.trim)
  else if starts_with "text/html" ct_lower then Some (strip_html decoded |> sanitize_utf8 |> String.trim)
  else if !rag_attachment_use_pdftotext && (ends_with ".pdf" (String.lowercase_ascii filename) || starts_with "application/pdf" ct_lower)
  then (
    try
      let tmp = Filename.temp_file "rag_att_" ".pdf" in
      let oc = open_out_bin tmp in
      output_string oc decoded;
      close_out oc;
      let cmd = "pdftotext -layout " ^ Filename.quote tmp ^ " -" in
      let out = run_shell_capture_stdout cmd in
      (try Sys.remove tmp with _ -> ());
      Option.map (fun s -> sanitize_utf8 s |> String.trim) out
    with _ -> None)
  else if !rag_attachment_use_pandoc && (
    ends_with ".docx" (String.lowercase_ascii filename)
    || ends_with ".md" (String.lowercase_ascii filename)
    || ends_with ".rtf" (String.lowercase_ascii filename)
    || ends_with ".html" (String.lowercase_ascii filename)
  ) then (
    try
      let tmp = Filename.temp_file "rag_att_" "" in
      let oc = open_out_bin tmp in
      output_string oc decoded;
      close_out oc;
      let cmd = "pandoc -t plain --wrap=none " ^ Filename.quote tmp in
      let out = run_shell_capture_stdout cmd in
      (try Sys.remove tmp with _ -> ());
      Option.map (fun s -> sanitize_utf8 s |> String.trim) out
    with _ -> None)
  else if looks_like_text decoded then Some (sanitize_utf8 decoded |> String.trim)
  else None

let summarize_attachment ~client ~sw ~(filename : string) ~(text : string) : string option =
  if (not !rag_attachment_summarize) || String.trim text = "" then None
  else
    let system_prompt =
      get_prompt "compress_attachment"
        ~default:"Summarize an email attachment. Preserve key facts. Output plain text only."
        ~vars:[("{{filename}}", filename); ("{{max_chars}}", string_of_int !rag_attachment_max_chars)]
    in
    let result = summarize_to_fit ~client ~sw ~system_prompt
      ~max_input_chars:!rag_attachment_max_input_chars
      ~max_chars:!rag_attachment_max_chars
      ~label:(Printf.sprintf "attachment[%s]" filename)
      text
    in
    let result = String.trim result in
    if result = "" then None else Some result

(* Extract raw attachment texts without LLM summarization — for evidence budget computation. *)
let extract_attachment_texts_raw ~(raw : string) : (string * string) list =
  let parts = collect_mime_leaf_parts raw in
  parts
  |> List.filter_map (fun p ->
         if not (is_attachment_part p.headers) then None
         else
           let filename =
             match filename_of_part_headers p.headers with
             | Some s -> s
             | None -> "attachment"
           in
           let ct = header_or_empty p.headers "content-type" in
           match decode_part_body p.headers p.body with
           | None -> None
           | Some decoded -> (
               match attachment_text_of_part ~filename ~content_type:ct ~decoded with
               | None -> None
               | Some text ->
                   let text = String.trim text in
                   if text = "" then None
                   else Some (filename, text)))

let attachment_summaries_of_raw ~client ~sw ~(raw : string) : Yojson.Safe.t list =
  let parts = collect_mime_leaf_parts raw in
  let items =
    parts
    |> List.filter_map (fun p ->
           if not (is_attachment_part p.headers) then None
           else
             let filename =
               match filename_of_part_headers p.headers with
               | Some s -> s
               | None -> "attachment"
             in
             let ct = header_or_empty p.headers "content-type" in
             match decode_part_body p.headers p.body with
             | None -> None
             | Some decoded -> (
                 match attachment_text_of_part ~filename ~content_type:ct ~decoded with
                 | None -> None
                 | Some text ->
                     let text = String.trim text in
                     if text = "" then None
                     else
                       match summarize_attachment ~client ~sw ~filename ~text with
                       | None -> None
                       | Some summary ->
                           Some
                             (`Assoc
                               [ ("filename", `String (sanitize_utf8 filename))
                               ; ("summary", `String (sanitize_utf8 summary))
                               ])))
  in
  if List.length items > !rag_attachment_max_attachments then take !rag_attachment_max_attachments items
  else items

let format_attachment_summaries_for_text (summaries : Yojson.Safe.t list) : string =
  let lines =
    summaries
    |> List.filter_map (function
         | `Assoc kv ->
             let fn =
               match List.assoc_opt "filename" kv with
               | Some (`String s) -> String.trim s
               | _ -> ""
             in
             let sm =
               match List.assoc_opt "summary" kv with
               | Some (`String s) -> String.trim s
               | _ -> ""
             in
             if fn = "" || sm = "" then None else Some (Printf.sprintf "- %s\n%s" fn sm)
         | _ -> None)
  in
  if lines = [] then "" else "ATTACHMENTS (summaries):\n" ^ String.concat "\n\n" lines

let debug_retrieval_enabled () : bool =
  !rag_debug_retrieval

type chat_message =
  { role : string
  ; content : string
  }

(*
  Session state

  Each session_id maps to a session_state holding:
  - tail: the most recent user/assistant turns (kept short to limit prompt growth)
  - history_summary: rolling summary of older conversation (with [Email N]
    references resolved to inline "(email from X re: Y)" by the summarizer)

  The goal is continuity without repeatedly sending entire historical evidence.
*)
type session_state =
  { mu : Eio.Mutex.t
  ; mutable history_summary : string
  ; mutable tail : chat_message list
  ; mutable user_name : string
  }

type pending_query =
  { mu : Eio.Mutex.t
  ; session_id : string
  ; question : string
      (** The user's original, verbatim question.  Used for:
          - the no-evidence prompt path (no retrieved emails, so no ambiguity)
          - storing the user turn in session tail (preserves the user's words) *)
  ; resolved_question : string
      (** Contextually rewritten version of the question produced by
          rewrite_queries_for_retrieval.  Pronouns, relative references like
          "the second email" or "that bug" are resolved into self-contained
          form.  Used for:
          - building search queries (better retrieval)
          - the WITH-evidence prompt path: because retrieved emails are
            inserted BEFORE the question in the final LLM prompt, an
            anaphoric reference like "the second email" would be
            misinterpreted as referring to the second *retrieved* email
            rather than the second email from the previous assistant answer.
            The resolved_question avoids this ambiguity.
          - select_relevant_sources (deciding which emails to rehydrate)
          CAVEAT: the rewrite LLM can fail and produce garbage (e.g. "...").
          The no-evidence path uses p.question as a safe fallback. *)
  ; mutable message_ids : string list
  ; mutable sources_json : Yojson.Safe.t
  ; evidence_by_id : (string, string) Hashtbl.t
  ; llm_calls : Yojson.Safe.t list
      (** Accumulated log of EVERY LLM call made during this request.
          Each entry is a JSON object:
            { "label": "<call-site name>",
              "model": "<model used>",
              "messages": [ ... the messages sent ... ],
              "response": "<raw LLM response>" }
          Populated during /query (rewrite, select_evidence) and
          /query/complete (summarize, chat).  Returned in the
          /query/complete response so the quality harness can inspect
          every prompt sent to every LLM. *)
  }

let session_tbl : (string, session_state) Hashtbl.t = Hashtbl.create 64
let session_tbl_mu : Eio.Mutex.t = Eio.Mutex.create ()

let pending_tbl : (string, pending_query) Hashtbl.t = Hashtbl.create 64
let pending_tbl_mu : Eio.Mutex.t = Eio.Mutex.create ()

(* Pending task-chat retrieval: caches state between [RETRIEVE] detection and
   body upload + re-prompt.  Keyed by request_id. *)
type pending_task_retrieval =
  { task_id : string
  ; user_message : string
  ; chat_model : string
  ; message_ids : string list            (* doc_ids the LLM selected for rehydration *)
  ; sources_json : Yojson.Safe.t         (* full kNN results for debug *)
  ; evidence_by_id : (string, string) Hashtbl.t  (* doc_id -> compressed_body, filled by /task/chat_bodies *)
  ; created_at : float
  } [@@warning "-69"]

let task_retrieval_tbl : (string, pending_task_retrieval) Hashtbl.t = Hashtbl.create 16
let task_retrieval_mu : Eio.Mutex.t = Eio.Mutex.create ()

(* Progress tracking for the query UI — lightweight phase labels keyed by session_id. *)
let progress_tbl : (string, string) Hashtbl.t = Hashtbl.create 64
let set_progress (session_id : string) (phase : string) =
  if String.trim session_id <> "" then Hashtbl.replace progress_tbl session_id phase
let clear_progress (session_id : string) =
  Hashtbl.remove progress_tbl session_id

let fresh_request_id (session_id : string) (question : string) : string =
  Digest.to_hex
    (Digest.string (session_id ^ "|" ^ question ^ "|" ^ string_of_float (Unix.gettimeofday ())))

let get_or_create_session (session_id : string) : session_state =
  Eio.Mutex.use_rw ~protect:true session_tbl_mu (fun () ->
    match Hashtbl.find_opt session_tbl session_id with
    | Some s -> s
    | None ->
        let s =
          { mu = Eio.Mutex.create ()
          ; history_summary = ""
          ; tail = []
          ; user_name = ""
          }
        in
        Hashtbl.replace session_tbl session_id s;
        s)

let trim_to_max (s : string) (max_len : int) : string =
  if max_len <= 0 then ""
  else if String.length s <= max_len then s
  else String.sub s 0 max_len

let render_messages (msgs : chat_message list) : string =
  msgs
  |> List.map (fun m ->
         let role = String.lowercase_ascii (String.trim m.role) in
         let label =
           if role = "assistant" then "Assistant"
           else if role = "system" then "System"
           else "User"
         in
         Printf.sprintf "%s: %s" label (String.trim m.content))
  |> String.concat "\n"

(* Extract cited [Email N] indices from LLM answer, renumber sequentially,
   and build a cited-only recap.  Returns (renumbered_answer, cited_recap).
   Uses a simple character-level scan (no external regex library needed). *)
let renumber_cited_sources ~(answer : string) ~(sources_json : Yojson.Safe.t) : (string * string) =
  let sources_list = match sources_json with `List xs -> xs | _ -> [] in
  let n_sources = List.length sources_list in
  let prefix = "[Email " in
  let plen = String.length prefix in
  (* Scan for all [Email N] occurrences, return list of (start, end_, orig_1based). *)
  let find_citations text =
    let len = String.length text in
    let results = ref [] in
    let i = ref 0 in
    while !i <= len - plen - 2 do (* at least "[Email N]" = plen + 1 digit + 1 bracket *)
      if String.sub text !i plen = prefix then (
        let j = ref (!i + plen) in
        while !j < len && text.[!j] >= '0' && text.[!j] <= '9' do incr j done;
        if !j > !i + plen && !j < len && text.[!j] = ']' then (
          let num_str = String.sub text (!i + plen) (!j - !i - plen) in
          (try
             let n = int_of_string num_str in
             results := (!i, !j + 1, n) :: !results
           with _ -> ());
          i := !j + 1)
        else i := !i + 1)
      else i := !i + 1
    done;
    List.rev !results
  in
  let citations = find_citations answer in
  (* Collect unique cited 0-based indices in order of first appearance. *)
  let cited_indices = ref [] in
  let seen = Hashtbl.create 16 in
  List.iter (fun (_start, _end, orig_n) ->
    let idx = orig_n - 1 in
    if idx >= 0 && idx < n_sources && not (Hashtbl.mem seen idx) then (
      Hashtbl.replace seen idx (List.length !cited_indices + 1);
      cited_indices := idx :: !cited_indices)
  ) citations;
  let cited_indices = List.rev !cited_indices in
  (* Renumber [Email N] in the answer text. *)
  let buf = Buffer.create (String.length answer) in
  let last = ref 0 in
  List.iter (fun (start, end_, orig_n) ->
    let idx = orig_n - 1 in
    Buffer.add_string buf (String.sub answer !last (start - !last));
    (match Hashtbl.find_opt seen idx with
     | Some new_n -> Buffer.add_string buf (Printf.sprintf "[Email %d]" new_n)
     | None -> Buffer.add_string buf (String.sub answer start (end_ - start)));
    last := end_
  ) citations;
  Buffer.add_string buf (String.sub answer !last (String.length answer - !last));
  let renumbered = Buffer.contents buf in
  (* Build cited-only recap with renumbered labels and full metadata. *)
  let get_field name = function `Assoc kv -> List.assoc_opt name kv | _ -> None in
  let get_md_str md key = match get_field key md with Some (`String s) -> String.trim s | _ -> "" in
  let get_md_int md key = match get_field key md with Some (`Int n) -> Some n | _ -> None in
  let get_md_bool md key = match get_field key md with Some (`Bool b) -> Some b | _ -> None in
  let get_md_attachments md =
    match get_field "attachments" md with
    | Some (`List ys) ->
        ys |> List.filter_map (function
          | `String s when String.trim s <> "" -> Some (String.trim s)
          | _ -> None)
    | _ -> []
  in
  let recap_lines =
    List.mapi (fun new_i orig_idx ->
      let v = List.nth sources_list orig_idx in
      let md = match get_field "metadata" v with Some m -> m | _ -> `Assoc [] in
      let date_ = get_md_str md "date" in
      let from_ = get_md_str md "from" in
      let to_ = get_md_str md "to" in
      let cc_ = get_md_str md "cc" in
      let subject = get_md_str md "subject" in
      let atts = get_md_attachments md in
      let action = get_md_int md "action_score" in
      let importance = get_md_int md "importance_score" in
      let reply_by = get_md_str md "reply_by" in
      let processed = get_md_bool md "processed" in
      let triage_parts = ref [] in
      (match action, importance with
       | Some a, Some imp ->
           triage_parts := !triage_parts @ [ Printf.sprintf "action_required=%d/100 importance=%d/100" a imp ]
       | _ -> ());
      let rb_display = if reply_by = "" || reply_by = "none" then "none" else reply_by in
      triage_parts := !triage_parts @ [ Printf.sprintf "reply_by=%s" rb_display ];
      triage_parts := !triage_parts @ [ Printf.sprintf "processed=%b" (processed = Some true) ];
      let parts =
        [ Printf.sprintf "[Email %d]" (new_i + 1)
        ; Printf.sprintf "date=%s" date_
        ; Printf.sprintf "from=%s" from_
        ]
        @ (if String.trim to_ <> "" then [ Printf.sprintf "to=%s" to_ ] else [])
        @ (if String.trim cc_ <> "" then [ Printf.sprintf "cc=%s" cc_ ] else [])
        @ [ Printf.sprintf "subject=%s" subject ]
        @ (if atts <> [] then [ Printf.sprintf "attachments=[%s]" (String.concat "; " atts) ] else [])
        @ (if !triage_parts <> [] then [ String.concat " " !triage_parts ] else [])
      in
      String.concat " " parts
    ) cited_indices
  in
  let recap = String.concat "\n" recap_lines in
  (renumbered, recap)


(*
  Summarization via Ollama

  This is a secondary use of the LLM, separate from final answer generation.
  It compresses older conversation turns into a rolling history_summary,
  resolving [Email N] citations to inline references so the summary is
  self-contained.
*)
let call_ollama_summarize ~client ~sw ~(text : string) ~(target_chars : int)
    : string option =
  let instr =
    get_prompt "conversation_summary" ~default:"Summarize the following conversation for context. Preserve key facts and identifiers. Do not invent." ~vars:[]
  in
  let messages =
    [ `Assoc [ ("role", `String "system"); ("content", `String (instr ^ Printf.sprintf " Target length: at most %d characters. Output plain text." target_chars)) ]
    ; `Assoc [ ("role", `String "user"); ("content", `String text) ]
    ]
  in
  match ollama_chat ~client ~sw ~label:"session_summary" ~stats:stats_chat_session ~messages () with
  | Ok s -> Some (trim_to_max (String.trim s) target_chars)
  | Error _ -> None

let maybe_summarize_session ~client ~sw (s : session_state) : unit =
  let history_max = 12000 in
  let history_trigger = int_of_float (0.8 *. float_of_int history_max) in
  let history_target = int_of_float (0.6 *. float_of_int history_max) in
  let keep_recent_msgs = 10 in

  let tail_text = render_messages s.tail in
  let combined_history =
    if String.trim s.history_summary = "" then tail_text
    else s.history_summary ^ "\n\n" ^ tail_text
  in
  if String.length combined_history > history_trigger && List.length s.tail > keep_recent_msgs then (
    let to_keep = take_last keep_recent_msgs s.tail in
    let to_summarize = drop_last keep_recent_msgs s.tail in
    let prefix =
      if String.trim s.history_summary = "" then render_messages to_summarize
      else s.history_summary ^ "\n\n" ^ render_messages to_summarize
    in
    match call_ollama_summarize ~client ~sw ~text:prefix ~target_chars:history_target with
    | Some summary ->
        s.history_summary <- trim_to_max summary history_target;
        s.tail <- to_keep
    | None -> ())

(*
  Task conversation lifecycle (Phase E)

  Rolling summary: when conversation tail exceeds a threshold, compress
  older turns into history_summary via LLM.

  Archival: on completion/dismissal, compress full conversation to notes,
  clear conversation + history_summary.
*)
let render_json_messages (msgs : Yojson.Safe.t list) : string =
  msgs
  |> List.map (fun m ->
    let kv = match m with `Assoc kv -> kv | _ -> [] in
    let role = match List.assoc_opt "role" kv with Some (`String s) -> s | _ -> "user" in
    let content = match List.assoc_opt "content" kv with Some (`String s) -> s | _ -> "" in
    let label = match String.lowercase_ascii role with
      | "assistant" -> "Assistant" | "system" -> "System" | _ -> "User"
    in
    Printf.sprintf "%s: %s" label (String.trim content))
  |> String.concat "\n"

let maybe_summarize_task_conversation ~client ~sw
    ~(task_id : string) ~(conversation : Yojson.Safe.t list)
    ~(history_summary : string) () : unit =
  let history_max = 12000 in
  let history_trigger = int_of_float (0.8 *. float_of_int history_max) in
  let history_target = int_of_float (0.6 *. float_of_int history_max) in
  let keep_recent = 10 in
  let n = List.length conversation in
  let tail_text = render_json_messages conversation in
  let combined =
    if String.trim history_summary = "" then tail_text
    else history_summary ^ "\n\n" ^ tail_text
  in
  if String.length combined > history_trigger && n > keep_recent then begin
    let to_keep = List.filteri (fun i _ -> i >= n - keep_recent) conversation in
    let to_summarize = List.filteri (fun i _ -> i < n - keep_recent) conversation in
    let prefix =
      if String.trim history_summary = "" then render_json_messages to_summarize
      else history_summary ^ "\n\n" ^ render_json_messages to_summarize
    in
    match call_ollama_summarize ~client ~sw ~text:prefix ~target_chars:history_target with
    | Some summary ->
        let new_summary = trim_to_max summary history_target in
        (match Rag_lib.Pg.update_task ~task_id
            ~history_summary:new_summary
            ~conversation_json:(Yojson.Safe.to_string (`List to_keep))
            () with
        | Ok _ ->
            Printf.printf "[task_lifecycle] summarized %d turns for task %s (%d chars → %d chars)\n%!"
              (List.length to_summarize) task_id (String.length prefix) (String.length new_summary)
        | Error e ->
            Printf.eprintf "[task_lifecycle] summary update error: %s\n%!" e)
    | None ->
        Printf.eprintf "[task_lifecycle] summarize failed for task %s\n%!" task_id
  end

(* Background fiber: generate symbolic rule + template emails for a newly created memory.
   Called from task_chat [MEMORY] marker handler. *)
let generate_memory_rule_and_templates ~client ~sw
    ~(memory_id : string) ~(memory_text : string)
    ~(trigger_doc_ids : string list) () : unit =
  Printf.printf "[memory_bg] starting rule+template generation for %s\n%!" memory_id;
  (* --- Phase A: Generate symbolic rule via LLM with iterative validation --- *)
  let max_retries = !memory_rule_max_retries in
  let rule_system =
    get_prompt "memory_rule_extract"
      ~default:{|You are a rule extraction assistant. Given a user memory (a natural language instruction about how to handle certain emails), extract a symbolic rule as a JSON object using MongoDB-style query syntax.

Available fields: sender, recipient, cc, bcc, subject, date, attachments
Available operators: contains, not_contains, equals, not_equals, matches (regex), starts_with, ends_with, is_empty, is_not_empty
Combinators: $and (array), $or (array), $not (object)

Leaf format: {"field": "<field>", "op": "<operator>", "value": "<value>"}
Combinator format: {"$and": [<expr>, ...]}, {"$or": [<expr>, ...]}, {"$not": <expr>}

If no clear rule can be extracted (the memory is too general or abstract), respond with exactly: null

Otherwise respond with ONLY the JSON rule object, no explanation.|}
      ~vars:[]
  in
  let rec try_rule attempt prev_error =
    if attempt > max_retries then begin
      Printf.printf "[memory_bg] rule extraction failed after %d retries for %s\n%!" max_retries memory_id
    end else begin
      let user_msg =
        let base = Printf.sprintf "MEMORY TEXT:\n%s" memory_text in
        match prev_error with
        | None -> base
        | Some err -> Printf.sprintf "%s\n\nPREVIOUS ATTEMPT FAILED VALIDATION:\n%s\nPlease fix the rule." base err
      in
      let messages : Yojson.Safe.t list =
        [ `Assoc [ ("role", `String "system"); ("content", `String rule_system) ]
        ; `Assoc [ ("role", `String "user"); ("content", `String user_msg) ]
        ] in
      match ollama_chat ~client ~sw ~label:"memory_rule" ~messages () with
      | Error msg ->
          Printf.eprintf "[memory_bg] rule LLM error (attempt %d): %s\n%!" attempt msg
      | Ok raw ->
          let trimmed =
            let s = String.trim raw in
            let s = if starts_with "```json" s then
              let after = String.sub s 7 (String.length s - 7) in
              if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
            else if starts_with "```" s then
              let after = String.sub s 3 (String.length s - 3) in
              if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
            else s in
            String.trim s
          in
          if trimmed = "null" || trimmed = "NULL" || trimmed = "" then
            Printf.printf "[memory_bg] no rule extracted for %s (memory too general)\n%!" memory_id
          else begin
            (* Validate JSON *)
            match (try Some (Yojson.Safe.from_string trimmed) with _ -> None) with
            | None ->
                Printf.eprintf "[memory_bg] invalid JSON (attempt %d), retrying\n%!" attempt;
                try_rule (attempt + 1) (Some "Invalid JSON syntax")
            | Some rule_json ->
                (* Basic structural validation *)
                let valid = match rule_json with
                  | `Assoc _ -> true
                  | _ -> false
                in
                if not valid then begin
                  Printf.eprintf "[memory_bg] rule not an object (attempt %d), retrying\n%!" attempt;
                  try_rule (attempt + 1) (Some "Rule must be a JSON object")
                end else begin
                  let rule_str = Yojson.Safe.to_string rule_json in
                  (match Rag_lib.Pg.update_memory ~memory_id ~rule:(Some rule_str) () with
                  | Ok _ ->
                      Printf.printf "[memory_bg] stored rule for %s: %s\n%!" memory_id
                        (truncate_chars rule_str ~max_chars:120)
                  | Error e ->
                      Printf.eprintf "[memory_bg] rule store error: %s\n%!" e)
                end
          end
    end
  in
  try_rule 1 None;

  (* --- Phase B: Generate template emails and embed them --- *)
  let template_count = !memory_template_count in
  if template_count > 0 then begin
    let template_system =
      get_prompt "memory_template_gen"
        ~default:(Printf.sprintf
          {|You are an email generation assistant. Given a user memory describing a type of email, generate %d short example emails that would trigger this memory. Each example should be realistic and distinct.

Output ONLY a JSON array of strings, where each string is a short email (headers + body). Example:
["From: alice@example.com\nTo: me@example.com\nSubject: Invoice #123\n\nPlease find attached invoice...", "From: bob@corp.com\nTo: me@example.com\nSubject: Payment reminder\n\nThis is a reminder..."]|}
          template_count)
        ~vars:[]
    in
    let user_msg = Printf.sprintf "MEMORY TEXT:\n%s" memory_text in
    let messages : Yojson.Safe.t list =
      [ `Assoc [ ("role", `String "system"); ("content", `String template_system) ]
      ; `Assoc [ ("role", `String "user"); ("content", `String user_msg) ]
      ] in
    match ollama_chat ~client ~sw ~label:"memory_template" ~messages () with
    | Error msg ->
        Printf.eprintf "[memory_bg] template LLM error: %s\n%!" msg
    | Ok raw ->
        let trimmed =
          let s = String.trim raw in
          let s = if starts_with "```json" s then
            let after = String.sub s 7 (String.length s - 7) in
            if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
          else if starts_with "```" s then
            let after = String.sub s 3 (String.length s - 3) in
            if ends_with "```" after then String.sub after 0 (String.length after - 3) else after
          else s in
          String.trim s
        in
        (try
          let templates = match Yojson.Safe.from_string trimmed with
            | `List items ->
                List.filter_map (fun j -> match j with `String s -> Some (String.trim s) | _ -> None) items
            | _ -> []
          in
          let stored = ref 0 in
          List.iter (fun template_text ->
            if String.trim template_text <> "" then begin
              match ollama_embed ~client ~sw ~task:Search_document
                  ~label:"memory_template" ~text:template_text () with
              | Ok emb ->
                  let emb = l2_normalize emb in
                  (match Rag_lib.Pg.insert_memory_template ~memory_id ~template_text ~embedding:emb with
                  | Ok () -> incr stored
                  | Error e -> Printf.eprintf "[memory_bg] template store error: %s\n%!" e)
              | Error msg ->
                  Printf.eprintf "[memory_bg] template embed error: %s\n%!" msg
            end
          ) templates;
          Printf.printf "[memory_bg] stored %d templates for %s\n%!" !stored memory_id
        with ex ->
          Printf.eprintf "[memory_bg] template parse error: %s\n%!" (Printexc.to_string ex))
  end;
  Printf.printf "[memory_bg] done for %s\n%!" memory_id

let archive_task_conversation ~client ~sw ~(task_id : string)
    ~(conversation : Yojson.Safe.t list) ~(history_summary : string)
    ~(title : string) () : unit =
  let full_text =
    let conv_text = render_json_messages conversation in
    if String.trim history_summary = "" then conv_text
    else history_summary ^ "\n\n" ^ conv_text
  in
  if String.trim full_text = "" then ()
  else
    let target_chars = 2000 in
    let system =
      get_prompt "task_archive"
        ~default:"Summarize the following task conversation into concise notes. \
          Preserve key decisions, action items, and outcomes. Third person."
        ~vars:[("{{task_title}}", title)]
    in
    let messages : Yojson.Safe.t list =
      [ `Assoc [ ("role", `String "system"); ("content", `String (system ^ Printf.sprintf " Target: at most %d characters." target_chars)) ]
      ; `Assoc [ ("role", `String "user"); ("content", `String full_text) ]
      ]
    in
    match ollama_chat ~client ~sw ~label:"task_archive" ~messages () with
    | Ok raw ->
        let notes = trim_to_max (String.trim raw) target_chars in
        (* Trim drafts to only the last entry *)
        let trimmed_drafts =
          match Rag_lib.Pg.get_task task_id with
          | Ok (Some json) ->
              let kv = match json with `Assoc kv -> kv | _ -> [] in
              (match List.assoc_opt "drafts" kv with
              | Some (`List (_ :: _ as dl)) ->
                  let last = List.nth dl (List.length dl - 1) in
                  Some (Yojson.Safe.to_string (`List [last]))
              | _ -> Some "[]")
          | _ -> None
        in
        (match Rag_lib.Pg.update_task ~task_id
            ~notes
            ~conversation_json:"[]"
            ~history_summary:""
            ?drafts_json:trimmed_drafts
            () with
        | Ok _ ->
            Printf.printf "[task_lifecycle] archived task %s (%d char notes)\n%!" task_id (String.length notes);
            (* Trim storage: delete context/style emails, clear compressed_body *)
            (match Rag_lib.Pg.trim_archived_task_storage task_id with
            | Ok () -> Printf.printf "[task_lifecycle] trimmed storage for %s\n%!" task_id
            | Error e -> Printf.eprintf "[task_lifecycle] trim storage error: %s\n%!" e)
        | Error e ->
            Printf.eprintf "[task_lifecycle] archive update error: %s\n%!" e)
    | Error e ->
        Printf.eprintf "[task_lifecycle] archive LLM error: %s\n%!" e

let request_header_or_empty (request : Http.Request.t) (name : string) : string =
  match Http.Header.get (Http.Request.headers request) name with
  | Some v -> v
  | None -> ""

(*
  Document identity

  doc_id is the stable key under which a message is stored in the index.
  Resolution order:
  1. RFC822 Message-Id header (preferred, matches Thunderbird's header)
  2. X-Thunderbird-Message-Id HTTP header (set by the add-on at /ingest time)
  3. SHA-256 digest of the raw body (fallback for headerless messages)
*)
let doc_id_of_raw (parsed_headers : (string, string) Hashtbl.t) (raw : string) : string =
  let from_rfc822 = header_or_empty parsed_headers "message-id" in
  if from_rfc822 <> "" then from_rfc822 else Digest.to_hex (Digest.string raw)

let doc_id_of_ingest (request : Http.Request.t) (parsed_headers : (string, string) Hashtbl.t)
    (raw : string) : string =
  let from_rfc822 = header_or_empty parsed_headers "message-id" in
  if from_rfc822 <> "" then from_rfc822
  else
    let from_request = request_header_or_empty request "x-thunderbird-message-id" in
    if from_request <> "" then from_request else Digest.to_hex (Digest.string raw)

(*
  Ingestion payload

  make_ingest_data constructs the index text and metadata for PostgreSQL storage.
  It includes:
  - id/doc_id: the Thunderbird message-id (preferred) or a stable hash fallback
  - metadata: lightweight fields used for UI display and prompt construction
  - text: the concatenation of headers + normalized body text, which is chunked
    and embedded.
*)
let make_ingest_data ~doc_id ~(headers : (string, string) Hashtbl.t) ~(raw : string)
    ~(body_text : string)
    : (string * Yojson.Safe.t) =
  let from_ = header_or_empty headers "from" |> decode_rfc2047 |> sanitize_utf8 in
  let to_ = header_or_empty headers "to" |> decode_rfc2047 |> sanitize_utf8 in
  let cc_ = header_or_empty headers "cc" |> decode_rfc2047 |> sanitize_utf8 in
  let bcc_ = header_or_empty headers "bcc" |> decode_rfc2047 |> sanitize_utf8 in
  let subject = header_or_empty headers "subject" |> decode_rfc2047 |> sanitize_utf8 in
  let date_ = header_or_empty headers "date" |> decode_rfc2047 |> sanitize_utf8 in
  let attachments = extract_attachment_filenames raw in
  let body_text = sanitize_utf8 body_text in

  let metadata_json =
    `Assoc
      [ ("from", `String from_)
      ; ("to", `String to_)
      ; ("cc", `String cc_)
      ; ("bcc", `String bcc_)
      ; ("subject", `String subject)
      ; ("date", `String date_)
      ; ("attachments", `List (List.map (fun f -> `String f) attachments))
      ; ("processed", `Bool false)
      ; ("ingested_at", `String (now_utc_iso8601 ()))
      ]
  in
  let attachments_line =
    if attachments = [] then "" else Printf.sprintf "\nAttachments: %s" (String.concat ", " attachments)
  in
  let text_for_index =
    Printf.sprintf
      "From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nDate: %s%s\n\n%s"
      from_ to_ cc_ bcc_ subject date_ attachments_line body_text
  in
  (text_for_index, metadata_json)

(*
  ingest_text_of_raw is a small helper used in the 2-phase query flow.

  It rebuilds the same "text_for_index"/metadata representation used at ingestion,
  but is called at /query/complete time so we can:
  - build EMAILS INDEX entries (date/from/subject), and
  - regenerate evidence text consistently with ingestion-time normalization.
*)
let ingest_text_of_raw ~(doc_id : string) ~(raw : string) : (string * Yojson.Safe.t) =
  let headers = parse_headers raw in
  let parts = extract_body_parts raw in
  let new_body = String.trim parts.new_text |> sanitize_utf8 in
  let quoted_raw = String.trim parts.quoted_text |> sanitize_utf8 in
  let quoted_capped =
    if String.trim quoted_raw = "" then ""
    else
      truncate_lines quoted_raw ~max_lines:!rag_quoted_context_max_lines
      |> truncate_chars ~max_chars:!rag_quoted_context_max_input_chars
      |> String.trim
  in
  let body_text =
    let parts = List.filter (fun s -> s <> "")
      [ (if quoted_capped = "" then "" else "QUOTED CONTEXT:\n" ^ quoted_capped)
      ; "NEW CONTENT:\n" ^ new_body
      ]
    in
    String.concat "\n\n" parts
  in
  make_ingest_data ~doc_id ~headers ~raw ~body_text

(*
  forward_ingest_raw

  Full ingestion pipeline for a single raw RFC822 message:
  - extract normalized body text
  - build a single index string including selected headers
  - chunk + embed each chunk (Ollama /api/embed)
  - store email metadata + chunk embeddings in PostgreSQL via Pg module
*)
let forward_ingest_raw ~client ~sw ~log ~(whoami : string) ~(doc_id : string)
    ~(headers : (string, string) Hashtbl.t) ~(raw : string) : (Http.Response.t * string) =
  (* Skip re-ingestion if already ingested with the same embed + triage models *)
  (match Rag_lib.Pg.ingested_models doc_id with
   | Ok (Some (em, tm, sm))
     when em = !ollama_embed_model && tm = !ollama_triage_model && sm = !ollama_summarize_model ->
       if log then
         Printf.eprintf "[ingest.skip] %s already ingested with same models (embed=%s triage=%s summarize=%s)\n%!" doc_id em tm sm;
       let body = Yojson.Safe.to_string
         (`Assoc [ ("ok", `Bool true); ("doc_id", `String doc_id); ("skipped", `Bool true)
                 ; ("reason", `String "already ingested with current models") ]) in
       let resp = Http.Response.make ~status:`OK () in
       (resp, body)
   | _ ->
  let from_ = header_or_empty headers "from" |> decode_rfc2047 |> sanitize_utf8 in
  let to_ = header_or_empty headers "to" |> decode_rfc2047 |> sanitize_utf8 in
  let cc_ = header_or_empty headers "cc" |> decode_rfc2047 |> sanitize_utf8 in
  let bcc_ = header_or_empty headers "bcc" |> decode_rfc2047 |> sanitize_utf8 in
  let subject = header_or_empty headers "subject" |> decode_rfc2047 |> sanitize_utf8 in
  let date_ = header_or_empty headers "date" |> decode_rfc2047 |> sanitize_utf8 in
  let in_reply_to = header_or_empty headers "in-reply-to" |> String.trim in
  (* Reject emails with completely empty metadata — likely encrypted/unreadable *)
  if String.trim from_ = "" && String.trim to_ = "" && String.trim subject = "" then (
    let ndoc = Rag_lib.Pg.normalize_doc_id doc_id in
    Printf.eprintf "[ingest.rejected] doc_id=%s reason=empty_metadata (from, to, subject all empty — likely encrypted)\n%!" ndoc;
    let resp = Http.Response.make ~status:`Bad_request () in
    (resp, Yojson.Safe.to_string
      (`Assoc [ ("ok", `Bool false); ("doc_id", `String doc_id)
              ; ("error", `String "email metadata is empty (from, to, subject all blank) — likely encrypted or unreadable") ])))
  else
  let parts = extract_body_parts raw in
  let new_body = String.trim parts.new_text |> sanitize_utf8 in
  let quoted_raw = String.trim parts.quoted_text |> sanitize_utf8 in
  (* Partial ingestion: body contains [ERROR:] markers (e.g. encrypted/encoded body) —
     skip triage, summarization, and embedding but still store metadata *)
  if body_text_has_error_marker new_body || body_text_has_error_marker quoted_raw then (
    let ndoc = Rag_lib.Pg.normalize_doc_id doc_id in
    Printf.printf "[ingest.partial] doc_id=%s reason=error_marker_in_body — storing metadata only\n%!" ndoc;
    let attachments = extract_attachment_filenames raw in
    let att_pg_array =
      let escaped = List.map (fun f ->
        "\"" ^ String.concat "\\\"" (String.split_on_char '"' f) ^ "\"") attachments in
      "{" ^ String.concat "," escaped ^ "}"
    in
    (match Rag_lib.Pg.upsert_email
        ~doc_id ~embed_model:!ollama_embed_model ~triage_model:!ollama_triage_model
        ~summarize_model:!ollama_summarize_model
        ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_ ~subject
        ~email_date:(parse_rfc822_to_iso8601 date_)
        ~attachments_json:att_pg_array
        ~action_score:None ~importance_score:None ~reply_by:""
        ~ingested_at:(now_utc_iso8601 ())
        ~whoami ~in_reply_to
        ~on_done:(record stats_pg_upsert) ()
    with
    | Error e ->
        Printf.eprintf "[ingest.partial.error] upsert_email: %s\n%!" e;
        let resp = Http.Response.make ~status:`Internal_server_error () in
        (resp, Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
    | Ok () ->
        Printf.printf "[ingest.partial.ok] doc_id=%s metadata_only=true\n%!" ndoc;
        let resp = Http.Response.make ~status:`OK () in
        (resp, Yojson.Safe.to_string
          (`Assoc [ ("ok", `Bool true); ("doc_id", `String doc_id)
                  ; ("partial", `Bool true)
                  ; ("reason", `String "body encrypted/unreadable — metadata only") ]))))
  else
  let attachment_summaries = attachment_summaries_of_raw ~client ~sw ~raw in
  let attachments_section = format_attachment_summaries_for_text attachment_summaries in
  let quoted_capped_untrimmed =
    if String.trim quoted_raw = "" then ""
    else
      truncate_lines quoted_raw ~max_lines:!rag_quoted_context_max_lines
      |> truncate_chars ~max_chars:!rag_quoted_context_max_input_chars
  in
  let quoted_capped = String.trim quoted_capped_untrimmed in
  let overflow_start = String.length quoted_capped_untrimmed in
  let has_overflow = overflow_start < String.length quoted_raw in
  let overflow =
    if has_overflow then
      String.sub quoted_raw overflow_start (String.length quoted_raw - overflow_start) |> String.trim
    else ""
  in
  let overflow_summary =
    if overflow = "" then None
    else summarize_quoted_context ~client ~sw ~quoted_text:overflow
  in
  let qs =
    match overflow_summary with
    | Some s when String.trim s <> "" -> "QUOTED CONTEXT (older, summarized):\n" ^ String.trim s
    | _ -> ""
  in
  let qc =
    if quoted_capped = "" then ""
    else if has_overflow then "QUOTED CONTEXT (recent):\n" ^ quoted_capped
    else "QUOTED CONTEXT:\n" ^ quoted_capped
  in
  let att = if attachments_section = "" then "" else attachments_section in
  let new_body_capped =
    summarize_to_fit ~client ~sw
      ~system_prompt:(get_prompt "compress_new_content_ingest" ~default:"Compress email body. Preserve all facts. Third person. Do not invent." ~vars:[])
      ~max_input_chars:!rag_summarize_max_input_chars
      ~max_chars:!rag_new_content_max_chars
      ~label:"new_content"
      new_body
  in
  let body_text =
    let parts = List.filter (fun s -> s <> "") [qs; qc; att; "NEW CONTENT:\n" ^ new_body_capped] in
    String.concat "\n\n" parts
  in
  let has_any_content =
    String.trim new_body <> "" || String.trim quoted_raw <> "" || String.trim attachments_section <> ""
  in

  let ndoc = Rag_lib.Pg.normalize_doc_id doc_id in
  if not has_any_content then
    Printf.printf "[ingest.note] doc_id=%s note=empty_body\n%!" ndoc;
  (
    if body_text_has_error_marker body_text then
      Printf.printf
        "[ingest.note] doc_id=%s note=body_text_contains_error_marker\n%!" ndoc;

    if log then (
      Printf.printf "\n[email being processed]\n";
      Printf.printf "From: %s\n" from_;
      Printf.printf "To: %s\n" to_;
      Printf.printf "Cc: %s\n" cc_;
      Printf.printf "Bcc: %s\n" bcc_;
      Printf.printf "Title: %s\n" subject;
      Printf.printf "Id: %s\n" doc_id;
      Printf.printf "Body:\n%s\n" body_text;
      flush stdout);

  let _index_text, _metadata_json =
    make_ingest_data ~doc_id ~headers ~raw ~body_text
  in
  let truncate_field s max_len =
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "..."
  in
  let preamble =
    Printf.sprintf "From: %s | To: %s | Subject: %s | Date: %s"
      (truncate_field from_ 80) (truncate_field to_ 120)
      (truncate_field subject 120) date_
  in
  let qs_text = match overflow_summary with
    | Some s when String.trim s <> "" -> String.trim s
    | _ -> ""
  in
  let sections =
    List.filter (fun (_, t) -> String.trim t <> "")
      [ ("quoted_context_old", qs_text)
      ; ("quoted_context", quoted_capped)
      ; ("attachments", attachments_section)
      ; ("new_content", new_body_capped)
      ]
  in
  let sectioned_chunks = chunk_sections ~preamble sections in
  let embed_one_chunk (i, section, ch) =
    let rec try_embed text attempt =
      match ollama_embed ~client ~sw ~task:Search_document ~label:"ingest" ~stats:stats_embed_ingest ~text () with
      | Ok v -> [(i, section, l2_normalize v)]
      | Error msg when is_truncation_error msg && attempt < 3 ->
          (* Split the chunk text in half (preserving the preamble prefix) and retry each half *)
          let half = String.length text / 2 in
          if half < 100 then (
            Printf.eprintf "[ingest.truncated] doc_id=%s chunk=%d section=%s chars=%d — chunk too small to split further\n%!"
              ndoc i section (String.length text);
            raise (Failure (Printf.sprintf "embedding truncated for chunk %d (%d chars) of %s — text too dense for embed model" i (String.length text) ndoc)))
          else (
            Printf.eprintf "[ingest.truncated] doc_id=%s chunk=%d section=%s chars=%d — splitting and retrying (attempt %d)\n%!"
              ndoc i section (String.length text) (attempt + 1);
            let left = String.sub text 0 half in
            let right = String.sub text half (String.length text - half) in
            try_embed left (attempt + 1) @ try_embed right (attempt + 1))
      | Error msg when is_truncation_error msg ->
          Printf.eprintf "[ingest.truncated] doc_id=%s chunk=%d section=%s chars=%d — max retries exceeded\n%!"
            ndoc i section (String.length text);
          raise (Failure (Printf.sprintf "embedding truncated for chunk %d (%d chars) of %s after %d split attempts" i (String.length text) ndoc attempt))
      | Error msg -> raise (Failure ("ollama_embed failed: " ^ msg))
    in
    try_embed ch 0
  in
  let embedded_chunks = List.concat_map embed_one_chunk sectioned_chunks in
  let attachments = extract_attachment_filenames raw in
  (* Format as PostgreSQL TEXT[] literal: {"file1.pdf","file2.xlsx"} *)
  let att_pg_array =
    let escaped = List.map (fun f ->
      "\"" ^ String.concat "\\\"" (String.split_on_char '"' f) ^ "\"") attachments in
    "{" ^ String.concat "," escaped ^ "}"
  in
  let strict_ok = not (body_text_has_error_marker body_text) in
  if not strict_ok then (
    Printf.eprintf "[ingest.strict] not recording success for doc_id=%s because body_text contains [ERROR:] markers\n%!" ndoc;
    let resp = Http.Response.make ~status:`OK () in
    (resp, {|{"ok":true,"warning":"error_markers"}|}))
  else
    match Rag_lib.Pg.upsert_email
      ~doc_id ~embed_model:!ollama_embed_model ~triage_model:!ollama_triage_model
      ~summarize_model:!ollama_summarize_model
      ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_ ~subject
      ~email_date:(parse_rfc822_to_iso8601 date_)
      ~attachments_json:att_pg_array
      ~action_score:None ~importance_score:None ~reply_by:""
      ~ingested_at:(now_utc_iso8601 ())
      ~whoami ~in_reply_to
      ~on_done:(record stats_pg_upsert) ()
    with
    | Error e ->
        Printf.eprintf "[ingest.pg.error] upsert_email: %s\n%!" e;
        let resp = Http.Response.make ~status:`Internal_server_error () in
        (resp, Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
    | Ok () ->
        match Rag_lib.Pg.insert_chunks ~doc_id ~on_done:(record stats_pg_insert) embedded_chunks with
        | Error e ->
            Printf.eprintf "[ingest.pg.error] insert_chunks: %s\n%!" e;
            let resp = Http.Response.make ~status:`Internal_server_error () in
            (resp, Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
        | Ok () ->
            Printf.printf "[ingest.ok] doc_id=%s chunks=%d\n%!" ndoc (List.length embedded_chunks);
            (* Reply-chain linking: if this is a sent email replying to a task trigger,
               link it to the task and record the actual reply content *)
            if in_reply_to <> "" then begin
              let irt_normalized = Rag_lib.Pg.normalize_doc_id in_reply_to in
              match Rag_lib.Pg.tasks_by_trigger_doc_id irt_normalized with
              | Ok task_ids when task_ids <> [] ->
                  List.iter (fun task_id ->
                    Printf.printf "[reply-link] sent email %s is a reply to trigger %s on task %s\n%!"
                      ndoc irt_normalized task_id;
                    (* Link the reply email to the task *)
                    (match Rag_lib.Pg.link_email_to_task ~task_id ~doc_id ~role:"reply"
                        ~compressed_body:new_body_capped () with
                    | Ok () ->
                        Printf.printf "[reply-link] linked reply %s to task %s\n%!" ndoc task_id
                    | Error e ->
                        Printf.eprintf "[reply-link] link error: %s\n%!" e);
                    (* Auto-mark task as done if it's still open/in_progress *)
                    (match Rag_lib.Pg.get_task task_id with
                    | Ok (Some json) ->
                        let kv = match json with `Assoc kv -> kv | _ -> [] in
                        let status = match List.assoc_opt "status" kv with Some (`String s) -> s | _ -> "" in
                        if status = "open" || status = "in_progress" then begin
                          (match Rag_lib.Pg.update_task ~task_id ~status:"done" () with
                          | Ok _ ->
                              Printf.printf "[reply-link] auto-marked task %s as done (user replied)\n%!" task_id
                          | Error e ->
                              Printf.eprintf "[reply-link] auto-done error: %s\n%!" e)
                        end
                    | _ -> ())
                  ) task_ids
              | Ok _ -> ()
              | Error e ->
                  Printf.eprintf "[reply-link] lookup error for in_reply_to=%s: %s\n%!" irt_normalized e
            end;
            (* Enqueue for async triage by the daemon (propose_tasks + process_task_proposals) *)
            if !task_auto_create then begin
              (match Rag_lib.Pg.enqueue_triage ~doc_id ~body_text ~compressed_body:new_body_capped () with
              | Ok () ->
                  Printf.printf "[ingest.enqueue] doc_id=%s queued for triage\n%!" ndoc;
                  !notify_prefetch ()
              | Error e ->
                  Printf.eprintf "[ingest.enqueue] error for %s: %s\n%!" ndoc e)
            end;
            let resp = Http.Response.make ~status:`OK () in
            (resp, {|{"ok":true}|})))

(*
  Mbox file discovery and streaming

  For bulk ingestion, the server walks the user's mail directory tree,
  identifies mbox files (those whose first 5 bytes are "From "), and
  streams messages out of them.

  The mbox streaming parser is chunk-based to handle multi-GB files
  without loading them into memory.  It emits one raw RFC822 string
  per message, correctly handling "From " line delimiters that may
  span chunk boundaries.
*)
let expand_home (p : string) : string =
  if String.length p > 0 && p.[0] = '~' then
    let home =
      match Sys.getenv_opt "HOME" with
      | Some h -> h
      | None -> ""
    in
    if p = "~" then home
    else if String.length p >= 2 && p.[1] = '/' then home ^ String.sub p 1 (String.length p - 1)
    else p
  else p

let is_mbox_file (path : string) : bool =
  try
    let st = Unix.stat path in
    if st.Unix.st_kind <> Unix.S_REG then false
    else
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = really_input_string ic 5 in
        String.length buf = 5 && String.sub buf 0 5 = "From ")
  with _ -> false

let should_skip_file (path : string) : bool =
  let lower = String.lowercase_ascii path in
  ends_with ".msf" lower || ends_with ".dat" lower || ends_with ".sqlite" lower
  || ends_with ".json" lower || ends_with ".log" lower

let rec collect_mbox_files ~recursive (acc : string list) (path : string) : string list =
  let path = expand_home path in
  try
    if Sys.is_directory path then
      if recursive then
        let entries = Sys.readdir path |> Array.to_list in
        List.fold_left
          (fun acc name ->
            let p = Filename.concat path name in
            collect_mbox_files ~recursive acc p)
          acc entries
      else acc
    else if should_skip_file path then acc
    else if is_mbox_file path then path :: acc
    else acc
  with _ -> acc

let stream_mbox_messages (path : string) ~(start_pos : int) ~(on_progress : int -> int -> unit)
    ~(on_checkpoint : int -> unit) ~(on_message : string -> unit) : unit =
  let st = Unix.stat path in
  if st.Unix.st_kind <> Unix.S_REG then (
    Printf.printf "\n[mbox] skip non-regular file=%s\n%!" path;
    ())
  else
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      (try if start_pos > 0 then seek_in ic start_pos else () with
      | _ -> ());
      let total =
        try in_channel_length ic with
        | _ -> 0
      in

      let abs_pos = ref (try pos_in ic with
      | _ -> start_pos) in
      let carry = ref "" in
      let started = ref false in
      let msg = Buffer.create 8192 in

      let flush_msg () =
        let raw = Buffer.contents msg in
        Buffer.clear msg;
        if String.trim raw <> "" then on_message raw
      in

      let is_from_line_start data i =
        i + 5 <= String.length data && String.sub data i 5 = "From "
      in

      let find_linebreak data from_idx : (int * int) option =
        let len = String.length data in
        let rec loop j =
          if j >= len then None
          else
            match String.index_from_opt data j '\n' with
            | Some nl ->
                let cr = String.index_from_opt data j '\r' in
                let pos =
                  match cr with
                  | None -> nl
                  | Some r when r < nl -> r
                  | Some _ -> nl
                in
                let lb_len =
                  if data.[pos] = '\r' && pos + 1 < len && data.[pos + 1] = '\n' then 2 else 1
                in
                Some (pos, lb_len)
            | None -> (
                match String.index_from_opt data j '\r' with
                | None -> None
                | Some r ->
                    let lb_len =
                      if r + 1 < len && data.[r + 1] = '\n' then 2 else 1
                    in
                    Some (r, lb_len))
        in
        loop from_idx
      in

      let find_next_delim_start data from_idx : int option =
        let len = String.length data in
        let rec loop j =
          match find_linebreak data j with
          | None -> None
          | Some (lb_pos, lb_len) ->
              let start = lb_pos + lb_len in
              if start + 5 <= len && String.sub data start 5 = "From " then Some start
              else loop (start + 1)
        in
        loop from_idx
      in

      let skip_delim_line data delim_start : int =
        match find_linebreak data delim_start with
        | None -> String.length data
        | Some (lb_pos, lb_len) -> lb_pos + lb_len
      in

      (* Ensure we print something immediately. *)
      on_progress !abs_pos total;

      let chunk = Bytes.create 65536 in
      let saw_any_read = ref false in
      let rec read_loop () =
        let n =
          try input ic chunk 0 (Bytes.length chunk) with
          | ex ->
              Printf.printf "\n[mbox] read error file=%s ex=%s\n%!" path
                (Printexc.to_string ex);
              raise ex
        in
        if n = 0 then (
          if (not !saw_any_read) && total > 0 && !abs_pos < total then
            Printf.printf "\n[mbox] WARNING: first read returned EOF file=%s pos=%d total=%d\n%!" path
              !abs_pos total;
          ())
        else (
          saw_any_read := true;
          abs_pos := !abs_pos + n;

          on_progress !abs_pos total;

          let chunk_s = Bytes.sub_string chunk 0 n in
          let data = !carry ^ chunk_s in
          let data_offset = !abs_pos - String.length data in
          let len = String.length data in

          let rec consume i =
            if i >= len then (
              carry := "";
              ())
            else if not !started then (
              (* We expect to start at an mbox delimiter. *)
              if i = 0 && is_from_line_start data 0 then (
                (try on_checkpoint data_offset with
                | _ -> ());
                let j = skip_delim_line data 0 in
                started := true;
                consume j)
              else (
                (* Fallback if start_pos wasn't aligned. *)
                started := true;
                consume i))
            else
              match find_next_delim_start data i with
              | Some delim_start ->
                  if delim_start > i then Buffer.add_substring msg data i (delim_start - i);
                  let checkpoint_pos = data_offset + delim_start in
                  (try on_checkpoint checkpoint_pos with
                  | _ -> ());
                  flush_msg ();
                  let j = skip_delim_line data delim_start in
                  consume j
              | None ->
                  (* No delimiter in the remainder; keep a small tail to detect boundary across chunks. *)
                  let tail_len =
                    if len - i <= 6 then len - i else 6
                  in
                  let keep_start = len - tail_len in
                  if keep_start > i then Buffer.add_substring msg data i (keep_start - i);
                  carry := String.sub data keep_start tail_len;
                  ()
          in

          consume 0;
          read_loop ())
      in

      read_loop ();

      (* Flush last buffered message to EOF. *)
      if Buffer.length msg > 0 then flush_msg ();
      (try on_checkpoint total with
      | _ -> ());
      (try on_progress total total with
      | _ -> ()))

let render_progress_bar ~width ~ratio : string =
  let w = if width < 10 then 10 else width in
  let r = if ratio < 0.0 then 0.0 else if ratio > 1.0 then 1.0 else ratio in
  let filled = int_of_float (r *. float_of_int w) in
  let buf = Bytes.make w '-' in
  for i = 0 to filled - 1 do
    Bytes.set buf i '#'
  done;
  Bytes.unsafe_to_string buf

let show_file_progress ~idx ~total_files ~path ~cur ~total_bytes ~(last_pct : int ref) : unit =
  let ratio =
    if total_bytes <= 0 then 0.0
    else float_of_int cur /. float_of_int total_bytes
  in
  let pct_int = int_of_float (ratio *. 100.0) in
  let pct_int = if pct_int < 0 then 0 else if pct_int > 100 then 100 else pct_int in
  if pct_int <> !last_pct then (
    last_pct := pct_int;
    let bar = render_progress_bar ~width:28 ~ratio:(float_of_int pct_int /. 100.0) in
    let mb x = float_of_int x /. (1024.0 *. 1024.0) in
    Printf.printf "\r[%d/%d] [%s] %3d%% (%.1f/%.1f MB)%!" idx total_files bar pct_int
      (mb cur) (mb total_bytes))

let show_scan_progress ~visited ~mbox_found ~path : unit =
  let name = Filename.basename path in
  Printf.printf "[scan] visited=%d mbox=%d %s\n%!" visited mbox_found name

let count_open_fds () : int =
  try Sys.readdir "/dev/fd" |> Array.length with
  | _ -> -1

let collect_mbox_files_with_progress ~recursive ~(on_progress : int -> int -> string -> unit)
    (roots : string list) : string list =
  let stack = ref (List.rev_map expand_home roots) in
  let files = ref [] in
  let visited = ref 0 in
  let mbox_found = ref 0 in
  let last = ref 0.0 in

  let maybe_progress path =
    let now = Unix.gettimeofday () in
    if now -. !last >= 0.25 then (
      last := now;
      on_progress !visited !mbox_found path)
  in

  while !stack <> [] do
    match !stack with
    | path :: rest ->
        stack := rest;
        incr visited;
        maybe_progress path;
        (try
           if Sys.is_directory path then
             if recursive then
               let entries = Sys.readdir path |> Array.to_list in
               let children = List.map (Filename.concat path) entries in
               stack := List.rev_append children !stack
             else ()
           else if should_skip_file path then ()
           else if is_mbox_file path then (
             incr mbox_found;
             files := path :: !files)
           else ()
         with _ -> ())
    | [] -> ()
  done;
  on_progress !visited !mbox_found "";
  List.rev !files

(*
  Bulk ingestion state persistence

  Tracks per-file progress (byte position, completion flag) so that
  a restarted bulk ingest can resume where it left off rather than
  re-processing already-seen messages.  State is saved as JSON to
  ~/.rag-o-mail/bulk_ingest_state.json (or $RAGOMAIL_BULK_STATE).
*)
type bulk_file_state =
  { size : int
  ; mtime : int
  ; last_pos : int
  ; completed : bool
  }

let bulk_state_path () : string =
  match Sys.getenv_opt "RAGOMAIL_BULK_STATE" with
  | Some p when String.trim p <> "" -> expand_home p
  | _ ->
      Filename.concat (rag_config_dir ()) "bulk_ingest_state.json"

let load_bulk_state () : (string, bulk_file_state) Hashtbl.t =
  let tbl = Hashtbl.create 128 in
  let path = bulk_state_path () in
  if Sys.file_exists path then
    try
      let json = Yojson.Safe.from_file path in
      (match json with
      | `Assoc kv ->
          List.iter
            (fun (k, v) ->
              match v with
              | `Assoc fields ->
                  let get_int name default =
                    match List.assoc_opt name fields with
                    | Some (`Int n) -> n
                    | _ -> default
                  in
                  let size = get_int "size" 0 in
                  let mtime = get_int "mtime" 0 in
                  let last_pos = get_int "last_pos" 0 in
                  let completed =
                    match List.assoc_opt "completed" fields with
                    | Some (`Bool b) -> b
                    | _ -> false
                  in
                  Hashtbl.replace tbl k { size; mtime; last_pos; completed }
              | _ -> ())
            kv
      | _ -> ())
    with _ -> ()
  else ();
  tbl

let save_bulk_state (tbl : (string, bulk_file_state) Hashtbl.t) : unit =
  let path = bulk_state_path () in
  let tmp = path ^ ".tmp" in
  let items =
    Hashtbl.to_seq tbl
    |> Seq.map (fun (k, st) ->
         ( k
         , `Assoc
             [ ("size", `Int st.size)
             ; ("mtime", `Int st.mtime)
             ; ("last_pos", `Int st.last_pos)
             ; ("completed", `Bool st.completed)
             ] ))
    |> List.of_seq
  in
  let json = `Assoc items in
  Yojson.Safe.to_file tmp json;
  Sys.rename tmp path

let safe_save_bulk_state (tbl : (string, bulk_file_state) Hashtbl.t) : bool =
  try
    save_bulk_state tbl;
    true
  with
  | ex ->
      let fds = count_open_fds () in
      Printf.printf "\n[bulk_state] save failed ex=%s open_fds=%d\n%!" (Printexc.to_string ex)
        fds;
      false

type bulk_file_progress =
  { expected : int ref
  ; processed : int ref
  ; failed : int ref
  ; scan_done : bool ref
  ; last_pos : int ref
  ; size : int
  ; mtime : int
  }

(*
  Bulk ingestion

  handle_bulk_ingest is a long-running endpoint that scans filesystem mail stores
  (e.g. mbox) and ingests messages concurrently.

  Key goals:
  - be restartable across runs (bulk_state_path)
  - show progress during scanning and per-file ingestion
  - tolerate failures in individual messages without aborting the whole run
*)
let handle_bulk_ingest ~client ~sw ~clock (body : string) : (Http.Response.t * string) =
  let json = Yojson.Safe.from_string body in
  let assoc =
    match json with
    | `Assoc kv -> kv
    | _ -> []
  in
  let get key = List.assoc_opt key assoc in
  let reset_state =
    match get "reset_state" with
    | Some (`Bool b) -> b
    | _ -> false
  in
  let recursive =
    match get "recursive" with
    | Some (`Bool b) -> b
    | _ -> true
  in
  let concurrency =
    match get "concurrency" with
    | Some (`Int n) when n > 0 && n <= 32 -> n
    | _ -> 4
  in
  let max_messages =
    match get "max_messages" with
    | Some (`Int n) when n >= 0 -> n
    | _ -> 0
  in
  let paths =
    match get "paths" with
    | Some (`List xs) ->
        xs
        |> List.filter_map (function
             | `String s -> Some s
             | _ -> None)
    | _ -> []
  in
  if paths = [] then
    let err = `Assoc [ ("error", `String "expected JSON body: { paths: [..], recursive?: bool, concurrency?: int, max_messages?: int }") ] in
    let resp = Http.Response.make ~status:`Bad_request () in
    (resp, Yojson.Safe.to_string err)
  else (
    Printf.printf "[bulk_ingest] request received (build=%s)\n%!" bulk_ingest_build_tag;
    Printf.printf "[bulk_ingest] scanning for mbox files...\n%!";

    if reset_state then (
      let p = bulk_state_path () in
      Printf.printf "[bulk_ingest] reset_state=true; deleting %s\n%!" p;
      (try Sys.remove (p ^ ".tmp") with
      | _ -> ());
      (try Sys.remove p with
      | _ -> ()));

    let state_tbl = if reset_state then Hashtbl.create 128 else load_bulk_state () in
    let state_mu = Eio.Mutex.create () in
    let last_save = ref 0.0 in
    let save_backoff_until = ref 0.0 in
    let maybe_save_state () =
      let now = Unix.gettimeofday () in
      if now < !save_backoff_until then ()
      else if now -. !last_save >= 10.0 then (
        last_save := now;
        let ok = safe_save_bulk_state state_tbl in
        if not ok then save_backoff_until := now +. 60.0)
    in

    let files =
      collect_mbox_files_with_progress ~recursive
        ~on_progress:(fun visited mbox_found path ->
          show_scan_progress ~visited ~mbox_found ~path)
        paths
    in
    Printf.printf "\n[bulk_ingest] scan complete: %d mbox files\n%!" (List.length files);
    Printf.printf "[bulk_ingest] starting ingestion...\n%!";

    let files_scanned = List.length files in
    let messages_seen = ref 0 in
    let messages_ingested = ref 0 in
    let messages_failed = ref 0 in
    let mu = Eio.Mutex.create () in

    let last_file_progress = ref (Unix.gettimeofday ()) in

    let q : [ `Stop | `Msg of string * string ] Eio.Stream.t = Eio.Stream.create 32 in
    let per_file : (string, bulk_file_progress) Hashtbl.t = Hashtbl.create 256 in

    let current_file = ref "" in
    let current_file_pos = ref 0 in
    let current_file_total = ref 0 in
    let in_file_progress = ref false in

    let maybe_print_ingest_status () =
      let now = Unix.gettimeofday () in
      if (not !in_file_progress) && now -. !last_file_progress >= 2.0 then (
        let seen, ok, failed =
          Eio.Mutex.use_rw ~protect:true mu (fun () -> (!messages_seen, !messages_ingested, !messages_failed))
        in
        Printf.printf "\n[ingest] file=%s pos=%d/%d seen=%d ok=%d failed=%d\n%!" !current_file
          !current_file_pos !current_file_total seen ok failed)
    in

    Eio.Switch.run (fun child_sw ->
      (* Heartbeat so we always show progress even if the producer blocks on backpressure. *)
      Fiber.fork ~sw:child_sw (fun () ->
        let rec loop () =
          Eio.Time.sleep clock 0.5;
          maybe_print_ingest_status ();
          loop ()
        in
        loop ());

      for _i = 1 to concurrency do
        Fiber.fork ~sw:child_sw (fun () ->
          let rec loop () =
            match Eio.Stream.take q with
            | `Stop -> ()
            | `Msg (file, raw) -> (
                try
                  let headers = parse_headers raw in
                  let doc_id = doc_id_of_raw headers raw in
                  let resp, _body =
                    forward_ingest_raw ~client ~sw ~log:false ~whoami:(String.trim !whoami) ~doc_id ~headers ~raw
                  in
                  let code = Cohttp.Code.code_of_status (Http.Response.status resp) in
                  let ok = code >= 200 && code < 300 in
                  Eio.Mutex.use_rw ~protect:true mu (fun () ->
                    if ok then incr messages_ingested else incr messages_failed);

                  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                    match Hashtbl.find_opt per_file file with
                    | None -> ()
                    | Some p ->
                        incr p.processed;
                        if not ok then incr p.failed);

                  loop ()
                with _ ->
                  Eio.Mutex.use_rw ~protect:true mu (fun () -> incr messages_failed);

                  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                    match Hashtbl.find_opt per_file file with
                    | None -> ()
                    | Some p ->
                        incr p.processed;
                        incr p.failed);

                  loop ())
          in
          loop ())
      done;

      let stop = ref false in
      let total_files = List.length files in
      files
      |> List.iteri (fun i path ->
           if not !stop then (
             let idx = i + 1 in
             current_file := Filename.basename path;

             let st = Unix.stat path in
             let size = st.Unix.st_size in
             let mtime = int_of_float st.Unix.st_mtime in

             let start_pos, skip =
               Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                 match Hashtbl.find_opt state_tbl path with
                 | Some prev
                   when prev.size = size && prev.mtime = mtime
                        && (prev.completed || prev.last_pos >= size) ->
                     (0, true)
                 | Some prev when prev.size = size && prev.mtime = mtime -> (prev.last_pos, false)
                 | _ -> (0, false))
             in

             let start_pos =
               if start_pos < 0 then 0
               else if start_pos > size then 0
               else start_pos
             in

             if skip then (
               Printf.printf "[%d/%d] %s (skipped; already completed)\n" idx total_files
                 (Filename.basename path);
               flush stdout)
             else (
               let size_mb = float_of_int size /. (1024.0 *. 1024.0) in
               Printf.printf "[%d/%d] %s size=%.1fMB start_pos=%d\n%!" idx total_files
                 (Filename.basename path) size_mb start_pos;
               last_file_progress := Unix.gettimeofday ();
               current_file_pos := start_pos;
               current_file_total := size;
               in_file_progress := true;
               let last_pct = ref (-1) in
                (* Show something immediately even if the first message is extremely large. *)
                show_file_progress ~idx ~total_files ~path ~cur:start_pos ~total_bytes:size ~last_pct;

                let p =
                  { expected = ref 0
                  ; processed = ref 0
                  ; failed = ref 0
                  ; scan_done = ref false
                  ; last_pos = ref start_pos
                  ; size
                  ; mtime
                  }
                in
                Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                  Hashtbl.replace per_file path p;
                  Hashtbl.replace state_tbl path
                    { size; mtime; last_pos = start_pos; completed = false };
                  maybe_save_state ());

                let on_checkpoint (pos : int) : unit =
                  p.last_pos := pos;
                  last_file_progress := Unix.gettimeofday ();
                  current_file_pos := pos;
                  current_file_total := size;
                  show_file_progress ~idx ~total_files ~path ~cur:pos ~total_bytes:size ~last_pct;
                  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                    Hashtbl.replace state_tbl path
                      { size; mtime; last_pos = pos; completed = false };
                    maybe_save_state ())
                in

               stream_mbox_messages path ~start_pos
                 ~on_progress:(fun cur total_bytes ->
                   last_file_progress := Unix.gettimeofday ();
                   current_file_total := total_bytes)
                 ~on_checkpoint
                 ~on_message:(fun raw ->
                   if not !stop then (
                     incr p.expected;
                     Eio.Mutex.use_rw ~protect:true mu (fun () -> incr messages_seen);
                     last_file_progress := Unix.gettimeofday ();
                     if max_messages > 0 && !messages_seen >= max_messages then stop := true;
                     if not !stop then Eio.Stream.add q (`Msg (path, raw))));

               p.scan_done := true;

                in_file_progress := false;
                Printf.printf "\n%!";
                flush stdout)));

      for _i = 1 to concurrency do
        Eio.Stream.add q `Stop
      done
    );

    Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
      Hashtbl.iter
        (fun path p ->
          if !(p.scan_done) && !(p.processed) >= !(p.expected) && !(p.failed) = 0 then
            Hashtbl.replace state_tbl path
              { size = p.size; mtime = p.mtime; last_pos = p.size; completed = true }
          else
            Hashtbl.replace state_tbl path
              { size = p.size; mtime = p.mtime; last_pos = !(p.last_pos); completed = false })
        per_file;
      ignore (safe_save_bulk_state state_tbl));

    let result =
      `Assoc
        [ ("status", `String "ok")
        ; ("files_scanned", `Int files_scanned)
        ; ("messages_seen", `Int !messages_seen)
        ; ("messages_ingested", `Int !messages_ingested)
        ; ("messages_failed", `Int !messages_failed)
        ]
    in
    let resp = Http.Response.make ~status:`OK () in
    (resp, Yojson.Safe.to_string result))

(*
  Query rewriting for multi-query retrieval.

  Given a conversation context and the user's latest question, generate
  reformulated queries to improve vector-search recall:
  1. Contextual rewrite: self-contained query with resolved pronouns/dates/refs
  2. HyDE: a short hypothetical email passage that would be a relevant result

  Returns a list of query strings (always includes the original question).
  Falls back to [question] on LLM failure or when rewriting is disabled.
*)
let rewrite_queries_for_retrieval ~client ~sw ~(question : string)
    ~(history_summary : string) ~(tail : chat_message list)
    ~(user_name : string) ?(rewrite_model : string option)
    ?(llm_log : Yojson.Safe.t list ref option)
    () : string list * string * bool * string option * string option =
  if not !rag_query_rewrite then ([question], question, false, None, None)
  else
    let has_context = String.trim history_summary <> "" || tail <> [] in
    let user_identity = build_user_identity ~long:true ~name:user_name ~email:!whoami () in
    let rewrite_field =
      if has_context then
        get_prompt_raw "query_rewrite_field" ~default:"- \"rewrite\": Rewrite the user's last question as a self-contained search query. Resolve pronouns and relative dates.\n"
      else ""
    in
    let system =
      get_prompt "query_rewrite"
        ~default:"You help search an email archive. Output a JSON object with resolved_question, hyp_from, hyp_to, hyp_subject, hyp_body fields."
        ~vars:[
          ("{{user_identity}}", user_identity);
          ("{{rewrite_field}}", rewrite_field);
          ("{{datetime_local}}", now_local_string ());
        ]
    in
    let messages : Yojson.Safe.t list =
      let base =
        [ `Assoc [ ("role", `String "system"); ("content", `String system) ] ]
      in
      let summary =
        if String.trim history_summary <> "" then
          [ `Assoc [ ("role", `String "user"); ("content", `String history_summary) ] ]
        else []
      in
      let turns =
        tail |> List.map (fun m ->
          `Assoc [ ("role", `String m.role); ("content", `String (String.trim m.content)) ])
      in
      let final =
        [ `Assoc [ ("role", `String "user"); ("content", `String question) ] ]
      in
      base @ summary @ turns @ final
    in
    let effective_rewrite_model =
      match rewrite_model with
      | Some m when String.trim m <> "" -> m
      | _ -> !ollama_rewrite_model
    in
    match ollama_chat ~client ~sw ~label:"rewrite" ~stats:stats_chat_rewrite ~model:effective_rewrite_model ~messages () with
    | Ok raw_resp ->
        if !rag_debug_ollama_chat then
          Printf.printf "\n[retrieval.rewrite.response]\n%s\n%!" raw_resp;
        (match llm_log with Some log ->
          log := !log @ [make_llm_call_entry ~label:"rewrite"
            ~model:effective_rewrite_model ~messages ~response:raw_resp]
        | None -> ());
        let raw_resp = String.trim raw_resp in
        let raw_resp =
          if starts_with "```" raw_resp then
            let lines = String.split_on_char '\n' raw_resp in
            let lines = match lines with _ :: rest -> rest | [] -> [] in
            let lines = List.rev lines in
            let lines =
              match lines with
              | l :: rest when starts_with "```" (String.trim l) -> List.rev rest
              | _ -> List.rev lines
            in
            String.concat "\n" lines
          else raw_resp
        in
        (try
           let json = Yojson.Safe.from_string raw_resp in
           let get_str key =
             match json with
             | `Assoc kv -> (
                 match List.assoc_opt key kv with
                 | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
                 | _ -> None)
             | _ -> None
           in
           let no_retrieval =
             match json with
             | `Assoc kv -> (match List.assoc_opt "no_retrieval" kv with
                 | Some (`Bool b) -> b
                 | Some (`String s) -> String.lowercase_ascii (String.trim s) = "true"
                 | _ -> false)
             | _ -> false
           in
           let resolved = match get_str "resolved_question" with
             | Some rq -> rq
             | None -> question
           in
           let queries = ref [question] in
           (* The resolved_question is often a better search query than the raw question *)
           if resolved <> question then queries := !queries @ [resolved];
           (match get_str "rewrite" with
            | Some r when r <> question && r <> resolved -> queries := !queries @ [r]
            | _ -> ());
           (* Assemble hypothetical email from individual fields *)
           let hyp_from = get_str "hyp_from" in
           let hyp_to   = get_str "hyp_to" in
           let hyp_subj = get_str "hyp_subject" in
           let hyp_body = get_str "hyp_body" in
           (match hyp_subj, hyp_body with
            | Some subj, Some body ->
                let from_line = match hyp_from with Some f -> f | None -> "someone" in
                let to_line   = match hyp_to   with Some t -> t | None -> "" in
                let hyp =
                  Printf.sprintf "From: %s\nTo: %s\nSubject: %s\n\nNEW CONTENT:\n%s"
                    from_line to_line subj body
                in
                queries := !queries @ [hyp]
            | _ ->
                Printf.eprintf "[retrieval.rewrite.warning] incomplete hypothetical (from=%b to=%b subject=%b body=%b): %s\n%!"
                  (hyp_from <> None) (hyp_to <> None) (hyp_subj <> None) (hyp_body <> None)
                  (if String.length raw_resp > 300 then String.sub raw_resp 0 300 ^ "..." else raw_resp));
           Printf.printf "[retrieval.rewrite] generated %d queries, resolved_question=%s\n%!"
             (List.length !queries)
             (if String.length resolved > 200 then String.sub resolved 0 200 ^ "..." else resolved);
           if debug_retrieval_enabled () then
             List.iteri (fun i q ->
               Printf.printf "[retrieval.rewrite.%d] %s\n%!" i
                 (if String.length q > 200 then String.sub q 0 200 ^ "..." else q))
               !queries;
           (* Safety net: if the LLM says no_retrieval but the question
              contains capitalized words (likely names) or email-related
              terms, override to force retrieval. *)
           let no_retrieval =
             if no_retrieval then
               let q = String.lowercase_ascii question in
               let has sub = contains_substring ~sub q in
               (* If the question mentions email-related actions, always retrieve *)
               let email_terms = has "email" || has "mail" || has "wrote" || has "write"
                 || has "send" || has "sent" || has "forward" || has "reply"
                 || has "message" || has "thread" || has "inbox"
                 || has "meeting" || has "calendar" || has "invite"
                 || has "attach" || has "deadline" || has "urgent" in
               (* If the question contains a capitalized multi-word name pattern,
                  it likely refers to a person/contact *)
               let has_proper_name =
                 let words = String.split_on_char ' ' question in
                 let rec check = function
                   | a :: b :: rest ->
                       let a_cap = String.length a > 1 && a.[0] >= 'A' && a.[0] <= 'Z' in
                       let b_cap = String.length b > 1 && b.[0] >= 'A' && b.[0] <= 'Z' in
                       if a_cap && b_cap then true else check (b :: rest)
                   | _ -> false
                 in
                 check words
               in
               if email_terms || has_proper_name then (
                 Printf.printf "[retrieval.rewrite] overriding no_retrieval=true (question contains email terms or proper names)\n%!";
                 false)
               else (
                 Printf.printf "[retrieval.rewrite] no_retrieval=true, skipping embedding\n%!";
                 true)
             else no_retrieval
           in
           (* Parse optional SQL filter and score_expr for query_knn.
              The LLM sees a flat "emails" table with a virtual cosine_distance column.
              We substitute cosine_distance -> the real expression before use. *)
           let expand_virtual_cols s =
             let target = "cosine_distance" and repl = "(ec.embedding <=> $1::vector)" in
             let tlen = String.length target in
             let buf = Buffer.create (String.length s) in
             let i = ref 0 in
             while !i <= String.length s - tlen do
               if String.sub s !i tlen = target then
                 (Buffer.add_string buf repl; i := !i + tlen)
               else
                 (Buffer.add_char buf s.[!i]; incr i)
             done;
             if !i < String.length s then
               Buffer.add_string buf (String.sub s !i (String.length s - !i));
             Buffer.contents buf
           in
           (* Validate filter & score_expr, retrying with LLM on errors *)
           let validated_filter, validated_score =
             let max_retries = 3 in
             let try_one kind raw validate_fn =
               match raw with
               | None -> (None, None)   (* validated_result, error *)
               | Some f ->
                   match validate_fn f with
                   | Ok v -> (Some (expand_virtual_cols v), None)
                   | Error e -> (None, Some (Printf.sprintf "%s %S: %s" kind f e))
             in
             let strip_fences s =
               if starts_with "```" s then
                 let lines = String.split_on_char '\n' s in
                 let lines = match lines with _ :: rest -> rest | [] -> [] in
                 let lines = List.rev lines in
                 let lines = match lines with
                   | l :: rest when starts_with "```" (String.trim l) -> List.rev rest
                   | _ -> List.rev lines in
                 String.concat "\n" lines
               else s
             in
             let rec try_fix attempt raw_filter raw_score conv last_resp =
               let vf, fe = try_one "filter" raw_filter Rag_lib.Sql_validate.validate_filter in
               let vs, se = try_one "score_expr" raw_score Rag_lib.Sql_validate.validate_score in
               let errors = List.filter_map Fun.id [fe; se] in
               if errors = [] then (
                 (match vf with Some f -> Printf.printf "[retrieval.rewrite] filter=%s\n%!" f | None -> ());
                 (match vs with Some s -> Printf.printf "[retrieval.rewrite] score_expr=%s\n%!" s | None -> ());
                 (vf, vs))
               else if attempt >= max_retries then (
                 Printf.eprintf "[retrieval.rewrite.warning] giving up on SQL fix after %d attempts\n%!" max_retries;
                 List.iter (fun e -> Printf.eprintf "[retrieval.rewrite.warning] %s\n%!" e) errors;
                 (vf, vs))
               else
                 let error_msg = String.concat "; " errors in
                 Printf.printf "[retrieval.rewrite] SQL validation failed (attempt %d/%d), asking LLM to fix: %s\n%!"
                   (attempt + 1) max_retries error_msg;
                 let fix_prompt =
                   "Your SQL fragments had validation errors:\n" ^ error_msg
                   ^ "\n\nPlease output ONLY a corrected JSON object with the fixed \"filter\" and/or \"score_expr\" fields."
                   ^ " Use only these allowed columns: doc_id, sender, recipient, cc, bcc, subject, email_date,"
                   ^ " attachments, action_score, importance_score, reply_by, processed, ingested_at, cosine_distance."
                   ^ " Output raw JSON only, no markdown fencing."
                 in
                 let fix_messages = conv @ [
                   `Assoc [("role", `String "assistant"); ("content", `String last_resp)];
                   `Assoc [("role", `String "user"); ("content", `String fix_prompt)];
                 ] in
                 match ollama_chat ~client ~sw ~label:"rewrite-fix"
                   ~stats:stats_chat_rewrite ~model:effective_rewrite_model
                   ~messages:fix_messages () with
                 | Error e ->
                     Printf.eprintf "[retrieval.rewrite.warning] LLM fix call failed: %s\n%!" e;
                     (vf, vs)
                 | Ok fix_resp ->
                     (match llm_log with Some log ->
                       log := !log @ [make_llm_call_entry
                         ~label:(Printf.sprintf "rewrite-fix-%d" (attempt + 1))
                         ~model:effective_rewrite_model ~messages:fix_messages ~response:fix_resp]
                     | None -> ());
                     let fix_resp = String.trim fix_resp |> strip_fences |> String.trim in
                     (try
                       let fix_json = Yojson.Safe.from_string fix_resp in
                       let get_fix_str key = match fix_json with
                         | `Assoc kv -> (match List.assoc_opt key kv with
                             | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
                             | _ -> None)
                         | _ -> None
                       in
                       let new_filter = match get_fix_str "filter", fe with
                         | Some f, Some _ -> Some f  | _, None -> raw_filter  | None, Some _ -> None in
                       let new_score = match get_fix_str "score_expr", se with
                         | Some s, Some _ -> Some s  | _, None -> raw_score  | None, Some _ -> None in
                       try_fix (attempt + 1) new_filter new_score fix_messages fix_resp
                     with _ ->
                       Printf.eprintf "[retrieval.rewrite.warning] failed to parse LLM fix response\n%!";
                       (vf, vs))
             in
             try_fix 0 (get_str "filter") (get_str "score_expr") messages raw_resp
           in
           (!queries, resolved, no_retrieval, validated_filter, validated_score)
         with _ ->
           Printf.eprintf "[retrieval.rewrite.error] failed to parse JSON response: %s\n%!"
             (if String.length raw_resp > 200 then String.sub raw_resp 0 200 ^ "..." else raw_resp);
           ([question], question, false, None, None))
    | Error err ->
        Printf.eprintf "[retrieval.rewrite.error] %s\n%!" (truncate_chars err ~max_chars:200);
        ([question], question, false, None, None)

(* Merge email entries from multiple retrievals.
   Deduplicates by doc_id, keeping the entry with the highest score.
   Returns a sorted `List of email entries, capped at top_k. *)
let merge_multi_query_sources (all_sources : Yojson.Safe.t list) (top_k : int) : Yojson.Safe.t =
  let get_doc_id = function
    | `Assoc kv -> (match List.assoc_opt "doc_id" kv with Some (`String s) -> s | _ -> "")
    | _ -> ""
  in
  let get_score = function
    | `Assoc kv -> (match List.assoc_opt "score" kv with
        | Some (`Float f) -> f
        | Some (`Int i) -> float_of_int i
        | _ -> 0.0)
    | _ -> 0.0
  in
  let best : (string, (float * Yojson.Safe.t)) Hashtbl.t = Hashtbl.create 64 in
  List.iter (fun src ->
    let doc_id = get_doc_id src in
    let score = get_score src in
    if doc_id <> "" then (
      match Hashtbl.find_opt best doc_id with
      | Some (prev_score, _) when prev_score >= score -> ()
      | _ -> Hashtbl.replace best doc_id (score, src))
  ) all_sources;
  let sorted =
    Hashtbl.to_seq best |> List.of_seq
    |> List.sort (fun (_, (s1, _)) (_, (s2, _)) -> compare s2 s1)
  in
  let capped = if top_k > 0 && List.length sorted > top_k then take top_k sorted else sorted in
  `List (List.map (fun (_, (_, src)) -> src) capped)

(* Given a list of retrieved sources (with metadata) and the user's question,
   ask the LLM which emails actually need their full body content loaded.
   Returns the filtered list of doc_ids.  Falls back to all doc_ids on error. *)
let select_relevant_sources ~client ~sw ~(resolved_question : string)
    ~(user_name : string) ?(rewrite_model : string option)
    ?(llm_log : Yojson.Safe.t list ref option)
    (sources_json : Yojson.Safe.t) : string list =
  let all_doc_ids =
    match sources_json with
    | `List ys ->
        ys |> List.filter_map (function
          | `Assoc kv -> (match List.assoc_opt "doc_id" kv with
              | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
              | _ -> None)
          | _ -> None)
    | _ -> []
  in
  let n = List.length all_doc_ids in
  if n = 0 then []
  else if n <= 3 then (
    Printf.printf "[select_evidence] %d sources ≤ 3, selecting all\n%!" n;
    all_doc_ids)
  else
  let table_lines =
    match sources_json with
    | `List ys ->
        ys |> List.mapi (fun i v ->
          match v with
          | `Assoc kv ->
              let s key = match List.assoc_opt key kv with
                | Some (`String s) -> s | _ -> ""
              in
              let md = match List.assoc_opt "metadata" kv with
                | Some (`Assoc mkv) -> mkv | _ -> []
              in
              let ms key = match List.assoc_opt key md with
                | Some (`String s) -> s | _ -> ""
              in
              let mi key = match List.assoc_opt key md with
                | Some (`Int n) -> Some (string_of_int n) | _ -> None
              in
              let score = match List.assoc_opt "score" kv with
                | Some (`Float f) -> Printf.sprintf "%.2f" f
                | _ -> "?"
              in
              let parts =
                [ Printf.sprintf "[%d]" (i + 1)
                ; Printf.sprintf "score=%s" score
                ; Printf.sprintf "from=%s" (ms "from")
                ; Printf.sprintf "to=%s" (ms "to")
                ]
                @ (let cc = ms "cc" in if String.trim cc <> "" then [Printf.sprintf "cc=%s" cc] else [])
                @ [ Printf.sprintf "subject=%s" (ms "subject")
                  ; Printf.sprintf "date=%s" (ms "date")
                  ]
                @ (match mi "action_score", mi "importance_score" with
                   | Some a, Some imp -> [Printf.sprintf "action_required=%s/100 importance=%s/100" a imp]
                   | _ -> [])
                @ (let rb = ms "reply_by" in
                   let rb_display = if String.trim rb = "" || rb = "none" then "none" else rb in
                   [Printf.sprintf "reply_by=%s" rb_display])
                @ (let atts = match List.assoc_opt "attachments" md with
                     | Some (`List xs) -> xs |> List.filter_map (function `String s -> Some s | _ -> None)
                     | _ -> []
                   in if atts <> [] then [Printf.sprintf "attachments=[%s]" (String.concat "; " atts)] else [])
                @ (let p = match List.assoc_opt "processed" md with
                     | Some (`Bool b) -> b | _ -> false
                   in [Printf.sprintf "processed=%b" p])
              in
              ignore (s "doc_id");
              String.concat " " parts
          | _ -> Printf.sprintf "[%d] (unknown)" (i + 1))
    | _ -> []
  in
  let table_str = String.concat "\n" table_lines in
  let user_identity = build_user_identity ~long:true ~name:user_name ~email:!whoami () in
  let system =
    get_prompt "select_evidence"
      ~default:"You are helping decide which retrieved emails need their full content loaded. Output a JSON array of 1-based row numbers."
      ~vars:[
        ("{{user_identity}}", user_identity);
        ("{{retrieved_email_table}}", table_str);
        ("{{resolved_question}}", resolved_question);
      ]
  in
  let user_msg =
    Printf.sprintf "Question: %s\n\nOutput ONLY a JSON array of relevant row numbers, e.g. [1, 3, 5]. No explanation."
      resolved_question
  in
  let messages : Yojson.Safe.t list =
    [ `Assoc [ ("role", `String "system"); ("content", `String system) ]
    ; `Assoc [ ("role", `String "user"); ("content", `String user_msg) ]
    ]
  in
  let effective_sel_model =
    match rewrite_model with
    | Some m when String.trim m <> "" -> m
    | _ -> !ollama_rewrite_model
  in
  match ollama_chat ~client ~sw ~label:"select_evidence" ~stats:stats_chat_select ~model:effective_sel_model ~messages () with
  | Error err ->
      (match llm_log with Some log ->
        log := !log @ [make_llm_call_entry ~label:"select_evidence"
          ~model:effective_sel_model ~messages ~response:("ERROR: " ^ err)]
      | None -> ());
      Printf.eprintf "[select_evidence.error] %s, selecting all\n%!" (truncate_chars err ~max_chars:200);
      all_doc_ids
  | Ok raw_resp ->
      (match llm_log with Some log ->
        log := !log @ [make_llm_call_entry ~label:"select_evidence"
          ~model:effective_sel_model ~messages ~response:raw_resp]
      | None -> ());
      let raw_resp = String.trim raw_resp in
      let raw_resp =
        if starts_with "```" raw_resp then
          let lines = String.split_on_char '\n' raw_resp in
          let lines = match lines with _ :: rest -> rest | [] -> [] in
          let lines = List.rev lines in
          let lines = match lines with
            | l :: rest when starts_with "```" (String.trim l) -> List.rev rest
            | _ -> List.rev lines
          in
          String.concat "\n" lines
        else raw_resp
      in
      (try
         let json = Yojson.Safe.from_string raw_resp in
         let indices = match json with
           | `List xs ->
               xs |> List.filter_map (function
                 | `Int n -> Some n
                 | `Float f -> Some (int_of_float f)
                 | `String s -> (try Some (int_of_string (String.trim s)) with _ -> None)
                 | _ -> None)
           | _ ->
               Printf.eprintf "[select_evidence.warning] expected JSON array, got: %s\n%!"
                 (if String.length raw_resp > 200 then String.sub raw_resp 0 200 ^ "..." else raw_resp);
               List.init n (fun i -> i + 1)
         in
         let selected =
           indices |> List.filter_map (fun idx ->
             if idx >= 1 && idx <= n then List.nth_opt all_doc_ids (idx - 1)
             else None)
         in
         let selected = if selected = [] then all_doc_ids else selected in
         Printf.printf "[select_evidence] %d/%d emails selected for rehydration: %s\n%!"
           (List.length selected) n (String.concat ", " selected);
         selected
       with _ ->
         Printf.eprintf "[select_evidence.error] failed to parse response: %s, selecting all\n%!"
           (if String.length raw_resp > 200 then String.sub raw_resp 0 200 ^ "..." else raw_resp);
         all_doc_ids)

(* Extract body parts from raw RFC822 and optionally compress to fit within a
   character budget.  Returns (body_text, metadata_json).
   body_text is formatted with "NEW CONTENT:", "QUOTED CONTEXT:", "ATTACHMENTS:" sections.
   If the raw content already fits within budget, no LLM compression is applied. *)
let extract_and_compress_email ~client ~sw ~(raw : string) ~(doc_id : string)
    ~(budget : int) ?(cached_md : Yojson.Safe.t option) ?summarize_model
    ?(include_quoted : bool = true) ?(include_attachments : bool = true)
    ?(llm_log : Yojson.Safe.t list ref option) () : (string * Yojson.Safe.t) =
  let _, md_from_raw = ingest_text_of_raw ~doc_id ~raw in
  let md =
    match cached_md with
    | Some (`Assoc cached_kv) ->
        (match md_from_raw with
        | `Assoc fresh_kv ->
            let tbl = Hashtbl.create 32 in
            List.iter (fun (k, v) -> Hashtbl.replace tbl k v) cached_kv;
            let override_keys = [ "from"; "to"; "cc"; "bcc"; "subject"; "attachments" ] in
            List.iter (fun (k, v) ->
              if List.mem k override_keys then
                let dominated = match v with
                  | `String s -> String.trim s = ""
                  | `List [] -> true
                  | _ -> false
                in
                if not dominated then Hashtbl.replace tbl k v)
              fresh_kv;
            `Assoc (Hashtbl.to_seq tbl |> List.of_seq)
        | _ -> `Assoc cached_kv)
    | _ -> md_from_raw
  in
  let parts = extract_body_parts raw in
  let new_body = String.trim parts.new_text |> sanitize_utf8 in
  let quoted_raw = if include_quoted then String.trim parts.quoted_text |> sanitize_utf8 else "" in
  let att_texts = if include_attachments then extract_attachment_texts_raw ~raw else [] in
  let total_raw =
    String.length new_body + String.length quoted_raw
    + List.fold_left (fun a (fn, t) -> a + String.length fn + String.length t + 30) 0 att_texts
  in
  let needs_compression = total_raw > budget in
  let format_atts_raw (atts : (string * string) list) : string =
    if atts = [] then ""
    else
      let lines = List.map (fun (fn, text) ->
        Printf.sprintf "ATTACHMENT [%s]:\n%s" fn text) atts
      in
      "\n\nATTACHMENTS:\n" ^ String.concat "\n\n" lines
  in
  if not needs_compression then (
    let quoted_section =
      if String.trim quoted_raw = "" then ""
      else "\n\nQUOTED CONTEXT:\n" ^ quoted_raw
    in
    let att_section = format_atts_raw att_texts in
    let body = "NEW CONTENT:\n" ^ new_body ^ quoted_section ^ att_section in
    (body, md))
  else (
    let new_content_budget =
      if include_quoted then budget * 2 / 3
      else budget in
    let quoted_budget = budget / 3 in
    let new_body_capped =
      summarize_to_fit ~client ~sw
        ~system_prompt:(get_prompt "compress_new_content_evidence"
          ~default:"Compress email body for Q&A evidence. Preserve all facts. Third person. Do not invent." ~vars:[])
        ~max_input_chars:!rag_summarize_max_input_chars
        ~max_chars:new_content_budget
        ~label:"evidence" ?summarize_model ?llm_log
        new_body
    in
    let quoted_section =
      if String.trim quoted_raw = "" then ""
      else
        let quoted_capped =
          summarize_to_fit ~client ~sw
            ~system_prompt:(get_prompt "compress_quoted_context_evidence"
              ~default:"Compress quoted thread context for Q&A evidence. Preserve facts. Third person. Do not invent." ~vars:[])
            ~max_input_chars:!rag_summarize_max_input_chars
            ~max_chars:quoted_budget
            ~label:"evidence-quoted" ?summarize_model ?llm_log
            quoted_raw
        in
        "\n\nQUOTED CONTEXT:\n" ^ quoted_capped
    in
    let att_budget = max 200 (budget / 6) in
    let att_section =
      if att_texts = [] then ""
      else
        let compressed_atts = List.map (fun (fn, text) ->
          let capped = summarize_to_fit ~client ~sw
            ~system_prompt:(get_prompt "compress_attachment"
              ~default:"Summarize an email attachment. Preserve key facts. Output plain text only."
              ~vars:[("{{filename}}", fn); ("{{max_chars}}", string_of_int att_budget)])
            ~max_input_chars:!rag_summarize_max_input_chars
            ~max_chars:att_budget
            ~label:(Printf.sprintf "evidence-att[%s]" fn) ?summarize_model ?llm_log
            text
          in
          Printf.sprintf "ATTACHMENT [%s]:\n%s" fn capped) att_texts
        in
        "\n\nATTACHMENTS:\n" ^ String.concat "\n\n" compressed_atts
    in
    let body = "NEW CONTENT:\n" ^ new_body_capped ^ quoted_section ^ att_section in
    (body, md))

(*
  Voice: server-side TTS (Piper) and STT (sox mic recording + Whisper)

  getUserMedia doesn't work in Thunderbird extension pages, so mic
  recording is done server-side via sox/rec.  The mic_worker runs in a
  background Thread, reads raw PCM from the rec pipe, performs VAD
  (RMS threshold), and transcribes speech segments via the Whisper
  server.  Session state is protected by a stdlib Mutex.
*)

type voice_session = {
  mutable text : string;
  mutable done_ : bool;
  mutable stop : bool;
  ts : float;
}

let voice_sessions : (string, voice_session) Hashtbl.t = Hashtbl.create 16
let voice_mu = Mutex.create ()

let voice_cleanup_old () =
  let now = Unix.gettimeofday () in
  Mutex.lock voice_mu;
  let expired = Hashtbl.fold (fun k v acc -> if now -. v.ts > 300. then k :: acc else acc) voice_sessions [] in
  List.iter (Hashtbl.remove voice_sessions) expired;
  Mutex.unlock voice_mu

let voice_sample_rate = 16000
let voice_chunk_samples = 4096
let voice_chunk_bytes = voice_chunk_samples * 2

let voice_raw_to_wav (raw : bytes) : bytes =
  let n = Bytes.length raw in
  let h = Bytes.create 44 in
  let w16 off v = Bytes.set_int16_le h off v in
  let w32 off v = Bytes.set_int32_le h off (Int32.of_int v) in
  Bytes.blit_string "RIFF" 0 h 0 4;
  w32 4 (36 + n);
  Bytes.blit_string "WAVE" 0 h 8 4;
  Bytes.blit_string "fmt " 0 h 12 4;
  w32 16 16;
  w16 20 1;
  w16 22 1;
  w32 24 voice_sample_rate;
  w32 28 (voice_sample_rate * 2);
  w16 32 2;
  w16 34 16;
  Bytes.blit_string "data" 0 h 36 4;
  w32 40 n;
  Bytes.cat h raw

let voice_rms (buf : bytes) (len : int) : float =
  let n = len / 2 in
  if n = 0 then 0.0
  else begin
    let sum = ref 0.0 in
    for i = 0 to n - 1 do
      let v = Bytes.get_int16_le buf (i * 2) in
      let f = Float.of_int v in
      sum := !sum +. f *. f
    done;
    sqrt (!sum /. Float.of_int n)
  end

let voice_transcribe_wav (wav_path : string) : string =
  let cmd = Printf.sprintf "curl -s -X POST %s/inference -F file=@%s -F response_format=json"
    (Filename.quote !voice_whisper_url) (Filename.quote wav_path) in
  match run_shell_capture_stdout cmd with
  | None -> ""
  | Some raw ->
      try
        match Yojson.Safe.from_string raw with
        | `Assoc kv ->
            (match List.assoc_opt "text" kv with
            | Some (`String s) -> String.trim s
            | _ -> "")
        | _ -> ""
      with _ -> ""

let voice_mic_worker (sid : string) (silence_sec : float) (stop_word : string) : unit =
  Printf.printf "[voice] mic_worker started for %s\n%!" sid;
  let ic =
    try Some (Unix.open_process_in
      (Printf.sprintf "rec -q -t raw -r %d -c 1 -b 16 -e signed-integer --endian little - 2>/dev/null"
        voice_sample_rate))
    with _ -> None
  in
  match ic with
  | None ->
      Printf.eprintf "[voice] ERROR: 'rec' (sox) not found\n%!";
      Mutex.lock voice_mu;
      (match Hashtbl.find_opt voice_sessions sid with
      | Some s -> s.text <- "[error: sox/rec not installed]"; s.done_ <- true
      | None -> ());
      Mutex.unlock voice_mu
  | Some ic ->
      let silence_chunks = max 1 (int_of_float (silence_sec *. Float.of_int voice_sample_rate /. Float.of_int voice_chunk_samples)) in
      let silence_threshold = 500.0 in
      let accumulated = Buffer.create 256 in
      let speaking = ref false in
      let silence_count = ref 0 in
      let audio_buf = Buffer.create (voice_chunk_bytes * 20) in
      let chunk = Bytes.create voice_chunk_bytes in
      let should_stop () =
        Mutex.lock voice_mu;
        let r = match Hashtbl.find_opt voice_sessions sid with
          | None -> true
          | Some s -> s.stop in
        Mutex.unlock voice_mu;
        r
      in
      let transcribe_segment () =
        if Buffer.length audio_buf > voice_chunk_bytes then begin
          let raw = Buffer.to_bytes audio_buf in
          let wav = voice_raw_to_wav raw in
          let dur = Float.of_int (Bytes.length raw) /. Float.of_int (voice_sample_rate * 2) in
          Printf.printf "[voice] Transcribing %.1fs segment...\n%!" dur;
          let tmp = Filename.temp_file "voice_seg" ".wav" in
          let oc = open_out_bin tmp in
          output_bytes oc wav;
          close_out oc;
          let text = voice_transcribe_wav tmp in
          (try Sys.remove tmp with _ -> ());
          if text <> "" then begin
            if Buffer.length accumulated > 0 then Buffer.add_char accumulated ' ';
            Buffer.add_string accumulated text;
            let acc = Buffer.contents accumulated in
            Mutex.lock voice_mu;
            (match Hashtbl.find_opt voice_sessions sid with
            | Some s -> s.text <- acc
            | None -> ());
            Mutex.unlock voice_mu;
            Printf.printf "[voice] Transcript so far: %s\n%!" acc;
            (* Check stop word — case-insensitive, ignoring trailing punctuation *)
            if stop_word <> "" then begin
              let strip_trailing_punct s =
                let len = ref (String.length s) in
                while !len > 0 && (let c = s.[!len - 1] in c = '.' || c = ',' || c = '!' || c = '?' || c = ';' || c = ':') do
                  decr len
                done;
                String.sub s 0 !len
              in
              let trimmed_lower = strip_trailing_punct (String.trim (String.lowercase_ascii acc)) in
              let sw_lower = String.lowercase_ascii stop_word in
              let sw_len = String.length sw_lower in
              let tl_len = String.length trimmed_lower in
              if tl_len >= sw_len &&
                 String.sub trimmed_lower (tl_len - sw_len) sw_len = sw_lower then begin
                (* Remove stop word (and any trailing punct) from original text *)
                let orig_trimmed = String.trim acc in
                let orig_stripped = strip_trailing_punct orig_trimmed in
                let trimmed = String.trim (String.sub orig_stripped 0 (String.length orig_stripped - sw_len)) in
                Mutex.lock voice_mu;
                (match Hashtbl.find_opt voice_sessions sid with
                | Some s -> s.text <- trimmed; s.done_ <- true
                | None -> ());
                Mutex.unlock voice_mu;
                Printf.printf "[voice] Stop word detected, done.\n%!"
              end
            end
          end
        end
      in
      (try
        let running = ref true in
        while !running && not (should_stop ()) do
          let n = try input ic chunk 0 voice_chunk_bytes with End_of_file -> 0 in
          if n < voice_chunk_bytes then
            running := false
          else begin
            let rms = voice_rms chunk n in
            if rms > silence_threshold then begin
              speaking := true;
              silence_count := 0;
              Buffer.add_bytes audio_buf (Bytes.sub chunk 0 n)
            end else if !speaking then begin
              Buffer.add_bytes audio_buf (Bytes.sub chunk 0 n);
              incr silence_count;
              if !silence_count >= silence_chunks then begin
                transcribe_segment ();
                (* Check if stop word triggered done *)
                let is_done =
                  Mutex.lock voice_mu;
                  let d = match Hashtbl.find_opt voice_sessions sid with
                    | Some s -> s.done_ | None -> true in
                  Mutex.unlock voice_mu;
                  d
                in
                if is_done then running := false;
                Buffer.clear audio_buf;
                speaking := false;
                silence_count := 0
              end
            end
          end
        done;
        (* Transcribe remaining audio *)
        if Buffer.length audio_buf > voice_chunk_bytes * 2 then begin
          transcribe_segment ()
        end
      with e ->
        Printf.eprintf "[voice] mic_worker error: %s\n%!" (Printexc.to_string e));
      ignore (Unix.close_process_in ic);
      let final = Buffer.contents accumulated in
      Mutex.lock voice_mu;
      (match Hashtbl.find_opt voice_sessions sid with
      | Some s -> s.text <- final; s.done_ <- true
      | None -> ());
      Mutex.unlock voice_mu;
      Printf.printf "[voice] mic_worker finished for %s: '%s'\n%!" sid final

let handler ~client ~sw ~clock _socket request body =
  (*
    HTTP routing

    This server is intentionally stateful:
    - sessions_tbl holds long-lived session_state by session_id
    - pending_tbl holds short-lived pending_query entries keyed by request_id

    Query endpoints implement the 2-phase flow:
    - /query: retrieval only (no Ollama chat)
    - /query/evidence: upload raw RFC822 bodies from Thunderbird
    - /query/complete: final prompt construction + Ollama chat
  *)
  let is_high_priority = match Http.Request.meth request, Http.Request.resource request with
    | `POST, "/ingest" | `POST, "/query/complete" | `POST, "/task/chat" -> true
    | _ -> false
  in
  let dispatch () =
  match Http.Request.meth request, Http.Request.resource request with
  | `GET, "/admin/timers" ->
      let entries = all_stats |> List.map (fun (name, s) ->
        `Assoc [
          ("name", `String name);
          ("count", `Int s.count);
          ("total", `Float s.total);
          ("avg", `Float (if s.count > 0 then s.total /. float_of_int s.count else 0.));
        ]) in
      let body = Yojson.Safe.to_string (`List entries) in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
  | `GET, "/admin/config" ->
      (* Return current settings.json and prompts.json content for test archival *)
      let read_file_opt path =
        if Sys.file_exists path then
          try let ic = open_in_bin path in
              let n = in_channel_length ic in
              let buf = Bytes.create n in
              really_input ic buf 0 n;
              close_in ic;
              Some (Bytes.to_string buf)
          with _ -> None
        else None
      in
      let settings_raw = match read_file_opt (settings_path ()) with Some s -> s | None -> "{}" in
      let prompts_raw = match read_file_opt (prompts_path ()) with Some s -> s | None -> "{}" in
      let body = Printf.sprintf {|{"config_dir":%s,"settings":%s,"prompts":%s}|}
        (Yojson.Safe.to_string (`String (rag_config_dir ())))
        settings_raw prompts_raw
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
  | `GET, "/admin/db_stats" ->
      (match Rag_lib.Pg.db_stats () with
      | Ok (rows, total_size) ->
          let json = `Assoc [ ("tables", `List (List.map (fun (name, count, size, desc, cat) ->
            `Assoc [ ("name", `String name)
                   ; ("rows", `Int count)
                   ; ("size", `String size)
                   ; ("description", `String desc)
                   ; ("category", `String cat) ]
          ) rows)); ("total_size", `String total_size) ] in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
      | Error e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) ~headers:json_headers ())

  | `POST, "/admin/clear_tasks" ->
      (match Rag_lib.Pg.clear_tasks () with
      | Ok () ->
          Printf.printf "[admin] cleared all task tables\n%!";
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:{|{"ok":true}|} ~headers:json_headers ()
      | Error e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) ~headers:json_headers ())

  | `POST, "/admin/clear_memories" ->
      (match Rag_lib.Pg.clear_memories () with
      | Ok () ->
          Printf.printf "[admin] cleared all memory tables\n%!";
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:{|{"ok":true}|} ~headers:json_headers ()
      | Error e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) ~headers:json_headers ())

  | `GET, "/admin/models" ->
      (* Query Ollama /api/tags for available models and return the list
         along with the current default chat model from settings. *)
      (try
         let uri = Uri.of_string (!ollama_base_url ^ "/api/tags") in
         let call () = get_uri ~client ~sw ~uri in
         let _resp, resp_body = !global_with_timeout 10.0 call in
         let all_models =
           try
             match Yojson.Safe.from_string resp_body with
             | `Assoc kv -> (
                 match List.assoc_opt "models" kv with
                 | Some (`List xs) ->
                     xs |> List.filter_map (function
                       | `Assoc mkv -> (
                           match List.assoc_opt "name" mkv with
                           | Some (`String n) -> Some n | _ -> None)
                       | _ -> None)
                 | _ -> [])
             | _ -> []
           with _ -> []
         in
         (* Classify each model by probing /api/show and checking model_info
            for a pooling_type key.  Embedding models have pooling (they reduce
            token embeddings to a single vector); chat/generation models do not. *)
         let is_embedding_model model_name =
           try
             let show_uri = Uri.of_string (!ollama_base_url ^ "/api/show") in
             let show_body = Yojson.Safe.to_string (`Assoc [("name", `String model_name)]) in
             let call () = post_json_uri ~client ~sw ~uri:show_uri ~body_json:show_body in
             let _resp, show_resp = !global_with_timeout 5.0 call in
             match Yojson.Safe.from_string show_resp with
             | `Assoc kv ->
                 (match List.assoc_opt "model_info" kv with
                  | Some (`Assoc mi) ->
                      List.exists (fun (k, _) ->
                        contains_substring ~sub:"pooling_type" k) mi
                  | _ -> false)
             | _ -> false
           with _ -> false
         in
         let embed_models, chat_models =
           List.fold_left (fun (emb, chat) name ->
             if is_embedding_model name then (name :: emb, chat)
             else (emb, name :: chat)
           ) ([], []) all_models
         in
         let embed_models = List.rev embed_models in
         let chat_models = List.rev chat_models in
         let body =
           `Assoc
             [ ("models", `List (List.map (fun s -> `String s) chat_models))
             ; ("embed_models", `List (List.map (fun s -> `String s) embed_models))
             ; ("all_models", `List (List.map (fun s -> `String s) all_models))
             ; ("default_chat_model", `String !ollama_llm_model)
             ; ("default_summarize_model", `String !ollama_summarize_model)
             ; ("default_rewrite_model", `String !ollama_rewrite_model)
             ]
           |> Yojson.Safe.to_string
         in
         Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
       with ex ->
         let body =
           `Assoc [ ("error", `String (Printexc.to_string ex)); ("models", `List []) ]
           |> Yojson.Safe.to_string
         in
         Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ())

  | `POST, "/admin/session/debug" ->
      let raw = read_all body in
      let session_id =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv -> (
              match List.assoc_opt "session_id" kv with
              | Some (`String s) -> s
              | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      if String.trim session_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing session_id\n" ()
      else
        let s = get_or_create_session session_id in
        let body =
          Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
            let tail_json =
              `List
                (List.map
                   (fun m ->
                     `Assoc
                       [ ("role", `String m.role)
                       ; ("content", `String m.content)
                       ])
                   s.tail)
            in
            `Assoc
              [ ("session_id", `String session_id)
              ; ("history_summary", `String s.history_summary)
              ; ("tail", tail_json)
              ]
            |> Yojson.Safe.to_string)
        in
        Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
  | `POST, "/admin/session/reset" ->
      let raw = read_all body in
      let session_id =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv -> (
              match List.assoc_opt "session_id" kv with
              | Some (`String s) -> s
              | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      if String.trim session_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing session_id\n" ()
      else (
        Eio.Mutex.use_rw ~protect:true session_tbl_mu (fun () -> Hashtbl.remove session_tbl session_id);
        let body =
          `Assoc [ ("status", `String "ok"); ("session_id", `String session_id) ] |> Yojson.Safe.to_string
        in
        Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ())
  | `POST, "/admin/bulk_state/reset" ->
      let p = bulk_state_path () in
      (try Sys.remove (p ^ ".tmp") with
      | _ -> ());
      (try Sys.remove p with
      | _ -> ());
      let body =
        `Assoc [ ("status", `String "ok"); ("path", `String p) ] |> Yojson.Safe.to_string
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()

  (*
    Ingestion endpoint

    Accepts a raw RFC822 message in the request body.
    This path is used both by:
    - interactive ingestion (single message), and
    - bulk ingestion tooling (which ultimately calls forward_ingest_raw per message).
  *)
  | `POST, "/ingest" ->
      let raw = read_all body in
      let headers = parse_headers raw in
      let doc_id = doc_id_of_ingest request headers raw in

      if Atomic.get ingest_paused then begin
        (* Ingestion paused — queue for later processing instead of dropping *)
        (match Rag_lib.Pg.enqueue_ingest ~doc_id ~raw () with
        | Ok () ->
            Printf.printf "[ingest] paused — queued doc_id=%s for later\n%!" doc_id;
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Printf.sprintf {|{"ok":true,"queued":true,"doc_id":"%s"}|} (String.escaped doc_id))
              ~headers:json_headers ()
        | Error msg ->
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error
              ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
              ~headers:json_headers ())
      end else begin
        let whoami = String.trim !whoami in
        if whoami = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request
            ~body:{|{"error":"whoami is required for ingestion. Set it in settings.json."}|}
            ~headers:json_headers ()
        else
        let resp, resp_body =
          forward_ingest_raw ~client ~sw ~log:true ~whoami ~doc_id ~headers ~raw
        in
        let status = Http.Response.status resp in
        Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()
      end

  (*
    Batch ingestion endpoint (async).

    Accepts a JSON array of { doc_id, raw } objects.  Each is enqueued into the
    ingest_queue table and will be processed by the background daemon (Phase -1).
    Returns immediately with the number of items queued.
  *)
  | `POST, "/ingest/batch" ->
      let raw_body = read_all body in
      (try
        let json = Yojson.Safe.from_string raw_body in
        let items = match json with
          | `Assoc kv ->
              (match List.assoc_opt "items" kv with
              | Some (`List items) -> items | _ -> [])
          | `List items -> items
          | _ -> []
        in
        let queued = ref 0 in
        let errors = ref [] in
        List.iter (fun item ->
          let kv = match item with `Assoc kv -> kv | _ -> [] in
          let doc_id = match List.assoc_opt "doc_id" kv with
            | Some (`String s) -> String.trim s | _ -> "" in
          let raw = match List.assoc_opt "raw" kv with
            | Some (`String s) -> s | _ -> "" in
          if doc_id = "" || raw = "" then
            errors := "missing doc_id or raw" :: !errors
          else begin
            match Rag_lib.Pg.enqueue_ingest ~doc_id ~raw () with
            | Ok () -> incr queued
            | Error e -> errors := e :: !errors
          end
        ) items;
        Printf.printf "[ingest/batch] queued %d item(s)\n%!" !queued;
        if !queued > 0 then !notify_prefetch ();
        let json = `Assoc
          [ ("ok", `Bool true)
          ; ("queued", `Int !queued)
          ; ("errors", `List (List.map (fun e -> `String e) (List.rev !errors)))
          ] in
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped (Printexc.to_string e)))
          ~headers:json_headers ())

  | `GET, "/ingest/status" ->
      (match Rag_lib.Pg.ingest_queue_status () with
      | Ok (pending, processing, done_, errored) ->
          let json = `Assoc
            [ ("pending", `Int pending)
            ; ("processing", `Int processing)
            ; ("done", `Int done_)
            ; ("error", `Int errored)
            ; ("total", `Int (pending + processing + done_ + errored))
            ] in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
      | Error e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
            ~headers:json_headers ())

  | `POST, "/ingest/clear_done" ->
      (match Rag_lib.Pg.clear_finished_ingests () with
      | Ok () ->
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:{|{"ok":true}|} ~headers:json_headers ()
      | Error e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
            ~headers:json_headers ())

  (*
    Evidence upload endpoint (phase 2)

    Thunderbird is responsible for retrieving full email content using its internal APIs.
    It uploads each message as message/rfc822, tagging it with:
    - X-RAG-Request-Id: correlates with the request_id returned by /query
    - X-Thunderbird-Message-Id: stable pointer used across ingestion/retrieval/UI
  *)
  | `POST, "/query/evidence" ->
      let request_id = request_header_or_empty request "x-rag-request-id" |> String.trim in
      let message_id = request_header_or_empty request "x-thunderbird-message-id" |> String.trim in
      if request_id = "" || message_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:"missing X-RAG-Request-Id or X-Thunderbird-Message-Id\n" ()
      else
        let raw = read_all body in
        let ok =
          Eio.Mutex.use_rw ~protect:true pending_tbl_mu (fun () ->
            match Hashtbl.find_opt pending_tbl request_id with
            | None -> false
            | Some p ->
                Eio.Mutex.use_rw ~protect:true p.mu (fun () ->
                  Hashtbl.replace p.evidence_by_id message_id raw;
                  true))
        in
        if not ok then
          Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"unknown request_id\n" ()
        else
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(`Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string)
            ~headers:json_headers ()

  (*
    Finalize query endpoint (phase 3)

    Preconditions:
    - /query has been called and returned request_id + message_ids
    - Thunderbird has uploaded evidence for each message_id via /query/evidence

    Responsibilities:
    - validate that all expected evidence has arrived
    - re-extract normalized text from raw emails (same logic as ingestion)
    - build final prompt (question before evidence; include SOURCES INDEX)
    - call Ollama /api/chat
    - update session state and cleanup pending state
  *)
  | `POST, "/query/complete" ->
      let raw = read_all body in
      let session_id, request_id, chat_model_override, summarize_model_override, stale_ids =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv ->
              let sid =
                match List.assoc_opt "session_id" kv with
                | Some (`String s) -> s
                | _ -> ""
              in
              let rid =
                match List.assoc_opt "request_id" kv with
                | Some (`String s) -> s
                | _ -> ""
              in
              let cm =
                match List.assoc_opt "chat_model" kv with
                | Some (`String s) -> String.trim s
                | _ -> ""
              in
              let sm =
                match List.assoc_opt "summarize_model" kv with
                | Some (`String s) -> String.trim s
                | _ -> ""
              in
              let stale =
                match List.assoc_opt "stale_ids" kv with
                | Some (`List xs) ->
                    xs |> List.filter_map (function `String s -> Some (String.trim s) | _ -> None)
                | _ -> []
              in
              (sid, rid, cm, sm, stale)
          | _ -> ("", "", "", "", [])
        with _ -> ("", "", "", "", [])
      in
      if String.trim session_id = "" || String.trim request_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing session_id/request_id\n" ()
      else (
        let pending_opt =
          Eio.Mutex.use_rw ~protect:true pending_tbl_mu (fun () -> Hashtbl.find_opt pending_tbl request_id)
        in
        match pending_opt with
        | None -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"unknown request_id\n" ()
        | Some p ->
            if p.session_id <> session_id then
              Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"request_id/session_id mismatch\n" ()
            else (
              (* Remove stale IDs (deleted/junk in Thunderbird) from the
                 pending query so they don't block evidence checks or
                 appear in the final prompt. *)
              if stale_ids <> [] then (
                let stale_set = Hashtbl.create 16 in
                List.iter (fun id -> Hashtbl.replace stale_set id true) stale_ids;
                Eio.Mutex.use_rw ~protect:true p.mu (fun () ->
                  p.message_ids <- p.message_ids |> List.filter (fun mid -> not (Hashtbl.mem stale_set mid));
                  p.sources_json <- (match p.sources_json with
                    | `List ys ->
                        `List (ys |> List.filter (fun v ->
                          match v with
                          | `Assoc kv ->
                              let did = match List.assoc_opt "doc_id" kv with
                                | Some (`String s) -> String.trim s | _ -> ""
                              in
                              not (Hashtbl.mem stale_set did)
                          | _ -> true))
                    | x -> x));
                Printf.printf "[query.complete] removed %d stale IDs\n%!" (List.length stale_ids));
              let missing =
                Eio.Mutex.use_rw ~protect:true p.mu (fun () ->
                  p.message_ids
                  |> List.filter (fun mid -> not (Hashtbl.mem p.evidence_by_id mid)))
              in
              if missing <> [] then
                let body =
                  `Assoc
                    [ ("status", `String "missing_evidence")
                    ; ("missing_message_ids", `List (List.map (fun s -> `String s) missing))
                    ]
                  |> Yojson.Safe.to_string
                in
                Cohttp_eio.Server.respond_string ~status:`Bad_request ~body ~headers:json_headers ()
              else (
                let s = get_or_create_session session_id in
                let tail_snapshot, history_summary, session_user_name =
                  Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
                    (s.tail, s.history_summary, s.user_name))
                in

                (* Mutable ref into p.llm_calls — used to accumulate LLM call
                   logs from summarize_to_fit and the final chat call. *)
                let p_llm_log = ref p.llm_calls in
                let summarize_model_opt =
                  if String.trim summarize_model_override <> "" then Some summarize_model_override else None
                in

                (* --- Evidence extraction & budget-aware compression ---
                   Pass 1: extract raw email bodies + metadata (no LLM calls).
                   Pass 2: compress only if total raw evidence exceeds the token budget. *)
                set_progress session_id "Extracting emails";
                let cached_md_by_doc : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 32 in
                (match p.sources_json with
                | `List ys ->
                    List.iter
                      (function
                        | `Assoc kv ->
                            let doc_id =
                              match List.assoc_opt "doc_id" kv with
                              | Some (`String s) -> s
                              | _ -> ""
                            in
                            let md =
                              match List.assoc_opt "metadata" kv with
                              | Some m -> m
                              | _ -> `Assoc []
                            in
                            if String.trim doc_id <> "" then Hashtbl.replace cached_md_by_doc doc_id md
                        | _ -> ())
                      ys
                | _ -> ());

                (* Collect raw RFC822 + cached metadata per doc_id (under mutex) *)
                let raw_by_mid : (string * string * Yojson.Safe.t option) list =
                  Eio.Mutex.use_rw ~protect:true p.mu (fun () ->
                    List.map (fun mid ->
                      let raw = Hashtbl.find p.evidence_by_id mid in
                      let cached_md = Hashtbl.find_opt cached_md_by_doc mid in
                      (mid, raw, cached_md))
                      p.message_ids)
                in

                (* Compute evidence char budget from num_ctx.
                   Conservative estimate: ~3 chars per token (accounts for
                   structured content, headers, special chars).
                   Reserve tokens for the model's response output. *)
                let n_emails = List.length raw_by_mid in
                let chars_per_token = 3 in
                let response_reserve_tokens = 2000 in
                let prompt_token_budget = !ollama_num_ctx - response_reserve_tokens in
                let total_char_budget = prompt_token_budget * chars_per_token in
                let overhead =
                  4000  (* system prompt + safety margin *)
                  + String.length (String.trim history_summary)
                  + List.fold_left (fun acc m -> acc + String.length m.content + 50) 0 tail_snapshot
                  + String.length p.resolved_question + 500  (* question + suffix + delimiter *)
                  + n_emails * 200  (* per-email header overhead *)
                in
                let evidence_budget = max 2000 (total_char_budget - overhead) in
                let per_email_budget = max 500 (evidence_budget / (max 1 n_emails)) in

                Printf.printf "[evidence.budget] num_ctx=%d total_budget=%d overhead=%d evidence_budget=%d per_email=%d emails=%d\n%!"
                  !ollama_num_ctx total_char_budget overhead evidence_budget per_email_budget n_emails;

                (* Extract + compress each email using the shared function *)
                let evidence_by_doc : (string, (string * Yojson.Safe.t)) Hashtbl.t = Hashtbl.create 32 in
                let ei = ref 0 in
                List.iter (fun (mid, raw, cached_md) ->
                  incr ei;
                  set_progress session_id (Printf.sprintf "Processing emails (%d/%d)" !ei n_emails);
                  let (body, md) = extract_and_compress_email ~client ~sw
                    ~raw ~doc_id:mid ~budget:per_email_budget
                    ?cached_md ?summarize_model:summarize_model_opt
                    ~llm_log:p_llm_log () in
                  Hashtbl.replace evidence_by_doc mid (body, md))
                  raw_by_mid;

                (* Build retrieval score lookup from sources_json *)
                let score_by_doc : (string, float) Hashtbl.t = Hashtbl.create 32 in
                (match p.sources_json with
                | `List ys ->
                    List.iter (function
                      | `Assoc kv ->
                          let doc_id = match List.assoc_opt "doc_id" kv with
                            | Some (`String s) -> s | _ -> ""
                          in
                          let score = match List.assoc_opt "score" kv with
                            | Some (`Float f) -> f
                            | Some (`Int n) -> Float.of_int n
                            | _ -> 0.0
                          in
                          if String.trim doc_id <> "" then Hashtbl.replace score_by_doc doc_id score
                      | _ -> ()) ys
                | _ -> ());

                (* Helper: extract a flat tuple from metadata JSON for prompt building *)
                let entry_of_md mid text md rehydrated =
                  let md_str key =
                    match md with
                    | `Assoc kv -> (
                        match List.assoc_opt key kv with
                        | Some (`String s) -> String.trim s
                        | _ -> "")
                    | _ -> ""
                  in
                  let md_int key =
                    match md with
                    | `Assoc kv -> (
                        match List.assoc_opt key kv with
                        | Some (`Int n) -> Some n
                        | _ -> None)
                    | _ -> None
                  in
                  let md_attachments =
                    match md with
                    | `Assoc kv -> (
                        match List.assoc_opt "attachments" kv with
                        | Some (`List ys) ->
                            ys |> List.filter_map (function
                              | `String s when String.trim s <> "" -> Some (String.trim s)
                              | _ -> None)
                        | _ -> [])
                    | _ -> []
                  in
                  let md_bool key =
                    match md with
                    | `Assoc kv -> (
                        match List.assoc_opt key kv with
                        | Some (`Bool b) -> Some b
                        | _ -> None)
                    | _ -> None
                  in
                  let triage_str =
                    let action = md_int "action_score" in
                    let importance = md_int "importance_score" in
                    let reply_by = md_str "reply_by" in
                    let processed = md_bool "processed" in
                    let parts = ref [] in
                    (match action, importance with
                     | Some a, Some imp ->
                         parts := !parts @ [ Printf.sprintf "action_required=%d/100 importance=%d/100" a imp ]
                     | _ -> ());
                    let rb_display = if reply_by = "" || reply_by = "none" then "none" else reply_by in
                    parts := !parts @ [ Printf.sprintf "reply_by=%s" rb_display ];
                    parts := !parts @ [ Printf.sprintf "processed=%b" (processed = Some true) ];
                    String.concat " " !parts
                  in
                  let score = match Hashtbl.find_opt score_by_doc mid with
                    | Some f -> f | None -> 0.0
                  in
                  (mid, text, md,
                   md_str "date", md_str "from", md_str "to",
                   md_str "cc", md_str "bcc", md_str "subject",
                   md_attachments, triage_str, rehydrated, score)
                in

                (* Build rehydrated entries from uploaded evidence *)
                let rehydrated_entries =
                  p.message_ids
                  |> List.map (fun mid ->
                         let text, md =
                           match Hashtbl.find_opt evidence_by_doc mid with
                           | Some (t, m) -> (t, m)
                           | None -> ("", `Assoc [])
                         in
                         entry_of_md mid text md true)
                in

                (* Build unrehydrated entries from all retrieved sources not in message_ids *)
                let rehydrated_set = Hashtbl.create 32 in
                List.iter (fun mid -> Hashtbl.replace rehydrated_set mid true) p.message_ids;
                let unrehydrated_entries =
                  match p.sources_json with
                  | `List ys ->
                      ys |> List.filter_map (fun v ->
                        match v with
                        | `Assoc kv ->
                            let doc_id = match List.assoc_opt "doc_id" kv with
                              | Some (`String s) -> s | _ -> ""
                            in
                            if Hashtbl.mem rehydrated_set doc_id then None
                            else
                              let md = match List.assoc_opt "metadata" kv with
                                | Some m -> m | None -> `Assoc []
                              in
                              Some (entry_of_md doc_id "" md false)
                        | _ -> None)
                  | _ -> []
                in

                (* Merge and sort all entries by retrieval score (best first),
                   matching the ordering used in the select_evidence prompt *)
                let all_entries =
                  (rehydrated_entries @ unrehydrated_entries)
                  |> List.sort (fun (_, _, _, _, _, _, _, _, _, _, _, _, s1) (_, _, _, _, _, _, _, _, _, _, _, _, s2) ->
                       compare s2 s1)
                in

                (* Determine which entries go into the LLM prompt:
                   rehydrated always; unrehydrated only if config says so *)
                let include_unrehydrated = !rag_include_unrehydrated_metadata in
                let prompt_entries =
                  if include_unrehydrated then all_entries
                  else all_entries |> List.filter (fun (_, _, _, _, _, _, _, _, _, _, _, rh, _) -> rh)
                in

                (* Build sources_json for the UI response: all entries with flags *)
                let orig_by_id = Hashtbl.create 32 in
                (match p.sources_json with
                | `List ys ->
                    List.iter (fun v ->
                      match v with
                      | `Assoc kv -> (
                          match List.assoc_opt "doc_id" kv with
                          | Some (`String s) -> Hashtbl.replace orig_by_id s v
                          | _ -> ())
                      | _ -> ()) ys
                | _ -> ());
                let sources_json =
                  `List (all_entries |> List.map (fun (mid, text, md, _, _, _, _, _, _, _, _, rh, _) ->
                    let base_kv =
                      match Hashtbl.find_opt orig_by_id mid with
                      | Some (`Assoc kv) -> kv
                      | _ -> [ ("doc_id", `String mid) ]
                    in
                    let kv = base_kv |> List.filter (fun (k, _) -> k <> "text" && k <> "metadata" && k <> "rehydrated" && k <> "in_prompt") in
                    let in_prompt = rh || include_unrehydrated in
                    let body_text = if rh then String.trim text else "" in
                    let extra = [ ("text", `String body_text); ("rehydrated", `Bool rh); ("in_prompt", `Bool in_prompt) ] in
                    let extra = if md <> `Assoc [] then ("metadata", md) :: extra else extra in
                    `Assoc (kv @ extra)))
                in

                let evidence_msg =
                  let lines =
                    prompt_entries
                    |> List.mapi (fun i (mid, text, _md, date_, from_, to_, cc_, bcc_, subject, atts, triage, rh, score) ->
                           let hdr_parts =
                             [ Printf.sprintf "[Email %d]" (i + 1)
                             ; Printf.sprintf "doc_id=%s" mid
                             ; Printf.sprintf "score=%.4f" score
                             ; Printf.sprintf "date=%s" date_
                             ; Printf.sprintf "from=%s" from_
                             ]
                             @ (if String.trim to_ <> "" then [ Printf.sprintf "to=%s" to_ ] else [])
                             @ (if String.trim cc_ <> "" then [ Printf.sprintf "cc=%s" cc_ ] else [])
                             @ (if String.trim bcc_ <> "" then [ Printf.sprintf "bcc=%s" bcc_ ] else [])
                             @ [ Printf.sprintf "subject=%s" subject ]
                             @ (if atts <> [] then [ Printf.sprintf "attachments=[%s]" (String.concat "; " atts) ] else [])
                             @ (if String.trim triage <> "" then [ triage ] else [])
                           in
                           let header = String.concat " " hdr_parts in
                           if rh then
                             header ^ "\n"
                             ^ (if String.trim text = "" then "(empty body)" else String.trim text)
                           else
                             header ^ "\n(metadata only — full content not loaded)")
                  in
                  String.concat "\n\n" lines
                in


                let user_identity_str = build_user_identity ~name:session_user_name ~email:!whoami () in
                let system_prompt =
                  get_prompt "chat"
                    ~default:"You are a helpful email assistant. Cite emails as [Email N]. Do not invent facts."
                    ~vars:[
                      ("{{user_identity}}", user_identity_str);
                      ("{{datetime_local}}", now_local_string ());
                      ("{{datetime_utc}}", now_utc_iso8601 ());
                    ]
                in

                (*
                  Final generation prompt construction

                  Message ordering:
                  - system: behavioral instructions + current time
                  - user: history summary (if any: compressed old turns, with
                    [Email N] refs already resolved to inline by the summarizer)
                  - tail: recent conversation turns as-is (literal content)
                  - user: evidence (retrieved email bodies)
                  - user: question + citation instructions
                *)
                let messages =
                  let base =
                    [ `Assoc [ ("role", `String "system"); ("content", `String system_prompt) ] ]
                  in
                  let with_context =
                    if String.trim history_summary = "" then base
                    else
                      base
                      @ [ `Assoc
                            [ ("role", `String "system")
                            ; ("content", `String ("Summary of earlier conversation:\n" ^ history_summary))
                            ]
                        ]
                  in
                  let with_tail =
                    with_context
                    @ List.map
                        (fun m ->
                          `Assoc
                            [ ("role", `String m.role)
                            ; ("content", `String m.content)
                            ])
                        tail_snapshot
                  in
                  if String.trim evidence_msg = "" then
                    (* NO-EVIDENCE PATH: no retrieved emails in this prompt.
                       Use p.question (the user's verbatim words) because there
                       are no inserted emails that could cause ambiguity with
                       anaphoric references.  This also serves as a safe
                       fallback when the rewrite LLM produces garbage for
                       resolved_question (e.g. "..."). *)
                    with_tail
                    @ [ `Assoc [ ("role", `String "user"); ("content", `String p.question) ] ]
                  else
                    (* WITH-EVIDENCE PATH: retrieved emails are inserted as a
                       USER message immediately before the question.  We MUST
                       use p.resolved_question here, not p.question, because
                       the user's original question may contain anaphoric
                       references like "the second email" or "that thread"
                       that referred to emails from the *previous* assistant
                       answer (in the tail).  Since retrieved emails now appear
                       between the tail and the question, those references
                       would be misread as pointing to the retrieved emails.
                       resolved_question has these references resolved into
                       self-contained form by the rewrite LLM, avoiding the
                       ambiguity. *)
                    let evidence_content =
                      "EMAILS THAT MAY BE RELEVANT:\n\n"
                      ^ evidence_msg
                    in
                    let question_suffix =
                      get_prompt "chat_question_suffix"
                        ~default:"Answer based on the retrieved emails above. Cite as [Email N]."
                        ~vars:[]
                    in
                    (* Defense: if the rewrite LLM produced garbage for
                       resolved_question (e.g. "..." or a very short string
                       that isn't a real question), fall back to the original
                       question.  This sacrifices anaphoric-reference safety
                       but is better than sending "..." to the chat LLM.
                       See prompts.json "query_rewrite" for the root cause. *)
                    let effective_question =
                      let rq = String.trim p.resolved_question in
                      if rq = "" || rq = "..." || rq = ".." || rq = "."
                         || String.length rq < 5 then begin
                        Printf.eprintf "[chat.warning] resolved_question is garbage (%S), falling back to original question\n%!" rq;
                        p.question
                      end else
                        p.resolved_question
                    in
                    let question_content =
                      effective_question ^ "\n\n" ^ question_suffix
                    in
                    with_tail
                    @ [ `Assoc [ ("role", `String "user")
                               ; ("content", `String (evidence_content ^ "\n\n────────────────\nUSER QUESTION:\n" ^ question_content)) ]
                      ]
                in

                set_progress session_id "Generating answer";
                let answer =
                  let effective_chat_model =
                    if String.trim chat_model_override <> "" then chat_model_override
                    else !ollama_llm_model
                  in
                  match ollama_chat ~client ~sw ~label:"chat" ~stats:stats_chat_answer ~model:chat_model_override ~messages () with
                  | Ok s ->
                      if !rag_debug_ollama_chat then
                        Printf.printf "\n[chat.raw_answer]\n%s\n%!" s;
                      p_llm_log := !p_llm_log @ [make_llm_call_entry
                        ~label:"chat" ~model:effective_chat_model
                        ~messages ~response:s];
                      strip_leading_boilerplate s |> String.trim
                  | Error msg ->
                      p_llm_log := !p_llm_log @ [make_llm_call_entry
                        ~label:"chat" ~model:effective_chat_model
                        ~messages ~response:("ERROR: " ^ msg)];
                      "ollama chat error: " ^ msg
                in

                let renumbered_answer, cited_recap =
                  renumber_cited_sources ~answer ~sources_json
                in
                Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
                  let add_msg role content =
                    s.tail <- s.tail @ [ { role; content } ];
                    let max_tail = 24 in
                    if List.length s.tail > max_tail then s.tail <- take_last max_tail s.tail
                  in
                  add_msg "user" p.question;
                  let answer_with_refs =
                    if String.trim cited_recap <> "" then
                      renumbered_answer ^ "\n\nEMAILS REFERENCED ABOVE:\n" ^ cited_recap
                    else renumbered_answer
                  in
                  add_msg "assistant" answer_with_refs;
                  maybe_summarize_session ~client ~sw s);

                Eio.Mutex.use_rw ~protect:true pending_tbl_mu (fun () -> Hashtbl.remove pending_tbl request_id);
                clear_progress session_id;

                let body =
                  `Assoc [ ("answer", `String answer); ("sources", sources_json)
                         ; ("llm_calls", `List !p_llm_log) ]
                  |> Yojson.Safe.to_string
                in
                Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ())))

  (*
    Multi-query retrieval with contextual rewriting + HyDE

    Before embedding the user's question, we optionally generate reformulated
    queries to improve recall:
    1. Contextual rewrite: resolves pronouns, relative dates, implicit refs
    2. HyDE (Hypothetical Document Embedding): a hypothetical email passage

    Each query is embedded separately, results are merged by doc_id (max score).
  *)

  (*
    Retrieval-only query endpoint (phase 1)

    This endpoint does not call Ollama chat.
    It embeds the user question, retrieves doc_ids via pgvector kNN, and returns
    request_id + message_ids so that Thunderbird can upload full evidence.
  *)
  | `POST, "/query" ->
      let query_body = read_all body in
      let session_id, question, top_k, mode, user_name, rewrite_model_override =
        try
          let json = Yojson.Safe.from_string query_body in
          let assoc =
            match json with
            | `Assoc kv -> kv
            | _ -> []
          in
          let get key = List.assoc_opt key assoc in
          let session_id =
            match get "session_id" with
            | Some (`String s) -> s
            | _ -> ""
          in
          let question =
            match get "question" with
            | Some (`String s) -> s
            | _ -> ""
          in
          let top_k =
            match get "top_k" with
            | Some (`Int n) -> n
            | _ -> 8
          in
          let mode =
            match get "mode" with
            | Some (`String s) -> s
            | _ -> "assistive"
          in
          let user_name =
            match get "user_name" with
            | Some (`String s) -> String.trim s
            | _ -> ""
          in
          let rm =
            match get "rewrite_model" with
            | Some (`String s) -> String.trim s
            | _ -> ""
          in
          (session_id, question, top_k, mode, user_name, rm)
        with _ -> ("", "", 8, "assistive", "", "")
      in
      if String.trim session_id = "" || String.trim question = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing session_id/question\n" ()
      else (
        let s = get_or_create_session session_id in
        (* Store user_name on the session if provided and not already set. *)
        if String.trim user_name <> "" then
          Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
            if String.trim s.user_name = "" then s.user_name <- user_name);
        let history_summary, tail =
          Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
            (s.history_summary, s.tail))
        in

        (* Accumulate EVERY LLM call made during this request so the quality
           harness can inspect all prompts, not just the final chat prompt. *)
        let llm_log : Yojson.Safe.t list ref = ref [] in

        let rewrite_model_opt =
          if String.trim rewrite_model_override <> "" then Some rewrite_model_override else None
        in
        set_progress session_id "Generating query";
        let queries, resolved_question, no_retrieval, rewrite_filter, rewrite_score =
          rewrite_queries_for_retrieval ~client ~sw ~question
            ~history_summary ~tail ~user_name:(s.user_name)
            ?rewrite_model:rewrite_model_opt
            ~llm_log ()
        in

        if no_retrieval then (
          clear_progress session_id;
          (* No retrieval needed — register a pending_query with empty message_ids
             so that /query/complete can answer directly from conversation context. *)
          let request_id = fresh_request_id session_id question in
          let p : pending_query =
            { mu = Eio.Mutex.create ()
            ; session_id
            ; question
            ; resolved_question
            ; message_ids = []
            ; sources_json = `List []
            ; evidence_by_id = Hashtbl.create 0
            ; llm_calls = !llm_log
            }
          in
          Eio.Mutex.use_rw ~protect:true pending_tbl_mu (fun () -> Hashtbl.replace pending_tbl request_id p);
          let body =
            `Assoc
              [ ("status", `String "no_retrieval")
              ; ("request_id", `String request_id)
              ; ("message_ids", `List [])
              ; ("sources", `List [])
              ]
            |> Yojson.Safe.to_string
          in
          Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ())
        else (
        set_progress session_id "Searching archive";
        let retrieval_sqls = ref [] in
        let retrieval_queries = ref [] in
        let retrieval_warnings = ref [] in
        let embed_and_retrieve (query_text : string) : Yojson.Safe.t list =
          match ollama_embed ~client ~sw ~task:Search_query ~label:"query" ~stats:stats_embed_query ~text:query_text () with
          | Error msg when is_truncation_error msg ->
              Printf.eprintf "[retrieval.embed.truncated] query truncated (%d chars): %s\n%!" (String.length query_text) msg;
              retrieval_warnings := (Printf.sprintf "Query embedding was truncated (%d chars exceeds model context). Results may be degraded." (String.length query_text)) :: !retrieval_warnings;
              []
          | Error msg ->
              Printf.eprintf "[retrieval.embed.error] %s\n%!" msg;
              []
          | Ok v ->
              let emb = l2_normalize v in
              if debug_retrieval_enabled () then
                Printf.printf "[retrieval.embed] query=%s\n%!"
                  (if String.length query_text > 120 then String.sub query_text 0 120 ^ "..." else query_text);
              retrieval_queries := query_text :: !retrieval_queries;
              (match Rag_lib.Pg.query_knn ~embedding:emb ~top_k
                ?filter:rewrite_filter ?score_expr:rewrite_score () with
              | Error msg ->
                  Printf.eprintf "[retrieval.pg.error] %s\n%!" msg;
                  if rewrite_filter <> None || rewrite_score <> None then (
                    Printf.eprintf "[retrieval.pg.fallback] retrying without filter/score_expr\n%!";
                    match Rag_lib.Pg.query_knn ~embedding:emb ~top_k () with
                    | Error msg2 ->
                        Printf.eprintf "[retrieval.pg.error] fallback also failed: %s\n%!" msg2;
                        []
                    | Ok (sources, sql) ->
                        retrieval_sqls := sql :: !retrieval_sqls;
                        sources)
                  else []
              | Ok (sources, sql) ->
                  retrieval_sqls := sql :: !retrieval_sqls;
                  sources)
        in

        let nq = List.length queries in
        let qi = ref 0 in
        let all_sources =
          List.concat (List.map (fun q ->
            incr qi;
            set_progress session_id (Printf.sprintf "Searching archive (%d/%d)" !qi nq);
            embed_and_retrieve q) queries)
        in
        (* If filter was used but yielded 0 results, retry without filter (keep score_expr) *)
        let all_sources =
          if all_sources = [] && rewrite_filter <> None then (
            Printf.printf "[retrieval.fallback] filter returned 0 results, retrying without filter\n%!";
            retrieval_sqls := [];
            retrieval_queries := [];
            let embed_and_retrieve_unfiltered (query_text : string) : Yojson.Safe.t list =
              match ollama_embed ~client ~sw ~task:Search_query ~label:"query" ~stats:stats_embed_query ~text:query_text () with
              | Error msg when is_truncation_error msg ->
                  Printf.eprintf "[retrieval.embed.truncated] query truncated (%d chars): %s\n%!" (String.length query_text) msg;
                  retrieval_warnings := (Printf.sprintf "Query embedding was truncated (%d chars exceeds model context). Results may be degraded." (String.length query_text)) :: !retrieval_warnings;
                  []
              | Error msg ->
                  Printf.eprintf "[retrieval.embed.error] %s\n%!" msg; []
              | Ok v ->
                  let emb = l2_normalize v in
                  retrieval_queries := query_text :: !retrieval_queries;
                  (match Rag_lib.Pg.query_knn ~embedding:emb ~top_k
                    ?score_expr:rewrite_score () with
                  | Error msg ->
                      Printf.eprintf "[retrieval.pg.error] %s\n%!" msg; []
                  | Ok (sources, sql) ->
                      retrieval_sqls := sql :: !retrieval_sqls;
                      sources)
            in
            List.concat (List.map embed_and_retrieve_unfiltered queries))
          else all_sources
        in
        let retrieval_sql =
          match List.rev !retrieval_sqls with
          | [] -> ""
          | [s] -> s
          | ss -> String.concat " | " ss
        in
        let retrieval_queries_json =
          `List (List.rev_map (fun s -> `String s) !retrieval_queries)
        in
        let sources_json = merge_multi_query_sources all_sources top_k in

        (
          if debug_retrieval_enabled () then (
            let summarize_one (v : Yojson.Safe.t) : string option =
              match v with
              | `Assoc kv ->
                  let doc_id =
                    match List.assoc_opt "doc_id" kv with
                    | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
                    | _ -> None
                  in
                  let score =
                    match List.assoc_opt "score" kv with
                    | Some (`Float f) -> Some (Printf.sprintf "%g" f)
                    | Some (`Int i) -> Some (string_of_int i)
                    | Some (`Intlit s) -> Some s
                    | Some (`String s) -> Some s
                    | _ -> None
                  in
                  (match doc_id, score with
                  | Some d, Some sc -> Some (Printf.sprintf "doc_id=%s score=%s" d sc)
                  | Some d, None -> Some (Printf.sprintf "doc_id=%s" d)
                  | _ -> None)
              | _ -> None
            in
            let lines =
              match sources_json with
              | `List ys -> ys |> List.filter_map summarize_one
              | _ -> []
            in
            Printf.printf "\n[retrieval.merged.response] %d queries -> %d unique sources\n%s\n%!"
              (List.length queries) (List.length lines) (String.concat "\n" lines));


          (* Selective rehydration: ask the LLM which emails need full content. *)
          set_progress session_id "Selecting emails";
          let message_ids =
            select_relevant_sources ~client ~sw ~resolved_question
              ~user_name:(s.user_name) ?rewrite_model:rewrite_model_opt ~llm_log sources_json
          in

          let request_id = fresh_request_id session_id question in
          let p : pending_query =
            { mu = Eio.Mutex.create ()
            ; session_id
            ; question
            ; resolved_question
            ; message_ids
            ; sources_json
            ; evidence_by_id = Hashtbl.create 32
            ; llm_calls = !llm_log
            }
          in
          Eio.Mutex.use_rw ~protect:true pending_tbl_mu (fun () -> Hashtbl.replace pending_tbl request_id p);
          clear_progress session_id;

          (* Annotate each source with rehydrated flag for the UI *)
          let rehydrated_set = Hashtbl.create 32 in
          List.iter (fun mid -> Hashtbl.replace rehydrated_set mid true) message_ids;
          let annotated_sources =
            match sources_json with
            | `List ys ->
                `List (ys |> List.map (fun v ->
                  match v with
                  | `Assoc kv ->
                      let doc_id = match List.assoc_opt "doc_id" kv with
                        | Some (`String s) -> s | _ -> ""
                      in
                      let rehydrated = Hashtbl.mem rehydrated_set doc_id in
                      `Assoc (kv @ [ ("rehydrated", `Bool rehydrated) ])
                  | _ -> v))
            | _ -> sources_json
          in

          let warnings_json =
            match !retrieval_warnings with
            | [] -> []
            | ws -> [ ("warnings", `List (List.rev_map (fun s -> `String s) ws)) ]
          in
          let body =
            `Assoc
              ([ ("status", `String "need_messages")
              ; ("request_id", `String request_id)
              ; ("message_ids", `List (List.map (fun s -> `String s) message_ids))
              ; ("sources", annotated_sources)
              ; ("retrieval_sql", `String retrieval_sql)
              ; ("retrieval_queries", retrieval_queries_json)
              ] @ warnings_json)
            |> Yojson.Safe.to_string
          in
          Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ())))
  (*
    Batch ingestion status check

    Accepts {"ids": ["<msg-id-1>", ...]} and returns which ones have been
    successfully ingested (no [ERROR:] markers).  Used by the Thunderbird
    add-on to display green/red indicators in the message list column.
  *)
  | `POST, "/admin/ingested_status" ->
      let raw = read_all body in
      let ids =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv -> (
              match List.assoc_opt "ids" kv with
              | Some (`List xs) ->
                  xs |> List.filter_map (function `String s -> Some (String.trim s) | _ -> None)
              | _ -> [])
          | _ -> []
        with _ -> []
      in
      let ingested, processed, partial, reply_by_pairs =
        match Rag_lib.Pg.batch_ingested_status ids with
        | Ok (i, p, pa, rb) -> (i, p, pa, rb)
        | Error e ->
            Printf.eprintf "[admin.ingested_status.error] %s\n%!" e;
            ([], [], [], [])
      in
      (* Map normalized doc_ids back to original request IDs for TB compatibility *)
      let norm_to_orig = Hashtbl.create 64 in
      List.iter (fun id ->
        Hashtbl.replace norm_to_orig (Rag_lib.Pg.normalize_doc_id id) id) ids;
      let map_back lst =
        List.filter_map (fun nid ->
          match Hashtbl.find_opt norm_to_orig nid with
          | Some orig -> Some orig
          | None -> Some nid) lst
      in
      let trigger_active =
        match Rag_lib.Pg.batch_trigger_active ids with
        | Ok ta -> ta
        | Error e ->
            Printf.eprintf "[admin.ingested_status.trigger_active.error] %s\n%!" e;
            []
      in
      let reply_by_obj =
        reply_by_pairs |> List.filter_map (fun (nid, rb) ->
          let orig = match Hashtbl.find_opt norm_to_orig nid with Some o -> o | None -> nid in
          Some (orig, `String rb))
      in
      let body =
        `Assoc
          [ ("ingested", `List (List.map (fun s -> `String s) (map_back ingested)))
          ; ("processed", `List (List.map (fun s -> `String s) (map_back processed)))
          ; ("partial", `List (List.map (fun s -> `String s) (map_back partial)))
          ; ("reply_by", `Assoc reply_by_obj)
          ; ("trigger_active", `List (List.map (fun s -> `String s) (map_back trigger_active)))
          ]
        |> Yojson.Safe.to_string
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()

  (*
    Email detail lookup for hover popups.

    Accepts {"doc_id": "<message-id>"}.
    Returns flattened metadata: sender, recipient, cc, subject, email_date,
    attachments, action_score, importance_score, reply_by, processed,
    plus a body_text preview from the first chunk.
  *)
  | `POST, "/admin/email_detail" ->
      let raw_req = read_all body in
      let doc_id = match Yojson.Safe.from_string raw_req with
        | `Assoc kv -> (match List.assoc_opt "doc_id" kv with Some (`String s) -> s | _ -> "")
        | _ -> ""
      in
      if doc_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:{|{"error":"missing doc_id"}|} ~headers:json_headers ()
      else (
        match Rag_lib.Pg.get_email_detail doc_id with
        | Error e ->
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error
              ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) ~headers:json_headers ()
        | Ok None ->
            Cohttp_eio.Server.respond_string ~status:`Not_found
              ~body:{|{"error":"not found"}|} ~headers:json_headers ()
        | Ok (Some detail) ->
            (* Flatten metadata for the UI *)
            let md = match detail with `Assoc kv -> (match List.assoc_opt "metadata" kv with Some (`Assoc m) -> m | _ -> []) | _ -> [] in
            let str k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
            let int_opt k = match List.assoc_opt k md with Some (`Int n) -> Some n | _ -> None in
            let bool_opt k = match List.assoc_opt k md with Some (`Bool b) -> Some b | _ -> None in
            let att = match List.assoc_opt "attachments" md with Some (`List l) -> l | _ -> [] in
            let body_text = match Rag_lib.Pg.get_body_preview doc_id with
              | Ok (Some s) when String.trim s <> "" -> Some (String.trim s)
              | _ -> None
            in
            let result = `Assoc (
              [ ("sender", `String (str "from"))
              ; ("recipient", `String (str "to"))
              ; ("cc", `String (str "cc"))
              ; ("subject", `String (str "subject"))
              ; ("email_date", `String (str "date"))
              ; ("attachments", `List att)
              ; ("action_score", match int_opt "action_score" with Some n -> `Int n | None -> `Null)
              ; ("importance_score", match int_opt "importance_score" with Some n -> `Int n | None -> `Null)
              ; ("reply_by", `String (str "reply_by"))
              ; ("processed", `Bool (bool_opt "processed" = Some true))
              ]
              @ (match body_text with Some t -> [("body_text", `String t)] | None -> [])
            )
            in
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string result) ~headers:json_headers ())

  (*
    Extract body text from raw RFC822 email.

    Accepts {"raw": "...", "doc_id": "...", "summarize": bool}.
    When summarize=false: fast MIME parse + body extraction (no LLM).
    When summarize=true:  also runs LLM summarization of quoted text + attachments.
    Returns {"body_text": "...", "metadata": {...}}.
    Used by the ingested-detail UI to show what was (or would be) indexed.
  *)
  | `POST, "/admin/extract_body" ->
      let raw_req = read_all body in
      let json = try Yojson.Safe.from_string raw_req with _ -> `Null in
      let get_str key = match json with
        | `Assoc kv -> (match List.assoc_opt key kv with Some (`String s) -> s | _ -> "")
        | _ -> ""
      in
      let summarize = match json with
        | `Assoc kv -> (match List.assoc_opt "summarize" kv with Some (`Bool b) -> b | _ -> false)
        | _ -> false
      in
      let raw_email = get_str "raw" in
      let doc_id = get_str "doc_id" in
      if raw_email = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing raw\n" ()
      else
        let headers = parse_headers raw_email in
        let parts = extract_body_parts raw_email in
        let new_body = String.trim parts.new_text |> sanitize_utf8 in
        let quoted_raw = String.trim parts.quoted_text |> sanitize_utf8 in
        let quoted_capped_untrimmed =
          if String.trim quoted_raw = "" then ""
          else
            truncate_lines quoted_raw ~max_lines:!rag_quoted_context_max_lines
            |> truncate_chars ~max_chars:!rag_quoted_context_max_input_chars
        in
        let quoted_capped = String.trim quoted_capped_untrimmed in
        let overflow_start = String.length quoted_capped_untrimmed in
        let has_overflow = overflow_start < String.length quoted_raw in
        let overflow =
          if has_overflow then
            String.sub quoted_raw overflow_start (String.length quoted_raw - overflow_start) |> String.trim
          else ""
        in
        let overflow_summary, attachment_summaries =
          if summarize then
            let qs = if overflow = "" then None
              else summarize_quoted_context ~client ~sw ~quoted_text:overflow in
            let atts = attachment_summaries_of_raw ~client ~sw ~raw:raw_email in
            (qs, atts)
          else (None, [])
        in
        let attachments_section = format_attachment_summaries_for_text attachment_summaries in
        let body_text =
          let qs =
            match overflow_summary with
            | Some s when String.trim s <> "" -> "QUOTED CONTEXT (older, summarized):\n" ^ String.trim s
            | _ -> ""
          in
          let qc =
            if quoted_capped = "" then ""
            else if has_overflow then "QUOTED CONTEXT (recent):\n" ^ quoted_capped
            else "QUOTED CONTEXT:\n" ^ quoted_capped
          in
          let att = if attachments_section = "" then "" else attachments_section in
          let parts = List.filter (fun s -> s <> "") [qs; qc; att; "NEW CONTENT:\n" ^ new_body] in
          String.concat "\n\n" parts
        in
        let _index_text, metadata_json =
          make_ingest_data ~doc_id ~headers ~raw:raw_email ~body_text
        in
        let resp_json =
          `Assoc
            [ ("body_text", `String body_text)
            ; ("metadata", metadata_json)
            ; ("summarize_model", `String (if summarize then !ollama_summarize_model else ""))
            ]
        in
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string resp_json) ~headers:json_headers ()

  (*
    Single-document ingestion detail

    Accepts {"id": "<msg-id>"} and returns the embedding model and
    metadata that were stored at ingestion time.  Used by the
    Thunderbird add-on's right-click "Show ingested data" action.
  *)
  | `POST, "/admin/ingested_detail" ->
      let raw = read_all body in
      let id =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv -> (
              match List.assoc_opt "id" kv with
              | Some (`String s) -> String.trim s
              | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      if id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing id\n" ()
      else
        let base_json =
          match Rag_lib.Pg.get_email_detail id with
          | Ok (Some json) -> json
          | Ok None ->
              `Assoc
                [ ("doc_id", `String id)
                ; ("ingested", `Bool false)
                ; ("detail", `Null)
                ]
          | Error e ->
              Printf.eprintf "[admin.ingested_detail.error] %s\n%!" e;
              `Assoc [ ("doc_id", `String id); ("error", `String e) ]
        in
        (* Append propose_tasks_debug if available *)
        let body = match base_json with
          | `Assoc kv ->
              let pt_debug = match Rag_lib.Pg.get_propose_tasks_debug id with
                | Ok (Some s) -> (try Yojson.Safe.from_string s with _ -> `Null)
                | _ -> `Null
              in
              `Assoc (kv @ [("propose_tasks_debug", pt_debug)])
          | other -> other
        in
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string body) ~headers:json_headers ()

  | `POST, "/admin/delete" ->
      let delete_body = read_all body in
      let doc_id =
        try
          let json = Yojson.Safe.from_string delete_body in
          match json with
          | `Assoc kv ->
              let get k = match List.assoc_opt k kv with Some (`String s) -> String.trim s | _ -> "" in
              let v = get "id" in
              if v <> "" then v else get "doc_id"
          | _ -> ""
        with _ -> ""
      in
      if doc_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:{|{"error":"missing id"}|} ~headers:json_headers ()
      else (
        match Rag_lib.Pg.delete_email doc_id with
        | Ok (existed, triggerless_task_ids) ->
            (* Dismiss tasks that lost all trigger emails *)
            let dismissed = List.filter_map (fun task_id ->
              match Rag_lib.Pg.update_task ~task_id ~status:"dismissed" () with
              | Ok true ->
                  Printf.printf "[admin.delete] dismissed task %s (no triggers left)\n%!" task_id;
                  Some task_id
              | _ -> None
            ) triggerless_task_ids in
            Printf.printf "[admin.delete] doc_id=%s existed=%b dismissed=%d tasks\n%!"
              doc_id existed (List.length dismissed);
            let json = `Assoc
              [ ("ok", `Bool true)
              ; ("existed", `Bool existed)
              ; ("dismissed_tasks", `List (List.map (fun s -> `String s) dismissed))
              ] in
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
        | Error e ->
            Printf.eprintf "[admin.delete.error] %s\n%!" e;
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error
              ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
              ~headers:json_headers ())
  | `POST, "/admin/reset" ->
      (* Probe embed dimension before recreating tables so vector column matches *)
      (match ollama_embed ~client ~sw ~label:"probe" ~text:"dimension probe" () with
       | Ok _ -> ()
       | Error msg ->
           Printf.eprintf "WARNING: could not probe embed model before reset: %s — using dimension %d\n%!"
             msg !rag_vector_dimension);
      (match Rag_lib.Pg.reset_all () with
       | Ok () ->
           Cohttp_eio.Server.respond_string ~status:`OK
             ~body:{|{"ok":true}|} ~headers:json_headers ()
       | Error e ->
           Printf.eprintf "[admin.reset.error] %s\n%!" e;
           Cohttp_eio.Server.respond_string ~status:`Internal_server_error
             ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped e))
             ~headers:json_headers ())
  | `GET, "/admin/settings" ->
      let body = Yojson.Safe.to_string
        (`Assoc
          [ ("settings", current_settings_json ())
          ; ("path", `String (settings_path ()))
          ; ("default_path", `String (default_settings_path ()))
          ]) in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()

  | `GET, "/admin/settings/defaults" ->
      let dp = default_settings_path () in
      (if Sys.file_exists dp then
        try
          let json = Yojson.Safe.from_file dp in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Yojson.Safe.pretty_to_string ~std:true json)
            ~headers:json_headers ()
        with e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String (Printexc.to_string e)) ]))
            ~headers:json_headers ()
      else
        Cohttp_eio.Server.respond_string ~status:`Not_found
          ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String ("default settings not found: " ^ dp)) ]))
          ~headers:json_headers ())

  | `POST, "/admin/settings" ->
      let raw = read_all body in
      (try
         let incoming = Yojson.Safe.from_string raw in
         (* Merge incoming keys into current settings *)
         let current = current_settings_json () in
         let merged =
           match current, incoming with
           | `Assoc base, `Assoc patch ->
               let rec merge_assoc base patch =
                 let updated =
                   List.map (fun (k, v) ->
                     match List.assoc_opt k patch with
                     | None -> (k, v)
                     | Some (`Assoc pv) ->
                         (match v with
                          | `Assoc bv -> (k, `Assoc (merge_assoc bv pv))
                          | _ -> (k, `Assoc pv))
                     | Some pv -> (k, pv))
                     base
                 in
                 (* Add keys from patch that aren't in base *)
                 let extra = List.filter (fun (k, _) -> not (List.mem_assoc k base)) patch in
                 updated @ extra
               in
               `Assoc (merge_assoc base patch)
           | _, _ -> incoming
         in
         match write_settings_json merged with
         | Error e ->
             Printf.eprintf "[admin.settings.write_error] %s\n%!" e;
             Cohttp_eio.Server.respond_string ~status:`Internal_server_error
               ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String e) ]))
               ~headers:json_headers ()
         | Ok () ->
             load_settings ();
             Cohttp_eio.Server.respond_string ~status:`OK
               ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true); ("settings", current_settings_json ()) ]))
               ~headers:json_headers ()
       with e ->
         let msg = Printexc.to_string e in
         Printf.eprintf "[admin.settings.error] %s\n%!" msg;
         Cohttp_eio.Server.respond_string ~status:`Bad_request
           ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))
           ~headers:json_headers ())

  | `GET, path when starts_with "/query/progress" path ->
      let uri = Uri.of_string (Http.Request.resource request) in
      let session_id =
        match Uri.get_query_param uri "session_id" with
        | Some s -> String.trim s
        | None -> ""
      in
      let phase =
        if session_id = "" then ""
        else match Hashtbl.find_opt progress_tbl session_id with Some p -> p | None -> ""
      in
      let body = Yojson.Safe.to_string (`Assoc [("phase", `String phase)]) in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()

  | `GET, "/admin/prompts" ->
      (match load_prompts_json () with
       | Some json ->
           let body = Yojson.Safe.to_string
             (`Assoc
               [ ("prompts", json)
               ; ("path", `String (prompts_path ()))
               ; ("default_path", `String (default_prompts_path ()))
               ]) in
           Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
       | None ->
           Cohttp_eio.Server.respond_string ~status:`Not_found
             ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String "prompts.json not found") ]))
             ~headers:json_headers ())

  | `GET, "/admin/prompts/defaults" ->
      let dp = default_prompts_path () in
      (if Sys.file_exists dp then
        try
          let json = Yojson.Safe.from_file dp in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Yojson.Safe.pretty_to_string ~std:true json)
            ~headers:json_headers ()
        with e ->
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String (Printexc.to_string e)) ]))
            ~headers:json_headers ()
      else
        Cohttp_eio.Server.respond_string ~status:`Not_found
          ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String ("default prompts not found: " ^ dp)) ]))
          ~headers:json_headers ())

  | `POST, "/admin/prompts" ->
      let raw = read_all body in
      (try
         let incoming = Yojson.Safe.from_string raw in
         match write_prompts_json incoming with
         | Error e ->
             Printf.eprintf "[admin.prompts.write_error] %s\n%!" e;
             Cohttp_eio.Server.respond_string ~status:`Internal_server_error
               ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String e) ]))
               ~headers:json_headers ()
         | Ok () ->
             Cohttp_eio.Server.respond_string ~status:`OK
               ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true) ]))
               ~headers:json_headers ()
       with e ->
         let msg = Printexc.to_string e in
         Printf.eprintf "[admin.prompts.error] %s\n%!" msg;
         Cohttp_eio.Server.respond_string ~status:`Bad_request
           ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))
           ~headers:json_headers ())

  | `GET, "/admin/pause" ->
      let json = `Assoc
        [ ("tasks_paused", `Bool (Atomic.get tasks_paused))
        ; ("ingest_paused", `Bool (Atomic.get ingest_paused))
        ] in
      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()

  | `POST, "/admin/pause" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        (match List.assoc_opt "tasks" kv with
        | Some (`Bool b) -> Atomic.set tasks_paused b
        | _ -> ());
        (match List.assoc_opt "ingest" kv with
        | Some (`Bool b) -> Atomic.set ingest_paused b
        | _ -> ());
        Printf.printf "[admin.pause] tasks_paused=%b ingest_paused=%b\n%!"
          (Atomic.get tasks_paused) (Atomic.get ingest_paused);
        let json = `Assoc
          [ ("ok", `Bool true)
          ; ("tasks_paused", `Bool (Atomic.get tasks_paused))
          ; ("ingest_paused", `Bool (Atomic.get ingest_paused))
          ] in
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped (Printexc.to_string e)))
          ~headers:json_headers ())

  | `POST, "/admin/reload" ->
      (try
         load_settings ();
         embed_dim_probed := false;
         (match ollama_embed ~client ~sw ~label:"probe" ~text:"dimension probe" () with
          | Ok _ -> ()
          | Error msg ->
              Printf.eprintf "WARNING: could not probe embed model %s: %s — keeping dimension %d\n%!"
                !ollama_embed_model msg !rag_vector_dimension);
         Cohttp_eio.Server.respond_string ~status:`OK
           ~body:{|{"ok":true}|} ~headers:json_headers ()
       with ex ->
         let msg = Printexc.to_string ex in
         Printf.eprintf "[admin.reload.error] %s\n%!" msg;
         Cohttp_eio.Server.respond_string ~status:`Internal_server_error
           ~body:(Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
           ~headers:json_headers ())
  | `POST, "/admin/mark_processed" ->
      let raw = read_all body in
      (* Accept either JSON {"id":"..."} or raw RFC822 (from filter action) *)
      let from_json =
        try
          let json = Yojson.Safe.from_string raw in
          match json with
          | `Assoc kv -> (match List.assoc_opt "id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      let is_json = from_json <> "" in
      let id =
        if is_json then from_json
        else
          let from_header = request_header_or_empty request "x-thunderbird-message-id" |> String.trim in
          if from_header <> "" then from_header
          else
            let rfc_headers = parse_headers raw in
            header_or_empty rfc_headers "message-id" |> String.trim
      in
      if id = "" then (
        Printf.printf "[admin.mark_processed] empty id, rejecting\n%!";
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing id\n" ())
      else (
        Printf.printf "[admin.mark_processed] id=%s is_json=%b\n%!" id is_json;
        let check_auto_complete doc_id =
          match Rag_lib.Pg.auto_complete_tasks_for_email doc_id with
          | Ok completed ->
              List.iter (fun tid ->
                Printf.printf "[admin.mark_processed] auto-completed task %s (all triggers processed)\n%!" tid
              ) completed
          | Error e ->
              Printf.eprintf "[admin.mark_processed] auto-complete check error: %s\n%!" e
        in
        match Rag_lib.Pg.set_processed id true with
        | Ok true ->
            Printf.printf "[admin.mark_processed] %s -> processed=true\n%!" id;
            check_auto_complete id;
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true); ("id", `String id); ("processed", `Bool true) ]))
              ~headers:json_headers ()
        | Ok false | Error _ when not is_json ->
            (* Not yet ingested but we have raw RFC822 — ingest first, then mark processed *)
            Printf.eprintf "[admin.mark_processed] %s not ingested, auto-ingesting from RFC822\n%!" id;
            let rfc_headers = parse_headers raw in
            let doc_id = doc_id_of_ingest request rfc_headers raw in
            let whoami = String.trim !whoami in
            let resp, _resp_body =
              forward_ingest_raw ~client ~sw ~log:true ~whoami ~doc_id ~headers:rfc_headers ~raw
            in
            let code = Cohttp.Code.code_of_status (Http.Response.status resp) in
            if code >= 200 && code < 300 then (
              ignore (Rag_lib.Pg.set_processed doc_id true);
              check_auto_complete doc_id;
              Cohttp_eio.Server.respond_string ~status:`OK
                ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true); ("id", `String doc_id); ("processed", `Bool true); ("auto_ingested", `Bool true) ]))
                ~headers:json_headers ())
            else
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error
                ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String "auto-ingest failed") ]))
                ~headers:json_headers ()
        | Ok false | Error _ ->
            Cohttp_eio.Server.respond_string ~status:`Not_found
              ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String "not ingested") ]))
              ~headers:json_headers ())

  | `POST, "/admin/mark_unprocessed" ->
      let raw = read_all body in
      (* Accept either JSON {"id":"..."} or raw RFC822 (from filter action) *)
      let id =
        let from_json =
          try
            let json = Yojson.Safe.from_string raw in
            match json with
            | `Assoc kv -> (match List.assoc_opt "id" kv with Some (`String s) -> String.trim s | _ -> "")
            | _ -> ""
          with _ -> ""
        in
        if from_json <> "" then from_json
        else
          let from_header = request_header_or_empty request "x-thunderbird-message-id" |> String.trim in
          if from_header <> "" then from_header
          else
            let rfc_headers = parse_headers raw in
            header_or_empty rfc_headers "message-id" |> String.trim
      in
      if id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing id\n" ()
      else (
        match Rag_lib.Pg.set_processed id false with
        | Ok true ->
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true); ("id", `String id); ("processed", `Bool false) ]))
              ~headers:json_headers ()
        | Ok false | Error _ ->
            Cohttp_eio.Server.respond_string ~status:`Not_found
              ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool false); ("error", `String "not ingested") ]))
              ~headers:json_headers ())

  | `POST, "/debug/stdout" ->
      let msg = read_all body |> String.trim in
      if msg <> "" then Printf.printf "[TB] %s\n%!" msg;
      Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok\n" ()

  | `POST, "/debug/stderr" ->
      let msg = read_all body |> String.trim in
      if msg <> "" then Printf.eprintf "[TB] %s\n%!" msg;
      Cohttp_eio.Server.respond_string ~status:`OK ~body:"ok\n" ()

  | `POST, "/admin/bulk_ingest" ->
      let bulk_body = read_all body in
      let resp, resp_body = handle_bulk_ingest ~client ~sw ~clock bulk_body in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()

  (* ===================================================================
     Task manager endpoints
     =================================================================== *)

  | `POST, "/task/list" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let get_str k = match List.assoc_opt k kv with Some (`String s) -> String.trim s | _ -> "" in
        let statuses =
          match List.assoc_opt "statuses" kv with
          | Some (`List xs) ->
              let ss = List.filter_map (function `String s -> Some (String.trim s) | _ -> None) xs in
              if ss = [] then None else Some ss
          | _ ->
              (* Backward compat: single "status" string *)
              let s = get_str "status" in
              if s = "" then None else Some [s]
        in
        let email_ids =
          match List.assoc_opt "email_ids" kv with
          | Some (`List xs) ->
              let ids = List.filter_map (function `String s -> Some (String.trim s) | _ -> None) xs in
              if ids = [] then None else Some ids
          | _ -> None
        in
        let sort_by =
          let s = get_str "sort_by" in
          if s = "" then None else Some s
        in
        let limit =
          match List.assoc_opt "limit" kv with
          | Some (`Int n) -> Some n
          | _ -> None
        in
        (match Rag_lib.Pg.list_tasks ?statuses ?email_ids ?sort_by ?limit () with
        | Ok tasks ->
            let body = `Assoc [ ("tasks", `List tasks) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        | Error e ->
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/list error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/task/get" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let task_id = match json with
          | `Assoc kv -> (match List.assoc_opt "task_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else
          (match Rag_lib.Pg.get_task task_id with
          | Ok (Some task_json) ->
              Cohttp_eio.Server.respond_string ~status:`OK
                ~body:(Yojson.Safe.to_string task_json) ~headers:json_headers ()
          | Ok None ->
              Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"task not found\n" ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/get error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/task/update" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let get_str k = match List.assoc_opt k kv with Some (`String s) -> Some (String.trim s) | _ -> None in
        let task_id = match get_str "task_id" with Some s -> s | None -> "" in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else
          let title = get_str "title" in
          let description = get_str "description" in
          let status = get_str "status" in
          let importance_score =
            match List.assoc_opt "importance_score" kv with
            | Some (`Int n) -> Some (Some n)
            | Some `Null -> Some None
            | _ -> None
          in
          let deadline = get_str "deadline" in
          let notes = get_str "notes" in
          let drafts_json =
            match List.assoc_opt "drafts" kv with
            | Some (`List _ as v) -> Some (Yojson.Safe.to_string v)
            | _ -> None
          in
          let should_archive = match status with
            | Some "done" | Some "dismissed" -> true | _ -> false
          in
          (* If archiving, fetch task first for conversation data *)
          let pre_task = if should_archive then Rag_lib.Pg.get_task task_id else Ok None in
          (match Rag_lib.Pg.update_task ~task_id ?title ?description ?status
                   ?importance_score ?deadline ?drafts_json ?notes () with
          | Ok true ->
              (* Archive conversation on completion/dismissal *)
              if should_archive then begin
                match pre_task with
                | Ok (Some task_json) ->
                    let tkv = match task_json with `Assoc kv -> kv | _ -> [] in
                    let conv = match List.assoc_opt "conversation" tkv with
                      | Some (`List l) -> l | _ -> []
                    in
                    let hist = match List.assoc_opt "history_summary" tkv with
                      | Some (`String s) -> s | _ -> ""
                    in
                    let t = match List.assoc_opt "title" tkv with
                      | Some (`String s) -> s | _ -> ""
                    in
                    archive_task_conversation ~client ~sw ~task_id
                      ~conversation:conv ~history_summary:hist ~title:t ()
                | _ -> ()
              end;
              (* Mark trigger emails as processed when task is done *)
              if status = Some "done" then
                (match Rag_lib.Pg.task_trigger_doc_ids task_id with
                | Ok doc_ids ->
                    List.iter (fun did ->
                      ignore (Rag_lib.Pg.set_processed did true)
                    ) doc_ids
                | Error e ->
                    Printf.eprintf "[task.update.done] failed to mark triggers processed: %s\n%!" e);
              let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          | Ok false ->
              Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"task not found\n" ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/update error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/task/delete" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let task_id = match json with
          | `Assoc kv -> (match List.assoc_opt "task_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else
          (match Rag_lib.Pg.delete_task task_id with
          | Ok true ->
              let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          | Ok false ->
              Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"task not found\n" ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/delete error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/task/reorder" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let pairs =
          match List.assoc_opt "order" kv with
          | Some (`List xs) ->
              List.filter_map (fun item ->
                match item with
                | `Assoc ikv ->
                    let tid = match List.assoc_opt "task_id" ikv with Some (`String s) -> String.trim s | _ -> "" in
                    let ord = match List.assoc_opt "sort_order" ikv with Some (`Int n) -> Some n | _ -> None in
                    (match tid, ord with
                     | "", _ | _, None -> None
                     | t, Some n -> Some (t, n))
                | _ -> None
              ) xs
          | _ -> []
        in
        if pairs = [] then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing or empty order array\n" ()
        else
          (match Rag_lib.Pg.reorder_tasks pairs with
          | Ok () ->
              let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/reorder error: %s\n" (Printexc.to_string e)) ())

  (* ===================================================================
     Memory system endpoints
     =================================================================== *)

  | `POST, "/memory/list" ->
      (try
        let enabled_only =
          let raw = read_all body in
          if String.trim raw = "" then false
          else match Yojson.Safe.from_string raw with
            | `Assoc kv ->
                (match List.assoc_opt "enabled_only" kv with
                 | Some (`Bool b) -> b | _ -> false)
            | _ -> false
        in
        match Rag_lib.Pg.list_memories ~enabled_only () with
        | Ok memories ->
            let body = `Assoc [ ("memories", `List memories) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        | Error e ->
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ()
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "memory/list error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/memory/create" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let get_str k = match List.assoc_opt k kv with Some (`String s) -> String.trim s | _ -> "" in
        let get_str_opt k = match List.assoc_opt k kv with
          | Some (`String s) when String.trim s <> "" -> Some (String.trim s) | _ -> None in
        let text = get_str "text" in
        if text = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing text\n" ()
        else
        let memory_id =
          let provided = get_str "memory_id" in
          if provided <> "" then provided
          else Printf.sprintf "mem-%08x-%04x-%04x"
            (Random.bits ()) (Random.int 0xFFFF) (Random.int 0xFFFF)
        in
        let rule = get_str_opt "rule" in
        let source_task_id = get_str_opt "source_task_id" in
        (match Rag_lib.Pg.create_memory ~memory_id ~text ?rule ?source_task_id () with
        | Ok () ->
            (* Link emails if provided *)
            let email_ids = match List.assoc_opt "email_ids" kv with
              | Some (`List ids) ->
                  List.filter_map (fun j -> match j with `String s -> Some s | _ -> None) ids
              | _ -> []
            in
            List.iter (fun doc_id ->
              ignore (Rag_lib.Pg.link_email_to_memory ~memory_id ~doc_id)
            ) email_ids;
            let body = `Assoc
              [ ("status", `String "ok")
              ; ("memory_id", `String memory_id)
              ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        | Error e ->
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "memory/create error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/memory/update" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let memory_id = match List.assoc_opt "memory_id" kv with
          | Some (`String s) -> String.trim s | _ -> "" in
        if memory_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing memory_id\n" ()
        else
        let text = match List.assoc_opt "text" kv with
          | Some (`String s) when String.trim s <> "" -> Some (String.trim s) | _ -> None in
        let rule = match List.assoc_opt "rule" kv with
          | Some `Null -> Some None
          | Some (`String s) -> Some (Some s)
          | Some j -> Some (Some (Yojson.Safe.to_string j))
          | None -> None in
        let enabled = match List.assoc_opt "enabled" kv with
          | Some (`Bool b) -> Some b | _ -> None in
        (match Rag_lib.Pg.update_memory ~memory_id ?text ?rule ?enabled () with
        | Ok true ->
            let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        | Ok false ->
            Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"memory not found\n" ()
        | Error e ->
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "memory/update error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/memory/delete" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let memory_id = match json with
          | `Assoc kv -> (match List.assoc_opt "memory_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if memory_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing memory_id\n" ()
        else
          (match Rag_lib.Pg.delete_memory memory_id with
          | Ok true ->
              let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          | Ok false ->
              Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"memory not found\n" ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "memory/delete error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/memory/get" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let memory_id = match json with
          | `Assoc kv -> (match List.assoc_opt "memory_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if memory_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing memory_id\n" ()
        else
          (match Rag_lib.Pg.get_memory memory_id with
          | Ok (Some mem) ->
              Cohttp_eio.Server.respond_string ~status:`OK
                ~body:(Yojson.Safe.to_string mem) ~headers:json_headers ()
          | Ok None ->
              Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"memory not found\n" ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "memory/get error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/task/recompute" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let task_id = match json with
          | `Assoc kv -> (match List.assoc_opt "task_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else begin
          (* Clear context/style emails, keep triggers *)
          ignore (Rag_lib.Pg.delete_task_context_and_style task_id);
          (* Reset flags, clear conversation and drafts *)
          (match Rag_lib.Pg.update_task ~task_id
              ~context_prefetched:false ~context_ready:false
              ~conversation_json:"[]" ~drafts_json:"[]"
              ~context_emails_json:"[]" ~history_summary:"" ~status:"open" () with
          | Ok _ ->
              Printf.printf "[task.recompute] reset task %s for recomputation\n%!" task_id;
              !notify_prefetch ();
              let body = `Assoc [ ("status", `String "ok") ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          | Error e ->
              let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
              Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
        end
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/recompute error: %s\n" (Printexc.to_string e)) ())

  | `POST, "/email/recompute_tasks" ->
      let raw_body = read_all body in
      (try
        let json = Yojson.Safe.from_string raw_body in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let get_str k = match List.assoc_opt k kv with Some (`String s) -> String.trim s | _ -> "" in
        let doc_id = get_str "doc_id" in
        let raw_email = get_str "raw" in
        if doc_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request
            ~body:{|{"error":"missing doc_id"}|} ~headers:json_headers ()
        else if raw_email = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request
            ~body:{|{"error":"missing raw"}|} ~headers:json_headers ()
        else
          (* 1. Get email metadata from PG *)
          let detail = match Rag_lib.Pg.get_email_detail doc_id with
            | Ok (Some (`Assoc kv)) ->
                (match List.assoc_opt "metadata" kv with Some (`Assoc m) -> m | _ -> [])
            | _ -> []
          in
          let md k = match List.assoc_opt k detail with Some (`String s) -> s | _ -> "" in
          let from_ = md "from" in
          let to_ = md "to" in
          let cc_ = md "cc" in
          let bcc_ = md "bcc" in
          let subject = md "subject" in
          let date_ = md "date" in
          if from_ = "" && to_ = "" && subject = "" then
            Cohttp_eio.Server.respond_string ~status:`Bad_request
              ~body:{|{"error":"email not found in database"}|} ~headers:json_headers ()
          else begin
            (* 2. Extract body text from raw RFC822 *)
            let parts = extract_body_parts raw_email in
            let new_body = String.trim parts.new_text |> sanitize_utf8 in
            let body_text =
              summarize_to_fit ~client ~sw ~label:"recompute_tasks_body"
                ~system_prompt:(get_prompt "compress_new_content_ingest"
                  ~default:"Compress email body. Preserve all facts. Third person. Do not invent." ~vars:[])
                ~max_input_chars:!rag_summarize_max_input_chars
                ~max_chars:!rag_new_content_max_chars
                new_body
            in
            (* 3. Remove old trigger links for this doc_id (preserves context/style links) *)
            let ndoc = Rag_lib.Pg.normalize_doc_id doc_id in
            let old_task_ids = match Rag_lib.Pg.remove_trigger_links ndoc with
              | Ok ids -> ids
              | Error e ->
                  Printf.eprintf "[email.recompute_tasks] unlink error: %s\n%!" e; []
            in
            (* 4. Delete orphan tasks (tasks that now have no trigger emails) *)
            if old_task_ids <> [] then
              (match Rag_lib.Pg.delete_orphan_tasks old_task_ids with
              | Ok deleted ->
                  if deleted <> [] then
                    Printf.printf "[email.recompute_tasks] deleted %d orphan task(s)\n%!" (List.length deleted)
              | Error e ->
                  Printf.eprintf "[email.recompute_tasks] orphan cleanup error: %s\n%!" e);
            (* 5. Get whoami from server config *)
            let whoami = String.trim !whoami in
            (* 6. Retrieve memories if enabled *)
            let memories_text =
              if !memory_enabled && String.trim whoami <> "" then
                let attachments = match List.assoc_opt "attachments" detail with
                  | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
                  | _ -> []
                in
                (* Embed body text for memory kNN retrieval *)
                let repr_embedding = match ollama_embed ~client ~sw ~task:Search_document
                    ~label:"recompute_tasks_mem" ~text:body_text () with
                  | Ok v -> l2_normalize v
                  | Error _ -> []
                in
                if repr_embedding <> [] then
                  let (text, _) = retrieve_and_format_memories
                    ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_
                    ~subject ~date:date_ ~attachments
                    ~embedding:repr_embedding () in
                  text
                else
                  (* Fallback: symbolic only *)
                  let sym = retrieve_memories_symbolic
                    ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_
                    ~subject ~date:date_ ~attachments () in
                  let buf = Buffer.create 256 in
                  List.iter (fun (mid, text) ->
                    Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid text)
                  ) sym;
                  Buffer.contents buf
              else ""
            in
            (* 7. Run propose_tasks *)
            let (task_proposals, pt_debug) = propose_tasks ~client ~sw ~whoami
              ~from_ ~to_ ~cc_ ~bcc_ ~subject ~date_ ~body_text
              ~memories_text in
            (* 8. Store debug *)
            (match pt_debug with
            | Some dbg -> ignore (Rag_lib.Pg.set_propose_tasks_debug ndoc (Yojson.Safe.to_string dbg))
            | None -> ());
            (* 9. Create new tasks *)
            if task_proposals <> [] then
              process_task_proposals ~client ~sw ~doc_id:ndoc ~body_text
                ~email_date:date_ ~proposals:task_proposals ();
            Printf.printf "[email.recompute_tasks] doc_id=%s proposals=%d\n%!" ndoc (List.length task_proposals);
            let result = `Assoc
              [ ("status", `String "ok")
              ; ("proposals", `Int (List.length task_proposals))
              ] in
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string result) ~headers:json_headers ()
          end
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "email/recompute_tasks error: %s\n" (Printexc.to_string e)) ())

  (* GET /task/needs_evidence — TB polls this to find doc_ids needing raw body upload.
     Returns { tasks: [ { task_id, doc_ids: [string] } ] } *)
  | `GET, "/task/needs_evidence" ->
      (match Rag_lib.Pg.tasks_needing_evidence ~limit:3 () with
      | Ok tasks ->
          let json = `Assoc [ ("tasks", `List (List.map (fun (tid, dids) ->
            `Assoc [ ("task_id", `String tid)
                   ; ("doc_ids", `List (List.map (fun d -> `String d) dids)) ]
          ) tasks)) ] in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Yojson.Safe.to_string json) ~headers:json_headers ()
      | Error e ->
          let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())

  (* POST /task/evidence — TB uploads a raw RFC822 body for a task email.
     Content-Type: message/rfc822
     Headers: X-Task-Id, X-Thunderbird-Message-Id (= doc_id)
     Server extracts + compresses the body and stores it in task_emails.compressed_body. *)
  | `POST, "/task/evidence" ->
      let hdrs = Http.Request.headers request in
      let task_id = Http.Header.get hdrs "x-task-id" |> Option.value ~default:"" |> String.trim in
      let doc_id = Http.Header.get hdrs "x-thunderbird-message-id" |> Option.value ~default:"" |> String.trim in
      if task_id = "" || doc_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:"missing X-Task-Id or X-Thunderbird-Message-Id header\n" ()
      else begin
        let raw = read_all body in
        let role = match Rag_lib.Pg.get_task_email_role ~task_id ~doc_id with
          | Ok (Some r) -> r | _ -> "context"
        in
        Printf.printf "[task/evidence] task=%s doc=%s role=%s raw=%d bytes\n%!" task_id doc_id role (String.length raw);
        let budget = 4000 in
        let include_quoted = role <> "style" in
        let (compressed, _md) = extract_and_compress_email ~client ~sw ~raw ~doc_id ~budget
          ~include_quoted ~include_attachments:false () in
        (match Rag_lib.Pg.update_task_email_body ~task_id ~doc_id ~compressed_body:compressed with
        | Ok () ->
            let body = `Assoc [ ("ok", `Bool true); ("task_id", `String task_id); ("doc_id", `String doc_id)
                              ; ("compressed_chars", `Int (String.length compressed)) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        | Error e ->
            Printf.eprintf "[task/evidence] update error: %s\n%!" e;
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ())
      end

  (* POST /task/evidence_done — TB signals all evidence uploaded for a task.
     Request: { task_id }
     Server triggers phase 3 of the pipeline (compress + generate first message)
     by notifying the prefetch daemon. *)
  | `POST, "/task/evidence_done" ->
      let raw = read_all body in
      (try
        let json = Yojson.Safe.from_string raw in
        let task_id = match json with
          | `Assoc kv -> (match List.assoc_opt "task_id" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else begin
          Printf.printf "[task/evidence_done] task=%s — checking if all bodies present\n%!" task_id;
          (* Check if any task_emails still have empty compressed_body *)
          let all_filled = match Rag_lib.Pg.get_task_emails_with_bodies task_id with
            | Ok rows ->
                List.for_all (fun (_did, role, cb) ->
                  role = "trigger" || String.trim cb <> "") rows
            | Error _ -> false
          in
          if all_filled then begin
            Printf.printf "[task/evidence_done] task=%s — all bodies present, notifying daemon\n%!" task_id;
            !notify_prefetch ();
            let body = `Assoc [ ("ok", `Bool true); ("ready", `Bool true) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          end else begin
            Printf.printf "[task/evidence_done] task=%s — some bodies still missing\n%!" task_id;
            let body = `Assoc [ ("ok", `Bool true); ("ready", `Bool false) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
          end
        end
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/evidence_done error: %s\n" (Printexc.to_string e)) ())

  (* POST /task/chat_bodies — Upload a raw RFC822 body for a [RETRIEVE]-selected email.
     Content-Type: message/rfc822
     Headers: X-Request-Id, X-Thunderbird-Message-Id (= doc_id)
     Server compresses the body and caches it in the pending_task_retrieval. *)
  | `POST, "/task/chat_bodies" ->
      let hdrs = Http.Request.headers request in
      let req_id = Http.Header.get hdrs "x-request-id" |> Option.value ~default:"" |> String.trim in
      let doc_id = Http.Header.get hdrs "x-thunderbird-message-id" |> Option.value ~default:"" |> String.trim in
      if req_id = "" || doc_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:"missing X-Request-Id or X-Thunderbird-Message-Id header\n" ()
      else begin
        let raw = read_all body in
        Printf.printf "[task/chat_bodies] req=%s doc=%s raw=%d bytes\n%!" req_id doc_id (String.length raw);
        let budget = 4000 in
        let (compressed, _md) = extract_and_compress_email ~client ~sw ~raw ~doc_id ~budget
          ~include_quoted:true ~include_attachments:false () in
        (* Store in the pending retrieval cache *)
        let found = Eio.Mutex.use_rw ~protect:true task_retrieval_mu (fun () ->
          match Hashtbl.find_opt task_retrieval_tbl req_id with
          | Some tr ->
              Hashtbl.replace tr.evidence_by_id doc_id compressed;
              true
          | None -> false)
        in
        if found then
          let body = `Assoc [ ("ok", `Bool true); ("doc_id", `String doc_id)
                            ; ("compressed_chars", `Int (String.length compressed)) ] |> Yojson.Safe.to_string in
          Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
        else
          Cohttp_eio.Server.respond_string ~status:`Not_found
            ~body:"request_id not found in retrieval cache\n" ()
      end

  (*
    /task/chat — Continue (or start) a task conversation.

    Server-side state: loads conversation from DB, appends user message,
    calls LLM, parses structured markers, applies side effects (drafts,
    score updates, new tasks, etc.), saves updated state, returns response.

    Request: { task_id, user_message, chat_model?, request_id? }
    Response: { message, task (updated), side_effects[] }
             OR { status: "retrieval", request_id, message_ids } when [RETRIEVE] triggers
  *)
  | `POST, "/task/chat" ->
      let raw_req = read_all body in
      (try
        let json = Yojson.Safe.from_string raw_req in
        let kv = match json with `Assoc kv -> kv | _ -> [] in
        let get_str k = match List.assoc_opt k kv with Some (`String s) -> String.trim s | _ -> "" in
        let task_id = get_str "task_id" in
        let user_message = get_str "user_message" in
        let chat_model = get_str "chat_model" in
        let request_id = get_str "request_id" in
        if task_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing task_id\n" ()
        else if user_message = "" && request_id = "" then
          Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing user_message\n" ()
        else
        (* For completion calls (request_id provided), recover user_message from cache *)
        let user_message =
          if request_id <> "" && user_message = "" then
            match Eio.Mutex.use_rw ~protect:true task_retrieval_mu (fun () ->
              Hashtbl.find_opt task_retrieval_tbl request_id) with
            | Some tr -> tr.user_message
            | None -> user_message
          else user_message
        in
        (* 1. Load task from DB *)
        match Rag_lib.Pg.get_task task_id with
        | Error e ->
            let body = `Assoc [ ("error", `String e) ] |> Yojson.Safe.to_string in
            Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ()
        | Ok None ->
            Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"task not found\n" ()
        | Ok (Some task_json) ->
            let task_kv = match task_json with `Assoc kv -> kv | _ -> [] in
            let task_str k = match List.assoc_opt k task_kv with Some (`String s) -> s | _ -> "" in
            let title = task_str "title" in
            let description = task_str "description" in
            let history_summary = task_str "history_summary" in
            let prior_resolutions = task_str "prior_resolutions" in
            let conversation =
              match List.assoc_opt "conversation" task_kv with
              | Some (`List ms) -> ms
              | _ -> []
            in
            (* Trigger email doc_ids for auto-filling in_reply_to in drafts *)
            let trigger_doc_ids =
              match Rag_lib.Pg.task_trigger_doc_ids task_id with
              | Ok ids -> ids | Error _ -> []
            in
            (* Pre-fetched context email doc_ids *)
            let context_doc_ids =
              match List.assoc_opt "context_emails" task_kv with
              | Some (`List ds) ->
                  List.filter_map (function `String s -> Some s | _ -> None) ds
              | _ -> []
            in

            (* 2. Build email context — always try compressed bodies from task_emails.
               Trigger email bodies are stored at task creation time; context/style
               bodies are populated later by the prefetch daemon. *)
            let task_email_bodies =
              match Rag_lib.Pg.get_task_emails_with_bodies task_id with
              | Ok rows -> rows | Error _ -> []
            in
            let email_aliases = ref [] in
            let alias_idx = ref 0 in
            let email_context_lines = ref [] in
            let style_context_lines = ref [] in
            let seen_doc_ids = Hashtbl.create 16 in
            let md_of_doc_id doc_id =
              match Rag_lib.Pg.get_email_detail doc_id with
              | Ok (Some detail) ->
                  let dkv = match detail with `Assoc kv -> kv | _ -> [] in
                  let md = match List.assoc_opt "metadata" dkv with Some (`Assoc m) -> m | _ -> [] in
                  let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
                  let date = ms "date" in
                  let date = if String.trim date = "" then ms "ingested_at" else date in
                  (ms "from", ms "to", ms "subject", date)
              | _ -> ("", "", "", "")
            in
            let clean_body ~is_style (body : string) : string =
              let lines = String.split_on_char '\n' body in
              let buf = Buffer.create (String.length body) in
              let in_quoted = ref false in
              List.iter (fun line ->
                let trimmed = String.trim line in
                if trimmed = "NEW CONTENT:" then ()
                else if String.length trimmed >= 15
                     && String.sub trimmed 0 14 = "QUOTED CONTEXT" then
                  in_quoted := true
                else if String.length trimmed >= 12
                     && String.sub trimmed 0 12 = "ATTACHMENTS:" then
                  in_quoted := false
                else if is_style && !in_quoted then ()
                else begin
                  if Buffer.length buf > 0 then Buffer.add_char buf '\n';
                  Buffer.add_string buf line
                end
              ) lines;
              String.trim (Buffer.contents buf)
            in
            (* Process all task_email_bodies rows (these have role info) *)
            List.iter (fun (doc_id, role, compressed_body) ->
              if not (Hashtbl.mem seen_doc_ids doc_id) then begin
                Hashtbl.replace seen_doc_ids doc_id true;
                let (from, to_, subject, date) = md_of_doc_id doc_id in
                let body_str = clean_body ~is_style:(role = "style") compressed_body in
                if role = "style" then begin
                  let body_part = if body_str = "" then "(body not yet available)" else body_str in
                  style_context_lines := (Printf.sprintf "---\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s\n\n%s"
                    from to_ subject date body_part) :: !style_context_lines
                end else begin
                  incr alias_idx;
                  let alias = Printf.sprintf "E%d" !alias_idx in
                  email_aliases := (alias, doc_id) :: !email_aliases;
                  let body_part = if body_str = "" then "\n(body not yet available)" else "\n\n" ^ body_str in
                  email_context_lines := (Printf.sprintf "%s [%s]:\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s%s"
                    alias role from to_ subject date body_part) :: !email_context_lines
                end
              end
            ) task_email_bodies;
            (* Also pick up any context_doc_ids not already covered *)
            List.iter (fun did ->
              if not (Hashtbl.mem seen_doc_ids did) then begin
                Hashtbl.replace seen_doc_ids did true;
                incr alias_idx;
                let alias = Printf.sprintf "E%d" !alias_idx in
                email_aliases := (alias, did) :: !email_aliases;
                let (from, to_, subject, date) = md_of_doc_id did in
                let md_line = if from <> "" then
                  Printf.sprintf "%s [context]:\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s\n(body not yet available)"
                    alias from to_ subject date
                else
                  Printf.sprintf "%s [context]: doc_id=%s (metadata unavailable)" alias did
                in
                email_context_lines := md_line :: !email_context_lines
              end
            ) context_doc_ids;
            let email_context =
              if !email_context_lines = [] then "No emails linked to this task."
              else String.concat "\n" (List.rev !email_context_lines)
            in
            (* For completion calls, inject retrieved emails into the context *)
            let email_context =
              if request_id = "" then email_context
              else
                match Eio.Mutex.use_rw ~protect:true task_retrieval_mu (fun () ->
                  Hashtbl.find_opt task_retrieval_tbl request_id) with
                | None -> email_context
                | Some tr ->
                    let lines = ref [] in
                    List.iter (fun doc_id ->
                      let (from, to_, subject, date) = md_of_doc_id doc_id in
                      incr alias_idx;
                      let alias = Printf.sprintf "E%d" !alias_idx in
                      email_aliases := (alias, doc_id) :: !email_aliases;
                      let body = match Hashtbl.find_opt tr.evidence_by_id doc_id with
                        | Some cb when String.trim cb <> "" -> "\n\n" ^ String.trim cb
                        | _ -> "\n(body not available)"
                      in
                      lines := (Printf.sprintf "%s [retrieved]:\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s%s"
                        alias from to_ subject date body) :: !lines
                    ) tr.message_ids;
                    if !lines = [] then email_context
                    else email_context ^ "\n\n" ^ String.concat "\n" (List.rev !lines)
            in
            let style_context =
              if !style_context_lines <> [] then
                "\n\nSTYLE CONTEXT (emails you have sent to the same recipients — match this tone and style):\n"
                ^ String.concat "\n" (List.rev !style_context_lines)
              else ""
            in

            (* 2b. Retrieve user memories for this task *)
            let memories_text =
              if not !memory_enabled then ""
              else
              let task_emb = match Rag_lib.Pg.get_task_embedding task_id with
                | Ok (Some emb) -> emb | _ -> []
              in
              (* Extract trigger email metadata for symbolic matching *)
              let trigger_md = match trigger_doc_ids with
                | doc_id :: _ ->
                    (match Rag_lib.Pg.get_email_detail doc_id with
                    | Ok (Some detail) ->
                        let dkv = match detail with `Assoc kv -> kv | _ -> [] in
                        let md = match List.assoc_opt "metadata" dkv with Some (`Assoc m) -> m | _ -> [] in
                        let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
                        Some (ms "from", ms "to", ms "cc", ms "subject", ms "date")
                    | _ -> None)
                | [] -> None
              in
              match trigger_md, task_emb with
              | Some (sender, recipient, cc, subject, date), emb when emb <> [] ->
                  let text, _ = retrieve_and_format_memories
                    ~sender ~recipient ~cc ~bcc:"" ~subject ~date
                    ~attachments:[] ~embedding:emb () in
                  text
              | Some (sender, recipient, cc, subject, date), _ ->
                  let mems = retrieve_memories_symbolic
                    ~sender ~recipient ~cc ~bcc:"" ~subject ~date
                    ~attachments:[] () in
                  let buf = Buffer.create 256 in
                  List.iter (fun (mid, text) ->
                    Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid text)
                  ) mems;
                  Buffer.contents buf
              | None, emb when emb <> [] ->
                  let mems = retrieve_memories_embedding ~embedding:emb () in
                  let buf = Buffer.create 256 in
                  List.iter (fun (mid, text) ->
                    Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid text)
                  ) mems;
                  Buffer.contents buf
              | _ -> ""
            in

            (* 3. Build system prompt *)
            let user_identity = build_user_identity ~name:(get_str "user_name") ~email:!whoami () in
            let memories_section =
              if String.trim memories_text = "" then ""
              else "USER MEMORIES (persistent preferences — follow these):\n" ^ memories_text
            in
            let prior_resolutions_section =
              if String.trim prior_resolutions = "" then ""
              else "PRIOR RESOLUTIONS (similar tasks resolved in the past — use as reference for tone, approach, and content):\n" ^ prior_resolutions
            in
            let system_prompt =
              get_prompt "task_interview"
                ~default:"You are a task management assistant. Help the user work through their tasks. \
                  Ask short clarifying questions. When ready, draft emails using [DRAFT to=\"...\" subject=\"...\"]...[/DRAFT] markers. \
                  Use [SCORE importance=N] to update importance (0-100). \
                  Use [DEADLINE YYYY-MM-DD] to update deadline. \
                  Use [TITLE ...] or [DESCRIPTION ...] to update task metadata. \
                  Use [DONE] when the task is complete. \
                  Use [TASK_NEW title=\"...\" description=\"...\"] to create a new task. \
                  Use [LINK EN context] to link an email to the current task."
                ~vars:[
                  ("{{user_identity}}", user_identity);
                  ("{{datetime_local}}", now_local_string ());
                  ("{{task_title}}", title);
                  ("{{task_description}}", description);
                  ("{{email_context}}", email_context);
                  ("{{style_context}}", style_context);
                  ("{{history_summary}}", if String.trim history_summary = "" then "(no prior conversation)" else history_summary);
                  ("{{user_memories}}", memories_section);
                  ("{{prior_resolutions}}", prior_resolutions_section);
                ]
            in

            (* 4. Build messages: system + conversation tail + new user message *)
            let user_msg_json =
              `Assoc [ ("role", `String "user"); ("content", `String user_message) ]
            in
            let updated_conversation = conversation @ [ user_msg_json ] in
            (* Strip _llm_debug from previous messages before sending to LLM *)
            let strip_debug msg = match msg with
              | `Assoc kv -> `Assoc (List.filter (fun (k, _) -> not (starts_with "_llm_" k)) kv)
              | other -> other
            in
            let messages : Yojson.Safe.t list =
              (`Assoc [ ("role", `String "system"); ("content", `String system_prompt) ])
              :: List.map strip_debug updated_conversation
            in

            (* 5. Call LLM *)
            let effective_model = if chat_model <> "" then chat_model else !ollama_llm_model in
            (match ollama_chat ~client ~sw ~label:"task_chat" ~model:effective_model ~messages () with
            | Error msg ->
                let body = `Assoc [ ("error", `String msg) ] |> Yojson.Safe.to_string in
                Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body ~headers:json_headers ()
            | Ok raw_resp ->
                let resp_text = String.trim raw_resp in

                (* Helper: find substring *)
                let find_sub s sub from =
                  let sub_len = String.length sub in
                  let s_len = String.length s in
                  let rec loop i =
                    if i + sub_len > s_len then None
                    else if String.sub s i sub_len = sub then Some i
                    else loop (i + 1)
                  in
                  loop from
                in

                (* ── [RETRIEVE] marker: search the email archive ─────── *)
                if request_id = "" && find_sub resp_text "[RETRIEVE]" 0 <> None then begin
                  Printf.printf "[task_chat] [RETRIEVE] detected, running search pipeline\n%!";
                  let ri_start = match find_sub resp_text "[RETRIEVE]" 0 with Some s -> s + 10 | None -> 0 in
                  let ri_end = match find_sub resp_text "[/RETRIEVE]" ri_start with
                    | Some e -> e | None -> String.length resp_text in
                  let retrieve_raw = String.trim (String.sub resp_text ri_start (ri_end - ri_start)) in
                  let retrieve_json = try Some (Yojson.Safe.from_string retrieve_raw) with _ -> None in
                  let rget_str key = match retrieve_json with
                    | Some (`Assoc kv) ->
                        (match List.assoc_opt key kv with
                         | Some (`String s) when String.trim s <> "" && String.trim s <> "..." -> Some (String.trim s)
                         | _ -> None)
                    | _ -> None
                  in
                  let question = match rget_str "question" with Some q -> q | None -> retrieve_raw in
                  let filter = rget_str "filter" in
                  let score_expr = rget_str "score_expr" in
                  Printf.printf "[task_chat.retrieve] question=%s filter=%s\n%!"
                    (truncate_chars question ~max_chars:120)
                    (match filter with Some f -> f | None -> "(none)");
                  (* Build search queries: original question + HyDE hypothetical *)
                  let queries = ref [question] in
                  (match retrieve_json with
                  | Some j ->
                      let hyp_from = (match rget_str "hyp_from" with Some f -> f | None -> "...") in
                      let hyp_to   = (match rget_str "hyp_to"   with Some t -> t | None -> "...") in
                      let hyp_subj = (match rget_str "hyp_subject" with Some s -> s | None -> "...") in
                      let hyp_body = (match rget_str "hyp_body" with Some b -> b | None -> "...") in
                      if hyp_subj <> "..." || hyp_body <> "..." then begin
                        let hyp = Printf.sprintf "From: %s\nTo: %s\nSubject: %s\n\nNEW CONTENT:\n%s"
                          hyp_from hyp_to hyp_subj hyp_body in
                        queries := !queries @ [hyp]
                      end
                  | None -> ());
                  (* Embed each query and search *)
                  let top_k = 10 in
                  let all_sources = List.concat (List.map (fun query_text ->
                    match ollama_embed ~client ~sw ~task:Search_query
                        ~label:"task_retrieve" ~text:query_text () with
                    | Error msg ->
                        Printf.eprintf "[task_chat.retrieve.embed.error] %s\n%!" msg; []
                    | Ok v ->
                        let emb = l2_normalize v in
                        (match Rag_lib.Pg.query_knn ~embedding:emb ~top_k ?filter ?score_expr () with
                        | Error msg ->
                            Printf.eprintf "[task_chat.retrieve.knn.error] %s\n%!" msg;
                            (* Fallback: retry without filter/score *)
                            if filter <> None || score_expr <> None then
                              (match Rag_lib.Pg.query_knn ~embedding:emb ~top_k () with
                              | Ok (sources, _) -> sources | Error _ -> [])
                            else []
                        | Ok (sources, _sql) -> sources)
                  ) !queries) in
                  let sources_json = merge_multi_query_sources all_sources top_k in
                  (* Select relevant sources *)
                  let user_name = match !whoami with "" -> "" | w -> w in
                  let sel_message_ids =
                    select_relevant_sources ~client ~sw ~resolved_question:question
                      ~user_name sources_json
                  in
                  Printf.printf "[task_chat.retrieve] %d queries -> %d sources -> %d selected\n%!"
                    (List.length !queries)
                    (match sources_json with `List l -> List.length l | _ -> 0)
                    (List.length sel_message_ids);
                  (* Cache retrieval state *)
                  let req_id = fresh_request_id task_id question in
                  let tr : pending_task_retrieval =
                    { task_id; user_message; chat_model
                    ; message_ids = sel_message_ids
                    ; sources_json
                    ; evidence_by_id = Hashtbl.create 16
                    ; created_at = Unix.gettimeofday ()
                    } in
                  Eio.Mutex.use_rw ~protect:true task_retrieval_mu (fun () ->
                    Hashtbl.replace task_retrieval_tbl req_id tr);
                  (* Return retrieval response — TB must upload bodies then re-call *)
                  let body = `Assoc
                    [ ("status", `String "retrieval")
                    ; ("request_id", `String req_id)
                    ; ("message_ids", `List (List.map (fun s -> `String s) sel_message_ids))
                    ; ("sources", sources_json)
                    ] |> Yojson.Safe.to_string in
                  Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
                end else begin

                let side_effects = ref [] in

                (* 6. Parse structured markers *)

                (* Parse [DRAFT ...] ... [/DRAFT] *)
                let drafts = ref [] in
                let rec parse_drafts text from =
                  match find_sub text "[DRAFT" from with
                  | None -> ()
                  | Some di ->
                      (* Find the end of the opening tag line *)
                      let tag_end = match find_sub text "]" di with Some e -> e + 1 | None -> di + 6 in
                      let tag_content = String.sub text (di + 6) (tag_end - di - 7) |> String.trim in
                      (* Parse tag attributes: to="..." cc="..." subject="..." in_reply_to=E1 *)
                      let parse_attr name content =
                        let pat = name ^ "=\"" in
                        match find_sub content pat 0 with
                        | None -> ""
                        | Some si ->
                            let start = si + String.length pat in
                            (match find_sub content "\"" start with
                            | Some ei -> String.sub content start (ei - start)
                            | None -> "")
                      in
                      let parse_attr_unquoted name content =
                        let pat = name ^ "=" in
                        match find_sub content pat 0 with
                        | None -> ""
                        | Some si ->
                            let start = si + String.length pat in
                            let end_pos = ref (String.length content) in
                            for i = start to String.length content - 1 do
                              if (content.[i] = ' ' || content.[i] = ']') && !end_pos > i then
                                end_pos := i
                            done;
                            String.sub content start (!end_pos - start) |> String.trim
                      in
                      let draft_to = parse_attr "to" tag_content in
                      let draft_cc = parse_attr "cc" tag_content in
                      let draft_bcc = parse_attr "bcc" tag_content in
                      let draft_subject = parse_attr "subject" tag_content in
                      let draft_in_reply_to = parse_attr_unquoted "in_reply_to" tag_content in
                      (* Find [/DRAFT] — if missing, treat rest of text as draft body *)
                      let end_di, resume =
                        match find_sub text "[/DRAFT]" tag_end with
                        | Some ei -> (ei, ei + 8)
                        | None -> (String.length text, String.length text)
                      in
                      let draft_body = String.trim (String.sub text tag_end (end_di - tag_end)) in
                      if draft_body <> "" then begin
                        let reply_to = if draft_in_reply_to <> "" then draft_in_reply_to
                          else match trigger_doc_ids with x :: _ -> x | [] -> "" in
                        let draft_json = `Assoc
                          [ ("to", `String draft_to)
                          ; ("cc", `String draft_cc)
                          ; ("bcc", `String draft_bcc)
                          ; ("subject", `String draft_subject)
                          ; ("body", `String draft_body)
                          ; ("in_reply_to", `String reply_to)
                          ] in
                        drafts := draft_json :: !drafts;
                        side_effects := `Assoc [ ("type", `String "draft"); ("draft", draft_json) ] :: !side_effects
                      end;
                      if resume < String.length text then
                        parse_drafts text resume
                in
                parse_drafts resp_text 0;

                (* Parse [SCORE importance=N] *)
                let new_importance = ref None in
                (match find_sub resp_text "[SCORE " 0 with
                | None -> ()
                | Some si ->
                    let tag_end = match find_sub resp_text "]" si with Some e -> e | None -> si in
                    let tag = String.sub resp_text si (tag_end - si + 1) in
                    (match find_sub tag "importance=" 0 with
                    | None -> ()
                    | Some ii ->
                        let start = ii + 11 in
                        let num_str = ref "" in
                        for i = start to String.length tag - 1 do
                          let c = tag.[i] in
                          if c >= '0' && c <= '9' then num_str := !num_str ^ String.make 1 c
                        done;
                        if !num_str <> "" then begin
                          let n = max 0 (min 100 (int_of_string !num_str)) in
                          new_importance := Some n;
                          side_effects := `Assoc [ ("type", `String "score"); ("importance", `Int n) ] :: !side_effects
                        end));

                (* Parse [DEADLINE YYYY-MM-DD] *)
                let new_deadline = ref None in
                (match find_sub resp_text "[DEADLINE " 0 with
                | None -> ()
                | Some si ->
                    let start = si + 10 in
                    let tag_end = match find_sub resp_text "]" start with Some e -> e | None -> start in
                    let deadline_str = String.trim (String.sub resp_text start (tag_end - start)) in
                    if String.length deadline_str >= 10 then begin
                      new_deadline := Some deadline_str;
                      side_effects := `Assoc [ ("type", `String "deadline"); ("deadline", `String deadline_str) ] :: !side_effects
                    end);

                (* Parse [TITLE ...] *)
                let new_title = ref None in
                (match find_sub resp_text "[TITLE " 0 with
                | None -> ()
                | Some si ->
                    let start = si + 7 in
                    let tag_end = match find_sub resp_text "]" start with Some e -> e | None -> start in
                    let t = String.trim (String.sub resp_text start (tag_end - start)) in
                    if t <> "" then begin
                      new_title := Some t;
                      side_effects := `Assoc [ ("type", `String "title"); ("title", `String t) ] :: !side_effects
                    end);

                (* Parse [DESCRIPTION ...] *)
                let new_description = ref None in
                (match find_sub resp_text "[DESCRIPTION " 0 with
                | None -> ()
                | Some si ->
                    let start = si + 13 in
                    let tag_end = match find_sub resp_text "]" start with Some e -> e | None -> start in
                    let d = String.trim (String.sub resp_text start (tag_end - start)) in
                    if d <> "" then begin
                      new_description := Some d;
                      side_effects := `Assoc [ ("type", `String "description"); ("description", `String d) ] :: !side_effects
                    end);

                (* Parse [DONE] *)
                let is_done = find_sub resp_text "[DONE]" 0 <> None in
                if is_done then
                  side_effects := `Assoc [ ("type", `String "done") ] :: !side_effects;

                (* Parse [DISMISS] *)
                let is_dismissed = find_sub resp_text "[DISMISS]" 0 <> None in
                if is_dismissed then
                  side_effects := `Assoc [ ("type", `String "dismiss") ] :: !side_effects;

                (* Parse [DELETE] *)
                let is_deleted = find_sub resp_text "[DELETE]" 0 <> None in
                if is_deleted then
                  side_effects := `Assoc [ ("type", `String "delete") ] :: !side_effects;

                (* Parse [RECOMPUTE] *)
                if find_sub resp_text "[RECOMPUTE]" 0 <> None then
                  side_effects := `Assoc [ ("type", `String "recompute") ] :: !side_effects;

                (* Parse [NEXT] *)
                if find_sub resp_text "[NEXT]" 0 <> None then
                  side_effects := `Assoc [ ("type", `String "next") ] :: !side_effects;

                (* Parse [PREVIOUS] *)
                if find_sub resp_text "[PREVIOUS]" 0 <> None then
                  side_effects := `Assoc [ ("type", `String "previous") ] :: !side_effects;

                (* Parse [TASK_NEW title="..." description="..."] *)
                (match find_sub resp_text "[TASK_NEW " 0 with
                | None -> ()
                | Some si ->
                    let tag_end = match find_sub resp_text "]" si with Some e -> e | None -> si in
                    let tag = String.sub resp_text si (tag_end - si + 1) in
                    let parse_attr name =
                      let pat = name ^ "=\"" in
                      match find_sub tag pat 0 with
                      | None -> ""
                      | Some ai ->
                          let start = ai + String.length pat in
                          (match find_sub tag "\"" start with
                          | Some ei -> String.sub tag start (ei - start)
                          | None -> "")
                    in
                    let new_title_ = parse_attr "title" in
                    let new_desc = parse_attr "description" in
                    if new_title_ <> "" then begin
                      (* Create the new task *)
                      let new_task_id = generate_task_id () in
                      (match Rag_lib.Pg.create_task
                        ~task_id:new_task_id ~title:new_title_ ~description:new_desc
                        ~importance_score:None ~deadline:""
                        ~embedding:[] ~conversation_json:"[]" ~drafts_json:"[]" () with
                      | Ok () ->
                          side_effects := `Assoc
                            [ ("type", `String "task_new")
                            ; ("task_id", `String new_task_id)
                            ; ("title", `String new_title_)
                            ; ("description", `String new_desc)
                            ] :: !side_effects;
                          Printf.printf "[task_chat] created new task %s: %s\n%!" new_task_id new_title_
                      | Error e ->
                          Printf.eprintf "[task_chat] failed to create task: %s\n%!" e)
                    end);

                (* Parse [LINK EN role] *)
                (match find_sub resp_text "[LINK " 0 with
                | None -> ()
                | Some si ->
                    let start = si + 6 in
                    let tag_end = match find_sub resp_text "]" start with Some e -> e | None -> start in
                    let content = String.trim (String.sub resp_text start (tag_end - start)) in
                    let parts = String.split_on_char ' ' content in
                    (match parts with
                    | alias :: rest ->
                        let role = match rest with r :: _ -> String.trim r | [] -> "context" in
                        (* Resolve alias to doc_id *)
                        let doc_id_opt =
                          List.find_opt (fun (a, _) -> a = alias) (List.rev !email_aliases)
                          |> Option.map snd
                        in
                        (match doc_id_opt with
                        | Some doc_id ->
                            (match Rag_lib.Pg.link_email_to_task ~task_id ~doc_id ~role () with
                            | Ok () ->
                                side_effects := `Assoc
                                  [ ("type", `String "link")
                                  ; ("alias", `String alias)
                                  ; ("doc_id", `String doc_id)
                                  ; ("role", `String role)
                                  ] :: !side_effects
                            | Error e ->
                                Printf.eprintf "[task_chat] link error: %s\n%!" e)
                        | None ->
                            Printf.eprintf "[task_chat] unknown alias: %s\n%!" alias)
                    | [] -> ()));

                (* Parse [MEMORY ...] or [MEMORY] ... — create a persistent user memory from this task *)
                (let memory_text_opt =
                  match find_sub resp_text "[MEMORY " 0 with
                  | Some si ->
                      (* Format: [MEMORY text here] *)
                      let start = si + 8 in
                      let tag_end = match find_sub resp_text "]" start with Some e -> e | None -> start in
                      let t = String.trim (String.sub resp_text start (tag_end - start)) in
                      if t <> "" then Some t else None
                  | None ->
                      (* Fallback: [MEMORY] text until end of line *)
                      match find_sub resp_text "[MEMORY]" 0 with
                      | Some si ->
                          let after = si + 8 in
                          if after < String.length resp_text then
                            let rest = String.sub resp_text after (String.length resp_text - after) in
                            let line = match String.index_opt rest '\n' with
                              | Some nl -> String.sub rest 0 nl
                              | None -> rest
                            in
                            let t = String.trim line in
                            if t <> "" then Some t else None
                          else None
                      | None -> None
                in
                match memory_text_opt with
                | None -> ()
                | Some memory_text ->
                    if memory_text <> "" && !memory_enabled then begin
                      let memory_id = Printf.sprintf "mem-%08x-%04x-%04x"
                        (Random.bits ()) (Random.int 0xFFFF) (Random.int 0xFFFF) in
                      (match Rag_lib.Pg.create_memory ~memory_id ~text:memory_text
                          ~source_task_id:task_id () with
                      | Ok () ->
                          (* Link trigger emails to this memory *)
                          List.iter (fun doc_id ->
                            ignore (Rag_lib.Pg.link_email_to_memory ~memory_id ~doc_id)
                          ) trigger_doc_ids;
                          side_effects := `Assoc
                            [ ("type", `String "memory")
                            ; ("memory_id", `String memory_id)
                            ; ("text", `String memory_text)
                            ] :: !side_effects;
                          Printf.printf "[task_chat] created memory %s: %s\n%!" memory_id
                            (truncate_chars memory_text ~max_chars:80);
                          (* Background: generate symbolic rule + template emails *)
                          Eio.Fiber.fork ~sw (fun () ->
                            generate_memory_rule_and_templates ~client ~sw ~memory_id ~memory_text
                              ~trigger_doc_ids ())
                      | Error e ->
                          Printf.eprintf "[task_chat] memory create error: %s\n%!" e)
                    end);

                (* 7. Strip markers from display text *)
                let display_text =
                  let t = ref resp_text in
                  (* Replace [DRAFT]...[/DRAFT] blocks with a placeholder *)
                  let rec strip_drafts () =
                    match find_sub !t "[DRAFT" 0 with
                    | None -> ()
                    | Some di ->
                        let ei, skip =
                          match find_sub !t "[/DRAFT]" di with
                          | Some ei -> (ei, ei + 8)
                          | None -> (String.length !t, String.length !t)
                        in
                        let before = String.sub !t 0 di in
                        let after = if skip < String.length !t
                          then String.sub !t skip (String.length !t - skip) else "" in
                        t := before ^ "See the draft in the right-hand pane." ^ after;
                        strip_drafts ()
                  in
                  strip_drafts ();
                  (* Strip [RETRIEVE]...[/RETRIEVE] blocks *)
                  let rec strip_retrieves () =
                    match find_sub !t "[RETRIEVE]" 0 with
                    | None -> ()
                    | Some di ->
                        let ei, skip =
                          match find_sub !t "[/RETRIEVE]" di with
                          | Some ei -> (ei, ei + 11)
                          | None -> (String.length !t, String.length !t)
                        in
                        let before = String.sub !t 0 di in
                        let after = if skip < String.length !t
                          then String.sub !t skip (String.length !t - skip) else "" in
                        t := before ^ after;
                        strip_retrieves ()
                  in
                  strip_retrieves ();
                  (* Remove single-line markers *)
                  let lines = String.split_on_char '\n' !t in
                  let filtered = List.filter (fun line ->
                    let l = String.trim line in
                    not (
                      (String.length l > 7 && String.sub l 0 7 = "[SCORE ")
                      || (String.length l > 10 && String.sub l 0 10 = "[DEADLINE ")
                      || (String.length l > 7 && String.sub l 0 7 = "[TITLE ")
                      || (String.length l > 13 && String.sub l 0 13 = "[DESCRIPTION ")
                      || l = "[DONE]"
                      || l = "[DISMISS]"
                      || l = "[DELETE]"
                      || l = "[RECOMPUTE]"
                      || l = "[NEXT]"
                      || l = "[PREVIOUS]"
                      || (String.length l > 10 && String.sub l 0 10 = "[TASK_NEW ")
                      || (String.length l > 6 && String.sub l 0 6 = "[LINK ")
                      || (String.length l > 8 && String.sub l 0 8 = "[MEMORY ")
                      || (String.length l >= 8 && String.sub l 0 8 = "[MEMORY]")
                    )) lines
                  in
                  let has_memory_marker = List.exists (fun line ->
                    let l = String.trim line in
                    (String.length l > 8 && String.sub l 0 8 = "[MEMORY ")
                    || (String.length l >= 8 && String.sub l 0 8 = "[MEMORY]")
                  ) lines in
                  let joined = String.concat "\n" filtered |> String.trim in
                  if joined = "" && has_memory_marker then
                    "Thank you, your input has been recorded as a permanent memory."
                  else joined
                in

                (* 8. Update task in DB — store cleaned text + debug info *)
                let llm_debug = `Assoc
                  [ ("model", `String effective_model)
                  ; ("messages", `List messages)
                  ; ("raw_response", `String resp_text)
                  ] in
                let assistant_msg_json =
                  `Assoc [ ("role", `String "assistant"); ("content", `String display_text)
                         ; ("_llm_debug", llm_debug) ]
                in
                let final_conversation = updated_conversation @ [ assistant_msg_json ] in
                let new_drafts_json =
                  if !drafts <> [] then
                    let existing = match List.assoc_opt "drafts" task_kv with
                      | Some (`List ds) -> ds | _ -> []
                    in
                    Some (Yojson.Safe.to_string (`List (existing @ List.rev !drafts)))
                  else None
                in
                let new_status =
                  if is_done then Some "done"
                  else if is_dismissed then Some "dismissed"
                  else if conversation = [] then Some "in_progress"
                  else None
                in
                let importance_update =
                  match !new_importance with
                  | Some n -> Some (Some n)
                  | None -> None
                in
                (match Rag_lib.Pg.update_task ~task_id
                  ?title:!new_title
                  ?description:!new_description
                  ?status:new_status
                  ?importance_score:importance_update
                  ?deadline:!new_deadline
                  ?drafts_json:new_drafts_json
                  ~conversation_json:(Yojson.Safe.to_string (`List final_conversation))
                  () with
                | Ok _ -> ()
                | Error e -> Printf.eprintf "[task_chat] update error: %s\n%!" e);

                (* 8b. Lifecycle: rolling summary or archival *)
                let task_history_summary = match List.assoc_opt "history_summary" task_kv with
                  | Some (`String s) -> s | _ -> ""
                in
                if is_done || is_dismissed then begin
                  archive_task_conversation ~client ~sw ~task_id
                    ~conversation:final_conversation
                    ~history_summary:task_history_summary
                    ~title ();
                  (* Mark trigger emails as processed *)
                  (match Rag_lib.Pg.task_trigger_doc_ids task_id with
                  | Ok doc_ids ->
                      List.iter (fun did ->
                        ignore (Rag_lib.Pg.set_processed did true)
                      ) doc_ids
                  | Error e ->
                      Printf.eprintf "[task_chat.done] failed to fetch trigger doc_ids: %s\n%!" e)
                end else
                  maybe_summarize_task_conversation ~client ~sw ~task_id
                    ~conversation:final_conversation
                    ~history_summary:task_history_summary ();

                (* Handle [RECOMPUTE]: reset context flags and clear context/style emails *)
                if find_sub resp_text "[RECOMPUTE]" 0 <> None then begin
                  (match Rag_lib.Pg.update_task ~task_id
                      ~context_prefetched:false ~context_ready:false
                      ~context_emails_json:"[]" () with
                  | Ok _ ->
                      ignore (Rag_lib.Pg.delete_task_context_and_style task_id);
                      Printf.printf "[task_chat] recompute triggered for task %s\n%!" task_id;
                      !notify_prefetch ()
                  | Error e ->
                      Printf.eprintf "[task_chat] recompute error: %s\n%!" e)
                end;

                (* Handle [DELETE]: delete the task *)
                if is_deleted then begin
                  (match Rag_lib.Pg.delete_task task_id with
                  | Ok true ->
                      Printf.printf "[task_chat] deleted task %s via [DELETE] marker\n%!" task_id
                  | Ok false ->
                      Printf.eprintf "[task_chat] task %s not found for deletion\n%!" task_id
                  | Error e ->
                      Printf.eprintf "[task_chat] delete error: %s\n%!" e)
                end;

                (* 9. Return response *)
                let resp_json = `Assoc
                  [ ("message", `String display_text)
                  ; ("raw_message", `String resp_text)
                  ; ("task_id", `String task_id)
                  ; ("side_effects", `List (List.rev !side_effects))
                  ; ("is_done", `Bool is_done)
                  ] in
                (* Clean up retrieval cache on completion calls *)
                if request_id <> "" then
                  Eio.Mutex.use_rw ~protect:true task_retrieval_mu (fun () ->
                    Hashtbl.remove task_retrieval_tbl request_id);

                Cohttp_eio.Server.respond_string ~status:`OK
                  ~body:(Yojson.Safe.to_string resp_json) ~headers:json_headers ()
                end)
      with e ->
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:(Printf.sprintf "task/chat error: %s\n" (Printexc.to_string e)) ())

  (* ===================================================================
     Voice endpoints: TTS (Piper) and STT (sox mic + Whisper)
     =================================================================== *)

  | `POST, "/synthesize" ->
      let raw = read_all body in
      let text =
        try match Yojson.Safe.from_string raw with
          | `Assoc kv -> (match List.assoc_opt "text" kv with Some (`String s) -> String.trim s | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      if text = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:{|{"error":"empty text"}|} ~headers:json_headers ()
      else if String.trim !voice_piper_model = "" then
        Cohttp_eio.Server.respond_string ~status:`Internal_server_error
          ~body:{|{"error":"voice.piper_model not configured in settings.json"}|} ~headers:json_headers ()
      else begin
        let tmp = Filename.temp_file "piper_tts" ".wav" in
        let cmd = Printf.sprintf "printf '%%s' %s | %s --model %s --output_file %s 2>&1"
          (Filename.quote text) (Filename.quote !voice_piper_bin)
          (Filename.quote !voice_piper_model) (Filename.quote tmp) in
        let ok = match run_shell_capture_stdout cmd with Some _ -> true | None -> false in
        if ok && Sys.file_exists tmp then begin
          let ic = open_in_bin tmp in
          let n = in_channel_length ic in
          let wav = Bytes.create n in
          really_input ic wav 0 n;
          close_in ic;
          (try Sys.remove tmp with _ -> ());
          let wav_headers = Http.Header.of_list
            [ ("content-type", "audio/wav")
            ; ("content-length", string_of_int n)
            ; ("access-control-allow-origin", "*")
            ; ("connection", "close") ] in
          Cohttp_eio.Server.respond_string ~status:`OK
            ~body:(Bytes.to_string wav) ~headers:wav_headers ()
        end else begin
          (try Sys.remove tmp with _ -> ());
          Cohttp_eio.Server.respond_string ~status:`Internal_server_error
            ~body:{|{"error":"piper failed"}|} ~headers:json_headers ()
        end
      end

  | `POST, path when starts_with "/mic/start/" path ->
      let after = String.sub path 11 (String.length path - 11) in
      let sid, query_str = match String.index_opt after '?' with
        | Some qi -> (String.sub after 0 qi,
                     String.sub after (qi + 1) (String.length after - qi - 1))
        | None -> (after, "")
      in
      let param key default =
        let prefix = key ^ "=" in
        let parts = String.split_on_char '&' query_str in
        match List.find_opt (fun p -> starts_with prefix p) parts with
        | Some p -> String.sub p (String.length prefix) (String.length p - String.length prefix)
        | None -> default
      in
      let silence = (try float_of_string (param "silence" "0.7") with _ -> 0.7) in
      let stop_word = Uri.pct_decode (param "stop_word" "over") in

      voice_cleanup_old ();

      (* Stop any existing session with this ID *)
      Mutex.lock voice_mu;
      (match Hashtbl.find_opt voice_sessions sid with
      | Some s when not s.done_ -> s.stop <- true
      | _ -> ());
      (* Create new session *)
      Hashtbl.replace voice_sessions sid
        { text = ""; done_ = false; stop = false; ts = Unix.gettimeofday () };
      Mutex.unlock voice_mu;

      (* Start recording in background thread *)
      ignore (Thread.create (fun () -> voice_mic_worker sid silence stop_word) ());

      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Printf.sprintf {|{"ok":true,"session":"%s"}|} (String.escaped sid))
        ~headers:json_headers ()

  | `POST, path when starts_with "/mic/stop/" path ->
      let sid = let s = String.sub path 10 (String.length path - 10) in
        match String.index_opt s '?' with Some qi -> String.sub s 0 qi | None -> s in

      (* Signal stop *)
      Mutex.lock voice_mu;
      (match Hashtbl.find_opt voice_sessions sid with
      | Some s -> s.stop <- true
      | None -> ());
      Mutex.unlock voice_mu;

      (* Wait briefly for worker to finish (up to 10s) *)
      let rec wait_done n =
        if n <= 0 then ()
        else begin
          Unix.sleepf 0.5;
          Mutex.lock voice_mu;
          let done_ = match Hashtbl.find_opt voice_sessions sid with
            | Some s -> s.done_ | None -> true in
          Mutex.unlock voice_mu;
          if not done_ then wait_done (n - 1)
        end
      in
      wait_done 20;

      Mutex.lock voice_mu;
      let text = match Hashtbl.find_opt voice_sessions sid with
        | Some s -> s.text | None -> "" in
      Mutex.unlock voice_mu;

      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Printf.sprintf {|{"text":%s,"done":true}|}
          (Yojson.Safe.to_string (`String text)))
        ~headers:json_headers ()

  | `GET, path when starts_with "/mic/result/" path ->
      let sid = let s = String.sub path 12 (String.length path - 12) in
        match String.index_opt s '?' with Some qi -> String.sub s 0 qi | None -> s in
      Mutex.lock voice_mu;
      let (text, done_) = match Hashtbl.find_opt voice_sessions sid with
        | Some s -> (s.text, s.done_)
        | None -> ("", false) in
      Mutex.unlock voice_mu;

      Cohttp_eio.Server.respond_string ~status:`OK
        ~body:(Printf.sprintf {|{"text":%s,"done":%s}|}
          (Yojson.Safe.to_string (`String text))
          (if done_ then "true" else "false"))
        ~headers:json_headers ()

  | `POST, _ ->
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"not found\n" ()
  | _ ->
      Cohttp_eio.Server.respond_string ~status:`Method_not_allowed ~body:"method not allowed\n" ()
  in
  if is_high_priority then with_high_priority dispatch
  else dispatch ()

let log_warning ex = Logs.warn (fun f -> f "%a" Eio.Exn.pp ex)

let () =
  Logs.set_reporter (Logs_fmt.reporter ())

(*
  Server startup

  Parses -p <port>, initialises the Eio event loop, binds the TCP socket
  (with a user-friendly error on EADDRINUSE), and starts the cohttp server.
*)
let () =
  let port = ref 8080 in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number (8080 by default)")
    ; ("--config-dir", Arg.Set_string config_dir, " Config directory for settings.json and prompts.json (default: ~/.rag-o-mail)")
    ]
    ignore "RAG email ingest server";

  (* Install defaults to config dir if not already present, then load *)
  ensure_dir (rag_config_dir ());
  install_default_if_missing
    ~src:(default_settings_path ())
    ~dst:(settings_path ());
  install_default_if_missing
    ~src:(default_prompts_path ())
    ~dst:(prompts_path ());
  load_settings ();

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  global_with_timeout := (fun seconds fn ->
    try Eio.Time.with_timeout_exn env#clock seconds fn
    with Eio.Time.Timeout ->
      raise (Failure (Printf.sprintf "ollama request timed out after %.0fs" seconds)));
  let client = Cohttp_eio.Client.make ~https:None env#net in
  (* Initialise PostgreSQL connection pool and schema *)
  let pg_stdenv : Caqti_eio.stdenv = object
    method net = (env#net :> [`Generic] Eio.Net.ty Eio.Std.r)
    method clock = env#clock
    method mono_clock = env#mono_clock
  end in
  (match Rag_lib.Pg.init ~sw ~stdenv:pg_stdenv with
   | Ok () -> ()
   | Error e ->
       Printf.eprintf "FATAL: PostgreSQL init failed: %s\n%!" e;
       exit 1);
  (* Purge emails with empty metadata (encrypted/unreadable — slipped through before the check) *)
  (match Rag_lib.Pg.purge_empty_metadata () with
   | Ok 0 -> ()
   | Ok n -> Printf.printf "[startup] purged %d emails with empty metadata (from/to/subject all blank)\n%!" n
   | Error e -> Printf.eprintf "[startup] purge_empty_metadata error: %s\n%!" e);
  (* Purge emails whose chunks contain raw base64 (body extraction failed to decode) *)
  (match Rag_lib.Pg.purge_base64_chunks () with
   | Ok 0 -> ()
   | Ok n -> Printf.printf "[startup] purged %d emails with base64-encoded chunks (body was not decoded)\n%!" n
   | Error e -> Printf.eprintf "[startup] purge_base64_chunks error: %s\n%!" e);
  (* --- Background task context prefetch daemon --- *)
  let prefetch_wake = Eio.Stream.create 10 in
  notify_prefetch := (fun () ->
    try Eio.Stream.add prefetch_wake () with _ -> ());
  (* Phase 0: triage — run propose_tasks + process_task_proposals for queued emails *)
  let triage_one_email ~client ~sw (doc_id : string) (body_text : string) (compressed_body : string) : unit =
    Printf.printf "[daemon.triage] processing doc_id=%s\n%!" doc_id;
    (* Get email metadata from DB *)
    let from_, to_, cc_, bcc_, subject, date_, attachments =
      match Rag_lib.Pg.get_email_detail doc_id with
      | Ok (Some detail) ->
          let md = match detail with
            | `Assoc kv -> (match List.assoc_opt "metadata" kv with Some (`Assoc m) -> m | _ -> [])
            | _ -> []
          in
          let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
          let atts = match List.assoc_opt "attachments" md with
            | Some (`List items) -> List.filter_map (fun j ->
                match j with `String s -> Some s | _ -> None) items
            | _ -> []
          in
          (ms "from", ms "to", ms "cc", ms "bcc", ms "subject", ms "date", atts)
      | _ ->
          Printf.eprintf "[daemon.triage] no metadata for %s, skipping\n%!" doc_id;
          ("", "", "", "", "", "", [])
    in
    if from_ = "" && to_ = "" && subject = "" then begin
      Printf.eprintf "[daemon.triage] empty metadata for %s, deleting from queue\n%!" doc_id;
      ignore (Rag_lib.Pg.delete_triage_entry doc_id)
    end else begin
      let whoami = String.trim !whoami in
      (* Retrieve memories if enabled *)
      let memories_text =
        if not !memory_enabled then ""
        else begin
          let repr_embedding = match Rag_lib.Pg.get_doc_embedding doc_id with
            | Ok (Some emb) -> emb | _ -> []
          in
          if repr_embedding <> [] then
            let text, _ = retrieve_and_format_memories
              ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_
              ~subject ~date:date_ ~attachments
              ~embedding:repr_embedding () in
            text
          else begin
            let sym = retrieve_memories_symbolic
              ~sender:from_ ~recipient:to_ ~cc:cc_ ~bcc:bcc_
              ~subject ~date:date_ ~attachments () in
            let buf = Buffer.create 256 in
            List.iter (fun (mid, text) ->
              Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid text)
            ) sym;
            Buffer.contents buf
          end
        end
      in
      let (task_proposals, pt_debug) = propose_tasks ~client ~sw ~whoami
        ~from_ ~to_ ~cc_ ~bcc_ ~subject ~date_ ~body_text
        ~memories_text in
      (match pt_debug with
      | Some dbg -> ignore (Rag_lib.Pg.set_propose_tasks_debug doc_id (Yojson.Safe.to_string dbg))
      | None -> ());
      if task_proposals <> [] then
        process_task_proposals ~client ~sw ~doc_id ~body_text:compressed_body
          ~email_date:date_ ~proposals:task_proposals ();
      Printf.printf "[daemon.triage] doc_id=%s proposals=%d\n%!" doc_id (List.length task_proposals);
      ignore (Rag_lib.Pg.delete_triage_entry doc_id)
    end
  in
  let prefetch_one_task ~client ~sw (task_id : string) (title : string) : unit =
    Printf.printf "[prefetch] starting for task %s: %s\n%!" task_id title;
    let trigger_doc_ids = match Rag_lib.Pg.task_trigger_doc_ids task_id with
      | Ok ids -> ids | Error _ -> []
    in
    let trigger_set = Hashtbl.create 16 in
    List.iter (fun did -> Hashtbl.replace trigger_set did true) trigger_doc_ids;
    (* Collect embeddings: task embedding + trigger email embeddings *)
    let embeddings = ref [] in
    (match Rag_lib.Pg.get_task_embedding task_id with
    | Ok (Some emb) -> embeddings := emb :: !embeddings
    | _ -> ());
    List.iter (fun doc_id ->
      match Rag_lib.Pg.get_doc_embedding doc_id with
      | Ok (Some emb) -> embeddings := emb :: !embeddings
      | _ -> ()
    ) trigger_doc_ids;
    if !embeddings = [] then begin
      Printf.eprintf "[prefetch] no embeddings found for task %s, skipping\n%!" task_id;
      ignore (Rag_lib.Pg.update_task ~task_id ~context_prefetched:true ())
    end else begin
      (* kNN for each embedding, collect unique doc_ids excluding triggers *)
      let top_k_per = 10 in
      let seen = Hashtbl.create 64 in
      let all_results = ref [] in
      List.iter (fun emb ->
        match Rag_lib.Pg.query_knn ~embedding:emb ~top_k:top_k_per () with
        | Ok (rows, _sql) ->
            List.iter (fun row ->
              let rkv = match row with `Assoc kv -> kv | _ -> [] in
              let doc_id = match List.assoc_opt "doc_id" rkv with
                | Some (`String s) -> s | _ -> "" in
              if doc_id <> "" && not (Hashtbl.mem trigger_set doc_id)
                 && not (Hashtbl.mem seen doc_id) then begin
                Hashtbl.replace seen doc_id true;
                all_results := row :: !all_results
              end
            ) rows
        | Error e ->
            Printf.eprintf "[prefetch] kNN error: %s\n%!" e
      ) !embeddings;
      let candidates = List.rev !all_results in
      let n_candidates = List.length candidates in
      Printf.printf "[prefetch] task %s: %d candidate emails from %d embeddings\n%!"
        task_id n_candidates (List.length !embeddings);
      if n_candidates = 0 then
        ignore (Rag_lib.Pg.update_task ~task_id
          ~context_emails_json:"[]" ~context_prefetched:true ())
      else begin
        (* Use shared select_relevant_sources to pick the most relevant candidates *)
        let task_desc = Printf.sprintf "Task: %s\nTrigger emails: %s"
          title
          (String.concat ", " (List.map (fun did ->
            match Rag_lib.Pg.get_email_detail did with
            | Ok (Some detail) ->
                let dkv = match detail with `Assoc kv -> kv | _ -> [] in
                let md = match List.assoc_opt "metadata" dkv with Some (`Assoc m) -> m | _ -> [] in
                let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
                Printf.sprintf "%s (%s)" (ms "subject") (ms "from")
            | _ -> did
          ) trigger_doc_ids))
        in
        let selected_doc_ids = select_relevant_sources ~client ~sw
          ~resolved_question:task_desc ~user_name:""
          ~rewrite_model:!ollama_triage_model
          (`List candidates)
        in
        (* Insert context doc_ids into task_emails *)
        List.iter (fun did ->
          ignore (Rag_lib.Pg.link_email_to_task ~task_id ~doc_id:did ~role:"context" ())
        ) selected_doc_ids;
        Printf.printf "[prefetch] task %s: stored %d context emails\n%!"
          task_id (List.length selected_doc_ids);

        (* Style email selection: find user's sent emails to trigger senders.
           Only match against the 'from' field — the person(s) who wrote to you
           and whom you're likely replying to. Cap at 4 total style emails. *)
        let max_style = 4 in
        let user_emails = extract_email_addresses !whoami in
        if user_emails <> [] then begin
          let recipients = ref [] in
          List.iter (fun did ->
            match Rag_lib.Pg.get_email_detail did with
            | Ok (Some detail) ->
                let md = match detail with
                  | `Assoc kv -> (match List.assoc_opt "metadata" kv with Some (`Assoc m) -> m | _ -> [])
                  | _ -> []
                in
                let v = match List.assoc_opt "from" md with Some (`String s) -> s | _ -> "" in
                if String.trim v <> "" then
                  let addrs = extract_email_addresses v in
                  List.iter (fun addr ->
                    if not (List.mem addr user_emails) && not (List.mem addr !recipients) then
                      recipients := addr :: !recipients
                  ) addrs
            | _ -> ()
          ) trigger_doc_ids;
          let recipients = List.rev !recipients in
          Printf.printf "[prefetch] task %s: %d recipients for style search\n%!"
            task_id (List.length recipients);
          let style_count = ref 0 in
          List.iter (fun recip ->
            if !style_count < max_style then begin
              let per_recip_limit = max 1 (max_style - !style_count) in
              match Rag_lib.Pg.find_style_emails ~sender_emails:user_emails ~recipient:recip ~limit:per_recip_limit () with
              | Ok style_ids ->
                  List.iter (fun did ->
                    if !style_count < max_style && not (Hashtbl.mem trigger_set did) then begin
                      ignore (Rag_lib.Pg.link_email_to_task ~task_id ~doc_id:did ~role:"style" ());
                      incr style_count
                    end
                  ) style_ids;
                  if style_ids <> [] then
                    Printf.printf "[prefetch] task %s: %d style emails for %s\n%!"
                      task_id (List.length style_ids) recip
              | Error e ->
                  Printf.eprintf "[prefetch] style search error for %s: %s\n%!" recip e
            end
          ) recipients
        end else
          Printf.printf "[prefetch] task %s: no email addresses in whoami, skipping style\n%!" task_id;

        let context_json = `List (List.map (fun did -> `String did) selected_doc_ids) in
        (match Rag_lib.Pg.update_task ~task_id
            ~context_emails_json:(Yojson.Safe.to_string context_json)
            ~context_prefetched:true () with
        | Ok _ -> ()
        | Error e ->
            Printf.eprintf "[prefetch] update error: %s\n%!" e)
      end
    end
  in
  (* Phase 3: Generate first assistant message once all evidence bodies are present *)
  let generate_first_message ~client ~sw (task_id : string) (title : string) : unit =
    Printf.printf "[prefetch.gen] generating first message for task %s: %s\n%!" task_id title;
    (* Load task description + prior_resolutions *)
    let description, prior_resolutions = match Rag_lib.Pg.get_task task_id with
      | Ok (Some json) ->
          let kv = match json with `Assoc kv -> kv | _ -> [] in
          let desc = match List.assoc_opt "description" kv with Some (`String s) -> s | _ -> "" in
          let pr = match List.assoc_opt "prior_resolutions" kv with Some (`String s) -> s | _ -> "" in
          (desc, pr)
      | _ -> ("", "")
    in
    (* Load all task_emails with compressed bodies — same layout as /task/chat *)
    let task_emails = match Rag_lib.Pg.get_task_emails_with_bodies task_id with
      | Ok rows -> rows | Error _ -> []
    in
    let trigger_doc_ids = List.filter_map (fun (doc_id, role, _) ->
      if role = "trigger" then Some doc_id else None
    ) task_emails in
    let alias_idx = ref 0 in
    let email_context_lines = ref [] in
    let style_context_lines = ref [] in
    let md_of_doc_id doc_id =
      match Rag_lib.Pg.get_email_detail doc_id with
      | Ok (Some detail) ->
          let dkv = match detail with `Assoc kv -> kv | _ -> [] in
          let md = match List.assoc_opt "metadata" dkv with Some (`Assoc m) -> m | _ -> [] in
          let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
          let date = ms "date" in
          let date = if String.trim date = "" then ms "ingested_at" else date in
          (ms "from", ms "to", ms "subject", date)
      | _ -> ("", "", "", "")
    in
    (* Strip section headers (NEW CONTENT: / QUOTED CONTEXT:) from body text for prompt.
       For style emails, also strip QUOTED CONTEXT entirely — only the user's own new
       content is useful for style matching. *)
    let clean_body ~is_style (body : string) : string =
      let lines = String.split_on_char '\n' body in
      let buf = Buffer.create (String.length body) in
      let in_quoted = ref false in
      List.iter (fun line ->
        let trimmed = String.trim line in
        if trimmed = "NEW CONTENT:" then ()
        else if String.length trimmed >= 15
             && String.sub trimmed 0 14 = "QUOTED CONTEXT" then
          in_quoted := true
        else if String.length trimmed >= 12
             && String.sub trimmed 0 12 = "ATTACHMENTS:" then
          in_quoted := false
        else if is_style && !in_quoted then ()
        else begin
          if Buffer.length buf > 0 then Buffer.add_char buf '\n';
          Buffer.add_string buf line
        end
      ) lines;
      String.trim (Buffer.contents buf)
    in
    List.iter (fun (doc_id, role, compressed_body) ->
      let (from, to_, subject, date) = md_of_doc_id doc_id in
      let body_str = clean_body ~is_style:(role = "style") compressed_body in
      if role = "style" then begin
        let body_part = if body_str = "" then "(body not yet available)" else body_str in
        style_context_lines := (Printf.sprintf "---\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s\n\n%s"
          from to_ subject date body_part) :: !style_context_lines
      end else begin
        incr alias_idx;
        let alias = Printf.sprintf "E%d" !alias_idx in
        let body_part = if body_str = "" then "\n(body not yet available)" else "\n\n" ^ body_str in
        if body_str = "" then
          Printf.eprintf "[prefetch.gen] task=%s email=%s role=%s has empty body\n%!" task_id doc_id role;
        email_context_lines := (Printf.sprintf "%s [%s]:\nFrom: %s\nTo: %s\nSubject: %s\nDate: %s%s"
          alias role from to_ subject date body_part) :: !email_context_lines
      end
    ) task_emails;
    let email_context =
      if !email_context_lines = [] then "No emails linked to this task."
      else String.concat "\n" (List.rev !email_context_lines)
    in
    let style_context =
      if !style_context_lines <> [] then
        "\n\nSTYLE CONTEXT (emails you have sent to the same recipients — match this tone and style):\n"
        ^ String.concat "\n" (List.rev !style_context_lines)
      else ""
    in
    let user_identity = build_user_identity ~name:"" ~email:!whoami () in
    (* Retrieve memories for first message generation *)
    let memories_text =
      if not !memory_enabled then ""
      else
      let task_emb = match Rag_lib.Pg.get_task_embedding task_id with
        | Ok (Some emb) -> emb | _ -> []
      in
      let trigger_md = match trigger_doc_ids with
        | doc_id :: _ ->
            (match Rag_lib.Pg.get_email_detail doc_id with
            | Ok (Some detail) ->
                let dkv = match detail with `Assoc kv -> kv | _ -> [] in
                let md = match List.assoc_opt "metadata" dkv with Some (`Assoc m) -> m | _ -> [] in
                let ms k = match List.assoc_opt k md with Some (`String s) -> s | _ -> "" in
                Some (ms "from", ms "to", ms "cc", ms "subject", ms "date")
            | _ -> None)
        | [] -> None
      in
      match trigger_md, task_emb with
      | Some (sender, recipient, cc, subj, date), emb when emb <> [] ->
          let text, _ = retrieve_and_format_memories
            ~sender ~recipient ~cc ~bcc:"" ~subject:subj ~date
            ~attachments:[] ~embedding:emb () in
          text
      | Some (sender, recipient, cc, subj, date), _ ->
          let mems = retrieve_memories_symbolic
            ~sender ~recipient ~cc ~bcc:"" ~subject:subj ~date
            ~attachments:[] () in
          let buf = Buffer.create 256 in
          List.iter (fun (mid, txt) ->
            Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid txt)
          ) mems;
          Buffer.contents buf
      | None, emb when emb <> [] ->
          let mems = retrieve_memories_embedding ~embedding:emb () in
          let buf = Buffer.create 256 in
          List.iter (fun (mid, txt) ->
            Buffer.add_string buf (Printf.sprintf "- [%s] %s\n" mid txt)
          ) mems;
          Buffer.contents buf
      | _ -> ""
    in
    let memories_section =
      if String.trim memories_text = "" then ""
      else "USER MEMORIES (persistent preferences — follow these):\n" ^ memories_text
    in
    let prior_resolutions_section =
      if String.trim prior_resolutions = "" then ""
      else "PRIOR RESOLUTIONS (similar tasks resolved in the past — use as reference for tone, approach, and content):\n" ^ prior_resolutions
    in
    let system_prompt =
      get_prompt "task_first_message"
        ~default:"You are a task assistant. Based on the trigger email(s), write a self-contained \
          first message: extract the task-relevant facts the user needs, then draft a reply if applicable \
          using [DRAFT to=\"...\" subject=\"...\"] ... [/DRAFT]. Do not greet, do not offer to help, \
          do not ask open-ended questions."
        ~vars:[
          ("{{user_identity}}", user_identity);
          ("{{datetime_local}}", now_local_string ());
          ("{{task_title}}", title);
          ("{{task_description}}", description);
          ("{{email_context}}", email_context);
          ("{{style_context}}", style_context);
          ("{{user_memories}}", memories_section);
          ("{{prior_resolutions}}", prior_resolutions_section);
        ]
    in
    let messages : Yojson.Safe.t list =
      [ `Assoc [ ("role", `String "system"); ("content", `String system_prompt) ]
      ; `Assoc [ ("role", `String "user"); ("content", `String "Generate the first message for this task.") ]
      ]
    in
    match ollama_chat ~client ~sw ~label:"task_first_msg" ~model:!ollama_triage_model ~messages () with
    | Ok first_msg ->
        let first_msg = String.trim first_msg in
        Printf.printf "[prefetch.gen] task %s: generated %d char first message\n%!"
          task_id (String.length first_msg);
        (* Parse [DRAFT ...] ... [/DRAFT] markers *)
        let find_sub s sub from =
          let sub_len = String.length sub in
          let s_len = String.length s in
          let rec loop i =
            if i + sub_len > s_len then None
            else if String.sub s i sub_len = sub then Some i
            else loop (i + 1)
          in
          loop from
        in
        let drafts = ref [] in
        let rec parse_drafts text from =
          match find_sub text "[DRAFT" from with
          | None -> ()
          | Some di ->
              let tag_end = match find_sub text "]" di with Some e -> e + 1 | None -> di + 6 in
              let tag_content = String.sub text (di + 6) (tag_end - di - 7) |> String.trim in
              let parse_attr name content =
                let pat = name ^ "=\"" in
                match find_sub content pat 0 with
                | None -> ""
                | Some si ->
                    let start = si + String.length pat in
                    (match find_sub content "\"" start with
                    | Some ei -> String.sub content start (ei - start)
                    | None -> "")
              in
              let draft_to = parse_attr "to" tag_content in
              let draft_cc = parse_attr "cc" tag_content in
              let draft_bcc = parse_attr "bcc" tag_content in
              let draft_subject = parse_attr "subject" tag_content in
              let end_di, resume =
                match find_sub text "[/DRAFT]" tag_end with
                | Some ei -> (ei, ei + 8)
                | None -> (String.length text, String.length text)
              in
              let draft_body = String.trim (String.sub text tag_end (end_di - tag_end)) in
              if draft_body <> "" then begin
                let reply_to = match trigger_doc_ids with x :: _ -> x | [] -> "" in
                drafts := `Assoc
                  [ ("to", `String draft_to)
                  ; ("cc", `String draft_cc)
                  ; ("bcc", `String draft_bcc)
                  ; ("subject", `String draft_subject)
                  ; ("body", `String draft_body)
                  ; ("in_reply_to", `String reply_to)
                  ] :: !drafts
              end;
              if resume < String.length text then
                parse_drafts text resume
        in
        parse_drafts first_msg 0;
        (* Strip [DRAFT]...[/DRAFT] from display text *)
        let display_text =
          let t = ref first_msg in
          let rec strip () =
            match find_sub !t "[DRAFT" 0 with
            | None -> ()
            | Some di ->
                let ei, skip =
                  match find_sub !t "[/DRAFT]" di with
                  | Some ei -> (ei, ei + 8)
                  | None -> (String.length !t, String.length !t)
                in
                let before = String.sub !t 0 di in
                let after = if skip < String.length !t
                  then String.sub !t skip (String.length !t - skip) else "" in
                t := before ^ "See the draft in the right-hand pane." ^ after;
                strip ()
          in
          strip (); String.trim !t
        in
        let first_msg_debug = `Assoc
          [ ("model", `String !ollama_triage_model)
          ; ("messages", `List messages)
          ; ("raw_response", `String first_msg)
          ] in
        let conv = `List [
          `Assoc [ ("role", `String "assistant"); ("content", `String display_text)
                 ; ("_llm_debug", first_msg_debug) ]
        ] |> Yojson.Safe.to_string in
        let drafts_json =
          if !drafts <> [] then Some (Yojson.Safe.to_string (`List (List.rev !drafts)))
          else None
        in
        (match Rag_lib.Pg.update_task ~task_id
            ~conversation_json:conv ?drafts_json ~context_ready:true () with
        | Ok _ ->
            Printf.printf "[prefetch.gen] task %s: context_ready=true, %d draft(s)\n%!"
              task_id (List.length !drafts)
        | Error e -> Printf.eprintf "[prefetch.gen] update error: %s\n%!" e)
    | Error e ->
        Printf.eprintf "[prefetch.gen] LLM error for task %s: %s\n%!" task_id e;
        (* Mark ready anyway to avoid infinite retry; conversation keeps the old state *)
        ignore (Rag_lib.Pg.update_task ~task_id ~context_ready:true ())
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Printf.printf "[prefetch] background daemon started\n%!";
    let rec loop () =
      (* Wait for notification or poll every 30s *)
      (try
        ignore (Eio.Stream.take_nonblocking prefetch_wake)
      with _ -> ());
      let did_work = ref false in
      (* Phase -1: async ingestion — highest daemon priority, runs even during high-priority *)
      (if Atomic.get ingest_paused then ()
      else match Rag_lib.Pg.dequeue_ingest () with
      | Ok (Some (doc_id, raw)) ->
          did_work := true;
          Printf.printf "[daemon.ingest] processing doc_id=%s (%d bytes)\n%!" doc_id (String.length raw);
          let whoami = String.trim !whoami in
          if whoami = "" then begin
            Printf.eprintf "[daemon.ingest] skipping %s — whoami not set\n%!" doc_id;
            ignore (Rag_lib.Pg.fail_ingest doc_id "whoami not configured")
          end else begin
            (try
              let headers = parse_headers raw in
              let resp, _resp_body =
                forward_ingest_raw ~client ~sw ~log:true ~whoami ~doc_id ~headers ~raw
              in
              let code = Cohttp.Code.code_of_status (Http.Response.status resp) in
              if code >= 200 && code < 300 then begin
                Printf.printf "[daemon.ingest] ok doc_id=%s\n%!" doc_id;
                ignore (Rag_lib.Pg.finish_ingest doc_id)
              end else begin
                Printf.eprintf "[daemon.ingest] failed doc_id=%s status=%d\n%!" doc_id code;
                ignore (Rag_lib.Pg.fail_ingest doc_id (Printf.sprintf "HTTP %d" code))
              end
            with e ->
              let msg = Printexc.to_string e in
              Printf.eprintf "[daemon.ingest] error for %s: %s\n%!" doc_id msg;
              ignore (Rag_lib.Pg.fail_ingest doc_id msg))
          end
      | _ -> ());
      (* Defer to high-priority work (ingestion, user queries/chat) *)
      if Atomic.get tasks_paused then ()
      else if Atomic.get high_priority_count > 0 then
        Printf.printf "[prefetch] deferring — high-priority request active\n%!"
      else begin
        (* Phase 0: triage — propose tasks for queued emails *)
        (match Rag_lib.Pg.dequeue_triage () with
        | Ok (Some (doc_id, body_text, compressed_body)) ->
            did_work := true;
            (try triage_one_email ~client ~sw doc_id body_text compressed_body
            with e ->
              Printf.eprintf "[daemon.triage] error for %s: %s\n%!" doc_id (Printexc.to_string e);
              ignore (Rag_lib.Pg.delete_triage_entry doc_id))
        | _ -> ());
        (* Phase 1: kNN + selection for tasks needing prefetch *)
        (if Atomic.get high_priority_count = 0 then
          match Rag_lib.Pg.tasks_needing_prefetch ~limit:1 () with
          | Ok ((task_id, title) :: _) ->
              did_work := true;
              (try prefetch_one_task ~client ~sw task_id title
              with e ->
                Printf.eprintf "[prefetch] error processing %s: %s\n%!" task_id (Printexc.to_string e))
          | _ -> ());
        (* Phase 2: generate first message for tasks with all evidence *)
        (if Atomic.get high_priority_count = 0 then
          match Rag_lib.Pg.tasks_ready_for_generation ~limit:1 () with
          | Ok ((task_id, title) :: _) ->
              did_work := true;
              (try generate_first_message ~client ~sw task_id title
              with e ->
                Printf.eprintf "[prefetch.gen] error for %s: %s\n%!" task_id (Printexc.to_string e))
          | _ -> ())
      end;
      Eio.Time.sleep env#clock (if !did_work then 2.0 else 30.0);
      loop ()
    in
    loop ());

  (* Startup cleanup: delete tasks with no trigger emails *)
  (match Rag_lib.Pg.cleanup_orphan_tasks () with
  | Ok [] -> ()
  | Ok deleted ->
      Printf.printf "[startup] deleted %d orphan task(s) with no triggers: %s\n%!"
        (List.length deleted) (String.concat ", " deleted)
  | Error e ->
      Printf.eprintf "[startup] orphan cleanup error: %s\n%!" e);

  (* One-time migration: extract [DRAFT] markers from existing conversations *)
  (match Rag_lib.Pg.tasks_needing_draft_migration () with
  | Ok [] -> ()
  | Ok task_ids ->
      Printf.printf "[migrate] %d task(s) have unparsed [DRAFT] markers\n%!" (List.length task_ids);
      let find_sub s sub from =
        let sub_len = String.length sub in
        let s_len = String.length s in
        let rec loop i =
          if i + sub_len > s_len then None
          else if String.sub s i sub_len = sub then Some i
          else loop (i + 1)
        in
        loop from
      in
      let parse_attr name content =
        let pat = name ^ "=\"" in
        match find_sub content pat 0 with
        | None -> ""
        | Some si ->
            let start = si + String.length pat in
            (match find_sub content "\"" start with
            | Some ei -> String.sub content start (ei - start)
            | None -> "")
      in
      List.iter (fun task_id ->
        match Rag_lib.Pg.get_task task_id with
        | Ok (Some task_json) ->
            let task_kv = match task_json with `Assoc kv -> kv | _ -> [] in
            let conversation = match List.assoc_opt "conversation" task_kv with
              | Some (`List ms) -> ms | _ -> []
            in
            let trigger_doc_ids = match Rag_lib.Pg.task_trigger_doc_ids task_id with
              | Ok ids -> ids | Error _ -> []
            in
            let reply_to = match trigger_doc_ids with x :: _ -> x | [] -> "" in
            let all_drafts = ref [] in
            let new_conversation = List.map (fun msg ->
              let mkv = match msg with `Assoc kv -> kv | _ -> [] in
              let role = match List.assoc_opt "role" mkv with Some (`String s) -> s | _ -> "" in
              let content = match List.assoc_opt "content" mkv with Some (`String s) -> s | _ -> "" in
              if role <> "assistant" then msg
              else begin
                (* Parse [DRAFT] blocks *)
                let rec collect text from =
                  match find_sub text "[DRAFT" from with
                  | None -> ()
                  | Some di ->
                      let tag_end = match find_sub text "]" di with Some e -> e + 1 | None -> di + 6 in
                      let tag_content = String.sub text (di + 6) (tag_end - di - 7) |> String.trim in
                      let draft_to = parse_attr "to" tag_content in
                      let draft_cc = parse_attr "cc" tag_content in
                      let draft_bcc = parse_attr "bcc" tag_content in
                      let draft_subject = parse_attr "subject" tag_content in
                      let end_di, resume =
                        match find_sub text "[/DRAFT]" tag_end with
                        | Some ei -> (ei, ei + 8)
                        | None -> (String.length text, String.length text)
                      in
                      let draft_body = String.trim (String.sub text tag_end (end_di - tag_end)) in
                      if draft_body <> "" then
                        all_drafts := `Assoc
                          [ ("to", `String draft_to); ("cc", `String draft_cc)
                          ; ("bcc", `String draft_bcc); ("subject", `String draft_subject)
                          ; ("body", `String draft_body); ("in_reply_to", `String reply_to)
                          ] :: !all_drafts;
                      if resume < String.length text then collect text resume
                in
                collect content 0;
                (* Strip [DRAFT]...[/DRAFT] from display *)
                let t = ref content in
                let rec strip () =
                  match find_sub !t "[DRAFT" 0 with
                  | None -> ()
                  | Some di ->
                      let ei, skip = match find_sub !t "[/DRAFT]" di with
                        | Some ei -> (ei, ei + 8)
                        | None -> (String.length !t, String.length !t)
                      in
                      let before = String.sub !t 0 di in
                      let after = if skip < String.length !t
                        then String.sub !t skip (String.length !t - skip) else "" in
                      t := before ^ "See the draft in the right-hand pane." ^ after;
                      strip ()
                in
                strip ();
                `Assoc [ ("role", `String "assistant"); ("content", `String (String.trim !t)) ]
              end
            ) conversation in
            if !all_drafts <> [] then begin
              let drafts_json = Yojson.Safe.to_string (`List (List.rev !all_drafts)) in
              let conv_json = Yojson.Safe.to_string (`List new_conversation) in
              (match Rag_lib.Pg.update_task ~task_id
                  ~conversation_json:conv_json ~drafts_json () with
              | Ok _ ->
                  Printf.printf "[migrate] task %s: extracted %d draft(s)\n%!"
                    task_id (List.length !all_drafts)
              | Error e ->
                  Printf.eprintf "[migrate] task %s update error: %s\n%!" task_id e)
            end
        | _ -> ()
      ) task_ids
  | Error e ->
      Printf.eprintf "[migrate] error checking for draft migration: %s\n%!" e);

  let socket =
    try
      Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.any, !port))
    with Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Printf.eprintf
        "Error: port %d is already in use.\n\
         Another instance of rag-o-mail (or another process) is likely running on that port.\n\
         Try:  lsof -ti:%d | xargs kill   or use a different port with -p <port>\n%!"
        !port !port;
      exit 1
  in
  Printf.printf "Listening on port %d\n%!" !port;
  let server = Cohttp_eio.Server.make ~callback:(handler ~client ~sw ~clock:env#clock) () in
  Cohttp_eio.Server.run socket server ~on_error:log_warning
