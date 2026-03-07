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
       chunk_text  TEXT NOT NULL,
       embedding   vector(%d) NOT NULL
     )|} !rag_vector_dimension
  ; {|CREATE INDEX IF NOT EXISTS idx_chunks_doc_id ON email_chunks(doc_id)|}
  (* Migration: drop redundant message_id column (identical to doc_id) *)
  ; {|ALTER TABLE emails DROP COLUMN IF EXISTS message_id|}
  ; {|ALTER TABLE emails ADD COLUMN IF NOT EXISTS summarize_model TEXT NOT NULL DEFAULT ''|}
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
  ; {|CREATE TABLE IF NOT EXISTS task_emails (
       task_id  TEXT NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
       doc_id   TEXT NOT NULL,
       role     TEXT NOT NULL DEFAULT 'trigger',
       added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       PRIMARY KEY (task_id, doc_id)
     )|}
  ; {|CREATE INDEX IF NOT EXISTS idx_task_emails_doc_id ON task_emails(doc_id)|}
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
    ?(on_done : (float -> unit) option)
    () : (unit, string) result =
  let t0 = Unix.gettimeofday () in
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO emails
      (doc_id, embed_model, triage_model, summarize_model, sender, recipient, cc, bcc,
       subject, email_date, attachments, action_score, importance_score,
       reply_by, processed, ingested_at, whoami)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NULLIF($10,'')::timestamptz,$11::text[],$12,$13,NULLIF($14,'')::timestamptz,FALSE,NULLIF($15,'')::timestamptz,$16)
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
      whoami = EXCLUDED.whoami
  |} in
  let open Caqti_type in
  (* Parameter order must match SQL: $1-$8 strings, $9 subject, $10 email_date,
     $11 attachments, $12 action_score, $13 importance_score, $14 reply_by,
     $15 ingested_at, $16 whoami *)
  let pt = t2
    (t2 (t4 string string string string) (t4 string string string string))
    (t2
      (t2 string string)
      (t2 (t2 string (option int)) (t4 (option int) string string string)))
  in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      C.exec req
        (((doc_id, embed_model, triage_model, summarize_model),
          (sender, recipient, cc, bcc)),
         ((subject, email_date),
          ((attachments_json, action_score), (importance_score, reply_by, ingested_at, whoami)))))
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.upsert_email: %.3fs\n%!" dt;
  (match on_done with Some f -> f dt | None -> ());
  result

let insert_chunks ~(doc_id : string) ?(on_done : (float -> unit) option)
    (chunks : (int * string * string * float list) list) : (unit, string) result =
  let t0 = Unix.gettimeofday () in
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO email_chunks (doc_id, chunk_index, section, chunk_text, embedding)
    VALUES ($1, $2, $3, $4, $5::vector)
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 (t3 string int string) (t2 string string) ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      let rec run = function
        | [] -> Ok ()
        | (idx, section, text, emb) :: rest ->
            let vec_str = float_list_to_pgvector emb in
            (match C.exec req ((doc_id, idx, section), (text, vec_str)) with
             | Ok () -> run rest
             | Error _ as e -> e)
      in
      run chunks)
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.insert_chunks (%d): %.3fs\n%!" (List.length chunks) dt;
  (match on_done with Some f -> f dt | None -> ());
  result

let purge_untriaged () : (int, string) result =
  let count_sql = "SELECT COUNT(*)::int FROM emails WHERE action_score IS NULL AND importance_score IS NULL" in
  let count_req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true count_sql in
  let del_sql = "DELETE FROM emails WHERE action_score IS NULL AND importance_score IS NULL" in
  let del_req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true del_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find count_req () with
    | Error _ as e -> e
    | Ok n ->
        match C.exec del_req () with
        | Error _ as e -> e
        | Ok () -> Ok n)

let purge_empty_metadata () : (int, string) result =
  let count_sql = "SELECT COUNT(*)::int FROM emails WHERE sender = '' AND recipient = '' AND subject = ''" in
  let count_req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true count_sql in
  let del_sql = "DELETE FROM emails WHERE sender = '' AND recipient = '' AND subject = ''" in
  let del_req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true del_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find count_req () with
    | Error _ as e -> e
    | Ok n ->
        match C.exec del_req () with
        | Error _ as e -> e
        | Ok () -> Ok n)

let purge_base64_chunks () : (int, string) result =
  let count_sql = {|SELECT COUNT(DISTINCT ec.doc_id)::int
    FROM email_chunks ec
    WHERE ec.chunk_text ~ '^[A-Za-z0-9+/=\s]{100,}$'
       OR ec.chunk_text ~ 'PGh0bW'|} in
  let count_req = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) ~oneshot:true count_sql in
  let del_sql = {|DELETE FROM emails WHERE doc_id IN (
    SELECT DISTINCT ec.doc_id FROM email_chunks ec
    WHERE ec.chunk_text ~ '^[A-Za-z0-9+/=\s]{100,}$'
       OR ec.chunk_text ~ 'PGh0bW')|} in
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

