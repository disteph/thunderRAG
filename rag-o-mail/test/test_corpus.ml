(*
  Corpus-level integration tests.

  These tests ingest all 100 synthetic emails from Corpus_emails and then
  exercise query, task, and admin endpoints against a realistic data set.
  All tests are `Slow because they involve embedding + LLM calls.
*)

open Helpers

(* ── Ingest helpers ── *)

let corpus_ingested = ref false

let ensure_corpus_ingested () =
  if not !corpus_ingested then begin
    Printf.printf "[corpus] ingesting %d emails...\n%!" (List.length Corpus_emails.emails);
    let ok = ref 0 in
    let fail = ref 0 in
    List.iter (fun (em : Corpus_emails.email_spec) ->
      let mid = "<" ^ em.id ^ ">" in
      let raw, _ = make_rfc822
        ~from_:em.from_ ~to_:em.to_ ~cc:em.cc
        ~subject:em.subject ~date:em.date
        ~in_reply_to:em.in_reply_to
        ~message_id:mid ~body:em.body () in
      let code, body = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
      if code = 200 then incr ok
      else begin
        incr fail;
        Printf.eprintf "[corpus] FAIL %s → %d: %s\n%!" em.id code body
      end
    ) Corpus_emails.emails;
    Printf.printf "[corpus] ingested: %d ok, %d failed\n%!" !ok !fail;
    corpus_ingested := true
  end

(* ── Tests ── *)

let test_bulk_ingest () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let code, body = get ~path:"/admin/db_stats" in
  Alcotest.(check int) "db_stats 200" 200 code;
  let json = json_of_string body in
  match json_int_field "emails" json with
  | Some n ->
      Printf.printf "[corpus] db_stats.emails = %d\n%!" n;
      Alcotest.(check bool) "at least 90 emails ingested" true (n >= 90)
  | None ->
      Alcotest.fail "db_stats missing emails field"

let test_ingested_status_batch () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let ids = List.map (fun (em : Corpus_emails.email_spec) ->
    "<" ^ em.id ^ ">"
  ) (List.filteri (fun i _ -> i < 10) Corpus_emails.emails) in
  let ids_json = String.concat "," (List.map (fun s ->
    Printf.sprintf {|"%s"|} s) ids) in
  let code, body = post_json ~path:"/admin/ingested_status"
    ~body_str:(Printf.sprintf {|{"ids":[%s]}|} ids_json) in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  let ingested = json_list_field "ingested" json in
  Printf.printf "[corpus] first 10 ids: %d ingested\n%!" (List.length ingested);
  Alcotest.(check bool) "most of first 10 ingested" true (List.length ingested >= 8)

let test_query_phoenix () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"When is the Project Phoenix go-live date?","top_k":5}|} sid) in
  Alcotest.(check int) "query 200" 200 code;
  let json = json_of_string body in
  let status = json_string_field "status" json in
  Alcotest.(check bool) "status is need_messages or no_retrieval"
    true (status = "need_messages" || status = "no_retrieval");
  let sources = json_list_field "sources" json in
  Printf.printf "[corpus] Phoenix query: %d sources\n%!" (List.length sources);
  if status = "need_messages" then
    Alcotest.(check bool) "has sources" true (List.length sources > 0)

let test_query_budget () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"What was decided in the Q2 budget review?","top_k":5}|} sid) in
  Alcotest.(check int) "query 200" 200 code;
  let json = json_of_string body in
  let sources = json_list_field "sources" json in
  Printf.printf "[corpus] Budget query: %d sources\n%!" (List.length sources);
  (* At least one source should reference budget-related emails *)
  let has_budget = List.exists (fun src ->
    let doc_id = json_string_field "doc_id" src in
    try ignore (Str.search_forward (Str.regexp_string "budget") doc_id 0); true
    with Not_found -> false
  ) sources in
  Printf.printf "[corpus] Budget query has budget source: %b\n%!" has_budget

let test_query_security_incident () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"What happened in the security incident? Was any customer data compromised?","top_k":5}|} sid) in
  Alcotest.(check int) "query 200" 200 code;
  let json = json_of_string body in
  let sources = json_list_field "sources" json in
  Printf.printf "[corpus] Security query: %d sources\n%!" (List.length sources)

let test_query_cross_thread () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"What infrastructure changes were made due to both Project Phoenix and the BigCorp deal?","top_k":8}|} sid) in
  Alcotest.(check int) "query 200" 200 code;
  let json = json_of_string body in
  let sources = json_list_field "sources" json in
  Printf.printf "[corpus] Cross-thread query: %d sources\n%!" (List.length sources);
  (* Should pull from multiple threads *)
  Alcotest.(check bool) "multiple sources" true (List.length sources >= 2)

let test_query_outage () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"What caused the production database outage and what action items came out of the post-mortem?","top_k":5}|} sid) in
  Alcotest.(check int) "query 200" 200 code;
  let json = json_of_string body in
  let sources = json_list_field "sources" json in
  Printf.printf "[corpus] Outage query: %d sources\n%!" (List.length sources)

let test_task_list_after_ingest () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  (* Give the daemon a moment to process triage *)
  Unix.sleepf 2.0;
  let code, body = post_json ~path:"/task/list" ~body_str:"{}" in
  Alcotest.(check int) "task/list 200" 200 code;
  let json = json_of_string body in
  let tasks = json_list_field "tasks" json in
  Printf.printf "[corpus] tasks after ingest: %d\n%!" (List.length tasks)

let test_fyi_list_after_ingest () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let code, body = get ~path:"/fyi/list" in
  Alcotest.(check int) "fyi/list 200" 200 code;
  let json = json_of_string body in
  let fyis = json_list_field "fyis" json in
  Printf.printf "[corpus] FYIs after ingest: %d\n%!" (List.length fyis)

let test_memory_crud_with_corpus () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  (* Create a memory *)
  let code, body = post_json ~path:"/memory/create"
    ~body_str:{|{"text":"Always prefer concise email summaries when reporting to executives."}|} in
  Alcotest.(check int) "memory/create 200" 200 code;
  let json = json_of_string body in
  let mem_id = json_string_field "memory_id" json in
  Alcotest.(check bool) "has memory_id" true (mem_id <> "");
  (* Verify it appears in list *)
  let code2, body2 = get ~path:"/memory/list" in
  Alcotest.(check int) "memory/list 200" 200 code2;
  let json2 = json_of_string body2 in
  let memories = json_list_field "memories" json2 in
  let found = List.exists (fun m ->
    json_string_field "memory_id" m = mem_id
  ) memories in
  Alcotest.(check bool) "memory in list" true found;
  (* Clean up *)
  let code3, _ = post_json ~path:"/memory/delete"
    ~body_str:(Printf.sprintf {|{"memory_id":"%s"}|} mem_id) in
  Alcotest.(check int) "memory/delete 200" 200 code3

let test_delete_single_email () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  (* Delete a standalone email that shouldn't affect test threads *)
  let mid = "<wiki-001@acme.com>" in
  let code, body = post_json ~path:"/admin/delete"
    ~body_str:(Printf.sprintf {|{"id":"%s"}|} mid) in
  Alcotest.(check int) "delete 200" 200 code;
  let json = json_of_string body in
  let ok = match json with `Assoc kv -> List.assoc_opt "ok" kv = Some (`Bool true) | _ -> false in
  Alcotest.(check bool) "ok=true" true ok;
  (* Verify it's gone *)
  let code2, body2 = post_json ~path:"/admin/ingested_status"
    ~body_str:(Printf.sprintf {|{"ids":["%s"]}|} mid) in
  Alcotest.(check int) "status 200" 200 code2;
  let json2 = json_of_string body2 in
  let ingested = json_list_field "ingested" json2 in
  Alcotest.(check int) "not ingested" 0 (List.length ingested)

let test_db_stats () =
  skip_if_unreachable ();
  ensure_corpus_ingested ();
  let code, body = get ~path:"/admin/db_stats" in
  Alcotest.(check int) "db_stats 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has emails" true (json_has_key "emails" json);
  Alcotest.(check bool) "has chunks" true (json_has_key "chunks" json);
  Printf.printf "[corpus] db_stats: %s\n%!" body

let tests =
  [ Alcotest.test_case "bulk ingest 100"         `Slow test_bulk_ingest
  ; Alcotest.test_case "ingested_status batch"    `Slow test_ingested_status_batch
  ; Alcotest.test_case "query: Phoenix go-live"   `Slow test_query_phoenix
  ; Alcotest.test_case "query: budget review"     `Slow test_query_budget
  ; Alcotest.test_case "query: security incident" `Slow test_query_security_incident
  ; Alcotest.test_case "query: cross-thread"      `Slow test_query_cross_thread
  ; Alcotest.test_case "query: outage post-mortem" `Slow test_query_outage
  ; Alcotest.test_case "tasks after ingest"       `Slow test_task_list_after_ingest
  ; Alcotest.test_case "FYIs after ingest"        `Slow test_fyi_list_after_ingest
  ; Alcotest.test_case "memory CRUD with corpus"  `Slow test_memory_crud_with_corpus
  ; Alcotest.test_case "delete single email"      `Slow test_delete_single_email
  ; Alcotest.test_case "db_stats after corpus"    `Slow test_db_stats
  ]
