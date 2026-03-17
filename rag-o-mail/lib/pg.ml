(*
  PostgreSQL + pgvector database module

  Manages the connection pool, schema, and all CRUD/query operations
  for the email vector store.  Replaces the former FAISS index
  and the OCaml-side flat-file ingestion ledger.

  Connection pool is initialised once at server startup via [init].
  All public functions return [(ok, error_string) result].
*)

open Config

(* ---------- helpers ---------- *)

let normalize_doc_id (id : string) : string =
  let id = String.trim id in
  if String.length id > 1 && id.[0] = '<' && id.[String.length id - 1] = '>'
  then String.sub id 1 (String.length id - 2)
  else id

let float_list_to_pgvector (v : float list) : string =
  let buf = Buffer.create (List.length v * 12) in
  Buffer.add_char buf '[';
  List.iteri (fun i f ->
    if i > 0 then Buffer.add_char buf ',';
    Buffer.add_string buf (Printf.sprintf "%.10g" f))
    v;
  Buffer.add_char buf ']';
  Buffer.contents buf

let pg_text_array (ids : string list) : string =
  let escape s =
    let buf = Buffer.create (String.length s + 2) in
    Buffer.add_char buf '"';
    String.iter (fun c ->
      if c = '"' || c = '\\' then Buffer.add_char buf '\\';
      Buffer.add_char buf c) s;
    Buffer.add_char buf '"';
    Buffer.contents buf
  in
  "{" ^ String.concat "," (List.map escape ids) ^ "}"

(* ---------- pool ---------- *)

type connection = (module Caqti_eio.CONNECTION)
type pool = (connection, Caqti_error.t) Caqti_eio.Pool.t

let pool_ref : pool option ref = ref None

let get_pool () =
  match !pool_ref with
  | Some p -> p
  | None -> failwith "[pg] pool not initialised — call Pg.init first"

let use (f : connection -> (unit, Caqti_error.t) result)
    : (unit, string) result =
  match Caqti_eio.Pool.use f (get_pool ()) with
  | Ok () -> Ok ()
  | Error e -> Error (Caqti_error.show e)

let use_ret (f : connection -> ('a, Caqti_error.t) result)
    : ('a, string) result =
  match Caqti_eio.Pool.use f (get_pool ()) with
  | Ok x -> Ok x
  | Error e -> Error (Caqti_error.show e)

(* ---------- schema ---------- *)

let schema_statements () =
  [ {|CREATE TABLE IF NOT EXISTS emails (
       doc_id        TEXT PRIMARY KEY,
       embed_model      TEXT NOT NULL DEFAULT '',
       triage_model     TEXT NOT NULL DEFAULT '',
       summarize_model  TEXT NOT NULL DEFAULT '',
       sender        TEXT NOT NULL DEFAULT '',
       recipient     TEXT NOT NULL DEFAULT '',
       cc            TEXT NOT NULL DEFAULT '',
       bcc           TEXT NOT NULL DEFAULT '',
       subject       TEXT NOT NULL DEFAULT '',
       email_date    TIMESTAMPTZ,
       attachments   TEXT[] NOT NULL DEFAULT '{}',
       action_score  INT,
       importance_score INT,
       reply_by      TIMESTAMPTZ,
       processed     BOOLEAN NOT NULL DEFAULT FALSE,
       processed_at  TIMESTAMPTZ,
       ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       whoami        TEXT
     )|}
  ; Printf.sprintf {|CREATE TABLE IF NOT EXISTS email_chunks (
       id          SERIAL PRIMARY KEY,
       doc_id      TEXT NOT NULL REFERENCES emails(doc_id) ON DELETE CASCADE,
       chunk_index INT NOT NULL,
       section     TEXT NOT NULL DEFAULT '',
       embedding   vector(%d) NOT NULL
     )|} !rag_vector_dimension
  ; {|CREATE INDEX IF NOT EXISTS idx_chunks_doc_id ON email_chunks(doc_id)|}
  (* Migration: drop redundant message_id column (identical to doc_id) *)
  ; {|ALTER TABLE emails DROP COLUMN IF EXISTS message_id|}
  ; {|ALTER TABLE emails ADD COLUMN IF NOT EXISTS summarize_model TEXT NOT NULL DEFAULT ''|}
  (* Migration: drop chunk_text column — email bodies are not stored server-side *)
  ; {|ALTER TABLE email_chunks DROP COLUMN IF EXISTS chunk_text|}
  ; {|ALTER TABLE emails ADD COLUMN IF NOT EXISTS whoami TEXT|}
  (* --- task manager tables --- *)
  ; {|CREATE TABLE IF NOT EXISTS tasks (
       task_id          TEXT PRIMARY KEY,
       title            TEXT NOT NULL DEFAULT '',
       description      TEXT NOT NULL DEFAULT '',
       status           TEXT NOT NULL DEFAULT 'open',
       importance_score INT,
       deadline         TIMESTAMPTZ,
       created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       conversation     JSONB NOT NULL DEFAULT '[]',
       history_summary  TEXT NOT NULL DEFAULT '',
       drafts           JSONB NOT NULL DEFAULT '[]',
       notes            TEXT NOT NULL DEFAULT ''
     )|}
  ; Printf.sprintf
      {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS embedding vector(%d)|}
      !rag_vector_dimension
  ; {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS context_emails JSONB NOT NULL DEFAULT '[]'|}
  ; {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS context_prefetched BOOLEAN NOT NULL DEFAULT FALSE|}
  ; {|CREATE TABLE IF NOT EXISTS task_emails (
       task_id  TEXT NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
       doc_id   TEXT NOT NULL,
       role     TEXT NOT NULL DEFAULT 'trigger',
       added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       PRIMARY KEY (task_id, doc_id)
     )|}
  ; {|CREATE INDEX IF NOT EXISTS idx_task_emails_doc_id ON task_emails(doc_id)|}
  ; {|ALTER TABLE task_emails ADD COLUMN IF NOT EXISTS compressed_body TEXT NOT NULL DEFAULT ''|}
  ; {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS context_ready BOOLEAN NOT NULL DEFAULT FALSE|}
  ; {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS sort_order INT|}
  ; {|CREATE TABLE IF NOT EXISTS propose_tasks_log (
       doc_id     TEXT PRIMARY KEY,
       debug      JSONB NOT NULL,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )|}
  ; {|ALTER TABLE emails DROP COLUMN IF EXISTS propose_tasks_debug|}
  (* --- memory system tables --- *)
  ; {|CREATE TABLE IF NOT EXISTS memories (
       memory_id      TEXT PRIMARY KEY,
       text           TEXT NOT NULL,
       rule           JSONB,
       source_task_id TEXT,
       enabled        BOOLEAN NOT NULL DEFAULT TRUE,
       created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )|}
  ; {|CREATE TABLE IF NOT EXISTS memory_emails (
       memory_id TEXT NOT NULL REFERENCES memories(memory_id) ON DELETE CASCADE,
       doc_id    TEXT NOT NULL,
       PRIMARY KEY (memory_id, doc_id)
     )|}
  ; {|CREATE INDEX IF NOT EXISTS idx_memory_emails_doc_id ON memory_emails(doc_id)|}
  ; Printf.sprintf {|CREATE TABLE IF NOT EXISTS memory_templates (
       id            SERIAL PRIMARY KEY,
       memory_id     TEXT NOT NULL REFERENCES memories(memory_id) ON DELETE CASCADE,
       template_text TEXT NOT NULL,
       embedding     vector(%d) NOT NULL
     )|} !rag_vector_dimension
  ; {|CREATE INDEX IF NOT EXISTS idx_memory_templates_memory_id ON memory_templates(memory_id)|}
  ; {|ALTER TABLE tasks ADD COLUMN IF NOT EXISTS prior_resolutions TEXT NOT NULL DEFAULT ''|}
  ; {|ALTER TABLE emails ADD COLUMN IF NOT EXISTS in_reply_to TEXT NOT NULL DEFAULT ''|}
  (* --- triage queue: emails waiting for daemon to run propose_tasks --- *)
  ; {|CREATE TABLE IF NOT EXISTS triage_queue (
       doc_id          TEXT PRIMARY KEY REFERENCES emails(doc_id) ON DELETE CASCADE,
       body_text       TEXT NOT NULL,
       compressed_body TEXT NOT NULL,
       status          TEXT NOT NULL DEFAULT 'pending',
       error           TEXT NOT NULL DEFAULT '',
       created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       started_at      TIMESTAMPTZ,
       finished_at     TIMESTAMPTZ
     )|}
  ; {|ALTER TABLE triage_queue ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending'|}
  ; {|ALTER TABLE triage_queue ADD COLUMN IF NOT EXISTS error TEXT NOT NULL DEFAULT ''|}
  ; {|ALTER TABLE triage_queue ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ|}
  ; {|ALTER TABLE triage_queue ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ|}
  (* --- FYI emails: triaged emails that did not produce tasks --- *)
  ; {|CREATE TABLE IF NOT EXISTS fyi_emails (
       doc_id     TEXT PRIMARY KEY,
       summary    TEXT NOT NULL,
       compressed_body TEXT NOT NULL DEFAULT '',
       email_date TIMESTAMPTZ,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )|}
  ; {|ALTER TABLE fyi_emails ADD COLUMN IF NOT EXISTS compressed_body TEXT NOT NULL DEFAULT ''|}
  (* --- ingest queue: raw emails waiting for async ingestion --- *)
  ; {|CREATE TABLE IF NOT EXISTS ingest_queue (
       doc_id      TEXT PRIMARY KEY,
       raw         TEXT NOT NULL,
       status      TEXT NOT NULL DEFAULT 'pending',
       error       TEXT NOT NULL DEFAULT '',
       created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       started_at  TIMESTAMPTZ,
       finished_at TIMESTAMPTZ
     )|}
  ; {|CREATE TABLE IF NOT EXISTS pending_processed (
       doc_id      TEXT PRIMARY KEY,
       created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )|}
  ]

let init_schema_with (module C : Caqti_eio.CONNECTION) =
  let rec run = function
    | [] -> Ok ()
    | sql :: rest ->
        let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
        (match C.exec req () with
         | Ok () -> run rest
         | Error _ as e -> e)
  in
  run (schema_statements ())

let init_schema () : (unit, string) result =
  use (fun (module C : Caqti_eio.CONNECTION) -> init_schema_with (module C))

(* ---------- init ---------- *)

let init ~(sw : Eio.Switch.t) ~(stdenv : Caqti_eio.stdenv) : (unit, string) result =
  let uri = Uri.of_string !pg_connection_string in
  match Caqti_eio_unix.connect_pool ~sw ~stdenv uri with
  | Error e -> Error (Caqti_error.show e)
  | Ok p ->
      pool_ref := Some p;
      Printf.printf "[pg] connected to %s\n%!" !pg_connection_string;
      init_schema ()

(* ---------- email CRUD ---------- *)

let upsert_email
    ~(doc_id : string) ~(embed_model : string) ~(triage_model : string)
    ~(summarize_model : string)
    ~(sender : string) ~(recipient : string) ~(cc : string) ~(bcc : string)
    ~(subject : string) ~(email_date : string)
    ~(attachments_json : string)
    ~(action_score : int option) ~(importance_score : int option)
    ~(reply_by : string) ~(ingested_at : string)
    ~(whoami : string)
    ?(in_reply_to : string = "")
    ?(on_done : (float -> unit) option)
    () : (unit, string) result =
  let t0 = Unix.gettimeofday () in
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO emails
      (doc_id, embed_model, triage_model, summarize_model, sender, recipient, cc, bcc,
       subject, email_date, attachments, action_score, importance_score,
       reply_by, processed, ingested_at, whoami, in_reply_to)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NULLIF($10,'')::timestamptz,$11::text[],$12,$13,NULLIF($14,'')::timestamptz,FALSE,NULLIF($15,'')::timestamptz,$16,$17)
    ON CONFLICT (doc_id) DO UPDATE SET
      embed_model = EXCLUDED.embed_model,
      triage_model = EXCLUDED.triage_model,
      summarize_model = EXCLUDED.summarize_model,
      sender = EXCLUDED.sender,
      recipient = EXCLUDED.recipient,
      cc = EXCLUDED.cc,
      bcc = EXCLUDED.bcc,
      subject = EXCLUDED.subject,
      email_date = EXCLUDED.email_date,
      attachments = EXCLUDED.attachments::text[],
      action_score = EXCLUDED.action_score,
      importance_score = EXCLUDED.importance_score,
      reply_by = EXCLUDED.reply_by,
      ingested_at = EXCLUDED.ingested_at,
      whoami = EXCLUDED.whoami,
      in_reply_to = EXCLUDED.in_reply_to
  |} in
  let open Caqti_type in
  (* Parameter order must match SQL: $1-$8 strings, $9 subject, $10 email_date,
     $11 attachments, $12 action_score, $13 importance_score, $14 reply_by,
     $15 ingested_at, $16 whoami, $17 in_reply_to *)
  let pt = t2
    (t2 (t4 string string string string) (t4 string string string string))
    (t2
      (t2 string string)
      (t2 (t2 string (option int)) (t2 (t4 (option int) string string string) string)))
  in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      C.exec req
        (((doc_id, embed_model, triage_model, summarize_model),
          (sender, recipient, cc, bcc)),
         ((subject, email_date),
          ((attachments_json, action_score), ((importance_score, reply_by, ingested_at, whoami), in_reply_to)))))
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.upsert_email: %.3fs\n%!" dt;
  (match on_done with Some f -> f dt | None -> ());
  result

let insert_chunks ~(doc_id : string) ?(on_done : (float -> unit) option)
    (chunks : (int * string * float list) list) : (unit, string) result =
  let t0 = Unix.gettimeofday () in
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO email_chunks (doc_id, chunk_index, section, embedding)
    VALUES ($1, $2, $3, $4::vector)
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 (t3 string int string) string ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      let rec run = function
        | [] -> Ok ()
        | (idx, section, emb) :: rest ->
            let vec_str = float_list_to_pgvector emb in
            (match C.exec req ((doc_id, idx, section), vec_str) with
             | Ok () -> run rest
             | Error _ as e -> e)
      in
      run chunks)
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.insert_chunks (%d): %.3fs\n%!" (List.length chunks) dt;
  (match on_done with Some f -> f dt | None -> ());
  result

