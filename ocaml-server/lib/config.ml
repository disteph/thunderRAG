(*
  Configuration and settings

  All config values are mutable refs.  Call [load_settings ()] after setting
  [config_dir] to read settings.json + env-var overrides into the refs.
  Call it again at any time (e.g. from /admin/reload) to pick up changes.
*)

(* User's home directory, used as the base for ~/.thunderRAG config dir. *)
let thunderrag_home_dir () : string =
  match Sys.getenv_opt "HOME" with
  | Some h when String.trim h <> "" -> h
  | _ -> "."

(* Mutable configuration directory.  Set via --config-dir before calling
   load_settings().  Defaults to ~/.thunderRAG. *)
let config_dir = ref (Filename.concat (thunderrag_home_dir ()) ".thunderRAG")

let thunderrag_config_dir () : string = !config_dir

(* Create a directory (mode 0700) if it does not already exist; silently ignores errors. *)
let ensure_dir (path : string) : unit =
  try
    if Sys.file_exists path then () else Unix.mkdir path 0o700
  with _ -> ()

(* Resolve the path to settings.json: THUNDERRAG_SETTINGS env var, or <config_dir>/settings.json.
   Supports ~ expansion. *)
let settings_path () : string =
  match Sys.getenv_opt "THUNDERRAG_SETTINGS" with
  | Some p when String.trim p <> "" ->
      let p = String.trim p in
      if String.length p > 0 && p.[0] = '~' then Filename.concat (thunderrag_home_dir ()) (String.sub p 1 (String.length p - 1))
      else p
  | _ -> Filename.concat (thunderrag_config_dir ()) "settings.json"

(* Load and parse settings.json from the current config dir. *)
let read_settings_json () : Yojson.Safe.t option =
  let p = settings_path () in
  if Sys.file_exists p then
    try Some (Yojson.Safe.from_file p) with _ -> None
  else None

(* Traverse a nested JSON object by a list of keys, e.g. ["ollama"; "base_url"]. *)
let json_get_path (json : Yojson.Safe.t) (path : string list) : Yojson.Safe.t option =
  let rec loop j = function
    | [] -> Some j
    | k :: rest -> (
        match j with
        | `Assoc kv -> (
            match List.assoc_opt k kv with
            | None -> None
            | Some v -> loop v rest)
        | _ -> None)
  in
  loop json path

(* Read a string setting from a parsed JSON object at the given key path. *)
let setting_string (json : Yojson.Safe.t option) (path : string list) ~(default : string) : string =
  match json with
  | None -> default
  | Some json -> (
      match json_get_path json path with
      | Some (`String s) when String.trim s <> "" -> String.trim s
      | _ -> default)

