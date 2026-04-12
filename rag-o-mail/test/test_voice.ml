open Helpers

(* Voice endpoints are hardware-dependent (mic, piper, whisper).
   We only smoke-test parameter validation and error handling. *)

(* ===== synthesize ===== *)

let test_synthesize_empty_text () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/synthesize" ~body_str:{|{"text":""}|} in
  Alcotest.(check int) "empty text → 400" 400 code

let test_synthesize_missing_text () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/synthesize" ~body_str:"{}" in
  Alcotest.(check int) "missing text → 400" 400 code

(* ===== mic/result — nonexistent session ===== *)

let test_mic_result_nonexistent () =
  skip_if_unreachable ();
  let code, body = get ~path:"/mic/result/nonexistent-session" in
  Alcotest.(check int) "mic/result → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "empty text" "" (json_string_field "text" json)

let tests =
  [ Alcotest.test_case "synthesize empty text"      `Quick test_synthesize_empty_text
  ; Alcotest.test_case "synthesize missing text"    `Quick test_synthesize_missing_text
  ; Alcotest.test_case "mic/result nonexistent"     `Quick test_mic_result_nonexistent
  ]