let delete_email (doc_id : string) : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM emails WHERE doc_id = $1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) sql in
  use (fun (module C : Caqti_eio.CONNECTION) -> C.exec req doc_id)

let reset_all () : (unit, string) result =
  use (fun (module C : Caqti_eio.CONNECTION) ->
    let exec sql =
      let req = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql in
      C.exec req ()
    in
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
    : ((string list * string list * (string * string) list), string) result =
  if ids = [] then Ok ([], [], [])
  else
    let normed = List.map normalize_doc_id ids in
    let arr = pg_text_array normed in
    let sql = "SELECT doc_id, processed, COALESCE(TO_CHAR(reply_by, 'YYYY-MM-DD'), '') FROM emails WHERE doc_id = ANY($1::text[])" in
    let open Caqti_type in
    let req = Caqti_request.Infix.(string ->* t3 string bool string) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.collect_list req arr with
      | Error _ as e -> e
      | Ok rows ->
          let ingested = List.map (fun (id, _, _) -> id) rows in
          let processed = rows |> List.filter_map (fun (id, p, _) -> if p then Some id else None) in
          let reply_by = rows |> List.filter_map (fun (id, _, rb) ->
            if String.trim rb <> "" then Some (id, rb) else None) in
          Ok (ingested, processed, reply_by))

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

let is_ingested (doc_id : string) : (bool, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "SELECT 1 FROM emails WHERE doc_id = $1 LIMIT 1" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.int) sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req doc_id with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
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

(* ---------- kNN retrieval ---------- *)