(* Read an integer setting from a parsed JSON object (accepts int, intlit, or string). *)
let setting_int (json : Yojson.Safe.t option) (path : string list) ~(default : int) : int =
  match json with
  | None -> default
  | Some json -> (
      match json_get_path json path with
      | Some (`Int n) -> n
      | Some (`Intlit s) -> (try int_of_string s with _ -> default)
      | Some (`String s) -> (try int_of_string (String.trim s) with _ -> default)
      | _ -> default)

(* Read a boolean setting from a parsed JSON object (accepts bool, 0/1, or string like "true"/"false"). *)
let setting_bool (json : Yojson.Safe.t option) (path : string list) ~(default : bool) : bool =
  let parse = function
    | "1" | "true" | "yes" | "on" -> Some true
    | "0" | "false" | "no" | "off" -> Some false
    | _ -> None
  in
  match json with
  | None -> default
  | Some json -> (
      match json_get_path json path with
      | Some (`Bool b) -> b
      | Some (`Int 1) -> true
      | Some (`Int 0) -> false
      | Some (`String s) -> (
          match parse (String.lowercase_ascii (String.trim s)) with
          | Some b -> b
          | None -> default)
      | _ -> default)

(* --- Environment variable helpers (env vars override settings.json) --- *)

let env_string (name : string) (fallback : string) : string =
  match Sys.getenv_opt name with
  | Some s when String.trim s <> "" -> String.trim s
  | _ -> fallback

let env_int (name : string) (fallback : int) : int =
  match Sys.getenv_opt name with
  | Some s -> (try int_of_string (String.trim s) with _ -> fallback)
  | None -> fallback

let env_bool (name : string) (fallback : bool) : bool =
  match Sys.getenv_opt name with
  | Some s -> (
      match String.lowercase_ascii (String.trim s) with
      | "1" | "true" | "yes" | "on" -> true
      | "0" | "false" | "no" | "off" -> false
      | _ -> fallback)
  | None -> fallback

(* --- Mutable configuration refs (populated by load_settings) --- *)

let ollama_timeout_seconds    = ref 300.0
let ollama_base_url           = ref "http://127.0.0.1:11434"
let ollama_num_ctx            = ref 8192
let ollama_embed_model        = ref "mxbai-embed-large"
let ollama_llm_model          = ref "llama3"
let ollama_summarize_model    = ref "llama3"
let ollama_triage_model       = ref "llama3"
let ollama_rewrite_model      = ref "llama3"
let rag_vector_dimension      = ref 1024
let rag_chunk_size            = ref 1500
let rag_chunk_overlap         = ref 200
let rag_max_evidence_chars_per_email = ref 8000
let rag_new_content_max_chars = ref 8000
let rag_summarize_max_input_chars = ref 20000
let rag_quoted_context_summarize  = ref false
let rag_quoted_context_max_lines  = ref 100
let rag_quoted_context_max_chars  = ref 8000
let rag_quoted_context_max_input_chars = ref 20000
let rag_attachment_summarize      = ref false
let rag_attachment_max_attachments = ref 4
let rag_attachment_max_chars      = ref 1500
let rag_attachment_max_input_chars = ref 20000
let rag_attachment_max_bytes      = ref 5_000_000
let rag_attachment_use_pdftotext  = ref false
let rag_attachment_use_pandoc     = ref false
let rag_include_unrehydrated_metadata = ref true
let rag_query_rewrite             = ref true
let pg_database                   = ref "thunderrag"
let pg_connection_string          = ref "postgresql://localhost/thunderrag"
let whoami                        = ref ""
let rag_debug_ollama_embed        = ref false
let rag_debug_ollama_chat         = ref false
let rag_debug_retrieval           = ref false

(* Read settings.json + env-var overrides into all config refs.
   Call once at startup after setting [config_dir], and again on /admin/reload. *)
let load_settings () : unit =
  let j = read_settings_json () in
  let ss env path ~default = env_string env (setting_string j path ~default) in
  let si env path ~default = env_int    env (setting_int    j path ~default) in
  let sb env path ~default = env_bool   env (setting_bool   j path ~default) in
  ollama_timeout_seconds :=
    (let default = 300.0 in
     match Sys.getenv_opt "OLLAMA_TIMEOUT_SECONDS" with
     | Some s -> (try float_of_string (String.trim s) with _ -> default)
     | None -> default);
  ollama_base_url       := ss "OLLAMA_BASE_URL"       [ "ollama"; "base_url" ]       ~default:"http://127.0.0.1:11434";
  ollama_num_ctx        := si "OLLAMA_NUM_CTX"        [ "ollama"; "num_ctx" ]        ~default:8192;
  ollama_embed_model    := ss "OLLAMA_EMBED_MODEL"    [ "ollama"; "embed_model" ]    ~default:"mxbai-embed-large";
  ollama_llm_model      := ss "OLLAMA_LLM_MODEL"      [ "ollama"; "llm_model" ]      ~default:"llama3";
  let llm = !ollama_llm_model in
  let model_or_llm env path =
    let v = ss env path ~default:"" in
    if String.trim v = "" then llm else v
  in
  ollama_summarize_model := model_or_llm "OLLAMA_SUMMARIZE_MODEL" [ "ollama"; "summarize_model" ];
  ollama_triage_model    := model_or_llm "OLLAMA_TRIAGE_MODEL"    [ "ollama"; "triage_model" ];
  ollama_rewrite_model   := model_or_llm "OLLAMA_REWRITE_MODEL"   [ "ollama"; "rewrite_model" ];
  rag_chunk_size         := si "RAG_CHUNK_SIZE"         [ "rag"; "chunk_size" ]         ~default:1500;
  rag_chunk_overlap      := si "RAG_CHUNK_OVERLAP"      [ "rag"; "chunk_overlap" ]      ~default:200;
  rag_max_evidence_chars_per_email := si "RAG_MAX_EVIDENCE_CHARS_PER_EMAIL" [ "rag"; "max_evidence_chars_per_email" ] ~default:8000;
  rag_new_content_max_chars := si "RAG_NEW_CONTENT_MAX_CHARS" [ "rag"; "new_content"; "max_chars" ] ~default:8000;
  rag_summarize_max_input_chars := si "RAG_SUMMARIZE_MAX_INPUT_CHARS" [ "rag"; "summarize"; "max_input_chars" ] ~default:20000;
  rag_quoted_context_summarize  := sb "RAG_QUOTED_CONTEXT_SUMMARIZE"  [ "rag"; "quoted_context"; "summarize" ]  ~default:false;
  rag_quoted_context_max_lines  := si "RAG_QUOTED_CONTEXT_MAX_LINES"  [ "rag"; "quoted_context"; "max_lines" ]  ~default:100;
  rag_quoted_context_max_chars  := si "RAG_QUOTED_CONTEXT_MAX_CHARS"  [ "rag"; "quoted_context"; "max_chars" ]  ~default:8000;
  rag_quoted_context_max_input_chars := si "RAG_QUOTED_CONTEXT_MAX_INPUT_CHARS" [ "rag"; "quoted_context"; "max_input_chars" ] ~default:20000;
  rag_attachment_summarize      := sb "RAG_ATTACHMENT_SUMMARIZE"      [ "rag"; "attachments"; "summarize" ]      ~default:false;
  rag_attachment_max_attachments := si "RAG_ATTACHMENT_MAX_ATTACHMENTS" [ "rag"; "attachments"; "max_attachments" ] ~default:4;
  rag_attachment_max_chars      := si "RAG_ATTACHMENT_MAX_CHARS"      [ "rag"; "attachments"; "max_chars" ]      ~default:1500;
  rag_attachment_max_input_chars := si "RAG_ATTACHMENT_MAX_INPUT_CHARS" [ "rag"; "attachments"; "max_input_chars" ] ~default:20000;
  rag_attachment_max_bytes      := si "RAG_ATTACHMENT_MAX_BYTES"      [ "rag"; "attachments"; "max_bytes" ]      ~default:5_000_000;
  rag_attachment_use_pdftotext  := sb "RAG_ATTACHMENT_USE_PDFTOTEXT"  [ "rag"; "attachments"; "use_pdftotext" ]  ~default:false;
  rag_attachment_use_pandoc     := sb "RAG_ATTACHMENT_USE_PANDOC"     [ "rag"; "attachments"; "use_pandoc" ]     ~default:false;
  rag_include_unrehydrated_metadata := sb "RAG_INCLUDE_UNREHYDRATED_METADATA" [ "rag"; "query"; "include_unrehydrated_metadata" ] ~default:true;
  rag_query_rewrite     := sb "RAG_QUERY_REWRITE"     [ "rag"; "query"; "rewrite" ]     ~default:true;
  pg_database           := ss "THUNDERRAG_PG_DATABASE" [ "pg"; "database" ]             ~default:"thunderrag";
  (let explicit = ss "THUNDERRAG_PG_URL" [ "pg"; "connection_string" ] ~default:"" in
   pg_connection_string := if explicit <> "" then explicit
     else Printf.sprintf "postgresql://localhost/%s" !pg_database);
  whoami                 := ss "THUNDERRAG_WHOAMI"      [ "whoami" ]                ~default:"";
  rag_debug_ollama_embed := sb "RAG_DEBUG_OLLAMA_EMBED" [ "debug"; "ollama_embed" ] ~default:false;
  rag_debug_ollama_chat  := sb "RAG_DEBUG_OLLAMA_CHAT"  [ "debug"; "ollama_chat" ]  ~default:false;
  rag_debug_retrieval    := sb "RAG_DEBUG_RETRIEVAL"    [ "debug"; "retrieval" ]    ~default:false;
  Printf.printf "[config] loaded from %s (db=%s)\n%!" (settings_path ()) !pg_database

(* Serialize all current settings to JSON matching the settings.json structure. *)
let current_settings_json () : Yojson.Safe.t =
  `Assoc
    [ ("whoami", `String !whoami)
    ; ("ollama", `Assoc
        [ ("base_url", `String !ollama_base_url)
        ; ("num_ctx", `Int !ollama_num_ctx)
        ; ("embed_model", `String !ollama_embed_model)
        ; ("llm_model", `String !ollama_llm_model)
        ; ("summarize_model", `String !ollama_summarize_model)
        ; ("triage_model", `String !ollama_triage_model)
        ; ("rewrite_model", `String !ollama_rewrite_model)
        ])
    ; ("pg", `Assoc
        [ ("database", `String !pg_database)
        ])
    ; ("rag", `Assoc
        [ ("chunk_size", `Int !rag_chunk_size)
        ; ("chunk_overlap", `Int !rag_chunk_overlap)
        ; ("max_evidence_chars_per_email", `Int !rag_max_evidence_chars_per_email)
        ; ("new_content", `Assoc [ ("max_chars", `Int !rag_new_content_max_chars) ])
        ; ("summarize", `Assoc [ ("max_input_chars", `Int !rag_summarize_max_input_chars) ])
        ; ("quoted_context", `Assoc
            [ ("summarize", `Bool !rag_quoted_context_summarize)
            ; ("max_lines", `Int !rag_quoted_context_max_lines)
            ; ("max_chars", `Int !rag_quoted_context_max_chars)
            ; ("max_input_chars", `Int !rag_quoted_context_max_input_chars)
            ])
        ; ("attachments", `Assoc
            [ ("summarize", `Bool !rag_attachment_summarize)
            ; ("max_attachments", `Int !rag_attachment_max_attachments)
            ; ("max_chars", `Int !rag_attachment_max_chars)
            ; ("max_input_chars", `Int !rag_attachment_max_input_chars)
            ; ("max_bytes", `Int !rag_attachment_max_bytes)
            ; ("use_pdftotext", `Bool !rag_attachment_use_pdftotext)
            ; ("use_pandoc", `Bool !rag_attachment_use_pandoc)
            ])
        ; ("query", `Assoc
            [ ("include_unrehydrated_metadata", `Bool !rag_include_unrehydrated_metadata)
            ; ("rewrite", `Bool !rag_query_rewrite)
            ])
        ])
    ; ("debug", `Assoc
        [ ("ollama_embed", `Bool !rag_debug_ollama_embed)
        ; ("ollama_chat", `Bool !rag_debug_ollama_chat)
        ; ("retrieval", `Bool !rag_debug_retrieval)
        ])
    ]

(* Write a JSON value to settings.json, preserving pretty-printing. *)
let write_settings_json (json : Yojson.Safe.t) : (unit, string) result =
  let path = settings_path () in
  try
    ensure_dir (thunderrag_config_dir ());
    let s = Yojson.Safe.pretty_to_string ~std:true json in
    let oc = open_out path in
    output_string oc s;
    output_char oc '\n';
    close_out oc;
    Ok ()
  with e -> Error (Printexc.to_string e)

(* --- Prompts (hot-reloadable) --- *)

(* Path to prompts.json: THUNDERRAG_PROMPTS env var, or ~/.thunderRAG/prompts.json. *)
let prompts_path () : string =
  match Sys.getenv_opt "THUNDERRAG_PROMPTS" with
  | Some p when String.trim p <> "" ->
      let p = String.trim p in
      if String.length p > 0 && p.[0] = '~' then Filename.concat (thunderrag_home_dir ()) (String.sub p 1 (String.length p - 1))
      else p
  | _ -> Filename.concat (thunderrag_config_dir ()) "prompts.json"

(* Path to the default prompts.json shipped with the codebase.
   Set via THUNDERRAG_DEFAULT_PROMPTS or auto-detected relative to the executable. *)
let default_prompts_path () : string =
  match Sys.getenv_opt "THUNDERRAG_DEFAULT_PROMPTS" with
  | Some p when String.trim p <> "" -> String.trim p
  | _ ->
      (* Try: directory of the executable / ../prompts.json (works for dune exec) *)
      let exe_dir = Filename.dirname Sys.executable_name in
      let candidate = Filename.concat (Filename.concat exe_dir "..") "prompts.json" in
      if Sys.file_exists candidate then candidate
      else
        (* Fallback: current working directory *)
        let cwd_candidate = "prompts.json" in
        if Sys.file_exists cwd_candidate then cwd_candidate
        else candidate  (* will just fail gracefully later *)

(* Path to the default settings.json shipped with the codebase.
   Set via THUNDERRAG_DEFAULT_SETTINGS or auto-detected relative to the executable. *)
let default_settings_path () : string =
  match Sys.getenv_opt "THUNDERRAG_DEFAULT_SETTINGS" with
  | Some p when String.trim p <> "" -> String.trim p
  | _ ->
      let exe_dir = Filename.dirname Sys.executable_name in
      let candidate = Filename.concat (Filename.concat exe_dir "..") "settings.json" in
      if Sys.file_exists candidate then candidate
      else
        let cwd_candidate = "settings.json" in
        if Sys.file_exists cwd_candidate then cwd_candidate
        else candidate

(* Copy a default file to the config directory if the target does not exist. *)
let install_default_if_missing ~(src : string) ~(dst : string) : unit =
  if (not (Sys.file_exists dst)) && Sys.file_exists src then (
    ensure_dir (thunderrag_config_dir ());
    try
      let ic = open_in_bin src in
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      close_in ic;
      let oc = open_out_bin dst in
      output_bytes oc buf;
      close_out oc;
      Printf.printf "[config] installed default %s -> %s\n%!" (Filename.basename src) dst
    with e ->
      Printf.eprintf "[config] failed to install %s -> %s: %s\n%!"
        src dst (Printexc.to_string e))

(* Read and parse prompts.json fresh from disk.  Called on every use so edits
   take effect without restarting the server. Returns None on missing/bad file. *)
let load_prompts_json () : Yojson.Safe.t option =
  let p = prompts_path () in
  if Sys.file_exists p then
    try Some (Yojson.Safe.from_file p) with e ->
      Printf.eprintf "[config] failed to parse %s: %s\n%!" p (Printexc.to_string e);
      None
  else (
    Printf.eprintf "[config] prompts file not found: %s\n%!" p;
    None)

(* Write a JSON value to prompts.json, preserving pretty-printing. *)
let write_prompts_json (json : Yojson.Safe.t) : (unit, string) result =
  let path = prompts_path () in
  try
    ensure_dir (thunderrag_config_dir ());
    let s = Yojson.Safe.pretty_to_string ~std:true json in
    let oc = open_out path in
    output_string oc s;
    output_char oc '\n';
    close_out oc;
    Ok ()
  with e -> Error (Printexc.to_string e)

(* Look up a prompt string by key from prompts.json.  Returns the raw string
   (with {{…}} meta-variables still in place) or the provided default.
   Accepts both a plain string and an array of strings (joined with "\n"). *)
let get_prompt_raw (key : string) ~(default : string) : string =
  match load_prompts_json () with
  | Some json -> (
      match json with
      | `Assoc kv -> (
          match List.assoc_opt key kv with
          | Some (`String s) -> s
          | Some (`List items) ->
              let lines = List.filter_map (function `String s -> Some s | _ -> None) items in
              String.concat "\n" lines
          | _ -> default)
      | _ -> default)
  | None -> default

(* Substitute meta-variables in a prompt string.
   [vars] is a list of (pattern, replacement) pairs, e.g.
   [("{{user_identity}}", "The user is: ..."); ("{{datetime_local}}", "2026-...")].
   Also expands {{indexed_email_format}} and {{email_body_sections}} by
   reading them from prompts.json. *)
let substitute_prompt_vars (prompt : string) (vars : (string * string) list) : string =
  let indexed_format = get_prompt_raw "indexed_email_format" ~default:"" in
  let body_sections = get_prompt_raw "email_body_sections" ~default:"" in
  let all_vars =
    ("{{indexed_email_format}}", indexed_format)
    :: ("{{email_body_sections}}", body_sections)
    :: vars
  in
  List.fold_left
    (fun acc (pat, rep) ->
      let rec replace s =
        match String.split_on_char pat.[0] s with
        | _ when not (String.length pat > 0) -> s
        | _ ->
            (* Simple substring replacement *)
            let pat_len = String.length pat in
            let buf = Buffer.create (String.length s) in
            let i = ref 0 in
            while !i <= String.length s - pat_len do
              if String.sub s !i pat_len = pat then (
                Buffer.add_string buf rep;
                i := !i + pat_len)
              else (
                Buffer.add_char buf s.[!i];
                incr i)
            done;
            (* Append remaining characters *)
            while !i < String.length s do
              Buffer.add_char buf s.[!i];
              incr i
            done;
            Buffer.contents buf
      in
      replace acc)
    prompt all_vars

(* Convenience: load a prompt by key, substitute meta-variables, return result.
   Falls back to [default] if the key is missing from prompts.json. *)
let get_prompt (key : string) ~(default : string) ~(vars : (string * string) list) : string =
  let raw = get_prompt_raw key ~default in
  substitute_prompt_vars raw vars

(* --- Timestamp helpers --- *)

(* Current time as ISO 8601 UTC string (e.g. "2025-06-15T08:30:00Z"). *)
let now_utc_iso8601 () : string =
  let tm = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(* Current local time as human-readable string for log output. *)
let now_local_string () : string =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
