open Helpers

let test_session_reset_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/session/reset" ~body_str:"{}" in
  Alcotest.(check int) "missing session_id → 400" 400 code

let test_session_reset_empty_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/session/reset"
    ~body_str:{|{"session_id":""}|} in
  Alcotest.(check int) "empty session_id → 400" 400 code

let test_session_reset_nonexistent () =
  skip_if_unreachable ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/admin/session/reset"
    ~body_str:(Printf.sprintf {|{"session_id":"%s"}|} sid) in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "status=ok" "ok" (json_string_field "status" json);
  Alcotest.(check string) "session_id matches" sid (json_string_field "session_id" json)

let test_session_debug_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/session/debug" ~body_str:"{}" in
  Alcotest.(check int) "missing session_id → 400" 400 code

let test_session_debug_nonexistent () =
  skip_if_unreachable ();
  let sid = fresh_session_id () in
  let code, body = post_json ~path:"/admin/session/debug"
    ~body_str:(Printf.sprintf {|{"session_id":"%s"}|} sid) in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "session_id matches" sid (json_string_field "session_id" json);
  let tail = json_list_field "tail" json in
  Alcotest.(check int) "tail is empty" 0 (List.length tail)

let test_bulk_state_reset () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/bulk_state/reset" ~body_str:"{}" in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "status=ok" "ok" (json_string_field "status" json)

let test_admin_reset () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/reset" ~body_str:"{}" in
  Alcotest.(check int) "status 200" 200 code

let test_ingested_status_empty () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/ingested_status"
    ~body_str:{|{"ids":[]}|} in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  let ingested = json_list_field "ingested" json in
  Alcotest.(check int) "no ingested" 0 (List.length ingested)

let test_mark_processed_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/mark_processed" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let test_mark_unprocessed_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/mark_unprocessed" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let tests =
  [ Alcotest.test_case "session/reset missing id"     `Quick test_session_reset_missing_id
  ; Alcotest.test_case "session/reset empty id"       `Quick test_session_reset_empty_id
  ; Alcotest.test_case "session/reset nonexistent"    `Quick test_session_reset_nonexistent
  ; Alcotest.test_case "session/debug missing id"     `Quick test_session_debug_missing_id
  ; Alcotest.test_case "session/debug nonexistent"    `Quick test_session_debug_nonexistent
  ; Alcotest.test_case "bulk_state/reset"             `Quick test_bulk_state_reset
  ; Alcotest.test_case "admin/reset"                  `Slow  test_admin_reset
  ; Alcotest.test_case "ingested_status empty"        `Quick test_ingested_status_empty
  ; Alcotest.test_case "mark_processed missing id"    `Quick test_mark_processed_missing_id
  ; Alcotest.test_case "mark_unprocessed missing id"  `Quick test_mark_unprocessed_missing_id
  ]
