(*
  Shared test helpers for the ThunderRAG integration test suite.

  These tests hit the running OCaml server over HTTP.  They require:
    - The OCaml server running (default http://localhost:8080)
    - Ollama running with the configured embed + LLM models pulled
    - PostgreSQL running with the thunderrag database

  Override the server URL with:
    THUNDERRAG_TEST_URL=http://host:port dune exec test/run_tests.exe
*)

let base_url () =
  match Sys.getenv_opt "THUNDERRAG_TEST_URL" with
  | Some u ->
      let u = String.trim u in
      if String.length u > 0 && u.[String.length u - 1] = '/' then
        String.sub u 0 (String.length u - 1)
      else u
  | None -> "http://127.0.0.1:8080"

(* ---------- fresh IDs ---------- *)

let fresh_session_id () =
  Printf.sprintf "test-session-%08x%04x"
    (Random.bits ()) (Random.bits () land 0xffff)

let fresh_message_id () =
  Printf.sprintf "<test-%08x%04x@example.com>"
    (Random.bits ()) (Random.bits () land 0xffff)

(* ---------- RFC822 construction ---------- *)

let make_rfc822
    ?(from_ = "Alice <alice@example.com>")
    ?(to_ = "Bob <bob@example.com>")
    ?(subject = "Test email")
    ?message_id
    ?(body = "This is a test email body.\nIt has multiple lines.")
    ?(cc = "")
    ?(date = "Mon, 10 Feb 2025 09:00:00 +0000")
    () =
  let mid = match message_id with Some m -> m | None -> fresh_message_id () in
  let headers = Buffer.create 256 in
  let add k v = Buffer.add_string headers (k ^ ": " ^ v ^ "\r\n") in
  add "From" from_;
  add "To" to_;
  if cc <> "" then add "Cc" cc;
  add "Subject" subject;
  add "Message-Id" mid;
  add "Date" date;
  add "MIME-Version" "1.0";
  add "Content-Type" "text/plain; charset=UTF-8";
  add "Content-Transfer-Encoding" "8bit";
  Buffer.add_string headers "\r\n";
  Buffer.add_string headers body;
  (Buffer.contents headers, mid)

(* ---------- HTTP helpers ---------- *)

(* We run all HTTP inside a single Eio main + switch.
   The test runner sets these refs before running tests. *)
let the_client : Cohttp_eio.Client.t option ref = ref None
let the_sw : Eio.Switch.t option ref = ref None

let client () = match !the_client with Some c -> c | None -> failwith "client not initialised"
let sw ()     = match !the_sw     with Some s -> s | None -> failwith "sw not initialised"

let json_headers =
  Http.Header.of_list [("Content-Type", "application/json")]

let read_all body =
  Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int

let post_json ~path ~body_str =
  let uri = Uri.of_string (base_url () ^ path) in
  let body = Cohttp_eio.Body.of_string body_str in
  let resp, resp_body =
    Cohttp_eio.Client.call (client ()) ~sw:(sw ()) ~headers:json_headers ~body `POST uri
  in
  let code = Http.Response.status resp |> Cohttp.Code.code_of_status in
  let resp_str = read_all resp_body in
  (code, resp_str)

let post_raw ~path ~data ~headers =
  let uri = Uri.of_string (base_url () ^ path) in
  let body = Cohttp_eio.Body.of_string data in
  let hdrs = Http.Header.of_list headers in
  let resp, resp_body =
    Cohttp_eio.Client.call (client ()) ~sw:(sw ()) ~headers:hdrs ~body `POST uri
  in
  let code = Http.Response.status resp |> Cohttp.Code.code_of_status in
  let resp_str = read_all resp_body in
  (code, resp_str)

let get ~path =
  let uri = Uri.of_string (base_url () ^ path) in
  let resp, resp_body =
    Cohttp_eio.Client.call (client ()) ~sw:(sw ()) `GET uri
  in
  let code = Http.Response.status resp |> Cohttp.Code.code_of_status in
  let resp_str = read_all resp_body in
  (code, resp_str)

let post_rfc822 ~path ~raw ~message_id =
  post_raw ~path ~data:raw
    ~headers:[
      ("Content-Type", "message/rfc822");
      ("X-Thunderbird-Message-Id", message_id);
    ]

let json_of_string s =
  try Yojson.Safe.from_string s
  with _ -> `Null

let json_string_field key json =
  match json with
  | `Assoc kv -> (match List.assoc_opt key kv with Some (`String s) -> s | _ -> "")
  | _ -> ""

let json_list_field key json =
  match json with
  | `Assoc kv -> (match List.assoc_opt key kv with Some (`List l) -> l | _ -> [])
  | _ -> []

(* ---------- server reachability check ---------- *)

let server_is_reachable () =
  try
    let code, _ = get ~path:"/" in
    (* 405 is fine — means the server is up (POST-only) *)
    code = 200 || code = 404 || code = 405
  with exn ->
    Printf.eprintf "[test] server_is_reachable exception: %s\n%!" (Printexc.to_string exn);
    false

let skip_if_unreachable () =
  if not (server_is_reachable ()) then
    Alcotest.fail "Server not reachable; skipping"
