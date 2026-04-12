open Helpers

(* ===== fyi/list ===== *)

let test_fyi_list () =
  skip_if_unreachable ();
  let code, body = get ~path:"/fyi/list" in
  Alcotest.(check int) "fyi/list → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "returns list" true (match json with `List _ -> true | _ -> false)

(* ===== fyi/create_task ===== *)

let test_fyi_create_task_missing_doc_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/fyi/create_task" ~body_str:"{}" in
  Alcotest.(check int) "missing doc_id → 400" 400 code

let tests =
  [ Alcotest.test_case "fyi/list"                    `Quick test_fyi_list
  ; Alcotest.test_case "fyi/create_task missing id"  `Quick test_fyi_create_task_missing_doc_id
  ]
