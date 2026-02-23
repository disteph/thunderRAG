(*
  ThunderRAG OCaml server

  Role in the system
  - Acts as the authoritative orchestrator for the RAG email assistant.
  - Owns session state (conversation tail + summaries), prompt construction, and calls to Ollama.
  - Performs a 2-phase query flow so that Thunderbird (not OCaml) fetches full email bodies/attachments.

  High-level flows
  - Ingestion:
    - Accept raw emails (RFC822), extract text (text/plain or HTML->text), build a "text_for_index" payload,
      embed chunks via Ollama /api/embeddings, and store embeddings + metadata in PostgreSQL/pgvector.
  - Query (2-phase):
    1) POST /query
       - Runs kNN vector retrieval via PostgreSQL/pgvector.
       - Returns status=need_messages + request_id + message_ids + email metadata.
    2) POST /query/evidence
       - Thunderbird uploads message/rfc822 evidence for each message id (header X-Thunderbird-Message-Id).
    3) POST /query/complete
       - Extracts body text again (same normalization as ingestion), builds the final prompt, calls
         Ollama /api/chat, updates session state, returns answer + metadata-only emails for UI.

  Key environment variables
  - OLLAMA_BASE_URL, OLLAMA_EMBED_MODEL, OLLAMA_LLM_MODEL
  - RAG_MAX_EVIDENCE_SOURCES, RAG_MAX_EVIDENCE_CHARS_PER_EMAIL
  - RAG_DEBUG_OLLAMA_EMBED=1: print Ollama /api/embeddings request JSON (ingestion + query-time)
  - RAG_DEBUG_RETRIEVAL=1: print retrieval payloads (/api/embeddings + /query_embedded) and response summary
  - RAG_DEBUG_OLLAMA_CHAT=1: print Ollama /api/chat request JSON (final generation prompt)
*)

open Eio.Std

let () = Tool_check.ensure ()

open Rag_lib.Config

