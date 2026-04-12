open Helpers

(* ===== ingest/status ===== *)

let test_ingest_status () =
  skip_if_unreachable ();
  let code, body = get ~path:"/ingest/status" in
  Alcotest.(check int) "ingest/status → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has pending" true (json_has_key "pending" json);
  Alcotest.(check bool) "has processing" true (json_has_key "processing" json);
  Alcotest.(check bool) "has done" true (json_has_key "done" json);
  Alcotest.(check bool) "has error" true (json_has_key "error" json)

(* ===== ingest/clear_done ===== *)

let test_ingest_clear_done () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/ingest/clear_done" ~body_str:"{}" in
  Alcotest.(check int) "clear_done → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok" true (json_bool_field "ok" json = Some true)

let tests =
  [ Alcotest.test_case "ingest/status"     `Quick test_ingest_status
  ; Alcotest.test_case "ingest/clear_done" `Quick test_ingest_clear_done
  ]
