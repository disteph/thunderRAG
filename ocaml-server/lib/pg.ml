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

let schema_statements =
  [ {|CREATE TABLE IF NOT EXISTS emails (
       doc_id        TEXT PRIMARY KEY,
       embed_model   TEXT NOT NULL DEFAULT '',
       triage_model  TEXT NOT NULL DEFAULT '',
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
       ingested_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )|}
  ; {|CREATE TABLE IF NOT EXISTS email_chunks (
       id          SERIAL PRIMARY KEY,
       doc_id      TEXT NOT NULL REFERENCES emails(doc_id) ON DELETE CASCADE,
       chunk_index INT NOT NULL,
       chunk_text  TEXT NOT NULL,
       embedding   vector(768) NOT NULL
     )|}
  ; {|CREATE INDEX IF NOT EXISTS idx_chunks_doc_id ON email_chunks(doc_id)|}
  (* Migration: drop redundant message_id column (identical to doc_id) *)
  ; {|ALTER TABLE emails DROP COLUMN IF EXISTS message_id|}
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
  run schema_statements

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
    ~(sender : string) ~(recipient : string) ~(cc : string) ~(bcc : string)
    ~(subject : string) ~(email_date : string)
    ~(attachments_json : string)
    ~(action_score : int option) ~(importance_score : int option)
    ~(reply_by : string) ~(ingested_at : string)
    ?(on_done : (float -> unit) option)
    () : (unit, string) result =
  let t0 = Unix.gettimeofday () in
  let doc_id = normalize_doc_id doc_id in
  let sql = {|
    INSERT INTO emails
      (doc_id, embed_model, triage_model, sender, recipient, cc, bcc,
       subject, email_date, attachments, action_score, importance_score,
       reply_by, processed, ingested_at)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,NULLIF($9,'')::timestamptz,$10::text[],$11,$12,NULLIF($13,'')::timestamptz,FALSE,NULLIF($14,'')::timestamptz)
    ON CONFLICT (doc_id) DO UPDATE SET
      embed_model = EXCLUDED.embed_model,
      triage_model = EXCLUDED.triage_model,
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
      ingested_at = EXCLUDED.ingested_at
  |} in
  let open Caqti_type in
  let pt = t2
    (t4 string string string string)
    (t2
      (t4 string string string string)
      (t2
        (t2 string string)
        (t4 (option int) (option int) string string)))
  in
  let req = Caqti_request.Infix.(pt ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      C.exec req
        ((doc_id, embed_model, triage_model, sender),
         ((recipient, cc, bcc, subject),
          ((email_date, attachments_json),
           (action_score, importance_score, reply_by, ingested_at)))))
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
    INSERT INTO email_chunks (doc_id, chunk_index, chunk_text, embedding)
    VALUES ($1, $2, $3, $4::vector)
  |} in
  let open Caqti_type in
  let req = Caqti_request.Infix.(t4 string int string string ->. unit) ~oneshot:true sql in
  let result =
    use (fun (module C : Caqti_eio.CONNECTION) ->
      let rec run = function
        | [] -> Ok ()
        | (idx, text, emb) :: rest ->
            let vec_str = float_list_to_pgvector emb in
            (match C.exec req (doc_id, idx, text, vec_str) with
             | Ok () -> run rest
             | Error _ as e -> e)
      in
      run chunks)
  in
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "[timer] pg.insert_chunks (%d): %.3fs\n%!" (List.length chunks) dt;
  (match on_done with Some f -> f dt | None -> ());
  result

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
    match exec "DROP TABLE IF EXISTS email_chunks" with
    | Error _ as e -> e
    | Ok () ->
      match exec "DROP TABLE IF EXISTS emails" with
      | Error _ as e -> e
      | Ok () -> init_schema_with (module C : Caqti_eio.CONNECTION))

(* ---------- status queries ---------- *)

let batch_ingested_status (ids : string list)
    : ((string list * string list), string) result =
  if ids = [] then Ok ([], [])
  else
    let normed = List.map normalize_doc_id ids in
    let arr = pg_text_array normed in
    let sql = "SELECT doc_id, processed FROM emails WHERE doc_id = ANY($1::text[])" in
    let open Caqti_type in
    let req = Caqti_request.Infix.(string ->* t2 string bool) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.collect_list req arr with
      | Error _ as e -> e
      | Ok rows ->
          let ingested = List.map fst rows in
          let processed = rows |> List.filter_map (fun (id, p) -> if p then Some id else None) in
          Ok (ingested, processed))

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
    SELECT doc_id, embed_model, triage_model, sender, recipient, cc, bcc,
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
    (t4 string string string string)
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
    | Ok (Some ((doc_id, embed_model, triage_model, sender),
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
          ; ("metadata", metadata)
          ])))

let set_processed (doc_id : string) (value : bool) : (bool, string) result =
  let doc_id = normalize_doc_id doc_id in
  if value then
    let sql = {|
      UPDATE emails SET processed = TRUE, processed_at = $2::timestamptz
      WHERE doc_id = $1
    |} in
    let req = Caqti_request.Infix.(Caqti_type.(t2 string string) ->. Caqti_type.unit) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.exec req (doc_id, now_utc_iso8601 ()) with
      | Ok () -> Ok true
      | Error _ as e -> e)
  else
    let sql = {|
      UPDATE emails SET processed = FALSE, processed_at = NULL
      WHERE doc_id = $1
    |} in
    let req = Caqti_request.Infix.(Caqti_type.string ->. Caqti_type.unit) ~oneshot:true sql in
    use_ret (fun (module C : Caqti_eio.CONNECTION) ->
      match C.exec req doc_id with
      | Ok () -> Ok true
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
    | Some expr -> Printf.sprintf "(%s) DESC" expr
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