let purge_empty_metadata () : (int, string) result =
  let count_sql = "SELECT COUNT(*)::int FROM emails WHERE sender = '' AND recipient = '' AND subject = ''" in
  let count_req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true count_sql in
  (* Clean up task_emails referencing these emails before deleting them *)
  let te_sql = {|DELETE FROM task_emails WHERE doc_id IN
    (SELECT doc_id FROM emails WHERE sender = '' AND recipient = '' AND subject = '')|} in
  let te_req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true te_sql in
  let del_sql = "DELETE FROM emails WHERE sender = '' AND recipient = '' AND subject = ''" in
  let del_req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true del_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find count_req () with
    | Error _ as e -> e
    | Ok n ->
        match C.exec te_req () with
        | Error _ as e -> e
        | Ok () ->
        match C.exec del_req () with
        | Error _ as e -> e
        | Ok () -> Ok n)

(* Remove task_emails rows whose doc_id no longer exists in the emails table.
   Returns the number of orphaned rows removed. *)
let purge_orphaned_task_emails () : (int, string) result =
  let count_sql = {|SELECT COUNT(*)::int FROM task_emails te
    WHERE NOT EXISTS (SELECT 1 FROM emails e WHERE e.doc_id = te.doc_id)|} in
  let count_req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true count_sql in
  let del_sql = {|DELETE FROM task_emails WHERE doc_id IN
    (SELECT te.doc_id FROM task_emails te
     WHERE NOT EXISTS (SELECT 1 FROM emails e WHERE e.doc_id = te.doc_id))|} in
  let del_req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true del_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find count_req () with
    | Error _ as e -> e
    | Ok n ->
        if n = 0 then Ok 0
        else
        match C.exec del_req () with
        | Error _ as e -> e
        | Ok () -> Ok n)

(* purge_base64_chunks: no-op — chunk_text column has been dropped *)
let purge_base64_chunks () : (int, string) result = Ok 0

let reset_all () : (unit, string) result =
  use (fun (module C : Caqti_eio.CONNECTION) ->
    let exec sql =
      let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
      C.exec req ()
    in
    match exec "DROP TABLE IF EXISTS fyi_emails" with
    | Error _ as e -> e
    | Ok () ->
      match exec "DROP TABLE IF EXISTS task_emails" with
      | Error _ as e -> e
      | Ok () ->
        match exec "DROP TABLE IF EXISTS tasks" with
        | Error _ as e -> e
        | Ok () ->
          match exec "DROP TABLE IF EXISTS email_chunks" with
          | Error _ as e -> e
          | Ok () ->
            match exec "DROP TABLE IF EXISTS emails" with
            | Error _ as e -> e
            | Ok () -> init_schema_with (module C : Caqti_eio.CONNECTION))

(* ---------- status queries ---------- *)

let batch_ingested_status (ids : string list)
    : ((string list * string list * string list * (string * string) list), string) result =
  if ids = [] then Ok ([], [], [], [])
  else
    let normed = List.map normalize_doc_id ids in
    let arr = pg_text_array normed in
    let sql = {|SELECT e.doc_id, e.processed,
                       COALESCE(TO_CHAR(e.reply_by, 'YYYY-MM-DD'), ''),
                       (SELECT COUNT(*) FROM email_chunks ec WHERE ec.doc_id = e.doc_id)
                FROM emails e WHERE e.doc_id = ANY($1::text[])|} in
    let open Caqti_type in
    let req = Caqti_request.Infix.(string ->* t4 string bool string int) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.collect_list req arr with
      | Error _ as e -> e
      | Ok rows ->
          let ingested = List.map (fun (id, _, _, _) -> id) rows in
          let processed = rows |> List.filter_map (fun (id, p, _, _) -> if p then Some id else None) in
          let partial = rows |> List.filter_map (fun (id, _, _, n_chunks) -> if n_chunks = 0 then Some id else None) in
          let reply_by = rows |> List.filter_map (fun (id, _, rb, _) ->
            if String.trim rb <> "" then Some (id, rb) else None) in
          Ok (ingested, processed, partial, reply_by))

let batch_trigger_active (ids : string list) : (string list, string) result =
  if ids = [] then Ok []
  else
    let normed = List.map normalize_doc_id ids in
    let arr = pg_text_array normed in
    let sql = {|SELECT DISTINCT te.doc_id
                FROM task_emails te
                JOIN tasks t ON t.task_id = te.task_id
                WHERE te.doc_id = ANY($1::text[])
                  AND te.role = 'trigger'
                  AND t.status IN ('open', 'in_progress')|} in
    let open Caqti_type in
    let req = Caqti_request.Infix.(string ->* string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.collect_list req arr with
      | Error _ as e -> e
      | Ok rows -> Ok rows)

