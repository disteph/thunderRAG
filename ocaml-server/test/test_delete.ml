open Helpers

let test_delete_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/delete"
    ~body_str:{|{"id":"<nonexistent-delete-test@example.com>"}|} in
  Alcotest.(check int) "delete nonexistent → 200" 200 code

let test_ingest_then_delete () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822
    ~subject:"Delete test email"
    ~body:"This email will be ingested and then deleted."
    ~message_id:"<test-delete-roundtrip@example.com>"
    () in
  let code1, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "ingest 200" 200 code1;
  let code2, _ = post_json ~path:"/admin/delete"
    ~body_str:(Printf.sprintf {|{"id":"%s"}|} mid) in
  Alcotest.(check int) "delete 200" 200 code2

let test_delete_then_status_empty () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822
    ~subject:"Delete-status test"
    ~body:"Ingest, delete, then check status."
    () in
  let code1, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "ingest 200" 200 code1;
  let _ = post_json ~path:"/admin/delete"
    ~body_str:(Printf.sprintf {|{"id":"%s"}|} mid) in
  let code3, body = post_json ~path:"/admin/ingested_status"
    ~body_str:(Printf.sprintf {|{"ids":["%s"]}|} mid) in
  Alcotest.(check int) "status 200" 200 code3;
  let json = json_of_string body in
  let ingested = json_list_field "ingested" json in
  Alcotest.(check int) "not ingested after delete" 0 (List.length ingested)

let tests =
  [ Alcotest.test_case "delete nonexistent"       `Quick test_delete_nonexistent
  ; Alcotest.test_case "ingest then delete"       `Slow  test_ingest_then_delete
  ; Alcotest.test_case "delete then status empty" `Slow  test_delete_then_status_empty
  ]
