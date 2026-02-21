open Helpers

(* Ingest a small corpus for query tests. Returns (raw, mid) list. *)
let ingest_test_corpus () =
  let emails = [
    make_rfc822
      ~from_:"Alice <alice@example.com>"
      ~to_:"Bob <bob@example.com>"
      ~subject:"Project Falcon launch date"
      ~body:"Hi Bob,\n\n\
             The launch date for Project Falcon is confirmed for March 15, 2025.\n\
             Please make sure the QA team is ready by March 10.\n\n\
             Thanks,\nAlice"
      ~message_id:"<falcon-launch@example.com>"
      ~date:"Wed, 05 Feb 2025 09:00:00 +0000"
      ();
    make_rfc822
      ~from_:"Bob <bob@example.com>"
      ~to_:"Alice <alice@example.com>"
      ~subject:"Re: Project Falcon launch date"
      ~body:"Hi Alice,\n\n\
             Got it. QA will be ready by March 10. I've also scheduled a dry run for March 12.\n\
             The staging environment is already set up.\n\n\
             Best,\nBob"
      ~message_id:"<falcon-reply@example.com>"
      ~date:"Wed, 05 Feb 2025 14:30:00 +0000"
      ();
    make_rfc822
      ~from_:"Carol <carol@example.com>"
      ~to_:"Team <team@example.com>"
      ~subject:"Q1 budget review meeting"
      ~body:"Hi team,\n\n\
             Reminder: the Q1 budget review meeting is scheduled for February 20, 2025 at 2pm.\n\
             Please bring your department expense reports.\n\n\
             Regards,\nCarol"
      ~message_id:"<budget-review@example.com>"
      ~date:"Mon, 10 Feb 2025 08:00:00 +0000"
      ();
  ] in
  List.iter (fun (raw, mid) ->
    let code, body = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
    if code <> 200 then
      Alcotest.fail (Printf.sprintf "Corpus ingest failed for %s: %d %s" mid code body)
  ) emails;
  emails

(* ---------- Phase 1: /query ---------- *)

let test_query_missing_session_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/query" ~body_str:{|{"question":"hello"}|} in
  Alcotest.(check int) "missing session_id → 400" 400 code

let test_query_missing_question () =
  skip_if_unreachable ();
  let sid = fresh_session_id () in
  let code, _ = post_json ~path:"/query"
    ~body_str:(Printf.sprintf {|{"session_id":"%s"}|} sid) in
  Alcotest.(check int) "missing question → 400" 400 code

let test_query_empty_question () =
  skip_if_unreachable ();
  let sid = fresh_session_id () in
  let code, _ = post_json ~path:"/query"
    ~body_str:(Printf.sprintf {|{"session_id":"%s","question":""}|} sid) in
  Alcotest.(check int) "empty question → 400" 400 code

let test_query_returns_need_messages () =
  skip_if_unreachable ();
  let _ = ingest_test_corpus () in
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"When is the Project Falcon launch date?","top_k":3}|} sid) in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "status=need_messages" "need_messages" (json_string_field "status" json);
  let mids = json_list_field "message_ids" json in
  Alcotest.(check bool) "has message_ids" true (List.length mids > 0);
  let sources = json_list_field "sources" json in
  Alcotest.(check bool) "has sources" true (List.length sources > 0)

let test_query_sources_have_doc_id () =
  skip_if_unreachable ();
  let _ = ingest_test_corpus () in
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"budget review","top_k":2}|} sid) in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  let sources = json_list_field "sources" json in
  List.iter (fun src ->
    let doc_id = json_string_field "doc_id" src in
    Alcotest.(check bool) "source has doc_id" true (doc_id <> "")
  ) sources

(* ---------- Phase 2: /query/evidence ---------- *)

let test_evidence_missing_headers () =
  skip_if_unreachable ();
  let code, _ = post_raw ~path:"/query/evidence" ~data:"some data" ~headers:[] in
  Alcotest.(check int) "missing headers → 400" 400 code

let test_evidence_unknown_request_id () =
  skip_if_unreachable ();
  let code, _ = post_raw ~path:"/query/evidence" ~data:"some data"
    ~headers:[
      ("X-RAG-Request-Id", "nonexistent-request-id");
      ("X-Thunderbird-Message-Id", "<fake@example.com>");
    ] in
  Alcotest.(check int) "unknown request_id → 404" 404 code

