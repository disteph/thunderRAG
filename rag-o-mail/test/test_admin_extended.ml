open Helpers

(* ===== GET endpoints — smoke tests (server up → 200) ===== *)

let test_get_timers () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/timers" in
  Alcotest.(check int) "GET /admin/timers → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "returns list" true (match json with `List _ -> true | _ -> false)

let test_get_queue_debug () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/queue_debug" in
  Alcotest.(check int) "GET /admin/queue_debug → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has server_time" true (json_has_key "server_time" json)

let test_get_config () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/config" in
  Alcotest.(check int) "GET /admin/config → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has settings" true (json_has_key "settings" json)

let test_get_db_stats () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/db_stats" in
  Alcotest.(check int) "GET /admin/db_stats → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has tables" true (json_has_key "tables" json)

let test_get_models () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/models" in
  Alcotest.(check int) "GET /admin/models → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has models" true (json_has_key "models" json)

(* ===== Settings endpoints ===== *)

let test_get_settings () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/settings" in
  Alcotest.(check int) "GET /admin/settings → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has settings" true (json_has_key "settings" json);
  Alcotest.(check bool) "has path" true (json_has_key "path" json)

let test_get_settings_defaults () =
  skip_if_unreachable ();
  let code, _ = get ~path:"/admin/settings/defaults" in
  (* May be 200 or 404 depending on whether defaults file exists *)
  Alcotest.(check bool) "200 or 404" true (code = 200 || code = 404)