let ingested_models (doc_id : string) : ((string * string * string) option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "SELECT embed_model, triage_model, summarize_model FROM emails WHERE doc_id = $1 LIMIT 1" in
  let open Caqti_type in
  let req = Caqti_request.Infix.(string ->? t3 string string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Ok (Some (em, tm, sm)) -> Ok (Some (em, tm, sm))
    | Ok None -> Ok None
    | Error _ as e -> e)

let get_email_detail (doc_id : string) : (Yojson.Safe.t option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT doc_id, embed_model, triage_model, summarize_model, sender, recipient, cc, bcc,
           subject,
           COALESCE(email_date::text, ''),
           COALESCE(array_to_json(attachments)::text, '[]'),
           action_score, importance_score,
           COALESCE(TO_CHAR(reply_by, 'YYYY-MM-DD'), ''),
           processed,
           COALESCE(processed_at::text, ''),
           COALESCE(ingested_at::text, '')
    FROM emails WHERE doc_id = $1
  |} in
  let open Caqti_type in
  let rt = t2
    (t2 (t4 string string string string) string)
    (t2
      (t4 string string string string)
      (t2
        (t2 string string)
        (t2
          (t4 (option int) (option int) string bool)
          (t2 string string))))
  in
  let req = Caqti_request.Infix.(string ->? rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some (((doc_id, embed_model, triage_model, summarize_model), sender),
                ((recipient, cc, bcc, subject),
                 ((email_date, att_text),
                  ((action_score, importance_score, reply_by, processed),
                   (processed_at, ingested_at)))))) ->
        let attachments = try Yojson.Safe.from_string att_text with _ -> `List [] in
        let metadata =
          `Assoc
            [ ("from", `String sender)
            ; ("to", `String recipient)
            ; ("cc", `String cc)
            ; ("bcc", `String bcc)
            ; ("subject", `String subject)
            ; ("date", `String email_date)
            ; ("attachments", attachments)
            ; ("action_score", match action_score with Some s -> `Int s | None -> `Null)
            ; ("importance_score", match importance_score with Some s -> `Int s | None -> `Null)
            ; ("reply_by", `String reply_by)
            ; ("processed", `Bool processed)
            ; ("processed_at", if processed_at = "" then `Null else `String processed_at)
            ; ("ingested_at", `String ingested_at)
            ]
        in
        Ok (Some (`Assoc
          [ ("doc_id", `String doc_id)
          ; ("embed_model", `String embed_model)
          ; ("triage_model", `String triage_model)
          ; ("summarize_model", `String summarize_model)
          ; ("metadata", metadata)
          ])))

let set_propose_tasks_debug (doc_id : string) (debug_json : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO propose_tasks_log (doc_id, debug, created_at)
    VALUES ($1, $2::jsonb, NOW())
    ON CONFLICT (doc_id) DO UPDATE SET debug = EXCLUDED.debug, created_at = NOW()
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, debug_json))

(* Delete an email and clean up all referencing tables.
   Returns (existed, triggerless_task_ids) where triggerless_task_ids are tasks
   that no longer have any trigger emails after this deletion. *)
let delete_email (doc_id : string)
    : (bool * string list, string) result =
  let doc_id = normalize_doc_id doc_id in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    let open Caqti_type in
    (* 1. Find task_ids referencing this doc_id as trigger *)
    let affected_sql = {|
      SELECT task_id FROM task_emails
      WHERE doc_id = $1 AND role = 'trigger'
    |} in
    let affected_req = Caqti_request.Infix.(string ->* string) ~oneshot:true affected_sql in
    let affected_task_ids = match C.collect_list affected_req doc_id with
      | Ok ids -> ids | Error _ -> [] in
    (* 2. Delete from task_emails (all roles) *)
    let te_sql = "DELETE FROM task_emails WHERE doc_id = $1" in
    let te_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true te_sql in
    (match C.exec te_req doc_id with Error _ as e -> e | Ok () ->
    (* 3. Delete from fyi_emails *)
    let fy_sql = "DELETE FROM fyi_emails WHERE doc_id = $1" in
    let fy_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true fy_sql in
    (match C.exec fy_req doc_id with Error _ as e -> e | Ok () ->
    (* 4. Delete from memory_emails *)
    let me_sql = "DELETE FROM memory_emails WHERE doc_id = $1" in
    let me_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true me_sql in
    (match C.exec me_req doc_id with Error _ as e -> e | Ok () ->
    (* 5. Delete from propose_tasks_log *)
    let pl_sql = "DELETE FROM propose_tasks_log WHERE doc_id = $1" in
    let pl_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true pl_sql in
    (match C.exec pl_req doc_id with Error _ as e -> e | Ok () ->
    (* 5b. Delete from ingest_queue (may still be pending) *)
    let iq_sql = "DELETE FROM ingest_queue WHERE doc_id = $1" in
    let iq_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true iq_sql in
    (match C.exec iq_req doc_id with Error _ as e -> e | Ok () ->
    (* 5c. Delete from pending_processed queue *)
    let pp_sql = "DELETE FROM pending_processed WHERE doc_id = $1" in
    let pp_req = Caqti_request.Infix.(string ->. unit) ~oneshot:true pp_sql in
    (match C.exec pp_req doc_id with Error _ as e -> e | Ok () ->
    (* 6. Delete from emails (cascades to email_chunks, triage_queue) *)
    let del_sql = "DELETE FROM emails WHERE doc_id = $1 RETURNING doc_id" in
    let del_req = Caqti_request.Infix.(string ->? string) ~oneshot:true del_sql in
    (match C.find_opt del_req doc_id with
    | Error _ as e -> e
    | Ok existed ->
        let existed = existed <> None in
        (* 7. For affected tasks, check if any triggers remain *)
        let check_sql = {|
          SELECT COUNT(*) FROM task_emails
          WHERE task_id = $1 AND role = 'trigger'
        |} in
        let check_req = Caqti_request.Infix.(string ->! int) ~oneshot:true check_sql in
        let triggerless = List.filter (fun tid ->
          match C.find check_req tid with
          | Ok 0 -> true | _ -> false
        ) affected_task_ids in
        Ok (existed, triggerless)))))))))

let get_propose_tasks_debug (doc_id : string) : (string option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|SELECT debug::text FROM propose_tasks_log WHERE doc_id = $1|} in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Ok v -> Ok v
    | Error _ as e -> e)

let set_processed (doc_id : string) (value : bool) : (bool, string) result =
  let doc_id = normalize_doc_id doc_id in
  if value then
    let sql = {|
      UPDATE emails SET processed = TRUE, processed_at = $2::timestamptz
      WHERE doc_id = $1
      RETURNING doc_id
    |} in
    let req = Caqti_request.Infix.(Caqti_type.(t2 string string) ->? Caqti_type.string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.find_opt req (doc_id, now_utc_iso8601 ()) with
      | Ok (Some _) -> Ok true
      | Ok None -> Ok false
      | Error _ as e -> e)
  else
    let sql = {|
      UPDATE emails SET processed = FALSE, processed_at = NULL
      WHERE doc_id = $1
      RETURNING doc_id
    |} in
    let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.find_opt req doc_id with
      | Ok (Some _) -> Ok true
      | Ok None -> Ok false
      | Error _ as e -> e)

let enqueue_pending_processed (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO pending_processed (doc_id, created_at)
    VALUES ($1, NOW())
    ON CONFLICT (doc_id) DO UPDATE
      SET created_at = NOW()
  |} in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req doc_id)

let delete_pending_processed (doc_id : string) : (bool, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM pending_processed WHERE doc_id = $1 RETURNING doc_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error _ as e -> e)

let consume_pending_processed (doc_id : string) : (bool, string) result =
  delete_pending_processed doc_id

(* ---------- kNN retrieval ---------- *)

let row_to_source_json
    ((doc_id, distance, sender),
     ((recipient, cc, bcc, subject),
      ((email_date, att_text, action_score, importance_score),
       (reply_by, processed, ingested_at))))
    : Yojson.Safe.t =
  let score = 1.0 -. distance in
  let attachments = try Yojson.Safe.from_string att_text with _ -> `List [] in
  let metadata =
    `Assoc
      ([ ("from", `String sender)
       ; ("to", `String recipient)
       ; ("cc", `String cc)
       ; ("bcc", `String bcc)
       ; ("subject", `String subject)
       ; ("date", `String email_date)
       ; ("attachments", attachments)
       ; ("reply_by", `String reply_by)
       ; ("processed", `Bool processed)
       ; ("ingested_at", `String ingested_at)
       ]
      @ (match action_score with Some s -> [("action_score", `Int s)] | None -> [])
      @ (match importance_score with Some s -> [("importance_score", `Int s)] | None -> []))
  in
  `Assoc
    [ ("doc_id", `String doc_id)
    ; ("score", `Float score)
    ; ("metadata", metadata)
    ]

let knn_row_type =
  let open Caqti_type in
  t2
    (t3 string float string)
    (t2
      (t4 string string string string)
      (t2
        (t4 string string (option int) (option int))
        (t3 string bool string)))

let query_knn ~(embedding : float list) ~(top_k : int)
    ?(filter : string option) ?(score_expr : string option)
    ?(on_done : (float -> unit) option)
    () : (Yojson.Safe.t list * string, string) result =
  let t0 = Unix.gettimeofday () in
  let vec = float_list_to_pgvector embedding in
  let order_clause =
    match score_expr with
    | Some expr -> Printf.sprintf "(%s) DESC NULLS LAST" expr
    | None -> "ec.embedding <=> $1::vector ASC"
  in
  let where_clause =
    match filter with
    | Some f -> Printf.sprintf "WHERE (%s)" f
    | None -> ""
  in
  let sql = Printf.sprintf {|
    SELECT ec.doc_id,
           ec.embedding <=> $1::vector AS distance,
           e.sender, e.recipient, e.cc, e.bcc, e.subject, COALESCE(e.email_date::text, ''),
           COALESCE(array_to_json(e.attachments)::text, '[]'),
           e.action_score, e.importance_score,
           COALESCE(TO_CHAR(e.reply_by, 'YYYY-MM-DD'), ''),
           e.processed,
           COALESCE(e.ingested_at::text, '')
    FROM email_chunks ec
    JOIN emails e ON ec.doc_id = e.doc_id
    %s
    ORDER BY %s
    LIMIT $2
  |} where_clause order_clause in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string int ->* knn_row_type) ~oneshot:true sql in
  let display_sql =
    let parts = ref [] in
    (match filter with
     | Some f -> parts := !parts @ [Printf.sprintf "WHERE %s" f]
     | None -> ());
    (match score_expr with
     | Some expr -> parts := !parts @ [Printf.sprintf "ORDER BY (%s) DESC" expr]
     | None -> ());
    parts := !parts @ [Printf.sprintf "LIMIT %d" top_k];
    String.concat " " !parts
  in
  let result =
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.collect_list req (vec, top_k) with
      | Error _ as e -> e
      | Ok rows -> Ok (List.map row_to_source_json rows, display_sql))
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.query_knn (top_k=%d): %.3fs\n%!" top_k dt;
  (match on_done with Some f -> f dt | None -> ());
  result

(* ---------- task CRUD ---------- *)

let create_task
    ~(task_id : string) ~(title : string) ~(description : string)
    ~(importance_score : int option) ~(deadline : string)
    ~(embedding : float list)
    ~(conversation_json : string) ~(drafts_json : string)
    ?(prior_resolutions : string = "")
    () : (unit, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    INSERT INTO tasks
      (task_id, title, description, status, importance_score, deadline,
       embedding, conversation, drafts, prior_resolutions)
    VALUES ($1, $2, $3, 'open', $4, NULLIF($5,'')::timestamptz,
            $6::vector, $7::jsonb, $8::jsonb, $9)
  |} in
  let open Caqti_type in
  let pt = t2
    (t2 (t4 string string string (option int))
        (t4 string string string string))
    string
  in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req
      (((task_id, title, description, importance_score),
        (deadline, vec, conversation_json, drafts_json)),
       prior_resolutions))

