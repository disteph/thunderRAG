open Helpers

(* ===== debug/stdout ===== *)

let test_debug_stdout () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/debug/stdout"
    ~body_str:"test message from integration tests" in
  Alcotest.(check int) "debug/stdout → 200" 200 code;
  Alcotest.(check bool) "body ok" true (String.trim body = "ok")

(* ===== debug/stderr ===== *)

let test_debug_stderr () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/debug/stderr"
    ~body_str:"test error from integration tests" in
  Alcotest.(check int) "debug/stderr → 200" 200 code;
  Alcotest.(check bool) "body ok" true (String.trim body = "ok")

(* ===== query/progress ===== *)

let test_query_progress_no_session () =
  skip_if_unreachable ();
  let code, body = get ~path:"/query/progress" in
  Alcotest.(check int) "progress → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "empty phase" "" (json_string_field "phase" json)

let test_query_progress_with_session () =
  skip_if_unreachable ();
  let code, body = get ~path:"/query/progress?session_id=nonexistent-sess" in
  Alcotest.(check int) "progress → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "empty phase" "" (json_string_field "phase" json)

let tests =
  [ Alcotest.test_case "debug/stdout"                `Quick test_debug_stdout
  ; Alcotest.test_case "debug/stderr"                `Quick test_debug_stderr
  ; Alcotest.test_case "query/progress no session"   `Quick test_query_progress_no_session
  ; Alcotest.test_case "query/progress with session" `Quick test_query_progress_with_session
  ]
