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

let json_headers =
  Http.Header.init_with "content-type" "application/json"
  |> fun h -> Http.Header.add h "connection" "close"

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
  let from_ = header_or_empty headers "from" |> sanitize_utf8 in
  let to_ = header_or_empty headers "to" |> sanitize_utf8 in
  let cc_ = header_or_empty headers "cc" |> sanitize_utf8 in
  let bcc_ = header_or_empty headers "bcc" |> sanitize_utf8 in
  let subject = header_or_empty headers "subject" |> sanitize_utf8 in
  let body_text = sanitize_utf8 body_text in

  let metadata_json =
    `Assoc
      [ ("from", `String from_)
      ; ("to", `String to_)
      ; ("cc", `String cc_)
      ; ("bcc", `String bcc_)
      ; ("subject", `String subject)
      ; ("message_id", `String doc_id)
      ]
  in
  let text_for_index =
    Printf.sprintf "From: %s\nTo: %s\nCc: %s\nBcc: %s\nSubject: %s\nMessage-Id: %s\n\n%s"
      from_ to_ cc_ bcc_ subject doc_id body_text
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
  forward_json ~client ~sw ~path:"/ingest" ~body_json:ingest_json

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
          if (not !saw_any_read) && total > 0 then
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
                  flush_msg ();
                  let checkpoint_pos = data_offset + delim_start in
                  (try on_checkpoint checkpoint_pos with
                  | _ -> ());
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
    let name = Filename.basename path in
    let mb x = float_of_int x /. (1024.0 *. 1024.0) in
    Printf.printf "\r[%d/%d] %s [%s] %3d%% (%.1f/%.1f MB)%!" idx total_files name bar pct_int
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
                 | Some prev when prev.size = size && prev.mtime = mtime && prev.completed -> (0, true)
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
               Printf.printf "[%d/%d] starting %s size=%.1fMB start_pos=%d\n%!" idx total_files
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
                  Eio.Mutex.use_rw ~protect:true state_mu (fun () ->
                    Hashtbl.replace state_tbl path
                      { size; mtime; last_pos = pos; completed = false };
                    maybe_save_state ())
                in

               stream_mbox_messages path ~start_pos
                 ~on_progress:(fun cur total_bytes ->
                   last_file_progress := Unix.gettimeofday ();
                   current_file_pos := cur;
                   current_file_total := total_bytes;
                    show_file_progress ~idx ~total_files ~path ~cur ~total_bytes ~last_pct)
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
      let resp, resp_body = forward_json ~client ~sw ~path:"/query" ~body_json:query_body in
      let status = Http.Response.status resp in
      Cohttp_eio.Server.respond_string ~status ~body:resp_body ~headers:json_headers ()
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
