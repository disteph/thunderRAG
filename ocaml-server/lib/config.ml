(*
  Configuration and settings

  Loads settings from environment variables and an optional JSON settings file.
  Environment variables take precedence over settings.json values.
*)

(* User's home directory, used as the base for ~/.thunderRAG config dir. *)
let thunderrag_home_dir () : string =
  match Sys.getenv_opt "HOME" with
  | Some h when String.trim h <> "" -> h
  | _ -> "."

(* Default configuration directory: ~/.thunderRAG *)
let thunderrag_config_dir () : string = Filename.concat (thunderrag_home_dir ()) ".thunderRAG"

(* Create a directory (mode 0700) if it does not already exist; silently ignores errors. *)
let ensure_dir (path : string) : unit =
  try
    if Sys.file_exists path then () else Unix.mkdir path 0o700
  with _ -> ()

(* Resolve the path to settings.json: THUNDERRAG_SETTINGS env var, or ~/.thunderRAG/settings.json.
   Supports ~ expansion. *)
let settings_path () : string =
  match Sys.getenv_opt "THUNDERRAG_SETTINGS" with
  | Some p when String.trim p <> "" ->
      let p = String.trim p in
      if String.length p > 0 && p.[0] = '~' then Filename.concat (thunderrag_home_dir ()) (String.sub p 1 (String.length p - 1))
      else p
  | _ -> Filename.concat (thunderrag_config_dir ()) "settings.json"

(* Eagerly load the settings JSON file at startup (None if missing or unparseable). *)
let settings_json : Yojson.Safe.t option =
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

(* Read a string setting from settings.json at the given key path. *)
let setting_string (path : string list) ~(default : string) : string =
  match settings_json with
  | None -> default
  | Some json -> (
      match json_get_path json path with
      | Some (`String s) when String.trim s <> "" -> String.trim s
      | _ -> default)

(* Read an integer setting from settings.json (accepts int, intlit, or string). *)
let setting_int (path : string list) ~(default : int) : int =
  match settings_json with
  | None -> default
  | Some json -> (
      match json_get_path json path with
      | Some (`Int n) -> n
      | Some (`Intlit s) -> (try int_of_string s with _ -> default)
      | Some (`String s) -> (try int_of_string (String.trim s) with _ -> default)
      | _ -> default)

(* Read a boolean setting from settings.json (accepts bool, 0/1, or string like "true"/"false"). *)
let setting_bool (path : string list) ~(default : bool) : bool =
  let parse = function
    | "1" | "true" | "yes" | "on" -> Some true
    | "0" | "false" | "no" | "off" -> Some false
    | _ -> None
  in
  match settings_json with
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

(* --- Resolved configuration values used throughout the server --- *)

(* Maximum seconds to wait for any single Ollama HTTP request. *)
let ollama_timeout_seconds : float =
  let default = 300.0 in
  match Sys.getenv_opt "OLLAMA_TIMEOUT_SECONDS" with
  | Some s -> (try float_of_string (String.trim s) with _ -> default)
  | None -> default

(* Ollama server URL for embedding and chat completions. *)
let ollama_base_url =
  env_string "OLLAMA_BASE_URL" (setting_string [ "ollama"; "base_url" ] ~default:"http://127.0.0.1:11434")

(* Model name used for embedding (e.g. nomic-embed-text). *)
let ollama_embed_model =
  env_string "OLLAMA_EMBED_MODEL" (setting_string [ "ollama"; "embed_model" ] ~default:"nomic-embed-text")

(* Model name used for LLM chat completions (e.g. llama3). *)
let ollama_llm_model =
  env_string "OLLAMA_LLM_MODEL" (setting_string [ "ollama"; "llm_model" ] ~default:"llama3")

(* Model name used for summarization at ingestion time (quote compression, attachment summaries).
   Falls back to ollama_llm_model if not set, so existing configs keep working. *)
let ollama_summarize_model =
  let v = env_string "OLLAMA_SUMMARIZE_MODEL" (setting_string [ "ollama"; "summarize_model" ] ~default:"") in
  if String.trim v = "" then ollama_llm_model else v

(* Model name used for triage at ingestion time (action_score, importance_score, reply_by).
   Falls back to ollama_llm_model if not set. *)
let ollama_triage_model =
  let v = env_string "OLLAMA_TRIAGE_MODEL" (setting_string [ "ollama"; "triage_model" ] ~default:"") in
  if String.trim v = "" then ollama_llm_model else v

(* Chunk size (characters) for splitting text before embedding. *)
let rag_chunk_size : int =
  env_int "RAG_CHUNK_SIZE" (setting_int [ "rag"; "chunk_size" ] ~default:1500)

(* Overlap (characters) between consecutive chunks. *)
let rag_chunk_overlap : int =
  env_int "RAG_CHUNK_OVERLAP" (setting_int [ "rag"; "chunk_overlap" ] ~default:200)

(* Maximum characters per email to include in evidence (truncated beyond this). *)
let rag_max_evidence_chars_per_email : int =
  env_int "RAG_MAX_EVIDENCE_CHARS_PER_EMAIL" (setting_int [ "rag"; "max_evidence_chars_per_email" ] ~default:8000)

(* Maximum characters for the NEW CONTENT section of an email body.
   If the new content exceeds this, it is recursively summarized. *)
let rag_new_content_max_chars : int =
  env_int "RAG_NEW_CONTENT_MAX_CHARS" (setting_int [ "rag"; "new_content"; "max_chars" ] ~default:8000)

(* Maximum characters per LLM summarization call input.  Shared default for
   summarize_to_fit when no context-specific override is provided. *)
let rag_summarize_max_input_chars : int =
  env_int "RAG_SUMMARIZE_MAX_INPUT_CHARS" (setting_int [ "rag"; "summarize"; "max_input_chars" ] ~default:20000)

(* Whether to LLM-summarize quoted thread context during ingestion. *)
let rag_quoted_context_summarize : bool =
  env_bool "RAG_QUOTED_CONTEXT_SUMMARIZE" (setting_bool [ "rag"; "quoted_context"; "summarize" ] ~default:false)

let rag_quoted_context_max_lines : int =
  env_int "RAG_QUOTED_CONTEXT_MAX_LINES" (setting_int [ "rag"; "quoted_context"; "max_lines" ] ~default:100)

let rag_quoted_context_max_chars : int =
  env_int "RAG_QUOTED_CONTEXT_MAX_CHARS" (setting_int [ "rag"; "quoted_context"; "max_chars" ] ~default:8000)

let rag_quoted_context_max_input_chars : int =
  env_int "RAG_QUOTED_CONTEXT_MAX_INPUT_CHARS" (setting_int [ "rag"; "quoted_context"; "max_input_chars" ] ~default:20000)

let rag_attachment_summarize : bool =
  env_bool "RAG_ATTACHMENT_SUMMARIZE" (setting_bool [ "rag"; "attachments"; "summarize" ] ~default:false)

let rag_attachment_max_attachments : int =
  env_int "RAG_ATTACHMENT_MAX_ATTACHMENTS" (setting_int [ "rag"; "attachments"; "max_attachments" ] ~default:4)

let rag_attachment_max_chars : int =
  env_int "RAG_ATTACHMENT_MAX_CHARS" (setting_int [ "rag"; "attachments"; "max_chars" ] ~default:1500)

let rag_attachment_max_input_chars : int =
  env_int "RAG_ATTACHMENT_MAX_INPUT_CHARS" (setting_int [ "rag"; "attachments"; "max_input_chars" ] ~default:20000)

let rag_attachment_max_bytes : int =
  env_int "RAG_ATTACHMENT_MAX_BYTES" (setting_int [ "rag"; "attachments"; "max_bytes" ] ~default:5_000_000)

let rag_attachment_use_pdftotext : bool =
  env_bool "RAG_ATTACHMENT_USE_PDFTOTEXT" (setting_bool [ "rag"; "attachments"; "use_pdftotext" ] ~default:false)

let rag_attachment_use_pandoc : bool =
  env_bool "RAG_ATTACHMENT_USE_PANDOC" (setting_bool [ "rag"; "attachments"; "use_pandoc" ] ~default:false)

(* Whether to include metadata-only entries for non-rehydrated emails in the
   final LLM prompt.  When true, the LLM sees a one-line header for every
   retrieved email even if its full body was not loaded.  When false, only
   rehydrated emails appear in the prompt. *)
let rag_include_unrehydrated_metadata : bool =
  env_bool "RAG_INCLUDE_UNREHYDRATED_METADATA"
    (setting_bool [ "rag"; "query"; "include_unrehydrated_metadata" ] ~default:true)

(* Whether to rewrite the user's query before embedding for retrieval.
   When enabled, generates a contextual rewrite + hypothetical email passage
   (multi-query) and merges results for better recall. *)
let rag_query_rewrite : bool =
  env_bool "RAG_QUERY_REWRITE" (setting_bool [ "rag"; "query"; "rewrite" ] ~default:true)

(* PostgreSQL connection string for pgvector store. *)
let pg_connection_string =
  env_string "THUNDERRAG_PG_URL"
    (setting_string [ "pg"; "connection_string" ] ~default:"postgresql://localhost/thunderrag")

(* --- Debug flags: enable verbose logging for specific subsystems --- *)

let rag_debug_ollama_embed : bool =
  env_bool "RAG_DEBUG_OLLAMA_EMBED" (setting_bool [ "debug"; "ollama_embed" ] ~default:false)

let rag_debug_ollama_chat : bool =
  env_bool "RAG_DEBUG_OLLAMA_CHAT" (setting_bool [ "debug"; "ollama_chat" ] ~default:false)

let rag_debug_retrieval : bool =
  env_bool "RAG_DEBUG_RETRIEVAL" (setting_bool [ "debug"; "retrieval" ] ~default:false)

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
   Also expands {{indexed_email_format}} by reading it from prompts.json. *)
let substitute_prompt_vars (prompt : string) (vars : (string * string) list) : string =
  let indexed_format = get_prompt_raw "indexed_email_format" ~default:"" in
  let all_vars = ("{{indexed_email_format}}", indexed_format) :: vars in
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