let test_post_settings_roundtrip () =
  skip_if_unreachable ();
  (* Read current settings *)
  let _, orig_body = get ~path:"/admin/settings" in
  let orig = json_of_string orig_body in
  let orig_settings = match orig with
    | `Assoc kv -> (match List.assoc_opt "settings" kv with Some s -> s | None -> `Null)
    | _ -> `Null
  in
  (* POST an empty patch (no-op merge) *)
  let code, body = post_json ~path:"/admin/settings" ~body_str:"{}" in
  Alcotest.(check int) "POST /admin/settings → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok=true" true (json_bool_field "ok" json = Some true);
  (* Verify settings unchanged *)
  let _, new_body = get ~path:"/admin/settings" in
  let new_json = json_of_string new_body in
  let new_settings = match new_json with
    | `Assoc kv -> (match List.assoc_opt "settings" kv with Some s -> s | None -> `Null)
    | _ -> `Null
  in
  Alcotest.(check string) "settings unchanged"
    (Yojson.Safe.to_string orig_settings)
    (Yojson.Safe.to_string new_settings)

let test_post_settings_bad_json () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/settings" ~body_str:"not json" in
  Alcotest.(check int) "bad JSON → 400" 400 code

(* ===== Prompts endpoints ===== *)

let test_get_prompts () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/prompts" in
  Alcotest.(check int) "GET /admin/prompts → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has prompts" true (json_has_key "prompts" json)

let test_get_prompts_defaults () =
  skip_if_unreachable ();
  let code, _ = get ~path:"/admin/prompts/defaults" in
  Alcotest.(check bool) "200 or 404" true (code = 200 || code = 404)

let test_post_prompts_bad_json () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/prompts" ~body_str:"not json" in
  Alcotest.(check int) "bad JSON → 400" 400 code

(* ===== Pause endpoints ===== *)

let test_pause_get () =
  skip_if_unreachable ();
  let code, body = get ~path:"/admin/pause" in
  Alcotest.(check int) "GET /admin/pause → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has tasks_paused" true (json_has_key "tasks_paused" json);
  Alcotest.(check bool) "has ingest_paused" true (json_has_key "ingest_paused" json)

let test_pause_roundtrip () =
  skip_if_unreachable ();
  (* Save current state *)
  let _, orig = get ~path:"/admin/pause" in
  let orig_json = json_of_string orig in
  let was_tasks = json_bool_field "tasks_paused" orig_json = Some true in
  let was_ingest = json_bool_field "ingest_paused" orig_json = Some true in
  (* Pause both *)
  let code, body = post_json ~path:"/admin/pause"
    ~body_str:{|{"tasks":true,"ingest":true}|} in
  Alcotest.(check int) "pause 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok" true (json_bool_field "ok" json = Some true);
  Alcotest.(check bool) "tasks paused" true (json_bool_field "tasks_paused" json = Some true);
  Alcotest.(check bool) "ingest paused" true (json_bool_field "ingest_paused" json = Some true);
  (* Restore *)
  let restore = Printf.sprintf {|{"tasks":%b,"ingest":%b}|} was_tasks was_ingest in
  let code2, _ = post_json ~path:"/admin/pause" ~body_str:restore in
  Alcotest.(check int) "restore 200" 200 code2

(* ===== Reload ===== *)

let test_reload () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/reload" ~body_str:"{}" in
  Alcotest.(check int) "POST /admin/reload → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok" true (json_bool_field "ok" json = Some true)

(* ===== Clear endpoints ===== *)

(* These are destructive — we only test that they respond correctly, not their side effects *)

let test_clear_ingest_queue () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/clear_ingest_queue" ~body_str:"{}" in
  Alcotest.(check int) "clear_ingest_queue → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok" true (json_bool_field "ok" json = Some true)

let test_clear_pending_processed () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/clear_pending_processed" ~body_str:"{}" in
  Alcotest.(check int) "clear_pending_processed → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok" true (json_bool_field "ok" json = Some true)

(* ===== email_detail ===== *)

let test_email_detail_missing_doc_id () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/email_detail" ~body_str:"{}" in
  Alcotest.(check int) "missing doc_id → 400" 400 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has error" true (json_string_field "error" json <> "")

let test_email_detail_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/email_detail"
    ~body_str:{|{"doc_id":"<nonexistent@example.com>"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== ingested_detail ===== *)

let test_ingested_detail_missing_id () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/ingested_detail" ~body_str:"{}" in
  Alcotest.(check int) "missing id → 400" 400 code

let test_ingested_detail_nonexistent () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/ingested_detail"
    ~body_str:{|{"id":"<nonexistent@example.com>"}|} in
  Alcotest.(check int) "nonexistent → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ingested=false" true (json_bool_field "ingested" json = Some false)

(* ===== extract_body ===== *)

let test_extract_body_missing_raw () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/extract_body"
    ~body_str:{|{"summarize":false}|} in
  Alcotest.(check int) "missing raw → 400" 400 code

let test_extract_body_basic () =
  skip_if_unreachable ();
  let raw, _ = make_rfc822 ~subject:"Extract test" ~body:"Hello world" () in
  let payload = Printf.sprintf {|{"raw":%s,"doc_id":"<extract-test@example.com>","summarize":false}|}
    (Yojson.Safe.to_string (`String raw)) in
  let code, body = post_json ~path:"/admin/extract_body" ~body_str:payload in
  Alcotest.(check int) "extract_body → 200" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "has body_text" true (json_string_field "body_text" json <> "");
  Alcotest.(check bool) "has metadata" true (json_has_key "metadata" json)

(* ===== mark_processed / mark_unprocessed with valid id ===== *)

let test_mark_processed_nonexistent () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/mark_processed"
    ~body_str:{|{"id":"<nonexistent-mark@example.com>"}|} in
  (* Non-existent email gets queued for pending processing *)
  Alcotest.(check int) "nonexistent → 200 (queued)" 200 code;
  let json = json_of_string body in
  Alcotest.(check bool) "ok=true" true (json_bool_field "ok" json = Some true)

let test_mark_unprocessed_nonexistent () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/mark_unprocessed"
    ~body_str:{|{"id":"<nonexistent-unmark@example.com>"}|} in
  Alcotest.(check int) "nonexistent → 404" 404 code

(* ===== ingested_status with actual IDs ===== *)

let test_ingested_status_with_ids () =
  skip_if_unreachable ();
  let code, body = post_json ~path:"/admin/ingested_status"
    ~body_str:{|{"ids":["<nonexistent-1@example.com>","<nonexistent-2@example.com>"]}|} in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  let ingested = json_list_field "ingested" json in
  Alcotest.(check int) "none ingested" 0 (List.length ingested)

let tests =
  (* GET smoke tests *)
  [ Alcotest.test_case "GET /admin/timers"            `Quick test_get_timers
  ; Alcotest.test_case "GET /admin/queue_debug"       `Quick test_get_queue_debug
  ; Alcotest.test_case "GET /admin/config"            `Quick test_get_config
  ; Alcotest.test_case "GET /admin/db_stats"          `Quick test_get_db_stats
  ; Alcotest.test_case "GET /admin/models"            `Slow  test_get_models
  (* Settings *)
  ; Alcotest.test_case "GET /admin/settings"          `Quick test_get_settings
  ; Alcotest.test_case "GET settings/defaults"        `Quick test_get_settings_defaults
  ; Alcotest.test_case "POST settings roundtrip"      `Quick test_post_settings_roundtrip
  ; Alcotest.test_case "POST settings bad JSON"       `Quick test_post_settings_bad_json
  (* Prompts *)
  ; Alcotest.test_case "GET /admin/prompts"           `Quick test_get_prompts
  ; Alcotest.test_case "GET prompts/defaults"         `Quick test_get_prompts_defaults
  ; Alcotest.test_case "POST prompts bad JSON"        `Quick test_post_prompts_bad_json
  (* Pause *)
  ; Alcotest.test_case "GET /admin/pause"             `Quick test_pause_get
  ; Alcotest.test_case "pause roundtrip"              `Quick test_pause_roundtrip
  (* Reload *)
  ; Alcotest.test_case "POST /admin/reload"           `Slow  test_reload
  (* Clear *)
  ; Alcotest.test_case "clear_ingest_queue"           `Quick test_clear_ingest_queue
  ; Alcotest.test_case "clear_pending_processed"      `Quick test_clear_pending_processed
  (* Email detail / ingested detail *)
  ; Alcotest.test_case "email_detail missing doc_id"  `Quick test_email_detail_missing_doc_id
  ; Alcotest.test_case "email_detail nonexistent"     `Quick test_email_detail_nonexistent
  ; Alcotest.test_case "ingested_detail missing id"   `Quick test_ingested_detail_missing_id
  ; Alcotest.test_case "ingested_detail nonexistent"  `Quick test_ingested_detail_nonexistent
  (* Extract body *)
  ; Alcotest.test_case "extract_body missing raw"     `Quick test_extract_body_missing_raw
  ; Alcotest.test_case "extract_body basic"           `Quick test_extract_body_basic
  (* Mark processed / unprocessed *)
  ; Alcotest.test_case "mark_processed nonexistent"   `Quick test_mark_processed_nonexistent
  ; Alcotest.test_case "mark_unprocessed nonexistent" `Quick test_mark_unprocessed_nonexistent
  ; Alcotest.test_case "ingested_status with IDs"     `Quick test_ingested_status_with_ids
  ]
