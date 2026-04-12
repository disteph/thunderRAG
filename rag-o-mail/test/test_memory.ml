open Helpers

(* ===== memory/list ===== *)

let test_memory_list () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/memory/list" ~body_str:"{}" in
  Alcotest.(check int) "memory/list → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has memories" true (json_has_key "memories" json)

let test_memory_list_enabled_only () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/memory/list"
    ~body_str:{|{"enabled_only":true}|} in
  Alcotest.(check int) "enabled_only → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has memories" true (json_has_key "memories" json)

(* ===== memory/create ===== *)

let test_memory_create_missing_text () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/create" ~body_str:"{}" in
  Alcotest.(check int) "missing text → 400" 400 code

(* ===== memory/create + get + update + delete roundtrip ===== *)

let test_memory_crud_roundtrip () =
  skip_if_unreachable ();
  let mid = Printf.sprintf "test-mem-%08x" (Random.bits ()) in
  (* Create *)
  let payload = Printf.sprintf
    {|{"memory_id":"%s","text":"Test memory for integration tests"}|} mid in
  let code, body = post_json ~path:"/memory/create" ~body_str:payload in
  Alcotest.(check int) "create → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check string) "status ok" "ok" (json_string_field "status" json);
  Alcotest.(check string) "memory_id matches" mid (json_string_field "memory_id" json);
  (* Get *)
  let get_payload = Printf.sprintf {|{"memory_id":"%s"}|} mid in
  let code2, body2 = post_json ~path:"/memory/get" ~body_str:get_payload in
  Alcotest.(check int) "get → 200" 200 code2;
  let json2 = json_of_string body2 in
  Alcotest.(check bool) "has text" true (json_string_field "text" json2 <> "");
  (* Update *)
  let upd_payload = Printf.sprintf
    {|{"memory_id":"%s","text":"Updated test memory","enabled":false}|} mid in
  let code3, body3 = post_json ~path:"/memory/update" ~body_str:upd_payload in
  Alcotest.(check int) "update → 200" 200 code3;
  let json3 = json_of_string body3 in
  Alcotest.(check string) "update ok" "ok" (json_string_field "status" json3);
  (* Delete *)
  let del_payload = Printf.sprintf {|{"memory_id":"%s"}|} mid in
  let code4, body4 = post_json ~path:"/memory/delete" ~body_str:del_payload in
  Alcotest.(check int) "delete → 200" 200 code4;
  let json4 = json_of_string body4 in
  Alcotest.(check string) "delete ok" "ok" (json_string_field "status" json4);
  (* Get again — should be 404 *)
  let code5, _ = post_json ~path:"/memory/get" ~body_str:get_payload in
  Alcotest.(check int) "get after delete → 404" 404 code5

(* ===== memory/get missing id ===== *)

let test_memory_get_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/get" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let test_memory_get_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/get"
    ~body_str:{|{"memory_id":"nonexistent-memory-000"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== memory/update missing id ===== *)

let test_memory_update_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/update" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let test_memory_update_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/update"
    ~body_str:{|{"memory_id":"nonexistent-memory-000","text":"x"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== memory/delete missing id ===== *)

let test_memory_delete_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/delete" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let test_memory_delete_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/memory/delete"
    ~body_str:{|{"memory_id":"nonexistent-memory-000"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

let tests =
  [ Alcotest.test_case "memory/list"                `Quick test_memory_list
  ; Alcotest.test_case "memory/list enabled_only"   `Quick test_memory_list_enabled_only
  ; Alcotest.test_case "memory/create missing text" `Quick test_memory_create_missing_text
  ; Alcotest.test_case "memory CRUD roundtrip"      `Slow  test_memory_crud_roundtrip
  ; Alcotest.test_case "memory/get missing id"      `Quick test_memory_get_missing_id
  ; Alcotest.test_case "memory/get nonexistent"     `Quick test_memory_get_nonexistent
  ; Alcotest.test_case "memory/update missing id"   `Quick test_memory_update_missing_id
  ; Alcotest.test_case "memory/update nonexistent"  `Quick test_memory_update_nonexistent
  ; Alcotest.test_case "memory/delete missing id"   `Quick test_memory_delete_missing_id
  ; Alcotest.test_case "memory/delete nonexistent"  `Quick test_memory_delete_nonexistent
  ]