let row_to_source_json
    ((doc_id, chunk_text, distance, sender),
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
  ignore chunk_text;
  `Assoc
    [ ("doc_id", `String doc_id)
    ; ("score", `Float score)
    ; ("metadata", metadata)
    ]

let knn_row_type =
  let open Caqti_type in
  t2
    (t4 string string float string)
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
    SELECT ec.doc_id, ec.chunk_text,
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
    () : (unit, string) result =
  let vec = float_list_to_pgvector embedding in
  let sql = {|
    INSERT INTO tasks
      (task_id, title, description, status, importance_score, deadline,
       embedding, conversation, drafts)
    VALUES ($1, $2, $3, 'open', $4, NULLIF($5,'')::timestamptz,
            $6::vector, $7::jsonb, $8::jsonb)
  |} in
  let open Caqti_type in
  let pt = t2
    (t4 string string string (option int))
    (t4 string string string string)
  in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req
      ((task_id, title, description, importance_score),
       (deadline, vec, conversation_json, drafts_json)))

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
           t.notes
    FROM tasks t WHERE t.task_id = $1
  |} in
  let open Caqti_type in
  let rt = t2
    (t4 string string string string)
    (t2
      (t4 (option int) string string string)
      (t4 string string string string))
  in
  let req = Caqti_request.Infix.(string ->? rt) ~oneshot:true sql in
  (* Also fetch linked emails *)
  let emails_sql = {|
    SELECT doc_id, role, COALESCE(added_at::text, '')
    FROM task_emails WHERE task_id = $1
    ORDER BY added_at
  |} in
  let emails_req = Caqti_request.Infix.(string ->* t3 string string string) ~oneshot:true emails_sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req task_id with
    | Error _ as e -> e
    | Ok None -> Ok None
    | Ok (Some ((tid, title, description, status),
                ((importance, deadline, created_at, updated_at),
                 (conversation_text, history_summary, drafts_text, notes)))) ->
        let conversation = try Yojson.Safe.from_string conversation_text with _ -> `List [] in
        let drafts = try Yojson.Safe.from_string drafts_text with _ -> `List [] in
        let emails =
          match C.collect_list emails_req tid with
          | Error _ -> []
          | Ok rows ->
              List.map (fun (doc_id, role, added_at) ->
                `Assoc [ ("doc_id", `String doc_id)
                       ; ("role", `String role)
                       ; ("added_at", `String added_at) ])
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

let list_tasks ?(status_filter : string option) ?(email_ids : string list option)
    ?(sort_by : string option) ?(limit : int option)
    () : (Yojson.Safe.t list, string) result =
  let wheres = ref [] in
  (match status_filter with
   | Some s -> wheres := Printf.sprintf "t.status = '%s'" s :: !wheres
   | None -> ());
  (match email_ids with
   | Some ids when ids <> [] ->
       let arr = pg_text_array ids in
       wheres := Printf.sprintf "EXISTS (SELECT 1 FROM task_emails te WHERE te.task_id = t.task_id AND te.doc_id = ANY('%s'::text[]))" arr :: !wheres
   | _ -> ());
  let where_clause =
    if !wheres = [] then ""
    else "WHERE " ^ String.concat " AND " (List.rev !wheres)
  in
  let order = match sort_by with
    | Some "deadline" -> "t.deadline ASC NULLS LAST"
    | Some "importance" -> "t.importance_score DESC NULLS LAST"
    | Some "created_at" -> "t.created_at DESC"
    | _ -> "t.updated_at DESC"
  in
  let lim = match limit with Some n -> Printf.sprintf " LIMIT %d" n | None -> "" in
  let sql = Printf.sprintf {|
    SELECT t.task_id, t.title, t.description, t.status,
           t.importance_score,
           COALESCE(TO_CHAR(t.deadline, 'YYYY-MM-DD'), ''),
           COALESCE(t.created_at::text, ''),
           COALESCE(t.updated_at::text, '')
    FROM tasks t
    %s
    ORDER BY %s%s
  |} where_clause order lim in
  let open Caqti_type in
  let rt = t2
    (t4 string string string string)
    (t4 (option int) string string string)
  in
  let req = Caqti_request.Infix.(unit ->* rt) ~oneshot:true sql in
  (* Also need linked email counts per task *)
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req () with
    | Error _ as e -> e
    | Ok rows ->
        Ok (List.map (fun ((tid, title, description, status),
                           (importance, deadline, created_at, updated_at)) ->
          `Assoc
            [ ("task_id", `String tid)
            ; ("title", `String title)
            ; ("description", `String description)
            ; ("status", `String status)
            ; ("importance_score", match importance with Some n -> `Int n | None -> `Null)
            ; ("deadline", `String deadline)
            ; ("created_at", `String created_at)
            ; ("updated_at", `String updated_at)
            ]) rows))

let delete_task (task_id : string) : (bool, string) result =
  let sql = "DELETE FROM tasks WHERE task_id = $1 RETURNING task_id" in
  let req = Caqti_request.Infix.(Caqti_type.string ->? Caqti_type.string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req task_id with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error _ as e -> e)

let link_email_to_task ~(task_id : string) ~(doc_id : string) ~(role : string)
    : (unit, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO task_emails (task_id, doc_id, role)
    VALUES ($1, $2, $3)
    ON CONFLICT (task_id, doc_id) DO UPDATE SET role = EXCLUDED.role
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t3 string string string ->. unit) ~oneshot:true sql in
  use (fun (module C : Caqti_eio.CONNECTION) ->
    C.exec req (task_id, doc_id, role))

let unlink_email_from_task ~(task_id : string) ~(doc_id : string)
    : (bool, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = "DELETE FROM task_emails WHERE task_id = $1 AND doc_id = $2 RETURNING task_id" in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t2 string string ->? string) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req (task_id, doc_id) with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error _ as e -> e)

let find_tasks_for_email (doc_id : string)
    : (Yojson.Safe.t list, string) result =
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    SELECT t.task_id, t.title, t.description, t.status,
           t.importance_score,
           COALESCE(TO_CHAR(t.deadline, 'YYYY-MM-DD'), ''),
           te.role
    FROM task_emails te
    JOIN tasks t ON te.task_id = t.task_id
    WHERE te.doc_id = $1
    ORDER BY t.updated_at DESC
  |} in
  let open Caqti_type in
  let rt = t2
    (t4 string string string string)
    (t3 (option int) string string)
  in
  let req = Caqti_request.Infix.(string ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req doc_id with
    | Error _ as e -> e
    | Ok rows ->
        Ok (List.map (fun ((tid, title, description, status),
                           (importance, deadline, role)) ->
          `Assoc
            [ ("task_id", `String tid)
            ; ("title", `String title)
            ; ("description", `String description)
            ; ("status", `String status)
            ; ("importance_score", match importance with Some n -> `Int n | None -> `Null)
            ; ("deadline", `String deadline)
            ; ("role", `String role)
            ]) rows))

let task_knn ~(embedding : float list) ~(top_k : int)
    ?(status_filter : string option)
    () : ((string * string * string * float) list, string) result =
  let vec = float_list_to_pgvector embedding in
  let where_clause = match status_filter with
    | Some s -> Printf.sprintf "WHERE t.status = '%s'" s
    | None -> "WHERE t.status IN ('open', 'in_progress')"
  in
  let sql = Printf.sprintf {|
    SELECT t.task_id, t.title, t.description,
           t.embedding <=> $1::vector AS distance
    FROM tasks t
    %s
      AND t.embedding IS NOT NULL
    ORDER BY t.embedding <=> $1::vector ASC
    LIMIT $2
  |} where_clause in
  let open Caqti_type in
  let rt = t4 string string string float in
  let req = Caqti_request.Infix.(t2 string int ->* rt) ~oneshot:true sql in
  use_ret (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req (vec, top_k) with
    | Error _ as e -> e
    | Ok rows -> Ok rows)
