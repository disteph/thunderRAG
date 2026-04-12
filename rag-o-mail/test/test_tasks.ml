open Helpers

(* ===== task/list ===== *)

let test_task_list_empty_body () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/task/list" ~body_str:"{}" in
  Alcotest.(check int) "task/list → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has tasks" true (json_has_key "tasks" json)

let test_task_list_filter_status () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/task/list"
    ~body_str:{|{"statuses":["open","in_progress"]}|} in
  Alcotest.(check int) "filtered list → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has tasks" true (json_has_key "tasks" json)

let test_task_list_with_limit () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/task/list"
    ~body_str:{|{"limit":3}|} in
  Alcotest.(check int) "limited list → 200" 200 code;
  let json = json_of_string body in
  let tasks = json_list_field "tasks" json in
  Alcotest.(check bool) "at most 3" true (List.length tasks <= 3)

(* ===== task/get ===== *)

let test_task_get_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/get" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

let test_task_get_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/get"
    ~body_str:{|{"task_id":"nonexistent-task-000"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== task/update ===== *)

let test_task_update_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/update" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

let test_task_update_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/update"
    ~body_str:{|{"task_id":"nonexistent-task-000","title":"new title"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== task/delete ===== *)

let test_task_delete_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/delete" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

let test_task_delete_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/delete"
    ~body_str:{|{"task_id":"nonexistent-task-000"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== task/reorder ===== *)

let test_task_reorder_empty () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/reorder" ~body_str:"{}" in
  Alcotest.(check int) "empty order → 400" 400 code

(* ===== task/recompute ===== *)

let test_task_recompute_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/recompute" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

(* ===== task/needs_evidence ===== *)

let test_task_needs_evidence () =
  skip_if_unreachable ();
  let code, body = get ~path:"/task/needs_evidence" in
  Alcotest.(check int) "needs_evidence → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has tasks" true (json_has_key "tasks" json)

(* ===== task/evidence ===== *)

let test_task_evidence_missing_headers () =
  skip_if_unreachable ();
  let code, _ = post_raw ~path:"/task/evidence"
    ~data:"some body" ~headers:[("Content-Type", "message/rfc822")] in
  Alcotest.(check int) "missing headers → 400" 400 code

(* ===== task/evidence_done ===== *)

let test_task_evidence_done_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/evidence_done" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

(* ===== task/chat ===== *)

let test_task_chat_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/chat" ~body_str:"{}" in
  Alcotest.(check int) "missing task_id → 400" 400 code

let test_task_chat_missing_message () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/chat"
    ~body_str:{|{"task_id":"nonexistent-task-000"}|} in
  Alcotest.(check int) "missing user_message → 400" 400 code

let test_task_chat_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/task/chat"
    ~body_str:{|{"task_id":"nonexistent-task-000","user_message":"hello"}|} in
  Alcotest.(check int) "nonexistent task → 404" 404 code

(* ===== task/chat_bodies ===== *)

let test_task_chat_bodies_missing_headers () =
  skip_if_unreachable ();
  let code, _ = post_raw ~path:"/task/chat_bodies"
    ~data:"some body" ~headers:[("Content-Type", "message/rfc822")] in
  Alcotest.(check int) "missing headers → 400" 400 code

(* ===== email/force_task ===== *)

let test_email_force_task_missing_id () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/email/force_task" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has error" true (json_has_key "error" json)

(* ===== email/recompute_tasks ===== *)

let test_email_recompute_missing_doc_id () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/email/recompute_tasks" ~body_str:"{}" in
  Alcotest.(check int) "missing doc_id → 400" 400 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has error" true (json_has_key "error" json)

let test_email_recompute_missing_raw () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/email/recompute_tasks"
    ~body_str:{|{"doc_id":"<test@example.com>"}|} in
  Alcotest.(check int) "missing raw → 400" 400 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has error" true (json_has_key "error" json)

let tests =
  [ Alcotest.test_case "task/list empty body"           `Quick test_task_list_empty_body
  ; Alcotest.test_case "task/list filter status"        `Quick test_task_list_filter_status
  ; Alcotest.test_case "task/list with limit"           `Quick test_task_list_with_limit
  ; Alcotest.test_case "task/get missing id"            `Quick test_task_get_missing_id
  ; Alcotest.test_case "task/get nonexistent"           `Quick test_task_get_nonexistent
  ; Alcotest.test_case "task/update missing id"         `Quick test_task_update_missing_id
  ; Alcotest.test_case "task/update nonexistent"        `Quick test_task_update_nonexistent
  ; Alcotest.test_case "task/delete missing id"         `Quick test_task_delete_missing_id
  ; Alcotest.test_case "task/delete nonexistent"        `Quick test_task_delete_nonexistent
  ; Alcotest.test_case "task/reorder empty"             `Quick test_task_reorder_empty
  ; Alcotest.test_case "task/recompute missing id"      `Quick test_task_recompute_missing_id
  ; Alcotest.test_case "task/needs_evidence"            `Quick test_task_needs_evidence
  ; Alcotest.test_case "task/evidence missing headers"  `Quick test_task_evidence_missing_headers
  ; Alcotest.test_case "task/evidence_done missing id"  `Quick test_task_evidence_done_missing_id
  ; Alcotest.test_case "task/chat missing id"           `Quick test_task_chat_missing_id
  ; Alcotest.test_case "task/chat missing message"      `Quick test_task_chat_missing_message
  ; Alcotest.test_case "task/chat nonexistent"          `Slow  test_task_chat_nonexistent
  ; Alcotest.test_case "task/chat_bodies missing hdr"   `Quick test_task_chat_bodies_missing_headers
  ; Alcotest.test_case "email/force_task missing id"    `Quick test_email_force_task_missing_id
  ; Alcotest.test_case "email/recompute missing doc_id" `Quick test_email_recompute_missing_doc_id
  ; Alcotest.test_case "email/recompute missing raw"    `Quick test_email_recompute_missing_raw
  ]
