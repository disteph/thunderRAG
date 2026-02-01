open Eio.Std

let () = Tool_check.ensure ()

let bulk_ingest_build_tag = "progress_bytes_v1"

let normalize_newlines_for_parsing (s : string) : string =
  if not (String.contains s '\r') then s
  else
    let len = String.length s in
    let b = Bytes.create len in
    let rec loop i j =
      if i >= len then Bytes.sub_string b 0 j
      else
        match s.[i] with
        | '\r' ->
            if i + 1 < len && s.[i + 1] = '\n' then (
              Bytes.set b j '\n';
              loop (i + 2) (j + 1))
            else (
              Bytes.set b j '\n';
              loop (i + 1) (j + 1))
        | c ->
            Bytes.set b j c;
            loop (i + 1) (j + 1)
    in
    loop 0 0

let sanitize_utf8 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let is_cont b = b land 0xC0 = 0x80 in
  let get i = int_of_char s.[i] in
  let add_byte i = Buffer.add_char buf s.[i] in
  let add_repl () = Buffer.add_char buf '?' in
  let rec loop i =
    if i >= len then ()
    else
      let b0 = get i in
      if b0 < 0x80 then (
        if b0 = 0 then Buffer.add_char buf ' ' else add_byte i;
        loop (i + 1))
      else if b0 >= 0xC2 && b0 <= 0xDF then
        if i + 1 < len then (
          let b1 = get (i + 1) in
          if is_cont b1 then (
            add_byte i;
            add_byte (i + 1);
            loop (i + 2))
          else (
            add_repl ();
            loop (i + 1)))
        else (
          add_repl ();
          loop (i + 1))
      else if b0 >= 0xE0 && b0 <= 0xEF then
        if i + 2 < len then (
          let b1 = get (i + 1) in
          let b2 = get (i + 2) in
          let ok =
            is_cont b1 && is_cont b2
            && (if b0 = 0xE0 then b1 >= 0xA0 else true)
            && (if b0 = 0xED then b1 < 0xA0 else true)
          in
          if ok then (
            add_byte i;
            add_byte (i + 1);
            add_byte (i + 2);
            loop (i + 3))
          else (
            add_repl ();
            loop (i + 1)))
        else (
          add_repl ();
          loop (i + 1))
      else if b0 >= 0xF0 && b0 <= 0xF4 then
        if i + 3 < len then (
          let b1 = get (i + 1) in
          let b2 = get (i + 2) in
          let b3 = get (i + 3) in
          let ok =
            is_cont b1 && is_cont b2 && is_cont b3
            && (if b0 = 0xF0 then b1 >= 0x90 else true)
            && (if b0 = 0xF4 then b1 <= 0x8F else true)
          in
          if ok then (
            add_byte i;
            add_byte (i + 1);
            add_byte (i + 2);
            add_byte (i + 3);
            loop (i + 4))
          else (
            add_repl ();
            loop (i + 1)))
        else (
          add_repl ();
          loop (i + 1))
      else (
        add_repl ();
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let hex_value (c : char) : int option =
  if c >= '0' && c <= '9' then Some (Char.code c - Char.code '0')
  else if c >= 'A' && c <= 'F' then Some (10 + Char.code c - Char.code 'A')
  else if c >= 'a' && c <= 'f' then Some (10 + Char.code c - Char.code 'a')
  else None

let percent_decode (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      match s.[i] with
      | '%' when i + 2 < len -> (
          match (hex_value s.[i + 1], hex_value s.[i + 2]) with
          | Some a, Some b ->
              Buffer.add_char buf (Char.chr ((a lsl 4) lor b));
              loop (i + 3)
          | _ ->
              Buffer.add_char buf s.[i];
              loop (i + 1))
      | c ->
          Buffer.add_char buf c;
          loop (i + 1)
  in
  loop 0;
  Buffer.contents buf

let strip_quotes (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

let decode_rfc2231_value (v : string) : string =
  let v = strip_quotes (String.trim v) in
  match String.split_on_char '\'' v with
  | charset :: _lang :: value :: _rest ->
      let charset = String.lowercase_ascii (String.trim charset) in
      if charset = "utf-8" || charset = "utf8" then percent_decode value else percent_decode value
  | _ -> percent_decode v

let find_param ~(name : string) (header_value : string) : string option =
  let parts = String.split_on_char ';' header_value |> List.map String.trim in
  let name_l = String.lowercase_ascii name in
  let rec loop = function
    | [] -> None
    | p :: rest ->
        let p_l = String.lowercase_ascii p in
        if String.length p_l >= String.length name_l + 1
           && String.sub p_l 0 (String.length name_l + 1) = name_l ^ "="
        then
          let v = String.sub p (String.length name_l + 1) (String.length p - (String.length name_l + 1)) in
          Some (String.trim v)
        else loop rest
  in
  loop parts

let decode_q_encoded (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      match s.[i] with
      | '_' ->
          Buffer.add_char buf ' ';
          loop (i + 1)
      | '=' when i + 2 < len -> (
          match (hex_value s.[i + 1], hex_value s.[i + 2]) with
          | Some a, Some b ->
              Buffer.add_char buf (Char.chr ((a lsl 4) lor b));
              loop (i + 3)
          | _ ->
              Buffer.add_char buf s.[i];
              loop (i + 1))
      | c ->
          Buffer.add_char buf c;
          loop (i + 1)
  in
  loop 0;
  Buffer.contents buf

let base64_value (c : char) : int option =
  if c >= 'A' && c <= 'Z' then Some (Char.code c - Char.code 'A')
  else if c >= 'a' && c <= 'z' then Some (26 + Char.code c - Char.code 'a')
  else if c >= '0' && c <= '9' then Some (52 + Char.code c - Char.code '0')
  else if c = '+' then Some 62
  else if c = '/' then Some 63
  else None

let decode_base64 (s : string) : string option =
  let len = String.length s in
  let buf = Buffer.create (len * 3 / 4) in
  let rec next_non_ws i =
    if i >= len then i
    else
      match s.[i] with
      | ' ' | '\t' | '\r' | '\n' -> next_non_ws (i + 1)
      | _ -> i
  in
  let rec loop i =
    let i = next_non_ws i in
    if i >= len then Some (Buffer.contents buf)
    else if i + 3 >= len then None
    else
      let c0 = s.[i] in
      let c1 = s.[i + 1] in
      let c2 = s.[i + 2] in
      let c3 = s.[i + 3] in
      let v0 = base64_value c0 in
      let v1 = base64_value c1 in
      let v2 = if c2 = '=' then Some 0 else base64_value c2 in
      let v3 = if c3 = '=' then Some 0 else base64_value c3 in
      match (v0, v1, v2, v3) with
      | Some a, Some b, Some c, Some d ->
          let triple = (a lsl 18) lor (b lsl 12) lor (c lsl 6) lor d in
          Buffer.add_char buf (Char.chr ((triple lsr 16) land 0xFF));
          if c2 <> '=' then Buffer.add_char buf (Char.chr ((triple lsr 8) land 0xFF));
          if c3 <> '=' then Buffer.add_char buf (Char.chr (triple land 0xFF));
          loop (i + 4)
      | _ -> None
  in
  loop 0

let decode_rfc2047 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let is_prefix i pref =
    let l = String.length pref in
    i + l <= len && String.sub s i l = pref
  in
  let find_from i ch =
    let rec loop j =
      if j >= len then None
      else if s.[j] = ch then Some j
      else loop (j + 1)
    in
    loop i
  in
  let rec loop i =
    if i >= len then ()
    else if is_prefix i "=?" then (
      match find_from (i + 2) '?' with
      | None ->
          Buffer.add_char buf s.[i];
          loop (i + 1)
      | Some j1 -> (
          match find_from (j1 + 1) '?' with
          | None ->
              Buffer.add_char buf s.[i];
              loop (i + 1)
          | Some j2 -> (
              match find_from (j2 + 1) '?' with
              | None ->
                  Buffer.add_char buf s.[i];
                  loop (i + 1)
              | Some j3 ->
                  if j3 + 1 < len && s.[j3 + 1] = '=' then (
                    let charset =
                      String.sub s (i + 2) (j1 - (i + 2)) |> String.lowercase_ascii
                    in
                    let enc =
                      String.sub s (j1 + 1) (j2 - (j1 + 1)) |> String.lowercase_ascii
                    in
                    let payload = String.sub s (j2 + 1) (j3 - (j2 + 1)) in
                    let decoded_opt =
                      if charset = "utf-8" || charset = "utf8" then
                        if enc = "q" then Some (decode_q_encoded payload)
                        else if enc = "b" then decode_base64 payload
                        else None
                      else None
                    in
                    (match decoded_opt with
                    | Some d -> Buffer.add_string buf d
                    | None -> Buffer.add_string buf (String.sub s i (j3 + 2 - i)));
                    loop (j3 + 2))
                  else (
                    Buffer.add_char buf s.[i];
                    loop (i + 1)))))
    else (
      Buffer.add_char buf s.[i];
      loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let extract_attachment_filenames (raw : string) : string list =
  let raw = normalize_newlines_for_parsing raw in
  let lines = String.split_on_char '\n' raw |> Array.of_list in
  let acc = Hashtbl.create 16 in
  let add_name (v : string) : unit =
    let v = v |> decode_rfc2231_value |> decode_rfc2047 |> sanitize_utf8 |> String.trim in
    if v <> "" then Hashtbl.replace acc v ()
  in
  let n = Array.length lines in
  let collect_folded (start_idx : int) (prefix_len : int) : (string * int) =
    let buf = Buffer.create 128 in
    let first = String.trim lines.(start_idx) in
    let rest =
      if String.length first > prefix_len then String.sub first prefix_len (String.length first - prefix_len)
      else ""
    in
    Buffer.add_string buf (String.trim rest);
    let j = ref (start_idx + 1) in
    let continue = ref true in
    while !continue && !j < n do
      let l = lines.(!j) in
      if String.length l > 0 && (l.[0] = ' ' || l.[0] = '\t') then (
        Buffer.add_char buf ' ';
        Buffer.add_string buf (String.trim l);
        incr j)
      else continue := false
    done;
    (Buffer.contents buf, !j)
  in
  let rec loop i =
    if i >= n then ()
    else
      let trimmed = String.trim lines.(i) in
      if trimmed = "" then loop (i + 1)
      else
        let lower = String.lowercase_ascii trimmed in
        if String.length lower >= 19 && String.sub lower 0 19 = "content-disposition:" then (
          let hv, j = collect_folded i 19 in
          (match find_param ~name:"filename*" hv with
          | Some v -> add_name v
          | None -> (
              match find_param ~name:"filename" hv with
              | Some v -> add_name v
              | None -> ()));
          loop j)
        else if String.length lower >= 13 && String.sub lower 0 13 = "content-type:" then (
          let hv, j = collect_folded i 13 in
          (match find_param ~name:"name*" hv with
          | Some v -> add_name v
          | None -> (
              match find_param ~name:"name" hv with
              | Some v -> add_name v
              | None -> ()));
          loop j)
        else loop (i + 1)
  in
  loop 0;
  Hashtbl.to_seq_keys acc |> List.of_seq

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

let parse_headers (raw : string) : (string, string) Hashtbl.t =
  let raw = normalize_newlines_for_parsing raw in
  let len = String.length raw in
  let find_sub ~sub =
    let sublen = String.length sub in
    let rec loop i =
      if i + sublen > len then None
      else if String.sub raw i sublen = sub then Some i
      else loop (i + 1)
    in
    loop 0
  in
  let header_end =
    match find_sub ~sub:"\n\n" with
    | Some i -> Some (i, 2)
    | None -> None
  in
  let header_text =
    match header_end with
    | Some (i, _sep_len) -> String.sub raw 0 i
    | None -> raw
  in
  let lines =
    header_text
    |> String.split_on_char '\n'
    |> List.map (fun s ->
           let s =
             if String.length s > 0 && s.[String.length s - 1] = '\r' then
               String.sub s 0 (String.length s - 1)
             else s
           in
           s)
  in
  let unfolded =
    let rec loop acc current_name current_value = function
      | [] -> (
          match current_name with
          | None -> List.rev acc
          | Some n -> List.rev ((n, current_value) :: acc))
      | line :: rest -> (
          match (line, current_name) with
          | "", _ ->
              (* End of headers. *)
              loop acc current_name current_value []
          | ( _
            , Some _ )
            when String.length line > 0
                 && (line.[0] = ' ' || line.[0] = '\t') ->
              let v = current_value ^ " " ^ String.trim line in
              loop acc current_name v rest
          | _ -> (
              let acc =
                match current_name with
                | None -> acc
                | Some n -> (n, current_value) :: acc
              in
              match String.index_opt line ':' with
              | None -> loop acc None "" rest
              | Some idx ->
                  let name = String.sub line 0 idx |> String.lowercase_ascii in
                  let value =
                    String.sub line (idx + 1) (String.length line - idx - 1)
                    |> String.trim
                  in
                  loop acc (Some name) value rest))
    in
    loop [] None "" lines
  in
  let tbl = Hashtbl.create 16 in
  let add name value =
    match Hashtbl.find_opt tbl name with
    | None -> Hashtbl.add tbl name value
    | Some existing -> Hashtbl.replace tbl name (existing ^ ", " ^ value)
  in
  List.iter (fun (k, v) -> add k v) unfolded;
  tbl

let header_or_empty (headers : (string, string) Hashtbl.t) (name : string) :
    string =
  match Hashtbl.find_opt headers (String.lowercase_ascii name) with
  | Some v -> v
  | None -> ""

let is_text_plain (header : Mrmime.Header.t) : bool =
  let ct = Mrmime.Header.content_type header in
  let ty = Mrmime.Content_type.ty ct in
  let subty = Mrmime.Content_type.subty ct |> Mrmime.Content_type.Subtype.to_string in
  match ty with
  | `Text -> String.lowercase_ascii subty = "plain"
  | _ -> false

let extract_text_plain_parts (raw : string) : string =
  let raw = normalize_newlines_for_parsing raw in
  let buf = Buffer.create 4096 in
  let emitters (header : Mrmime.Header.t) =
    if is_text_plain header then
      let emitter = function
        | None -> ()
        | Some chunk -> Buffer.add_string buf chunk
      in
      (emitter, ())
    else
      let emitter = function
        | None -> ()
        | Some _chunk -> ()
      in
      (emitter, ())
  in
  match Angstrom.parse_string ~consume:All (Mrmime.Mail.stream emitters) raw with
  | Ok _ -> Buffer.contents buf
  | Error _msg -> ""

let python_engine_base = "http://127.0.0.1:8000"

let ollama_base_url =
  match Sys.getenv_opt "OLLAMA_BASE_URL" with
  | Some s when String.trim s <> "" -> String.trim s
  | _ -> "http://127.0.0.1:11434"

let ollama_embed_model =
  match Sys.getenv_opt "OLLAMA_EMBED_MODEL" with
  | Some s when String.trim s <> "" -> String.trim s
  | _ -> "nomic-embed-text"

let ollama_llm_model =
  match Sys.getenv_opt "OLLAMA_LLM_MODEL" with
  | Some s when String.trim s <> "" -> String.trim s
  | _ -> "llama3"

let is_ok_status (status : Http.Status.t) : bool =
  let code = Cohttp.Code.code_of_status status in
  code >= 200 && code < 300

let json_headers =
  Http.Header.init_with "content-type" "application/json"
  |> fun h -> Http.Header.add h "connection" "close"

let post_json_uri ~client ~sw ~(uri : Uri.t) ~(body_json : string) : (Http.Response.t * string) =
  let body = Cohttp_eio.Body.of_string body_json in
  let _ = sw in
  Eio.Switch.run (fun inner_sw ->
    let resp, resp_body =
      Cohttp_eio.Client.call client ~sw:inner_sw ~headers:json_headers ~body `POST uri
    in
    (resp, read_all resp_body))

let ollama_embed ~client ~sw ~(text : string) : (float list, string) result =
  let uri = Uri.of_string (ollama_base_url ^ "/api/embeddings") in
  let body_json =
    `Assoc [ ("model", `String ollama_embed_model); ("prompt", `String text) ]
    |> Yojson.Safe.to_string
  in
  let resp, resp_body = post_json_uri ~client ~sw ~uri ~body_json in
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

let ollama_chat ~client ~sw ~(messages : Yojson.Safe.t list) : (string, string) result =
  let uri = Uri.of_string (ollama_base_url ^ "/api/chat") in
  let body_obj : Yojson.Safe.t =
    `Assoc
      [ ("model", `String ollama_llm_model)
      ; ("messages", `List messages)
      ; ("stream", `Bool false)
      ]
  in
  (match Sys.getenv_opt "RAG_DEBUG_OLLAMA_CHAT" with
  | Some v when String.trim v = "1" ->
      Printf.printf "\n[ollama.chat.request]\n%s\n%!" (Yojson.Safe.pretty_to_string body_obj)
  | _ -> ());
  let body_json = Yojson.Safe.to_string body_obj in
  let resp, resp_body = post_json_uri ~client ~sw ~uri ~body_json in
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

let l2_normalize (vec : float list) : float list =
  let s =
    List.fold_left
      (fun acc v -> acc +. (v *. v))
      0.0 vec
  in
  if s <= 0.0 then vec
  else
    let inv = 1.0 /. sqrt s in
    List.map (fun v -> v *. inv) vec

let chunk_text (text : string) : string list =
  let chunk_size = 1500 in
  let overlap = 200 in
  let cleaned = String.trim text in
  let n = String.length cleaned in
  let rec loop start acc =
    if start >= n then List.rev acc
    else
      let end_ = min n (start + chunk_size) in
      let chunk = String.sub cleaned start (end_ - start) |> String.trim in
      let acc = if chunk = "" then acc else chunk :: acc in
      if end_ >= n then List.rev acc else loop (max 0 (end_ - overlap)) acc
  in
  if cleaned = "" then [] else loop 0 []

type chat_message =
  { role : string
  ; content : string
  }

type session_state =
  { mu : Eio.Mutex.t
  ; mutable history_summary : string
  ; mutable tail : chat_message list
  ; mutable sources_summary : string
  ; mutable last_sources_recap : string
  }

let session_tbl : (string, session_state) Hashtbl.t = Hashtbl.create 64
let session_tbl_mu : Eio.Mutex.t = Eio.Mutex.create ()

let get_or_create_session (session_id : string) : session_state =
  Eio.Mutex.use_rw ~protect:true session_tbl_mu (fun () ->
    match Hashtbl.find_opt session_tbl session_id with
    | Some s -> s
    | None ->
        let s =
          { mu = Eio.Mutex.create ()
          ; history_summary = ""
          ; tail = []
          ; sources_summary = ""
          ; last_sources_recap = ""
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

let take (n : int) (xs : 'a list) : 'a list =
  let rec loop k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | y :: ys -> loop (k - 1) (y :: acc) ys
  in
  if n <= 0 then [] else loop n [] xs

let take_last (n : int) (xs : 'a list) : 'a list =
  if n <= 0 then []
  else
    let len = List.length xs in
    let drop = len - n in
    let rec loop i = function
      | [] -> []
      | y :: ys -> if i <= 0 then y :: ys else loop (i - 1) ys
    in
    if drop <= 0 then xs else loop drop xs

let drop_last (n : int) (xs : 'a list) : 'a list =
  if n <= 0 then xs
  else
    let len = List.length xs in
    let keep = len - n in
    let rec loop i = function
      | [] -> []
      | y :: ys -> if i <= 0 then [] else y :: loop (i - 1) ys
    in
    if keep <= 0 then [] else loop keep xs

let sources_recap_of_query_response (resp_body : string) : string option =
  try
    let json = Yojson.Safe.from_string resp_body in
    let assoc =
      match json with
      | `Assoc kv -> kv
      | _ -> []
    in
    match List.assoc_opt "sources" assoc with
    | Some (`List xs) ->
        let xs = if List.length xs > 12 then take 12 xs else xs in
        let lines =
          xs
          |> List.mapi (fun i v ->
                 let get_field name =
                   match v with
                   | `Assoc kv -> List.assoc_opt name kv
                   | _ -> None
                 in
                 let doc_id =
                   match get_field "doc_id" with
                   | Some (`String s) -> s
                   | _ -> ""
                 in
                 let md =
                   match get_field "metadata" with
                   | Some (`Assoc kv) -> kv
                   | _ -> []
                 in
                 let get_md_str key =
                   match List.assoc_opt key md with
                   | Some (`String s) -> String.trim s
                   | _ -> ""
                 in
                 let from_ = get_md_str "from" in
                 let subject = get_md_str "subject" in
                 let date_ = get_md_str "date" in
                 let atts =
                   match List.assoc_opt "attachments" md with
                   | Some (`List ys) ->
                       ys
                       |> List.filter_map (function
                            | `String s when String.trim s <> "" -> Some (String.trim s)
                            | _ -> None)
                       |> String.concat ", "
                   | _ -> ""
                 in
                 let att_part = if atts = "" then "" else Printf.sprintf " attachments=%s" atts in
                 Printf.sprintf
                   "[Source %d] doc_id=%s from=%s subject=%s date=%s%s"
                   (i + 1) doc_id from_ subject date_ att_part)
        in
        Some (String.concat "\n" lines)
    | _ -> Some ""
  with _ -> None

let answer_of_query_response (resp_body : string) : string option =
  try
    let json = Yojson.Safe.from_string resp_body in
    match json with
    | `Assoc kv -> (
        match List.assoc_opt "answer" kv with
        | Some (`String s) -> Some s
        | _ -> None)
    | _ -> None
  with _ -> None

let call_ollama_summarize ~client ~sw ~(kind : string) ~(text : string) ~(target_chars : int)
    : string option =
  let instr =
    if kind = "sources" then
      "Summarize the following sources recap so it can be used as context for follow-up questions. Preserve any doc_id/message_id, dates, subjects, senders, and attachment filenames. Do not invent sources."
    else
      "Summarize the following conversation so it can be used as context for a future assistant reply. Preserve user preferences, decisions, constraints, open questions, and any specific identifiers. Do not invent facts."
  in
  let messages =
    [ `Assoc [ ("role", `String "system"); ("content", `String (instr ^ Printf.sprintf " Target length: at most %d characters. Output plain text." target_chars)) ]
    ; `Assoc [ ("role", `String "user"); ("content", `String text) ]
    ]
  in
  match ollama_chat ~client ~sw ~messages with
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
    match call_ollama_summarize ~client ~sw ~kind:"history" ~text:prefix ~target_chars:history_target with
    | Some summary ->
        s.history_summary <- trim_to_max summary history_target;
        s.tail <- to_keep
    | None -> ());

  let sources_max = 8000 in
  let sources_trigger = int_of_float (0.8 *. float_of_int sources_max) in
  let sources_target = int_of_float (0.6 *. float_of_int sources_max) in
  if String.length s.sources_summary > sources_trigger then
    match
      call_ollama_summarize ~client ~sw ~kind:"sources" ~text:s.sources_summary
        ~target_chars:sources_target
    with
    | Some summary -> s.sources_summary <- trim_to_max summary sources_target
    | None -> ()

let sources_recap_of_sources_json (sources_json : Yojson.Safe.t) : string =
  let xs =
    match sources_json with
    | `List ys -> if List.length ys > 12 then take 12 ys else ys
    | _ -> []
  in
  let get_assoc_field name = function
    | `Assoc kv -> List.assoc_opt name kv
    | _ -> None
  in
  let get_md_str md key =
    match md with
    | `Assoc kv -> (
        match List.assoc_opt key kv with
        | Some (`String s) -> String.trim s
        | _ -> "")
    | _ -> ""
  in
  let lines =
    xs
    |> List.mapi (fun i v ->
           let doc_id =
             match get_assoc_field "doc_id" v with
             | Some (`String s) -> s
             | _ -> ""
           in
           let md =
             match get_assoc_field "metadata" v with
             | Some m -> m
             | _ -> `Assoc []
           in
           let from_ = get_md_str md "from" in
           let subject = get_md_str md "subject" in
           let date_ = get_md_str md "date" in
           let atts =
             match md with
             | `Assoc kv -> (
                 match List.assoc_opt "attachments" kv with
                 | Some (`List ys) ->
                     ys
                     |> List.filter_map (function
                          | `String s when String.trim s <> "" -> Some (String.trim s)
                          | _ -> None)
                     |> String.concat ", "
                 | _ -> "")
             | _ -> ""
           in
           let att_part = if atts = "" then "" else Printf.sprintf " attachments=%s" atts in
           Printf.sprintf
             "[Source %d] doc_id=%s from=%s subject=%s date=%s%s"
             (i + 1) doc_id from_ subject date_ att_part)
  in
  String.concat "\n" lines

let forward_json ~client ~sw ~(path : string) ~(body_json : string) : (Http.Response.t * string)
    =
  let uri = Uri.of_string (python_engine_base ^ path) in
  let body = Cohttp_eio.Body.of_string body_json in
  let _ = sw in
  Eio.Switch.run (fun inner_sw ->
    let resp, resp_body =
      Cohttp_eio.Client.call client ~sw:inner_sw ~headers:json_headers ~body `POST uri
    in
    (resp, read_all resp_body))

let request_header_or_empty (request : Http.Request.t) (name : string) : string =
  match Http.Header.get (Http.Request.headers request) name with
  | Some v -> v
  | None -> ""

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

let make_ingest_json ~doc_id ~(headers : (string, string) Hashtbl.t) ~(raw : string)
    ~(body_text : string) : string =
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
      ; ("message_id", `String doc_id)
      ]
  in
  let attachments_line =
    if attachments = [] then "" else Printf.sprintf "\nAttachments: %s" (String.concat ", " attachments)
  in
  let text_for_index =
    Printf.sprintf
      "From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nDate: %s%s\nMessage-Id: %s\n\n%s"
      from_ to_ cc_ bcc_ subject date_ attachments_line doc_id body_text
  in
  `Assoc
    [ ("id", `String doc_id)
    ; ("text", `String text_for_index)
    ; ("metadata", metadata_json)
    ]
  |> Yojson.Safe.to_string

let forward_ingest_raw ~client ~sw ~log ~(doc_id : string) ~(headers : (string, string) Hashtbl.t)
    ~(raw : string) : (Http.Response.t * string) =
  let from_ = header_or_empty headers "from" in
  let to_ = header_or_empty headers "to" in
  let cc_ = header_or_empty headers "cc" in
  let bcc_ = header_or_empty headers "bcc" in
  let subject = header_or_empty headers "subject" in
  let body_text = extract_text_plain_parts raw in

  if log then (
    Printf.printf "From: %s\n" from_;
    Printf.printf "To: %s\n" to_;
    Printf.printf "Cc: %s\n" cc_;
    Printf.printf "Bcc: %s\n" bcc_;
    Printf.printf "Title: %s\n" subject;
    Printf.printf "Id: %s\n" doc_id;
    Printf.printf "Body:\n%s\n" body_text;
    flush stdout);

  let ingest_json = make_ingest_json ~doc_id ~headers ~raw ~body_text in
  let index_text =
    try
      let json = Yojson.Safe.from_string ingest_json in
      match json with
      | `Assoc kv -> (
          match List.assoc_opt "text" kv with
          | Some (`String s) -> s
          | _ -> "")
      | _ -> ""
    with _ -> ""
  in
  let metadata_json =
    try
      let json = Yojson.Safe.from_string ingest_json in
      match json with
      | `Assoc kv -> (
          match List.assoc_opt "metadata" kv with
          | Some m -> m
          | _ -> `Assoc [])
      | _ -> `Assoc []
    with _ -> `Assoc []
  in
  let chunks = chunk_text index_text in
  let embedded_chunks =
    chunks
    |> List.mapi (fun i ch ->
           match ollama_embed ~client ~sw ~text:ch with
           | Ok v -> (i, ch, l2_normalize v)
           | Error msg -> raise (Failure ("ollama_embed failed: " ^ msg)))
  in
  let chunks_json =
    `List
      (List.map
         (fun (i, ch, v) ->
           `Assoc
             [ ("chunk_index", `Int i)
             ; ("text", `String ch)
             ; ("embedding", `List (List.map (fun f -> `Float f) v))
             ])
         embedded_chunks)
  in
  let body_json =
    `Assoc
      [ ("id", `String doc_id)
      ; ("metadata", metadata_json)
      ; ("chunks", chunks_json)
      ]
    |> Yojson.Safe.to_string
  in
  forward_json ~client ~sw ~path:"/ingest_embedded" ~body_json

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
  let ends_with s suf =
    let ls = String.length s in
    let lq = String.length suf in
    ls >= lq && String.sub s (ls - lq) lq = suf
  in
  ends_with lower ".msf" || ends_with lower ".dat" || ends_with lower ".sqlite"
  || ends_with lower ".json" || ends_with lower ".log"

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
      let home =
        match Sys.getenv_opt "HOME" with
        | Some h -> h
        | None -> "."
      in
      Filename.concat home ".rag_bulk_ingest_state.json"

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
                    forward_ingest_raw ~client ~sw ~log:false ~doc_id ~headers ~raw
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

let handler ~client ~sw ~clock _socket request body =
  match Http.Request.meth request, Http.Request.resource request with
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
              ; ("sources_summary", `String s.sources_summary)
              ; ("last_sources_recap", `String s.last_sources_recap)
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
  | `POST, "/ingest" ->
      let raw = read_all body in
      let headers = parse_headers raw in
      let doc_id = doc_id_of_ingest request headers raw in

      let resp, resp_body =
        forward_ingest_raw ~client ~sw ~log:true ~doc_id ~headers ~raw
      in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()
  | `POST, "/query" ->
      let query_body = read_all body in
      let session_id, question, top_k, mode =
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
          (session_id, question, top_k, mode)
        with _ -> ("", "", 8, "assistive")
      in
      if String.trim session_id = "" || String.trim question = "" then
        Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"missing session_id/question\n" ()
      else (
        let s = get_or_create_session session_id in
        let tail_snapshot, history_summary, sources_summary, last_sources_recap =
          Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
            (s.tail, s.history_summary, s.sources_summary, s.last_sources_recap))
        in

        let q_embedding =
          match ollama_embed ~client ~sw ~text:question with
          | Ok v -> l2_normalize v
          | Error msg ->
              let body = Printf.sprintf "ollama embed error: %s\n" msg in
              raise (Failure body)
        in

        let retrieval_body =
          `Assoc
            [ ("embedding", `List (List.map (fun f -> `Float f) q_embedding))
            ; ("top_k", `Int top_k)
            ]
          |> Yojson.Safe.to_string
        in
        let resp_r, resp_r_body =
          forward_json ~client ~sw ~path:"/query_embedded" ~body_json:retrieval_body
        in
        let status_r = Http.Response.status resp_r in
        if not (is_ok_status status_r) then
          Cohttp_eio.Server.respond_string ~status:status_r ~body:resp_r_body ~headers:json_headers ()
        else (
          let sources_json =
            try
              let json = Yojson.Safe.from_string resp_r_body in
              match json with
              | `Assoc kv -> (
                  match List.assoc_opt "sources" kv with
                  | Some s -> s
                  | None -> `List [])
              | _ -> `List []
            with _ -> `List []
          in

          let evidence_msg =
            let excerpt (s : string) =
              let max_len = 800 in
              if String.length s <= max_len then s else String.sub s 0 max_len
            in
            let lines =
              match sources_json with
              | `List ys ->
                  ys
                  |> List.mapi (fun i v ->
                         let getf name =
                           match v with
                           | `Assoc kv -> List.assoc_opt name kv
                           | _ -> None
                         in
                         let doc_id =
                           match getf "doc_id" with
                           | Some (`String s) -> s
                           | _ -> ""
                         in
                         let md =
                           match getf "metadata" with
                           | Some m -> m
                           | _ -> `Assoc []
                         in
                         let get_md key =
                           match md with
                           | `Assoc kv -> (
                               match List.assoc_opt key kv with
                               | Some (`String s) -> String.trim s
                               | _ -> "")
                           | _ -> ""
                         in
                         let from_ = get_md "from" in
                         let subject = get_md "subject" in
                         let date_ = get_md "date" in
                         let text =
                           match getf "text" with
                           | Some (`String s) -> s
                           | _ -> ""
                         in
                         Printf.sprintf "[Source %d] doc_id=%s date=%s from=%s subject=%s\n%s"
                           (i + 1) doc_id date_ from_ subject (excerpt (String.trim text)))
              | _ -> []
            in
            String.concat "\n\n" lines
          in

          let system_prompt =
            "You are a careful assistant in an ongoing multi-turn chat. "
            ^ "Treat the previous user/assistant turns as conversation context. "
            ^ "Answer ONLY the last user message. "
            ^ "After the current user request, you may receive a system message containing RETRIEVED EVIDENCE for that request; use it to answer the most recent user message. "
            ^ "Do not greet, do not restate the user's request, and do not narrate your process. "
            ^ "Do not invent email facts; use the provided evidence and cite sources as [Source N] when relying on them. "
            ^ "If the user refers to 'the second one you listed', resolve it against your most recent numbered list."
          in

          let messages =
            let base =
              [ `Assoc [ ("role", `String "system"); ("content", `String system_prompt) ] ]
            in
            let with_summaries =
              let add_if_nonempty label v acc =
                if String.trim v = "" then acc
                else
                  acc
                  @ [ `Assoc
                        [ ("role", `String "system")
                        ; ("content", `String (label ^ "\n" ^ v))
                        ]
                    ]
              in
              base
              |> add_if_nonempty "SESSION SUMMARY:" history_summary
              |> add_if_nonempty "SOURCES SUMMARY:" sources_summary
              |> add_if_nonempty "PREVIOUS SOURCES RECAP:" last_sources_recap
            in
            let with_tail =
              with_summaries
              @ List.map
                  (fun m ->
                    `Assoc
                      [ ("role", `String m.role)
                      ; ("content", `String m.content)
                      ])
                  tail_snapshot
            in
            let with_question =
              with_tail
              @ [ `Assoc [ ("role", `String "user"); ("content", `String question) ] ]
            in
            if String.trim evidence_msg = "" then with_question
            else
              with_question
              @ [ `Assoc
                    [ ("role", `String "system")
                    ; ("content", `String ("RETRIEVED EMAILS THAT MAY BE RELEVANT TO REPLY TO THE ABOVE USER REQUEST:\n" ^ evidence_msg))
                    ]
                ]
          in

          let answer =
            match ollama_chat ~client ~sw ~messages with
            | Ok s -> String.trim s
            | Error msg -> "ollama chat error: " ^ msg
          in

          let recap = sources_recap_of_sources_json sources_json in
          Eio.Mutex.use_rw ~protect:true s.mu (fun () ->
            let add_msg role content =
              s.tail <- s.tail @ [ { role; content } ];
              let max_tail = 24 in
              if List.length s.tail > max_tail then s.tail <- take_last max_tail s.tail
            in
            add_msg "user" question;
            add_msg "assistant" answer;

            if String.trim s.last_sources_recap <> "" then (
              if String.trim s.sources_summary = "" then s.sources_summary <- s.last_sources_recap
              else s.sources_summary <- s.sources_summary ^ "\n\n" ^ s.last_sources_recap);
            s.last_sources_recap <- recap;

            maybe_summarize_session ~client ~sw s);

          let body =
            `Assoc [ ("answer", `String answer); ("sources", sources_json) ]
            |> Yojson.Safe.to_string
          in
          Cohttp_eio.Server.respond_string ~status:`OK ~body ~headers:json_headers ()))
  | `POST, "/admin/delete" ->
      let delete_body = read_all body in
      let resp, resp_body = forward_json ~client ~sw ~path:"/admin/delete" ~body_json:delete_body in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()
  | `POST, "/admin/reset" ->
      let resp, resp_body = forward_json ~client ~sw ~path:"/admin/reset" ~body_json:"{}" in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()
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

let () =
  let port = ref 8080 in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number (8080 by default)") ]
    ignore "RAG email ingest server";

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.any, !port))
  in
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let server = Cohttp_eio.Server.make ~callback:(handler ~client ~sw ~clock:env#clock) () in
  Cohttp_eio.Server.run socket server ~on_error:log_warning