let get_task (task_id : string)
    : (Yojson.Safe.t option, string) result =
  let sql = {|
    SELECT t.task_id, t.title, t.description, t.status,
           t.importance_score,
           COALESCE(TO_CHAR(t.deadline, 'YYYY-MM-DD'), ''),
           COALESCE(t.created_at::text, ''),
           COALESCE(t.updated_at::text, ''),
           t.conversation::text,
           t.history_summary,
           t.drafts::text,
           t.notes,
           t.context_emails::text,
           t.context_prefetched,
           t.context_ready,
           t.prior_resolutions
    FROM tasks t WHERE t.task_id = $1
  |} in
  let open Caqti_type in
  let rt = t2
    (t4 string string string string)
    (t2
      (t4 (option int) string string string)
      (t2
        (t4 string string string string)
        (t2 string (t2 (t2 bool bool) string))))
  in
  let req = Caqti_request.Infix.(string ->? rt) ~oneshot:true sql in
  (* Also fetch linked emails with metadata from emails table *)
  let emails_sql = {|
    SELECT te.doc_id, te.role, COALESCE(te.added_at::text, ''),
           COALESCE(e.sender, ''), COALESCE(e.subject, ''),
           COALESCE(TO_CHAR(e.email_date, 'YYYY-MM-DD HH24:MI'),
                    TO_CHAR(e.ingested_at, 'YYYY-MM-DD HH24:MI'), ''),
           COALESCE(e.recipient, ''), COALESCE(e.cc, ''),
           COALESCE(te.compressed_body, '')
    FROM task_emails te
    LEFT JOIN emails e ON e.doc_id = te.doc_id
    WHERE te.task_id = $1
    ORDER BY te.added_at
  |} in
  let open Caqti_type in
  let emails_rt = t2 (t2 (t4 string string string string) (t4 string string string string)) string in
  let emails_req = Caqti_request.Infix.(string ->* emails_rt) ~oneshot:true emails_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req task_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some ((tid, title, description, status),
                ((importance, deadline, created_at, updated_at),
                 ((conversation_text, history_summary, drafts_text, notes),
                  (context_emails_text, ((context_prefetched, context_ready), prior_resolutions)))))) ->
        let conversation = try Yojson.Safe.from_string conversation_text with _ -> `List [] in
        let drafts = try Yojson.Safe.from_string drafts_text with _ -> `List [] in
        let context_emails = try Yojson.Safe.from_string context_emails_text with _ -> `List [] in
        let emails =
          match C.collect_list emails_req tid with
          | Error _ -> []
          | Ok rows ->
              List.map (fun (((doc_id, role, added_at, sender), (subject, email_date, recipient, cc)), compressed_body) ->
                `Assoc [ ("doc_id", `String doc_id)
                       ; ("role", `String role)
                       ; ("added_at", `String added_at)
                       ; ("sender", `String sender)
                       ; ("subject", `String subject)
                       ; ("date", `String email_date)
                       ; ("recipient", `String recipient)
                       ; ("cc", `String cc)
                       ; ("compressed_body", `String compressed_body) ])
                rows
        in
        Ok (Some (`Assoc
          [ ("task_id", `String tid)
          ; ("title", `String title)
          ; ("description", `String description)
          ; ("status", `String status)
          ; ("importance_score", match importance with Some n -> `Int n | None -> `Null)
          ; ("deadline", `String deadline)
          ; ("created_at", `String created_at)
          ; ("updated_at", `String updated_at)
          ; ("conversation", conversation)
          ; ("history_summary", `String history_summary)
          ; ("drafts", drafts)
          ; ("notes", `String notes)
          ; ("emails", `List emails)
          ; ("context_emails", context_emails)
          ; ("context_prefetched", `Bool context_prefetched)
          ; ("context_ready", `Bool context_ready)
          ; ("prior_resolutions", `String prior_resolutions)
          ])))

let update_task
    ~(task_id : string)
    ?(title : string option)
    ?(description : string option)
    ?(status : string option)
    ?(importance_score : int option option)
    ?(deadline : string option)
    ?(embedding : float list option)
    ?(conversation_json : string option)
    ?(history_summary : string option)
    ?(drafts_json : string option)
    ?(notes : string option)
    ?(context_emails_json : string option)
    ?(context_prefetched : bool option)
    ?(context_ready : bool option)
    ?(sort_order : int option option)
    ?(prior_resolutions : string option)
    () : (bool, string) result =
  let escape_literal (s : string) : string =
    let buf = Buffer.create (String.length s + 4) in
    Buffer.add_string buf "E'";
    String.iter (fun c ->
      match c with
      | '\'' -> Buffer.add_string buf "''"
      | '\\' -> Buffer.add_string buf "\\\\"
      | _ -> Buffer.add_char buf c) s;
    Buffer.add_char buf '\'';
    Buffer.contents buf
  in
  let set_parts = ref [] in
  let add field literal =
    set_parts := Printf.sprintf "%s = %s" field literal :: !set_parts
  in
  (match title with Some t -> add "title" (escape_literal t) | None -> ());
  (match description with Some d -> add "description" (escape_literal d) | None -> ());
  (match status with Some s -> add "status" (escape_literal s) | None -> ());
  (match importance_score with
   | Some (Some n) -> add "importance_score" (string_of_int n)
   | Some None -> add "importance_score" "NULL"
   | None -> ());
  (match deadline with
   | Some d when String.trim d = "" -> add "deadline" "NULL"
   | Some d -> add "deadline" (escape_literal d ^ "::timestamptz")
   | None -> ());
  (match embedding with
   | Some emb -> add "embedding" (escape_literal (float_list_to_pgvector emb) ^ "::vector")
   | None -> ());
  (match conversation_json with
   | Some c -> add "conversation" (escape_literal c ^ "::jsonb")
   | None -> ());
  (match history_summary with Some h -> add "history_summary" (escape_literal h) | None -> ());
  (match drafts_json with
   | Some d -> add "drafts" (escape_literal d ^ "::jsonb")
   | None -> ());
  (match notes with Some n -> add "notes" (escape_literal n) | None -> ());
  (match context_emails_json with
   | Some c -> add "context_emails" (escape_literal c ^ "::jsonb")
   | None -> ());
  (match context_prefetched with
   | Some b -> add "context_prefetched" (if b then "TRUE" else "FALSE")
   | None -> ());
  (match context_ready with
   | Some b -> add "context_ready" (if b then "TRUE" else "FALSE")
   | None -> ());
  (match sort_order with
   | Some (Some n) -> add "sort_order" (string_of_int n)
   | Some None -> add "sort_order" "NULL"
   | None -> ());
  (match prior_resolutions with Some p -> add "prior_resolutions" (escape_literal p) | None -> ());
  if !set_parts = [] then Ok true
  else begin
    add "updated_at" (escape_literal (now_utc_iso8601 ()) ^ "::timestamptz");
    let sql = Printf.sprintf
      "UPDATE tasks SET %s WHERE task_id = $1 RETURNING task_id"
      (String.concat ", " (List.rev !set_parts))
    in
    let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.find_opt req task_id with
      | Ok (Some _) -> Ok true
      | Ok None -> Ok false
      | Error _ as e -> e)
  end

let list_tasks ?(statuses : string list option) ?(email_ids : string list option)
    ?(sort_by : string option) ?(limit : int option)
    () : (Yojson.Safe.t list, string) result =
  let wheres = ref [] in
  (match statuses with
   | Some ss when ss <> [] ->
       let quoted = List.map (Printf.sprintf "'%s'") ss in
       wheres := Printf.sprintf "t.status IN (%s)" (String.concat ", " quoted) :: !wheres
   | _ -> ());
  (match email_ids with
   | Some ids when ids <> [] ->
       let normed = List.map normalize_doc_id ids in
       let arr = pg_text_array normed in
       wheres := Printf.sprintf "EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = t.task_id AND te.doc_id = ANY('%s'::text[]))" arr :: !wheres
   | _ -> ());
  let where_clause =
    if !wheres = [] then ""
    else "WHERE " ^ String.concat " AND " (List.rev !wheres)
  in
  let order = match sort_by with
    | Some "deadline" -> "t.deadline ASC NULLS LAST, t.updated_at DESC"
    | Some "importance" -> "t.importance_score DESC NULLS LAST, t.updated_at DESC"
    | Some "created_at" -> "t.created_at DESC"
    | Some "manual" -> "t.sort_order ASC NULLS LAST, t.updated_at DESC"
    | _ -> "t.updated_at DESC"
  in
  let lim = match limit with Some n -> Printf.sprintf " LIMIT %d" n | None -> "" in
  let sql = Printf.sprintf {|
    SELECT t.task_id, t.title, t.description, t.status,
           t.importance_score,
           COALESCE(TO_CHAR(t.deadline, 'YYYY-MM-DD'), ''),
           COALESCE(t.created_at::text, ''),
           COALESCE(t.updated_at::text, ''),
           t.context_ready,
           t.sort_order
    FROM tasks t
    %s
    ORDER BY %s%s
  |} where_clause order lim in
  let open Caqti_type in
  let rt = t2
    (t4 string string string string)
    (t2 (t2 (t4 (option int) string string string) bool) (option int))
  in
  let req = Caqti_request.Infix.(unit ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        Ok (List.map (fun ((tid, title, description, status),
                           (((importance, deadline, created_at, updated_at), context_ready), sort_order)) ->
          `Assoc
            [ ("task_id", `String tid)
            ; ("title", `String title)
            ; ("description", `String description)
            ; ("status", `String status)
            ; ("importance_score", match importance with Some n -> `Int n | None -> `Null)
            ; ("deadline", `String deadline)
            ; ("created_at", `String created_at)
            ; ("updated_at", `String updated_at)
            ; ("context_ready", `Bool context_ready)
            ; ("sort_order", match sort_order with Some n -> `Int n | None -> `Null)
            ]) rows))

let reorder_tasks (pairs : (string * int) list) : (unit, string) result =
  if pairs = [] then Ok ()
  else
    let cases = List.mapi (fun _ (tid, ord) ->
      Printf.sprintf "WHEN '%s' THEN %d"
        (String.concat "''" (String.split_on_char '\'' tid)) ord
    ) pairs in
    let ids = List.map (fun (tid, _) ->
      Printf.sprintf "'%s'" (String.concat "''" (String.split_on_char '\'' tid))
    ) pairs in
    let sql = Printf.sprintf
      "UPDATE tasks SET sort_order = CASE task_id %s END WHERE task_id IN (%s)"
      (String.concat " " cases) (String.concat ", " ids)
    in
    let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      C.exec req ())