let () = ensure_dir (thunderrag_config_dir ())

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
  - RAG_DEBUG_OLLAMA_EMBED=1 prints the exact embeddings request JSON.
  - RAG_DEBUG_OLLAMA_CHAT=1 prints the exact chat request JSON.
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
  let uri = Uri.of_string (!ollama_base_url ^ "/api/embeddings") in
  let body_obj : Yojson.Safe.t =
    `Assoc [ ("model", `String !ollama_embed_model); ("prompt", `String prompt) ]
  in
  if !rag_debug_ollama_embed then
    Printf.printf "\n[ollama.embed.request]\n%s\n%!" (Yojson.Safe.pretty_to_string body_obj);
  let body_json = Yojson.Safe.to_string body_obj in
  let call () = post_json_uri ~client ~sw ~uri ~body_json in
  let resp, resp_body = !global_with_timeout !ollama_timeout_seconds call in
  let result =
    if not (is_ok_status (Http.Response.status resp)) then Error resp_body
    else
      try
        let json = Yojson.Safe.from_string resp_body in
        match json with
        | `Assoc kv -> (
            match List.assoc_opt "embedding" kv with
            | Some (`List xs) ->
                let vec =
                  xs
                  |> List.filter_map (function
                       | `Float f -> Some f
                       | `Int i -> Some (float_of_int i)
                       | `Intlit s -> (try Some (float_of_string s) with
                          | _ -> None)
                       | `String s -> (try Some (float_of_string s) with
                          | _ -> None)
                       | _ -> None)
                in
                if vec = [] then Error "empty embedding" else Ok vec
            | _ -> Error "missing embedding")
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

let ollama_chat ~client ~sw ?(label = "") ?(stats : call_stats option) ?(model = "") ~(messages : Yojson.Safe.t list) () : (string, string) result =
  let t0 = Unix.gettimeofday () in
  let effective_model = if String.trim model <> "" then String.trim model else !ollama_llm_model in
  let uri = Uri.of_string (!ollama_base_url ^ "/api/chat") in
  let body_obj : Yojson.Safe.t =
    `Assoc
      [ ("model", `String effective_model)
      ; ("messages", `List messages)
      ; ("stream", `Bool false)
      ; ("options", `Assoc [ ("num_ctx", `Int !ollama_num_ctx) ])
      ]
  in
  if !rag_debug_ollama_chat then
    Printf.printf "\n[ollama.chat.request]\n%s\n%!" (Yojson.Safe.pretty_to_string body_obj);
  let body_json = Yojson.Safe.to_string body_obj in
  let call () = post_json_uri ~client ~sw ~uri ~body_json in
  let resp, resp_body = !global_with_timeout !ollama_timeout_seconds call in
  let result =
    if not (is_ok_status (Http.Response.status resp)) then Error resp_body
    else
      try
        let json = Yojson.Safe.from_string resp_body in
        match json with
        | `Assoc kv -> (
            match List.assoc_opt "message" kv with
            | Some (`Assoc mv) -> (
                match List.assoc_opt "content" mv with
                | Some (`String s) -> Ok s
                | _ -> Error "missing chat content")
            | _ -> Error "missing chat message")
        | _ -> Error "bad chat response"
      with ex -> Error (Printexc.to_string ex)
  in
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
  in
  let rec drop = function
    | [] -> []
    | l :: rest -> if is_preamble_line l then drop rest else l :: rest
  in
  String.concat "\n" (drop lines)

let summarize_to_fit ~client ~sw ~system_prompt ~max_input_chars ~max_chars
    ~label ?(llm_log : Yojson.Safe.t list ref option) (text : string) : string =
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
      match ollama_chat ~client ~sw ~label:("summarize." ^ label) ~stats:stats_chat_summarize ~model:!ollama_summarize_model ~messages () with
      | Ok s ->
          if !rag_debug_ollama_chat then Printf.printf "\n[%s.summary.response]\n%s\n%!" label s;
          (match llm_log with Some log ->
            log := !log @ [make_llm_call_entry ~label:("summarize:" ^ label)
              ~model:!ollama_summarize_model ~messages ~response:s]
          | None -> ());
          let s = strip_summary_preamble s |> String.trim in
          if s = "" then (
            Printf.eprintf "[%s.summary.error] empty response from ollama\n%!" label;
            None)
          else Some s
      | Error err ->
          (match llm_log with Some log ->
            log := !log @ [make_llm_call_entry ~label:("summarize:" ^ label)
              ~model:!ollama_summarize_model ~messages ~response:("ERROR: " ^ err)]
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

(*
  Email triage via LLM

  At ingestion time, score each email for actionability and importance, and
  extract a reply-by deadline (if any).  The triage model is configurable
  via ollama.triage_model in settings.json.  Results are stored in metadata
  and appended to the embedding text so that vector search can match
  queries like "urgent emails I need to reply to".
*)
type triage_result =
  { action_score      : int     (* 0–100: does this email require action from me? *)
  ; importance_score  : int     (* 0–100: how important is this email? *)
  ; reply_by          : string  (* ISO 8601 date/time or "none" *)
  }

let triage_email ~client ~sw ~(whoami : string)
    ~(from_ : string) ~(to_ : string) ~(cc_ : string) ~(bcc_ : string)
    ~(subject : string) ~(date_ : string) ~(body_text : string)
    : triage_result option =
  if String.trim whoami = "" then (
    Printf.eprintf "[triage] skipped: whoami is empty\n%!";
    None)
  else
  let body_excerpt = String.trim body_text in
  let user_identity =
    if String.trim whoami <> ""
    then Printf.sprintf "The user (the email account owner) is: %s. " (String.trim whoami)
    else ""
  in
  let system =
    get_prompt "triage" ~default:"You are an email triage assistant. Respond with ONLY a JSON object: {\"action_score\": <int 0-100>, \"importance_score\": <int 0-100>, \"reply_by\": \"YYYY-MM-DD or none\"}" ~vars:[("{{user_identity}}", user_identity)]
  in
  let user_msg =
    Printf.sprintf
      "EMAIL HEADERS:\n\
       From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nDate: %s\n\n\
       BODY:\n%s"
      from_ to_ cc_ bcc_ subject date_ body_excerpt
  in
  let messages : Yojson.Safe.t list =
    [ `Assoc [ ("role", `String "system"); ("content", `String system) ]
    ; `Assoc [ ("role", `String "user"); ("content", `String user_msg) ]
    ]
  in
  match ollama_chat ~client ~sw ~label:"triage" ~stats:stats_chat_triage ~model:!ollama_triage_model ~messages () with
  | Ok raw_resp ->
      if !rag_debug_ollama_chat then Printf.printf "\n[triage.response]\n%s\n%!" raw_resp;
      (* Strip markdown code fences if the model wraps its JSON *)
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
        let get_int key = match json with
          | `Assoc kv -> (match List.assoc_opt key kv with
              | Some (`Int n) -> n
              | Some (`Float f) -> int_of_float f
              | Some (`String s) -> (try int_of_string (String.trim s) with _ -> -1)
              | _ -> -1)
          | _ -> -1
        in
        let get_str key = match json with
          | `Assoc kv -> (match List.assoc_opt key kv with
              | Some (`String s) -> String.trim s
              | _ -> "none")
          | _ -> "none"
        in
        let action = max 0 (min 100 (get_int "action_score")) in
        let importance = max 0 (min 100 (get_int "importance_score")) in
        let reply_by = get_str "reply_by" in
        Printf.printf "[triage] action=%d importance=%d reply_by=%s\n%!" action importance reply_by;
        Some { action_score = action; importance_score = importance; reply_by }
      with ex ->
        Printf.eprintf "[triage.parse_error] %s — raw: %s\n%!" (Printexc.to_string ex)
          (truncate_chars raw_resp ~max_chars:200 |> String.trim);
        None)
  | Error err ->
      Printf.eprintf "[triage.error] %s\n%!" (truncate_chars err ~max_chars:400 |> String.trim);
      None

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
  ; message_ids : string list
  ; sources_json : Yojson.Safe.t
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
           triage_parts := !triage_parts @ [ Printf.sprintf "action=%d/100 importance=%d/100" a imp ];
           if reply_by <> "" && reply_by <> "none" then
             triage_parts := !triage_parts @ [ Printf.sprintf "reply_by=%s" reply_by ]
       | _ -> ());
      (match processed with Some true -> triage_parts := !triage_parts @ [ "processed=true" ] | _ -> ());
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
    ~(triage : triage_result option)
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
      (([ ("from", `String from_)
        ; ("to", `String to_)
        ; ("cc", `String cc_)
        ; ("bcc", `String bcc_)
        ; ("subject", `String subject)
        ; ("date", `String date_)
        ; ("attachments", `List (List.map (fun f -> `String f) attachments))
        ]
       @ (match triage with
          | Some t ->
              [ ("action_score", `Int t.action_score)
              ; ("importance_score", `Int t.importance_score)
              ; ("reply_by", `String t.reply_by)
              ]
          | None -> [])
       @ [ ("processed", `Bool false)
         ; ("ingested_at", `String (now_utc_iso8601 ()))
         ]
       ) : (string * Yojson.Safe.t) list)
  in
  let attachments_line =
    if attachments = [] then "" else Printf.sprintf "\nAttachments: %s" (String.concat ", " attachments)
  in
  let triage_line =
    match triage with
    | Some t ->
        Printf.sprintf "\nTRIAGE: action_required=%d/100 importance=%d/100 reply_by=%s"
          t.action_score t.importance_score t.reply_by
    | None -> ""
  in
  let text_for_index =
    Printf.sprintf
      "From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nDate: %s%s%s\n\n%s"
      from_ to_ cc_ bcc_ subject date_ attachments_line triage_line body_text
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
  make_ingest_data ~doc_id ~headers ~raw ~body_text ~triage:None

(*
  forward_ingest_raw

  Full ingestion pipeline for a single raw RFC822 message:
  - extract normalized body text
  - build a single index string including selected headers
  - chunk + embed each chunk (Ollama /api/embeddings)
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
  let parts = extract_body_parts raw in
  let new_body = String.trim parts.new_text |> sanitize_utf8 in
  let quoted_raw = String.trim parts.quoted_text |> sanitize_utf8 in
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
  let triage =
    triage_email ~client ~sw ~whoami ~from_ ~to_ ~cc_ ~bcc_ ~subject ~date_ ~body_text
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
    make_ingest_data ~doc_id ~headers ~raw ~body_text ~triage
  in
  let triage_line =
    match triage with
    | Some t ->
        Printf.sprintf " | triage: action=%d/100 importance=%d/100 reply_by=%s"
          t.action_score t.importance_score t.reply_by
    | None -> ""
  in
  let truncate_field s max_len =
    if String.length s <= max_len then s
    else String.sub s 0 max_len ^ "..."
  in
  let preamble =
    Printf.sprintf "From: %s | To: %s | Subject: %s | Date: %s%s"
      (truncate_field from_ 80) (truncate_field to_ 120)
      (truncate_field subject 120) date_ triage_line
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
  let embedded_chunks =
    sectioned_chunks
    |> List.map (fun (i, section, ch) ->
           match ollama_embed ~client ~sw ~task:Search_document ~label:"ingest" ~stats:stats_embed_ingest ~text:ch () with
           | Ok v -> (i, section, ch, l2_normalize v)
           | Error msg -> raise (Failure ("ollama_embed failed: " ^ msg)))
  in
  let attachments = extract_attachment_filenames raw in
  (* Format as PostgreSQL TEXT[] literal: {"file1.pdf","file2.xlsx"} *)
  let att_pg_array =
    let escaped = List.map (fun f ->
      "\"" ^ String.concat "\\\"" (String.split_on_char '"' f) ^ "\"") attachments in
    "{" ^ String.concat "," escaped ^ "}"
  in
  let action_score = match triage with Some t -> Some t.action_score | None -> None in
  let importance_score = match triage with Some t -> Some t.importance_score | None -> None in
  (* reply_by from triage is YYYY-MM-DD or "none" — convert "none"/empty to
     empty string which becomes NULL via the ::timestamptz cast on empty string.
     For non-empty, append T00:00:00Z for midnight UTC. *)
  let reply_by = match triage with
    | Some t when t.reply_by <> "" && t.reply_by <> "none" -> t.reply_by ^ "T00:00:00Z"
    | _ -> ""
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
      ~action_score ~importance_score ~reply_by
      ~ingested_at:(now_utc_iso8601 ())
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
  ~/.thunderrag/bulk_ingest_state.json (or $RAG_BULK_STATE).
*)
type bulk_file_state =
  { size : int
  ; mtime : int
  ; last_pos : int
  ; completed : bool
  }

let bulk_state_path () : string =
  match Sys.getenv_opt "RAG_BULK_STATE" with
  | Some p when String.trim p <> "" -> expand_home p
  | _ ->
      Filename.concat (thunderrag_config_dir ()) "bulk_ingest_state.json"

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
                    forward_ingest_raw ~client ~sw ~log:false ~whoami:"" ~doc_id ~headers ~raw
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
    ~(user_name : string) ?(llm_log : Yojson.Safe.t list ref option)
    () : string list * string * bool * string option * string option =
  if not !rag_query_rewrite then ([question], question, false, None, None)
  else
    let has_context = String.trim history_summary <> "" || tail <> [] in
    let user_identity =
      let name_part = String.trim user_name in
      let email_part = String.trim !whoami in
      match (name_part <> "", email_part <> "") with
      | true, true  -> Printf.sprintf "The user (the email account owner) is: %s (email: %s).\n" name_part email_part
      | true, false -> Printf.sprintf "The user (the email account owner) is: %s.\n" name_part
      | false, true -> Printf.sprintf "The user (the email account owner) email is: %s.\n" email_part
      | false, false -> ""
    in
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
    match ollama_chat ~client ~sw ~label:"rewrite" ~stats:stats_chat_rewrite ~model:!ollama_rewrite_model ~messages () with
    | Ok raw_resp ->
        if !rag_debug_ollama_chat then
          Printf.printf "\n[retrieval.rewrite.response]\n%s\n%!" raw_resp;
        (match llm_log with Some log ->
          log := !log @ [make_llm_call_entry ~label:"rewrite"
            ~model:!ollama_rewrite_model ~messages ~response:raw_resp]
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
           let validated_filter =
             match get_str "filter" with
             | None -> None
             | Some f ->
                 match Rag_lib.Sql_validate.validate_filter f with
                 | Ok validated ->
                     let expanded = expand_virtual_cols validated in
                     Printf.printf "[retrieval.rewrite] filter=%s\n%!" expanded; Some expanded
                 | Error err -> Printf.eprintf "[retrieval.rewrite.warning] rejected filter %S: %s\n%!" f err; None
           in
           let validated_score =
             match get_str "score_expr" with
             | None -> None
             | Some s ->
                 match Rag_lib.Sql_validate.validate_score s with
                 | Ok validated ->
                     let expanded = expand_virtual_cols validated in
                     Printf.printf "[retrieval.rewrite] score_expr=%s\n%!" expanded; Some expanded
                 | Error err -> Printf.eprintf "[retrieval.rewrite.warning] rejected score_expr %S: %s\n%!" s err; None
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
    ~(user_name : string) ?(llm_log : Yojson.Safe.t list ref option)
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
                   | Some a, Some imp -> [Printf.sprintf "action=%s/100 importance=%s/100" a imp]
                   | _ -> [])
                @ (let rb = ms "reply_by" in
                   if String.trim rb <> "" && rb <> "none" then [Printf.sprintf "reply_by=%s" rb] else [])
                @ (let atts = match List.assoc_opt "attachments" md with
                     | Some (`List xs) -> xs |> List.filter_map (function `String s -> Some s | _ -> None)
                     | _ -> []
                   in if atts <> [] then [Printf.sprintf "attachments=[%s]" (String.concat "; " atts)] else [])
                @ (let p = match List.assoc_opt "processed" md with
                     | Some (`Bool true) -> true | _ -> false
                   in if p then ["processed=true"] else [])
              in
              ignore (s "doc_id");
              String.concat " " parts
          | _ -> Printf.sprintf "[%d] (unknown)" (i + 1))
    | _ -> []
  in
  let table_str = String.concat "\n" table_lines in
  let user_identity =
    let name_part = String.trim user_name in
    let email_part = String.trim !whoami in
    match (name_part <> "", email_part <> "") with
    | true, true  -> Printf.sprintf "The user (the email account owner) is: %s (email: %s).\n" name_part email_part
    | true, false -> Printf.sprintf "The user (the email account owner) is: %s.\n" name_part
    | false, true -> Printf.sprintf "The user (the email account owner) email is: %s.\n" email_part
    | false, false -> ""
  in
  let system =
    get_prompt "select_evidence"
      ~default:"You are helping decide which retrieved emails need their full content loaded. Output a JSON array of 1-based row numbers."
      ~vars:[
        ("{{user_identity}}", user_identity);
        ("{{retrieved_email_table}}", table_str);
        ("{{resolved_question}}", resolved_question);
      ]
  in
  let messages : Yojson.Safe.t list =
    [ `Assoc [ ("role", `String "system"); ("content", `String system) ] ]
  in
  match ollama_chat ~client ~sw ~label:"select_evidence" ~stats:stats_chat_select ~model:!ollama_summarize_model ~messages () with
  | Error err ->
      (match llm_log with Some log ->
        log := !log @ [make_llm_call_entry ~label:"select_evidence"
          ~model:!ollama_summarize_model ~messages ~response:("ERROR: " ^ err)]
      | None -> ());
      Printf.eprintf "[select_evidence.error] %s, selecting all\n%!" (truncate_chars err ~max_chars:200);
      all_doc_ids
  | Ok raw_resp ->
      (match llm_log with Some log ->
        log := !log @ [make_llm_call_entry ~label:"select_evidence"
          ~model:!ollama_summarize_model ~messages ~response:raw_resp]
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
        (Yojson.Safe.to_string (`String (thunderrag_config_dir ())))
        settings_raw prompts_raw
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()
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

      let hdr_whoami = request_header_or_empty request "x-thunderrag-whoami" in
      let whoami = if String.trim hdr_whoami <> "" then hdr_whoami else !whoami in
      let resp, resp_body =
        forward_ingest_raw ~client ~sw ~log:true ~whoami ~doc_id ~headers ~raw
      in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()

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
      let session_id, request_id, chat_model_override =
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
              (sid, rid, cm)
          | _ -> ("", "", "")
        with _ -> ("", "", "")
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

                let evidence_by_doc : (string, (string * Yojson.Safe.t)) Hashtbl.t = Hashtbl.create 32 in
                Eio.Mutex.use_rw ~protect:true p.mu (fun () ->
                  List.iter
                    (fun mid ->
                      let raw = Hashtbl.find p.evidence_by_id mid in
                      let _, md_from_raw = ingest_text_of_raw ~doc_id:mid ~raw in
                      let cached_md =
                        match Hashtbl.find_opt cached_md_by_doc mid with
                        | Some m -> m
                        | None -> `Assoc []
                      in
                      let md =
                        match cached_md, md_from_raw with
                        | `Assoc cached_kv, `Assoc fresh_kv ->
                            let tbl = Hashtbl.create 32 in
                            List.iter (fun (k, v) -> Hashtbl.replace tbl k v) cached_kv;
                            let override_keys =
                              [ "from"; "to"; "cc"; "bcc"; "subject"; "attachments" ]
                            in
                            List.iter
                              (fun (k, v) ->
                                if List.mem k override_keys then Hashtbl.replace tbl k v)
                              fresh_kv;
                            `Assoc (Hashtbl.to_seq tbl |> List.of_seq)
                        | _ -> cached_md
                      in
                      let parts = extract_body_parts raw in
                      let new_body = String.trim parts.new_text |> sanitize_utf8 in
                      let new_body_capped =
                        summarize_to_fit ~client ~sw
                          ~system_prompt:(get_prompt "compress_new_content_evidence" ~default:"Compress email body for Q&A evidence. Preserve all facts. Third person. Do not invent." ~vars:[])
                          ~max_input_chars:!rag_summarize_max_input_chars
                          ~max_chars:!rag_max_evidence_chars_per_email
                          ~label:"evidence" ~llm_log:p_llm_log
                          new_body
                      in
                      let quoted_raw = String.trim parts.quoted_text |> sanitize_utf8 in
                      let quoted_section =
                        if String.trim quoted_raw = "" then ""
                        else
                          let quoted_capped =
                            summarize_to_fit ~client ~sw
                              ~system_prompt:(get_prompt "compress_quoted_context_evidence" ~default:"Compress quoted thread context for Q&A evidence. Preserve facts. Third person. Do not invent." ~vars:[])
                              ~max_input_chars:!rag_summarize_max_input_chars
                              ~max_chars:(!rag_max_evidence_chars_per_email / 2)
                              ~label:"evidence-quoted" ~llm_log:p_llm_log
                              quoted_raw
                          in
                          "\n\nQUOTED CONTEXT:\n" ^ quoted_capped
                      in
                      let body = "NEW CONTENT:\n" ^ new_body_capped ^ quoted_section in
                      Hashtbl.replace evidence_by_doc mid (body, md))
                    p.message_ids);

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
                         parts := !parts @ [ Printf.sprintf "action=%d/100 importance=%d/100" a imp ];
                         if reply_by <> "" && reply_by <> "none" then
                           parts := !parts @ [ Printf.sprintf "reply_by=%s" reply_by ]
                     | _ -> ());
                    (match processed with
                     | Some true -> parts := !parts @ [ "processed=true" ]
                     | _ -> ());
                    String.concat " " !parts
                  in
                  (mid, text, md,
                   md_str "date", md_str "from", md_str "to",
                   md_str "cc", md_str "bcc", md_str "subject",
                   md_attachments, triage_str, rehydrated)
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

                (* Merge and sort all entries by date (oldest first) *)
                let all_entries =
                  (rehydrated_entries @ unrehydrated_entries)
                  |> List.sort (fun (_, _, _, d1, _, _, _, _, _, _, _, _) (_, _, _, d2, _, _, _, _, _, _, _, _) ->
                       String.compare d1 d2)
                in

                (* Determine which entries go into the LLM prompt:
                   rehydrated always; unrehydrated only if config says so *)
                let include_unrehydrated = !rag_include_unrehydrated_metadata in
                let prompt_entries =
                  if include_unrehydrated then all_entries
                  else all_entries |> List.filter (fun (_, _, _, _, _, _, _, _, _, _, _, rh) -> rh)
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
                  `List (all_entries |> List.map (fun (mid, text, md, _, _, _, _, _, _, _, _, rh) ->
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
                    |> List.mapi (fun i (mid, text, _md, date_, from_, to_, cc_, bcc_, subject, atts, triage, rh) ->
                           let hdr_parts =
                             [ Printf.sprintf "[Email %d]" (i + 1)
                             ; Printf.sprintf "doc_id=%s" mid
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


                let user_identity_str =
                  let name_part = String.trim session_user_name in
                  let email_part = String.trim !whoami in
                  match (name_part <> "", email_part <> "") with
                  | true, true  -> Printf.sprintf "The user is: %s (email: %s). " name_part email_part
                  | true, false -> Printf.sprintf "The user is: %s. " name_part
                  | false, true -> Printf.sprintf "The user email is: %s. " email_part
                  | false, false -> ""
                in
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
                            [ ("role", `String "user")
                            ; ("content", `String history_summary)
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
                    @ [ `Assoc [ ("role", `String "user"); ("content", `String evidence_content) ]
                      ; `Assoc [ ("role", `String "user"); ("content", `String question_content) ]
                      ]
                in

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
      let session_id, question, top_k, mode, user_name =
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
          (session_id, question, top_k, mode, user_name)
        with _ -> ("", "", 8, "assistive", "")
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

        let queries, resolved_question, no_retrieval, rewrite_filter, rewrite_score =
          rewrite_queries_for_retrieval ~client ~sw ~question
            ~history_summary ~tail ~user_name:(s.user_name)
            ~llm_log ()
        in

        if no_retrieval then (
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
        let retrieval_sqls = ref [] in
        let retrieval_queries = ref [] in
        let embed_and_retrieve (query_text : string) : Yojson.Safe.t list =
          match ollama_embed ~client ~sw ~task:Search_query ~label:"query" ~stats:stats_embed_query ~text:query_text () with
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
                  []
              | Ok (sources, sql) ->
                  retrieval_sqls := sql :: !retrieval_sqls;
                  sources)
        in

        let all_sources =
          List.concat (List.map embed_and_retrieve queries)
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
          let message_ids =
            select_relevant_sources ~client ~sw ~resolved_question
              ~user_name:(s.user_name) ~llm_log sources_json
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

          let body =
            `Assoc
              [ ("status", `String "need_messages")
              ; ("request_id", `String request_id)
              ; ("message_ids", `List (List.map (fun s -> `String s) message_ids))
              ; ("sources", annotated_sources)
              ; ("retrieval_sql", `String retrieval_sql)
              ; ("retrieval_queries", retrieval_queries_json)
              ]
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
      let ingested, processed, reply_by_pairs =
        match Rag_lib.Pg.batch_ingested_status ids with
        | Ok (i, p, rb) -> (i, p, rb)
        | Error e ->
            Printf.eprintf "[admin.ingested_status.error] %s\n%!" e;
            ([], [], [])
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
      let reply_by_obj =
        reply_by_pairs |> List.filter_map (fun (nid, rb) ->
          let orig = match Hashtbl.find_opt norm_to_orig nid with Some o -> o | None -> nid in
          Some (orig, `String rb))
      in
      let body =
        `Assoc
          [ ("ingested", `List (List.map (fun s -> `String s) (map_back ingested)))
          ; ("processed", `List (List.map (fun s -> `String s) (map_back processed)))
          ; ("reply_by", `Assoc reply_by_obj)
          ]
        |> Yojson.Safe.to_string
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()

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
            ~triage:None
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
        let body =
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
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:(Yojson.Safe.to_string body) ~headers:json_headers ()

  | `POST, "/admin/delete" ->
      let delete_body = read_all body in
      let doc_id =
        try
          let json = Yojson.Safe.from_string delete_body in
          match json with
          | `Assoc kv -> (
              match List.assoc_opt "id" kv with
              | Some (`String s) -> String.trim s
              | _ -> "")
          | _ -> ""
        with _ -> ""
      in
      if doc_id = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:{|{"error":"missing id"}|} ~headers:json_headers ()
      else (
        match Rag_lib.Pg.delete_email doc_id with
        | Ok () ->
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:{|{"ok":true}|} ~headers:json_headers ()
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
        match Rag_lib.Pg.set_processed id true with
        | Ok true ->
            Printf.printf "[admin.mark_processed] %s -> processed=true\n%!" id;
            Cohttp_eio.Server.respond_string ~status:`OK
              ~body:(Yojson.Safe.to_string (`Assoc [ ("ok", `Bool true); ("id", `String id); ("processed", `Bool true) ]))
              ~headers:json_headers ()
        | Ok false | Error _ when not is_json ->
            (* Not yet ingested but we have raw RFC822 — ingest first, then mark processed *)
            Printf.eprintf "[admin.mark_processed] %s not ingested, auto-ingesting from RFC822\n%!" id;
            let rfc_headers = parse_headers raw in
            let doc_id = doc_id_of_ingest request rfc_headers raw in
            let hdr_whoami = request_header_or_empty request "x-thunderrag-whoami" in
            let whoami = if String.trim hdr_whoami <> "" then hdr_whoami else !whoami in
            let resp, _resp_body =
              forward_ingest_raw ~client ~sw ~log:true ~whoami ~doc_id ~headers:rfc_headers ~raw
            in
            let code = Cohttp.Code.code_of_status (Http.Response.status resp) in
            if code >= 200 && code < 300 then (
              ignore (Rag_lib.Pg.set_processed doc_id true);
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
  | `POST, _ ->
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"not found\n" ()
  | _ ->
      Cohttp_eio.Server.respond_string ~status:`Method_not_allowed ~body:"method not allowed\n" ()

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
    ; ("--config-dir", Arg.Set_string config_dir, " Config directory for settings.json and prompts.json (default: ~/.thunderRAG)")
    ]
    ignore "RAG email ingest server";

  (* Install defaults to config dir if not already present, then load *)
  ensure_dir (thunderrag_config_dir ());
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
  let socket =
    try
      Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.any, !port))
    with Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Printf.eprintf
        "Error: port %d is already in use.\n\
         Another instance of rag-email-server (or another process) is likely running on that port.\n\
         Try:  lsof -ti:%d | xargs kill   or use a different port with -p <port>\n%!"
        !port !port;
      exit 1
  in
  Printf.printf "Listening on port %d\n%!" !port;
  let server = Cohttp_eio.Server.make ~callback:(handler ~client ~sw ~clock:env#clock) () in
  Cohttp_eio.Server.run socket server ~on_error:log_warning