let test_evidence_upload_succeeds () =
  skip_if_unreachable ();
  let _ = ingest_test_corpus () in
  let sid = fresh_session_id () in
  let code1, body1 = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"What is the launch date?","top_k":2}|} sid) in
  Alcotest.(check int) "query 200" 200 code1;
  let json = json_of_string body1 in
  let request_id = json_string_field "request_id" json in
  let mids = json_list_field "message_ids" json in
  Alcotest.(check bool) "has mids" true (List.length mids > 0);
  let mid = match List.hd mids with `String s -> s | _ -> "" in
  let raw, _ = make_rfc822
    ~subject:"Evidence for test"
    ~body:"This is the evidence body text."
    ~message_id:mid
    () in
  let code2, body2 = post_raw ~path:"/query/evidence" ~data:raw
    ~headers:[
      ("Content-Type", "message/rfc822");
      ("X-RAG-Request-Id", request_id);
      ("X-Thunderbird-Message-Id", mid);
    ] in
  Alcotest.(check int) "evidence 200" 200 code2;
  let json2 = json_of_string body2 in
  Alcotest.(check string) "status=ok" "ok" (json_string_field "status" json2)

(* ---------- Phase 3: /query/complete ---------- *)

let test_complete_missing_fields () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/query/complete" ~body_str:"{}" in
  Alcotest.(check int) "missing fields → 400" 400 code

let test_complete_unknown_request_id () =
  skip_if_unreachable ();
  let sid = fresh_session_id () in
  let code, _ = post_json ~path:"/query/complete"
    ~body_str:(Printf.sprintf {|{"session_id":"%s","request_id":"nonexistent"}|} sid) in
  Alcotest.(check int) "unknown request_id → 404" 404 code

let test_complete_session_mismatch () =
  skip_if_unreachable ();
  let _ = ingest_test_corpus () in
  let sid = fresh_session_id () in
  let code1, body1 = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"launch date?","top_k":1}|} sid) in
  Alcotest.(check int) "query 200" 200 code1;
  let json = json_of_string body1 in
  let request_id = json_string_field "request_id" json in
  let code, _ = post_json ~path:"/query/complete"
    ~body_str:(Printf.sprintf {|{"session_id":"wrong-session","request_id":"%s"}|} request_id) in
  Alcotest.(check int) "session mismatch → 400" 400 code

let test_complete_missing_evidence () =
  skip_if_unreachable ();
  let _ = ingest_test_corpus () in
  let sid = fresh_session_id () in
  let code1, body1 = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"launch date?","top_k":2}|} sid) in
  Alcotest.(check int) "query 200" 200 code1;
  let json = json_of_string body1 in
  let request_id = json_string_field "request_id" json in
  let mids = json_list_field "message_ids" json in
  Alcotest.(check bool) "has mids" true (List.length mids > 0);
  let code, body = post_json ~path:"/query/complete"
    ~body_str:(Printf.sprintf {|{"session_id":"%s","request_id":"%s"}|} sid request_id) in
  Alcotest.(check int) "missing evidence → 400" 400 code;
  let json2 = json_of_string body in
  Alcotest.(check string) "status=missing_evidence" "missing_evidence" (json_string_field "status" json2)

(* ---------- Full roundtrip ---------- *)

let test_full_roundtrip () =
  skip_if_unreachable ();
  let corpus = ingest_test_corpus () in
  let corpus_tbl = Hashtbl.create 8 in
  List.iter (fun (raw, mid) -> Hashtbl.replace corpus_tbl mid raw) corpus;
  let sid = fresh_session_id () in

  (* Phase 1 *)
  let code1, body1 = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"When is the Project Falcon launch date?","top_k":3}|} sid) in
  Alcotest.(check int) "query 200" 200 code1;
  let json1 = json_of_string body1 in
  Alcotest.(check string) "need_messages" "need_messages" (json_string_field "status" json1);
  let request_id = json_string_field "request_id" json1 in
  let mids = json_list_field "message_ids" json1
    |> List.filter_map (function `String s -> Some s | _ -> None) in
  Alcotest.(check bool) "has mids" true (List.length mids > 0);

  (* Phase 2 *)
  List.iter (fun mid ->
    let raw = match Hashtbl.find_opt corpus_tbl mid with
      | Some r -> r
      | None ->
          let r, _ = make_rfc822 ~subject:"(placeholder)" ~body:"n/a" ~message_id:mid () in
          r
    in
    let code, body = post_raw ~path:"/query/evidence" ~data:raw
      ~headers:[
        ("Content-Type", "message/rfc822");
        ("X-RAG-Request-Id", request_id);
        ("X-Thunderbird-Message-Id", mid);
      ] in
    if code <> 200 then
      Alcotest.fail (Printf.sprintf "Evidence upload failed for %s: %d %s" mid code body)
  ) mids;

  (* Phase 3 *)
  let code3, body3 = post_json ~path:"/query/complete"
    ~body_str:(Printf.sprintf {|{"session_id":"%s","request_id":"%s"}|} sid request_id) in
  Alcotest.(check int) "complete 200" 200 code3;
  let json3 = json_of_string body3 in
  let answer = json_string_field "answer" json3 in
  Alcotest.(check bool) "answer non-empty" true (String.length answer > 0);
  let sources = json_list_field "sources" json3 in
  Alcotest.(check bool) "has sources" true (List.length sources > 0);
  let answer_lower = String.lowercase_ascii answer in
  let relevant = List.exists (fun kw -> String.length kw > 0 &&
    (try ignore (Str.search_forward (Str.regexp_string kw) answer_lower 0); true
     with Not_found -> false))
    ["march"; "falcon"; "launch"; "15"]
  in
  Alcotest.(check bool) "answer mentions Falcon/March/launch/15" true relevant