let delete_task (task_id : string) : (bool, string) result =
  let sql = "DELETE FROM tasks WHERE task_id = $1 RETURNING task_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req task_id with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error _ as e -> e)

let link_email_to_task ~(task_id : string) ~(doc_id : string) ~(role : string)
    ?(compressed_body : string option) () : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let cb = match compressed_body with Some s -> s | None -> "" in
  let sql = {|
    INSERT INTO task_emails (task_id, doc_id, role, compressed_body)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (task_id, doc_id) DO UPDATE SET role = EXCLUDED.role, compressed_body = EXCLUDED.compressed_body
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t4 string string string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (task_id, doc_id, role, cb))

(* Remove trigger-role links for a doc_id, return affected task_ids *)
let remove_trigger_links (doc_id : string)
    : (string list, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM task_emails WHERE doc_id = $1 AND role = 'trigger' RETURNING task_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req doc_id with
    | Error _ as e -> e
    | Ok ids -> Ok ids)

(* Remove a doc_id from all task_emails rows, return affected task_ids *)
let remove_email_from_all_tasks (doc_id : string)
    : (string list, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM task_emails WHERE doc_id = $1 RETURNING task_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req doc_id with
    | Error _ as e -> e
    | Ok ids -> Ok ids)

(* Delete tasks that have no remaining trigger emails *)
let delete_orphan_tasks (task_ids : string list)
    : (string list, string) result =
  if task_ids = [] then Ok []
  else
    let placeholders = List.mapi (fun i _ -> Printf.sprintf "$%d" (i + 1)) task_ids in
    let sql = Printf.sprintf
      {|DELETE FROM tasks WHERE task_id IN (%s)
        AND NOT EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = tasks.task_id AND te.role = 'trigger')
        RETURNING task_id|}
      (String.concat ", " placeholders) in
    (* Use oneshot with dynamic SQL since param count varies *)
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match task_ids with
      | [a] ->
          let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true
            {|DELETE FROM tasks WHERE task_id = $1
              AND NOT EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = tasks.task_id AND te.role = 'trigger')
              RETURNING task_id|} in
          (match C.collect_list req a with Error _ as e -> e | Ok ids -> Ok ids)
      | [a; b] ->
          let open Caqti_type in
          let req = Caqti_request.Infix.(t2 string string ->* string) ~oneshot:true sql in
          (match C.collect_list req (a, b) with Error _ as e -> e | Ok ids -> Ok ids)
      | _ ->
          (* For 3+ task_ids, iterate one at a time *)
          let deleted = ref [] in
          let single_sql =
            {|DELETE FROM tasks WHERE task_id = $1
              AND NOT EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = tasks.task_id AND te.role = 'trigger')
              RETURNING task_id|} in
          let single_req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true single_sql in
          List.iter (fun tid ->
            match C.find_opt single_req tid with
            | Ok (Some id) -> deleted := id :: !deleted
            | _ -> ()
          ) task_ids;
          Ok (List.rev !deleted))

(* For each task linked to doc_id via trigger role, check if ALL trigger emails
   are processed. If so, auto-complete the task. Returns list of auto-completed task_ids. *)
let auto_complete_tasks_for_email (doc_id : string)
    : (string list, string) result =
  let doc_id = normalize_doc_id doc_id in
  (* Find task_ids linked to this email as trigger *)
  let find_sql = "SELECT DISTINCT task_id FROM task_emails WHERE doc_id = $1 AND role = 'trigger'" in
  let find_req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true find_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list find_req doc_id with
    | Error _ as e -> e
    | Ok task_ids ->
        let completed = ref [] in
        List.iter (fun tid ->
          (* Check: all trigger emails for this task are processed *)
          let check_sql =
            {|SELECT COUNT(*) = 0 FROM task_emails te
              JOIN emails e ON e.doc_id = te.doc_id
              WHERE te.task_id = $1 AND te.role = 'trigger'
                AND e.processed IS NOT TRUE|} in
          let check_req = Caqti_request.Infix.(Caqti_type.string ->! Caqti_type.bool) ~oneshot:true check_sql in
          (match C.find check_req tid with
          | Ok true ->
              (* All triggers processed — mark task done if still open/in_progress *)
              let update_sql =
                {|UPDATE tasks SET status = 'done', updated_at = NOW()
                  WHERE task_id = $1 AND status IN ('open', 'in_progress')
                  RETURNING task_id|} in
              let update_req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true update_sql in
              (match C.find_opt update_req tid with
              | Ok (Some id) -> completed := id :: !completed
              | _ -> ())
          | _ -> ())
        ) task_ids;
        Ok (List.rev !completed))


(* Get the first chunk embedding for a doc_id as a float list *)
let get_doc_embedding (doc_id : string)
    : (float list option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT embedding::text FROM email_chunks
    WHERE doc_id = $1
    ORDER BY chunk_index ASC
    LIMIT 1
  |} in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some vec_str) ->
        (* Parse "[0.1,0.2,...]" format *)
        let s = String.trim vec_str in
        let s = if String.length s > 2 then String.sub s 1 (String.length s - 2) else s in
        let floats = String.split_on_char ',' s |> List.filter_map (fun f ->
          try Some (float_of_string (String.trim f)) with _ -> None
        ) in
        if floats = [] then Ok None else Ok (Some floats))

(* Get a task's stored embedding vector *)
let get_task_embedding (task_id : string)
    : (float list option, string) result =
  let sql = "SELECT embedding::text FROM tasks WHERE task_id = $1 AND embedding IS NOT NULL" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req task_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some vec_str) ->
        let s = String.trim vec_str in
        let s = if String.length s > 2 then String.sub s 1 (String.length s - 2) else s in
        let floats = String.split_on_char ',' s |> List.filter_map (fun f ->
          try Some (float_of_string (String.trim f)) with _ -> None
        ) in
        if floats = [] then Ok None else Ok (Some floats))

(* Find tasks that need context prefetch: open/in_progress, not yet prefetched *)
let tasks_needing_prefetch ?(limit : int = 5) ()
    : ((string * string) list, string) result =
  let sql = {|
    SELECT task_id, title FROM tasks
    WHERE status IN ('open', 'in_progress')
      AND context_prefetched = FALSE
    ORDER BY created_at ASC
    LIMIT $1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(int ->* t2 string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req limit with
    | Error _ as e -> e
    | Ok rows -> Ok rows)

(* Get trigger email doc_ids for a task *)
let task_trigger_doc_ids (task_id : string)
    : (string list, string) result =
  let sql = "SELECT doc_id FROM task_emails WHERE task_id = $1 AND role = 'trigger'" in
  let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req task_id with
    | Error _ as e -> e
    | Ok ids -> Ok ids)

(* Find task_ids where a given doc_id is a trigger — used for reply-chain linking *)
let tasks_by_trigger_doc_id (doc_id : string)
    : (string list, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "SELECT task_id FROM task_emails WHERE doc_id = $1 AND role = 'trigger'" in
  let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req doc_id with
    | Error _ as e -> e
    | Ok ids -> Ok ids)

(* Delete context and style task_emails rows for a task (keeps triggers) *)
let delete_task_context_and_style (task_id : string)
    : (int, string) result =
  let sql = "DELETE FROM task_emails WHERE task_id = $1 AND role IN ('context', 'style') RETURNING doc_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req task_id with
    | Error _ as e -> e
    | Ok ids -> Ok (List.length ids))

(* Find user's sent emails to a given recipient.
   sender_emails: list of the user's email addresses (extracted from whoami).
   recipient: the target email address or name to match in to/cc fields.
   Returns doc_ids of matching emails, most recent first. *)
