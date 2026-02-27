open Helpers

let test_get_root_returns_405 () =
  skip_if_unreachable ();
  let code, _ = get ~path:"/" in
  Alcotest.(check int) "GET / → 405" 405 code

let test_get_ingest_returns_405 () =
  skip_if_unreachable ();
  let code, _ = get ~path:"/ingest" in
  Alcotest.(check int) "GET /ingest → 405" 405 code

let test_post_unknown_path_returns_404 () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/nonexistent" ~body_str:"{}" in
  Alcotest.(check int) "POST /nonexistent → 404" 404 code

let test_post_unknown_nested_path_returns_404 () =
  skip_if_unreachable ();
  let code, _ = post_json ~path:"/admin/nonexistent" ~body_str:"{}" in
  Alcotest.(check int) "POST /admin/nonexistent → 404" 404 code

let tests =
  [ Alcotest.test_case "GET / → 405"                    `Quick test_get_root_returns_405
  ; Alcotest.test_case "GET /ingest → 405"              `Quick test_get_ingest_returns_405
  ; Alcotest.test_case "POST unknown → 404"             `Quick test_post_unknown_path_returns_404
  ; Alcotest.test_case "POST admin/unknown → 404"       `Quick test_post_unknown_nested_path_returns_404
  ]