let test_session_state_persists () =
  skip_if_unreachable ();
  let corpus = ingest_test_corpus () in
  let corpus_tbl = Hashtbl.create 8 in
  List.iter (fun (raw, mid) -> Hashtbl.replace corpus_tbl mid raw) corpus;
  let sid = fresh_session_id () in

  (* First turn *)
  let _, body1 = post_json ~path:"/query"
    ~body_str:(Printf.sprintf
      {|{"session_id":"%s","question":"Who scheduled the budget review?","top_k":3}|} sid) in
  let json1 = json_of_string body1 in
  let request_id = json_string_field "request_id" json1 in
  let mids = json_list_field "message_ids" json1
    |> List.filter_map (function `String s -> Some s | _ -> None) in
  List.iter (fun mid ->
    let raw = match Hashtbl.find_opt corpus_tbl mid with
      | Some r -> r
      | None -> let r, _ = make_rfc822 ~subject:"placeholder" ~body:"n/a" ~message_id:mid () in r
    in
    ignore (post_raw ~path:"/query/evidence" ~data:raw
      ~headers:[
        ("Content-Type", "message/rfc822");
        ("X-RAG-Request-Id", request_id);
        ("X-Thunderbird-Message-Id", mid);
      ])
  ) mids;
  let code3, _ = post_json ~path:"/query/complete"
    ~body_str:(Printf.sprintf {|{"session_id":"%s","request_id":"%s"}|} sid request_id) in
  Alcotest.(check int) "complete 200" 200 code3;

  (* Check session debug *)
  let code_dbg, body_dbg = post_json ~path:"/admin/session/debug"
    ~body_str:(Printf.sprintf {|{"session_id":"%s"}|} sid) in
  Alcotest.(check int) "debug 200" 200 code_dbg;
  let json_dbg = json_of_string body_dbg in
  let tail = json_list_field "tail" json_dbg in
  Alcotest.(check bool) "tail has >= 2 entries" true (List.length tail >= 2)

let tests =
  (* Phase 1 *)
  [ Alcotest.test_case "query: missing session_id"       `Quick test_query_missing_session_id
  ; Alcotest.test_case "query: missing question"         `Quick test_query_missing_question
  ; Alcotest.test_case "query: empty question"           `Quick test_query_empty_question
  ; Alcotest.test_case "query: returns need_messages"    `Slow  test_query_returns_need_messages
  ; Alcotest.test_case "query: sources have doc_id"      `Slow  test_query_sources_have_doc_id
  (* Phase 2 *)
  ; Alcotest.test_case "evidence: missing headers"       `Quick test_evidence_missing_headers
  ; Alcotest.test_case "evidence: unknown request_id"    `Quick test_evidence_unknown_request_id
  ; Alcotest.test_case "evidence: upload succeeds"       `Slow  test_evidence_upload_succeeds
  (* Phase 3 *)
  ; Alcotest.test_case "complete: missing fields"        `Quick test_complete_missing_fields
  ; Alcotest.test_case "complete: unknown request_id"    `Quick test_complete_unknown_request_id
  ; Alcotest.test_case "complete: session mismatch"      `Slow  test_complete_session_mismatch
  ; Alcotest.test_case "complete: missing evidence"      `Slow  test_complete_missing_evidence
  (* Full roundtrip *)
  ; Alcotest.test_case "full roundtrip"                  `Slow  test_full_roundtrip
  ; Alcotest.test_case "session state persists"          `Slow  test_session_state_persists
  ]