let find_style_emails ~(sender_emails : string list) ~(recipient : string)
    ~(limit : int) () : (string list, string) result =
  if sender_emails = [] then Ok []
  else
    let sender_clauses = List.mapi (fun i _addr ->
      Printf.sprintf "sender ILIKE $%d" (i + 1)
    ) sender_emails in
    let sender_where = String.concat " OR " sender_clauses in
    let recip_idx = List.length sender_emails + 1 in
    let recip_pattern = Printf.sprintf "%%%s%%" recipient in
    let limit_idx = recip_idx + 1 in
    let sql = Printf.sprintf
      {|SELECT doc_id FROM emails
        WHERE (%s)
          AND (recipient ILIKE $%d OR cc ILIKE $%d)
        ORDER BY email_date DESC NULLS LAST
        LIMIT $%d|}
      sender_where recip_idx recip_idx limit_idx
    in
    (* Dynamic param count — use oneshot with manual binding.
       For simplicity, limit to max 4 sender emails (4 + recip + limit = 6 params) *)
    let sender_patterns = List.map (fun addr -> Printf.sprintf "%%%s%%" addr) sender_emails in
    match sender_patterns with
    | [a] ->
        let open Caqti_type in
        let req = Caqti_request.Infix.(t3 string string int ->* string) ~oneshot:true sql in
        use_ret (fun (module C : Caqti_eio.CONNECTION) ->
          match C.collect_list req (a, recip_pattern, limit) with
          | Error _ as e -> e | Ok ids -> Ok ids)
    | [a; b] ->
        let open Caqti_type in
        let req = Caqti_request.Infix.(t2 (t2 string string) (t2 string int) ->* string) ~oneshot:true sql in
        use_ret (fun (module C : Caqti_eio.CONNECTION) ->
          match C.collect_list req ((a, b), (recip_pattern, limit)) with
          | Error _ as e -> e | Ok ids -> Ok ids)
    | [a; b; c] ->
        let open Caqti_type in
        let req = Caqti_request.Infix.(t2 (t3 string string string) (t2 string int) ->* string) ~oneshot:true sql in
        use_ret (fun (module C : Caqti_eio.CONNECTION) ->
          match C.collect_list req ((a, b, c), (recip_pattern, limit)) with
          | Error _ as e -> e | Ok ids -> Ok ids)
    | [a; b; c; d] ->
        let open Caqti_type in
        let req = Caqti_request.Infix.(t2 (t4 string string string string) (t2 string int) ->* string) ~oneshot:true sql in
        use_ret (fun (module C : Caqti_eio.CONNECTION) ->
          match C.collect_list req ((a, b, c, d), (recip_pattern, limit)) with
          | Error _ as e -> e | Ok ids -> Ok ids)
    | _ ->
        (* More than 4 sender emails — use just the first 4 *)
        Ok []

(* Find tasks needing evidence upload: prefetched but not ready,
   with task_emails rows that have empty compressed_body (role != 'trigger').
   Returns list of (task_id, doc_ids_needing_bodies). *)
let tasks_needing_evidence ?(limit : int = 3) ()
    : ((string * string list) list, string) result =
  let sql = {|
    SELECT t.task_id, te.doc_id
    FROM tasks t
    JOIN task_emails te ON te.task_id = t.task_id
    WHERE t.context_prefetched = TRUE
      AND t.context_ready = FALSE
      AND t.status IN ('open', 'in_progress')
      AND te.role IN ('context', 'style')
      AND te.compressed_body = ''
    ORDER BY t.created_at ASC
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->* t2 string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        (* Group doc_ids by task_id, limit to `limit` tasks *)
        let tbl : (string, string list) Hashtbl.t = Hashtbl.create 16 in
        let order = ref [] in
        List.iter (fun (tid, did) ->
          if not (Hashtbl.mem tbl tid) then order := tid :: !order;
          let cur = match Hashtbl.find_opt tbl tid with Some l -> l | None -> [] in
          Hashtbl.replace tbl tid (cur @ [did])
        ) rows;
        let tasks = List.rev !order in
        let tasks = if List.length tasks > limit then
          let rec take n acc = function
            | [] -> List.rev acc
            | _ when n <= 0 -> List.rev acc
            | x :: xs -> take (n - 1) (x :: acc) xs
          in take limit [] tasks
        else tasks in
        Ok (List.map (fun tid ->
          (tid, match Hashtbl.find_opt tbl tid with Some l -> l | None -> [])
        ) tasks))

(* Update compressed_body for a task_email row *)
let update_task_email_body ~(task_id : string) ~(doc_id : string)
    ~(compressed_body : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    UPDATE task_emails SET compressed_body = $3
    WHERE task_id = $1 AND doc_id = $2
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t3 string string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (task_id, doc_id, compressed_body))

(* Get the role of a specific task_email entry *)
let get_task_email_role ~(task_id : string) ~(doc_id : string)
    : (string option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT role FROM task_emails WHERE task_id = $1 AND doc_id = $2 LIMIT 1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->? string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find_opt req (task_id, doc_id))

(* Get all task_emails with their compressed bodies for a task, grouped by role *)
let get_task_emails_with_bodies (task_id : string)
    : ((string * string * string) list, string) result =
  let sql = {|
    SELECT te.doc_id, te.role, te.compressed_body
    FROM task_emails te
    WHERE te.task_id = $1
    ORDER BY CASE te.role WHEN 'trigger' THEN 0 WHEN 'context' THEN 1 ELSE 2 END, te.added_at
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(string ->* t3 string string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req task_id with
    | Error _ as e -> e
    | Ok rows -> Ok rows)

(* Get the best available body text preview for a doc_id from task_emails *)
let get_body_preview (doc_id : string) : (string option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT compressed_body FROM task_emails
    WHERE doc_id = $1 AND compressed_body <> ''
    ORDER BY LENGTH(compressed_body) DESC
    LIMIT 1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(string ->? string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Error _ as e -> e
    | Ok v -> Ok v)

(* Find tasks where all evidence bodies are uploaded but first message not yet generated.
   context_prefetched=true, context_ready=false, no empty compressed_body on context/style rows. *)
let tasks_ready_for_generation ?(limit : int = 1) ()
    : ((string * string) list, string) result =
  let sql = {|
    SELECT t.task_id, t.title
    FROM tasks t
    WHERE t.context_prefetched = TRUE
      AND t.context_ready = FALSE
      AND t.status IN ('open', 'in_progress')
      AND NOT EXISTS (
        SELECT 1 FROM task_emails te
        WHERE te.task_id = t.task_id
          AND te.role IN ('context', 'style')
          AND te.compressed_body = ''
      )
    ORDER BY t.created_at ASC
    LIMIT $1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(int ->* t2 string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req limit with
    | Error _ as e -> e
    | Ok rows -> Ok rows)

let task_knn ~(embedding : float list) ~(top_k : int)
    ?(status_filter : string option)
    () : ((string * string * string * int option * string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let where_clause = match status_filter with
    | Some s -> Printf.sprintf "WHERE t.status = '%s'" s
    | None -> "WHERE t.status IN ('open', 'in_progress')"
  in
  let sql = Printf.sprintf {|
    SELECT t.task_id, t.title, t.description,
           t.importance_score,
           COALESCE(TO_CHAR(t.deadline, 'YYYY-MM-DD'), ''),
           t.embedding <=> $1::vector AS distance
    FROM tasks t
    %s
      AND t.embedding IS NOT NULL
    ORDER BY t.embedding <=> $1::vector ASC
    LIMIT $2
  |} where_clause in
  let open Caqti_type in
  let rt = t2 (t4 string string string (option int)) (t2 string float) in
  let req = Caqti_request.Infix.(t2 string int ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req (vec, top_k) with
    | Error _ as e -> e
    | Ok rows -> Ok (List.map (fun ((tid, title, desc, imp), (dl, dist)) ->
        (tid, title, desc, imp, dl, dist)) rows))

(* kNN search against resolved (done/dismissed) tasks — returns notes + last draft body
   for building prior_resolutions context on new tasks *)
let task_knn_resolved ~(embedding : float list) ~(top_k : int)
    () : ((string * string * string * string * string * string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    SELECT t.task_id, t.title, t.description, t.status, t.notes,
           COALESCE(
             (SELECT te.compressed_body FROM task_emails te
              WHERE te.task_id = t.task_id AND te.role = 'reply'
              ORDER BY te.added_at DESC LIMIT 1),
             CASE WHEN (t.drafts::jsonb -> -1 ->> 'used')::boolean IS TRUE
                  THEN t.drafts::jsonb -> -1 ->> 'body'
                  ELSE '' END,
             ''),
           t.embedding <=> $1::vector AS distance
    FROM tasks t
    WHERE t.status IN ('done', 'dismissed')
      AND t.embedding IS NOT NULL
    ORDER BY t.embedding <=> $1::vector ASC
    LIMIT $2
  |} in
  let open Caqti_type in
  let rt = t2 (t4 string string string string) (t2 string (t2 string float)) in
  let req = Caqti_request.Infix.(t2 string int ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req (vec, top_k) with
    | Error _ as e -> e
    | Ok rows -> Ok (List.map (fun ((tid, title, desc, status), (notes, (draft_body, dist))) ->
        (tid, title, desc, status, notes, draft_body, dist)) rows))

(* Clear compressed_body from task_emails and context_emails on a task (for storage trim on archival) *)
let trim_archived_task_storage (task_id : string) : (unit, string) result =
  (* Delete context/style task_emails rows *)
  let del_sql = "DELETE FROM task_emails WHERE task_id = $1 AND role IN ('context', 'style')" in
  let del_req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true del_sql in
  (* Clear compressed_body on remaining (trigger) rows *)
  let clear_sql = "UPDATE task_emails SET compressed_body = '' WHERE task_id = $1" in
  let clear_req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true clear_sql in
  (* Clear context_emails JSON *)
  let ctx_sql = "UPDATE tasks SET context_emails = '[]'::jsonb WHERE task_id = $1" in
  let ctx_req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true ctx_sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    match C.exec del_req task_id with
    | Error _ as e -> e
    | Ok () ->
    match C.exec clear_req task_id with
    | Error _ as e -> e
    | Ok () -> C.exec ctx_req task_id)

(* Find tasks with raw [DRAFT markers in conversation but empty drafts array *)
let tasks_needing_draft_migration ()
    : (string list, string) result =
  let sql = {|
    SELECT task_id FROM tasks
    WHERE drafts = '[]'::jsonb
      AND conversation::text LIKE '%[DRAFT %'
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->* string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req ())

(* Delete all tasks that have no trigger emails at all *)
let cleanup_orphan_tasks ()
    : (string list, string) result =
  let sql = {|
    DELETE FROM tasks
    WHERE NOT EXISTS (
      SELECT 1 FROM task_emails te
      WHERE te.task_id = tasks.task_id AND te.role = 'trigger'
    )
    AND status IN ('open', 'in_progress')
    RETURNING task_id
  |} in
  let req = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req ())

(* ---------- memory CRUD ---------- *)

let create_memory
    ~(memory_id : string) ~(text : string)
    ?(rule : string option)
    ?(source_task_id : string option)
    () : (unit, string) result =
  let sql = {|
    INSERT INTO memories (memory_id, text, rule, source_task_id)
    VALUES ($1, $2, $3::jsonb, $4)
  |} in
  let open Caqti_type in
  let pt = t4 string string (option string) (option string) in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (memory_id, text, rule, source_task_id))

let get_memory (memory_id : string)
    : (Yojson.Safe.t option, string) result =
  let sql = {|
    SELECT m.memory_id, m.text, m.rule::text, m.source_task_id,
           m.enabled, COALESCE(m.created_at::text, ''),
           COALESCE(m.updated_at::text, '')
    FROM memories m WHERE m.memory_id = $1
  |} in
  let open Caqti_type in
  let rt = t2
    (t4 string string (option string) (option string))
    (t3 bool string string)
  in
  let req = Caqti_request.Infix.(string ->? rt) ~oneshot:true sql in
  (* Also fetch linked emails *)
  let emails_sql = "SELECT doc_id FROM memory_emails WHERE memory_id = $1" in
  let emails_req = Caqti_request.Infix.(string ->* string) ~oneshot:true emails_sql in
  (* And templates *)
  let templates_sql = "SELECT id, template_text FROM memory_templates WHERE memory_id = $1" in
  let templates_req = Caqti_request.Infix.(string ->* t2 int string) ~oneshot:true templates_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req memory_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some ((mid, text, rule_str, source_task_id), (enabled, created_at, updated_at))) ->
        let rule_json = match rule_str with
          | Some s -> (try Yojson.Safe.from_string s with _ -> `Null)
          | None -> `Null
        in
        let emails = match C.collect_list emails_req mid with
          | Ok ids -> `List (List.map (fun id -> `String id) ids)
          | Error _ -> `List []
        in
        let templates = match C.collect_list templates_req mid with
          | Ok rows -> `List (List.map (fun (id, txt) ->
              `Assoc [("id", `Int id); ("template_text", `String txt)]) rows)
          | Error _ -> `List []
        in
        Ok (Some (`Assoc
          [ ("memory_id", `String mid)
          ; ("text", `String text)
          ; ("rule", rule_json)
          ; ("source_task_id", match source_task_id with Some s -> `String s | None -> `Null)
          ; ("enabled", `Bool enabled)
          ; ("created_at", `String created_at)
          ; ("updated_at", `String updated_at)
          ; ("linked_emails", emails)
          ; ("templates", templates)
          ])))

let update_memory
    ~(memory_id : string)
    ?(text : string option)
    ?(rule : string option option)
    ?(enabled : bool option)
    () : (bool, string) result =
  let escape_literal (s : string) : string =
    let buf = Buffer.create (String.length s + 4) in
    Buffer.add_string buf "E'";
    String.iter (fun c ->
      match c with
      | '\'' -> Buffer.add_string buf "''"
      | '\\' -> Buffer.add_string buf "\\\\"
      | _ -> Buffer.add_char buf c) s;
    Buffer.add_char buf '\'';
    Buffer.contents buf
  in
  let set_parts = ref [] in
  let add field literal =
    set_parts := Printf.sprintf "%s = %s" field literal :: !set_parts
  in
  (match text with Some t -> add "text" (escape_literal t) | None -> ());
  (match rule with
   | Some (Some r) -> add "rule" (escape_literal r ^ "::jsonb")
   | Some None -> add "rule" "NULL"
   | None -> ());
  (match enabled with
   | Some b -> add "enabled" (if b then "TRUE" else "FALSE")
   | None -> ());
  if !set_parts = [] then Ok true
  else begin
    add "updated_at" (escape_literal (now_utc_iso8601 ()) ^ "::timestamptz");
    let sql = Printf.sprintf
      "UPDATE memories SET %s WHERE memory_id = $1 RETURNING memory_id"
      (String.concat ", " (List.rev !set_parts))
    in
    let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.find_opt req memory_id with
      | Ok (Some _) -> Ok true
      | Ok None -> Ok false
      | Error _ as e -> e)
  end

