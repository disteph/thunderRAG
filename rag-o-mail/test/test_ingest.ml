open Helpers

let test_ingest_plain_text () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822
    ~subject:"Integration test: plain text"
    ~body:"The quick brown fox jumps over the lazy dog.\n\nThis is a test message for ThunderRAG integration testing."
    () in
  let code, body = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "status 200" 200 code;
  let json = json_of_string body in
  let ok = match json with `Assoc kv -> List.assoc_opt "ok" kv = Some (`Bool true) | _ -> false in
  Alcotest.(check bool) "ok=true" true ok

let test_ingest_html_email () =
  skip_if_unreachable ();
  let html_body = "<html><body><h1>Hello</h1><p>This is <b>bold</b> text in an HTML email.</p></body></html>" in
  let raw =
    "From: sender@example.com\r\n\
     To: receiver@example.com\r\n\
     Subject: Integration test: HTML\r\n\
     Message-Id: <test-html-ingest@example.com>\r\n\
     Date: Mon, 10 Feb 2025 10:00:00 +0000\r\n\
     MIME-Version: 1.0\r\n\
     Content-Type: text/html; charset=UTF-8\r\n\
     \r\n" ^ html_body
  in
  let code, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:"<test-html-ingest@example.com>" in
  Alcotest.(check int) "status 200" 200 code

let test_ingest_multipart_email () =
  skip_if_unreachable ();
  let boundary = "----=_Part_12345" in
  let raw = Printf.sprintf
    "From: multi@example.com\r\n\
     To: receiver@example.com\r\n\
     Subject: Integration test: multipart\r\n\
     Message-Id: <test-multipart-ingest@example.com>\r\n\
     Date: Mon, 10 Feb 2025 11:00:00 +0000\r\n\
     MIME-Version: 1.0\r\n\
     Content-Type: multipart/alternative; boundary=\"%s\"\r\n\
     \r\n\
     --%s\r\n\
     Content-Type: text/plain; charset=UTF-8\r\n\
     \r\n\
     Plain text part of the multipart email.\r\n\
     --%s\r\n\
     Content-Type: text/html; charset=UTF-8\r\n\
     \r\n\
     <html><body><p>HTML part of the multipart email.</p></body></html>\r\n\
     --%s--\r\n"
    boundary boundary boundary boundary
  in
  let code, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:"<test-multipart-ingest@example.com>" in
  Alcotest.(check int) "status 200" 200 code

let test_ingest_rfc2047_subject () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822
    ~subject:"=?UTF-8?B?VGVzdCBzdWJqZWN0IGVuY29kZWQ=?="
    ~body:"Body of the RFC2047 test email."
    () in
  let code, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "status 200" 200 code

let test_ingest_empty_body () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822 ~body:"" () in
  let code, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "status 200" 200 code

let test_ingest_duplicate_idempotent () =
  skip_if_unreachable ();
  let raw, mid = make_rfc822
    ~subject:"Duplicate test"
    ~body:"This message will be ingested twice."
    ~message_id:"<test-duplicate-ingest@example.com>"
    () in
  let code1, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "first ingest 200" 200 code1;
  let code2, _ = post_rfc822 ~path:"/ingest" ~raw ~message_id:mid in
  Alcotest.(check int) "second ingest 200" 200 code2

let tests =
  [ Alcotest.test_case "plain text"          `Slow test_ingest_plain_text
  ; Alcotest.test_case "HTML email"          `Slow test_ingest_html_email
  ; Alcotest.test_case "multipart email"     `Slow test_ingest_multipart_email
  ; Alcotest.test_case "RFC2047 subject"     `Slow test_ingest_rfc2047_subject
  ; Alcotest.test_case "empty body"          `Slow test_ingest_empty_body
  ; Alcotest.test_case "duplicate idempotent" `Slow test_ingest_duplicate_idempotent
  ]