let delete_memory (memory_id : string) : (bool, string) result =
  let sql = "DELETE FROM memories WHERE memory_id = $1 RETURNING memory_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req memory_id with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error _ as e -> e)

let list_memories ?(enabled_only : bool = false) ()
    : (Yojson.Safe.t list, string) result =
  let where = if enabled_only then "WHERE m.enabled = TRUE" else "" in
  let sql = Printf.sprintf {|
    SELECT m.memory_id, m.text, m.rule::text, m.source_task_id,
           m.enabled, COALESCE(m.created_at::text, ''),
           COALESCE(m.updated_at::text, '')
    FROM memories m
    %s
    ORDER BY m.created_at DESC
  |} where in
  let open Caqti_type in
  let rt = t2
    (t4 string string (option string) (option string))
    (t3 bool string string)
  in
  let req = Caqti_request.Infix.(unit ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        Ok (List.map (fun ((mid, text, rule_str, source_task_id),
                           (enabled, created_at, updated_at)) ->
          let rule_json = match rule_str with
            | Some s -> (try Yojson.Safe.from_string s with _ -> `Null)
            | None -> `Null
          in
          `Assoc
            [ ("memory_id", `String mid)
            ; ("text", `String text)
            ; ("rule", rule_json)
            ; ("source_task_id", match source_task_id with Some s -> `String s | None -> `Null)
            ; ("enabled", `Bool enabled)
            ; ("created_at", `String created_at)
            ; ("updated_at", `String updated_at)
            ]) rows))

let link_email_to_memory ~(memory_id : string) ~(doc_id : string)
    : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO memory_emails (memory_id, doc_id)
    VALUES ($1, $2)
    ON CONFLICT DO NOTHING
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (memory_id, doc_id))

let insert_memory_template ~(memory_id : string)
    ~(template_text : string) ~(embedding : float list)
    : (unit, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    INSERT INTO memory_templates (memory_id, template_text, embedding)
    VALUES ($1, $2, $3::vector)
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t3 string string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (memory_id, template_text, vec))

(* Retrieve memories whose symbolic rules match — returns all enabled memories
   with non-NULL rules. The caller evaluates the rules in OCaml. *)
let memories_with_rules ()
    : ((string * string * string) list, string) result =
  let sql = {|
    SELECT memory_id, text, rule::text
    FROM memories
    WHERE enabled = TRUE AND rule IS NOT NULL
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->* t3 string string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req ())

(* kNN search against memory_templates embeddings.
   Returns (memory_id, distance) pairs sorted by distance. *)
let memory_templates_knn ~(embedding : float list) ~(top_k : int)
    () : ((string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    SELECT mt.memory_id, mt.embedding <=> $1::vector AS distance
    FROM memory_templates mt
    JOIN memories m ON m.memory_id = mt.memory_id
    WHERE m.enabled = TRUE
    ORDER BY mt.embedding <=> $1::vector ASC
    LIMIT $2
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string int ->* t2 string float) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req (vec, top_k))

(* kNN search against email_chunks that are linked to memories via memory_emails.
   Returns (memory_id, distance) pairs sorted by distance. *)
let memory_emails_knn ~(embedding : float list) ~(top_k : int)
    () : ((string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    SELECT me.memory_id, MIN(ec.embedding <=> $1::vector) AS distance
    FROM memory_emails me
    JOIN email_chunks ec ON ec.doc_id = me.doc_id
    JOIN memories m ON m.memory_id = me.memory_id
    WHERE m.enabled = TRUE
    GROUP BY me.memory_id
    ORDER BY distance ASC
    LIMIT $2
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string int ->* t2 string float) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req (vec, top_k))

(* kNN search against task embeddings for tasks linked to memories via source_task_id.
   Returns (memory_id, distance) pairs sorted by distance. *)
let memory_tasks_knn ~(embedding : float list) ~(top_k : int)
    () : ((string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    SELECT m.memory_id, t.embedding <=> $1::vector AS distance
    FROM memories m
    JOIN tasks t ON t.task_id = m.source_task_id
    WHERE m.enabled = TRUE
      AND t.embedding IS NOT NULL
    ORDER BY t.embedding <=> $1::vector ASC
    LIMIT $2
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string int ->* t2 string float) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.collect_list req (vec, top_k))

(* Get the text of a memory by id *)
let memory_text (memory_id : string) : (string option, string) result =
  let sql = "SELECT text FROM memories WHERE memory_id = $1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find_opt req memory_id)

(* --- Ingest queue (async ingestion) --- *)

let enqueue_ingest ~(doc_id : string) ~(raw : string) ()
    : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO ingest_queue (doc_id, raw, status)
    VALUES ($1, $2, 'pending')
    ON CONFLICT (doc_id) DO UPDATE
      SET raw = EXCLUDED.raw,
          status = 'pending',
          error = '',
          created_at = NOW(),
          started_at = NULL,
          finished_at = NULL
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, raw))

(* Dequeue oldest entry from ingest queue.
   Returns (doc_id, raw) or None. Reclaims stale 'processing' rows too. *)
let dequeue_ingest ~(stale_after_seconds : int) ()
    : ((string * string) option, string) result =
  let sql = {|
    WITH next AS (
      SELECT doc_id
      FROM ingest_queue
      WHERE status = 'pending'
         OR (status = 'processing'
             AND started_at IS NOT NULL
             AND started_at < NOW() - make_interval(secs => $1))
      ORDER BY created_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE ingest_queue iq
    SET status = 'processing',
        error = '',
        started_at = NOW(),
        finished_at = NULL
    FROM next
    WHERE iq.doc_id = next.doc_id
    RETURNING iq.doc_id, iq.raw
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(int ->? t2 string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find_opt req stale_after_seconds)

let finish_ingest (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    UPDATE ingest_queue
    SET status = 'done', finished_at = NOW()
    WHERE doc_id = $1
  |} in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req doc_id)

let fail_ingest (doc_id : string) (error : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    UPDATE ingest_queue
    SET status = 'error', error = $2, finished_at = NOW()
    WHERE doc_id = $1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, error))

let requeue_ingest (doc_id : string) (error : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    UPDATE ingest_queue
    SET status = 'pending',
        error = $2,
        started_at = NULL,
        finished_at = NULL
    WHERE doc_id = $1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, error))

let delete_ingest_entry (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM ingest_queue WHERE doc_id = $1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req doc_id)

(* Return counts by status for progress display *)
let ingest_queue_status ()
    : ((int * int * int * int), string) result =
  let sql = {|
    SELECT
      COUNT(*) FILTER (WHERE status = 'pending'),
      COUNT(*) FILTER (WHERE status = 'processing'),
      COUNT(*) FILTER (WHERE status = 'done'),
      COUNT(*) FILTER (WHERE status = 'error')
    FROM ingest_queue
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->! t4 int int int int) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find req ())

(* Quick check: any pending work? *)
let ingest_queue_pending_count () : (int, string) result =
  let sql = "SELECT COUNT(*) FROM ingest_queue WHERE status IN ('pending', 'processing')" in
  let req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find req ())

(* Clean up finished entries (done/error) older than a threshold *)
let clear_finished_ingests () : (unit, string) result =
  let sql = "DELETE FROM ingest_queue WHERE status IN ('done', 'error')" in
  let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req ())

(* --- Triage queue --- *)

let enqueue_triage ~(doc_id : string) ~(body_text : string)
    ~(compressed_body : string) () : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO triage_queue (doc_id, body_text, compressed_body, status, error, started_at, finished_at)
    VALUES ($1, $2, $3, 'pending', '', NULL, NULL)
    ON CONFLICT (doc_id) DO UPDATE
      SET body_text = EXCLUDED.body_text,
          compressed_body = EXCLUDED.compressed_body,
          status = 'pending',
          error = '',
          started_at = NULL,
          finished_at = NULL,
          created_at = NOW()
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t3 string string string ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, body_text, compressed_body))

(* Dequeue oldest entry from triage queue.
   Returns (doc_id, body_text, compressed_body) or None. *)
let dequeue_triage ~(stale_after_seconds : int) ()
    : ((string * string * string) option, string) result =
  let sql = {|
    WITH next AS (
      SELECT doc_id
      FROM triage_queue
      WHERE status = 'pending'
         OR (status = 'processing'
             AND started_at IS NOT NULL
             AND started_at < NOW() - make_interval(secs => $1))
      ORDER BY created_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE triage_queue tq
    SET status = 'processing',
        error = '',
        started_at = NOW(),
        finished_at = NULL
    FROM next
    WHERE tq.doc_id = next.doc_id
    RETURNING tq.doc_id, tq.body_text, tq.compressed_body
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(int ->? t3 string string string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find_opt req stale_after_seconds)

let delete_triage_entry (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM triage_queue WHERE doc_id = $1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req doc_id)

let fail_triage (doc_id : string) (error : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    UPDATE triage_queue
    SET status = 'error', error = $2, finished_at = NOW()
    WHERE doc_id = $1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (doc_id, error))

let triage_queue_status ()
    : ((int * int * int), string) result =
  let sql = {|
    SELECT
      COUNT(*) FILTER (WHERE status = 'pending'),
      COUNT(*) FILTER (WHERE status = 'processing'),
      COUNT(*) FILTER (WHERE status = 'error')
    FROM triage_queue
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->! t3 int int int) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.find req ())

(* Database statistics: row count + total size per table, plus overall total size *)

let table_description (name : string) : string =
  match name with
  | "emails"            -> "Email metadata & headers"
  | "email_chunks"      -> "Vector embeddings for email search"
  | "tasks"             -> "Task definitions & state"
  | "task_emails"       -> "Email→task links (trigger/context/style)"
  | "propose_tasks_log" -> "Triage LLM debug log"
  | "triage_queue"      -> "Daemon Phase 0 pending queue"
  | "fyi_emails"        -> "Triaged emails with no tasks (FYI)"
  | "ingest_queue"      -> "Async ingestion pending queue"
  | "pending_processed" -> "Pending mark-processed queue"
  | "memories"          -> "User memories & preferences"
  | "memory_emails"     -> "Memory→email source links"
  | "memory_templates"  -> "Vector embeddings for memory retrieval"
  | _ -> ""

let table_category (name : string) : string =
  match name with
  | "emails" | "email_chunks" | "ingest_queue" | "pending_processed" -> "email"
  | "tasks" | "task_emails" | "propose_tasks_log" | "triage_queue" | "fyi_emails" -> "task"
  | "memories" | "memory_emails" | "memory_templates" -> "memory"
  | _ -> "other"

(* (name, rows, size, description, category) per table *)
let db_stats () : ((string * int * string * string * string) list * string, string) result =
  let sql = {|
    SELECT
      t.tablename,
      COALESCE(s.n_live_tup, 0)::int,
      pg_size_pretty(pg_total_relation_size(quote_ident(t.tablename)::regclass))
    FROM pg_tables t
    LEFT JOIN pg_stat_user_tables s ON s.relname = t.tablename
    WHERE t.schemaname = 'public'
    ORDER BY pg_total_relation_size(quote_ident(t.tablename)::regclass) DESC
  |} in
  let total_sql = {|
    SELECT pg_size_pretty(SUM(pg_total_relation_size(quote_ident(t.tablename)::regclass)))
    FROM pg_tables t
    WHERE t.schemaname = 'public'
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->* t3 string int string) ~oneshot:true sql in
  let total_req = Caqti_request.Infix.(unit ->? string) ~oneshot:true total_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        let cat_order = function "email" -> 0 | "task" -> 1 | "memory" -> 2 | _ -> 3 in
        let rows = List.map (fun (name, count, size) ->
          (name, count, size, table_description name, table_category name)) rows in
        let rows = List.sort (fun (_, _, _, _, c1) (_, _, _, _, c2) ->
          compare (cat_order c1) (cat_order c2)) rows in
        let total = match C.find_opt total_req () with
          | Ok (Some s) -> s | _ -> "" in
        Ok (rows, total))

(* Clear all task-related tables *)
let clear_tasks () : (unit, string) result =
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    let exec sql =
      let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
      C.exec req ()
    in
    match exec "DELETE FROM fyi_emails" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM task_emails" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM propose_tasks_log" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM triage_queue" with
    | Error _ as e -> e
    | Ok () ->
    exec "DELETE FROM tasks")

(* Clear email/RAG storage tables *)
let clear_rag () : (unit, string) result =
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    let exec sql =
      let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
      C.exec req ()
    in
    match exec "DELETE FROM fyi_emails WHERE doc_id NOT IN (SELECT doc_id FROM emails)" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM propose_tasks_log WHERE doc_id NOT IN (SELECT doc_id FROM emails)" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM pending_processed" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM email_chunks" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM emails" with
    | Error _ as e -> e
    | Ok () ->
    match exec {|DELETE FROM task_emails te
      WHERE NOT EXISTS (SELECT 1 FROM emails e WHERE e.doc_id = te.doc_id)|} with
    | Error _ as e -> e
    | Ok () ->
    exec {|DELETE FROM tasks
      WHERE NOT EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = tasks.task_id AND te.role = 'trigger')|})

let clear_ingest_queue () : (unit, string) result =
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
      "DELETE FROM ingest_queue" in
    C.exec req ())

(* Clear all memory-related tables *)
let clear_memories () : (unit, string) result =
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    let exec sql =
      let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
      C.exec req ()
    in
    match exec "DELETE FROM memory_templates" with
    | Error _ as e -> e
    | Ok () ->
    match exec "DELETE FROM memory_emails" with
    | Error _ as e -> e
    | Ok () ->
    exec "DELETE FROM memories")

(* --- FYI emails --- *)

let insert_fyi ~(doc_id : string) ~(summary : string)
    ~(compressed_body : string) ~(email_date : string) () : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO fyi_emails (doc_id, summary, compressed_body, email_date)
    VALUES ($1, $2, $3, CASE WHEN $4 = '' THEN NULL ELSE $4::timestamptz END)
    ON CONFLICT (doc_id) DO UPDATE
      SET summary = EXCLUDED.summary,
          compressed_body = EXCLUDED.compressed_body,
          email_date = EXCLUDED.email_date
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 (t2 string string) (t2 string string) ->. unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req ((doc_id, summary), (compressed_body, email_date)))

let delete_fyi (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM fyi_emails WHERE doc_id = $1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req doc_id)

(* Return all FYI entries joined with email metadata.
   Each row: (doc_id, summary, email_date, sender, subject) *)
let list_fyi () : ((string * string * string * string * string) list, string) result =
  let sql = {|
    SELECT f.doc_id, f.summary,
           COALESCE(TO_CHAR(f.email_date, 'YYYY-MM-DD HH24:MI'), ''),
           COALESCE(e.sender, ''), COALESCE(e.subject, '')
    FROM fyi_emails f
    LEFT JOIN emails e ON e.doc_id = f.doc_id
    WHERE COALESCE(e.processed, FALSE) IS NOT TRUE
    ORDER BY f.email_date DESC NULLS LAST
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(unit ->* t2 (t3 string string string) (t2 string string)) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        Ok (List.map (fun ((doc_id, summary, date), (sender, subject)) ->
          (doc_id, summary, date, sender, subject)) rows))

let get_fyi_body_preview (doc_id : string) : (string option, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT compressed_body FROM fyi_emails
    WHERE doc_id = $1 AND compressed_body <> ''
    LIMIT 1
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(string ->? string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Error _ as e -> e
    | Ok v -> Ok v)
