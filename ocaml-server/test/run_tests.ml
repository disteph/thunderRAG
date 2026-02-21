(*
  ThunderRAG Integration Test Runner

  Runs HTTP integration tests against a running OCaml server.
  All tests auto-skip if the server is not reachable.

  Usage:
    dune exec test/run_tests.exe
    THUNDERRAG_TEST_URL=http://localhost:9090 dune exec test/run_tests.exe
    dune exec test/run_tests.exe -- --quick   # skip slow tests
*)

let () =
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Cohttp_eio.Client.make ~https:None env#net in
  Helpers.the_client := Some client;
  Helpers.the_sw := Some sw;
  Alcotest.run "ThunderRAG"
    [ ("routing",    Test_routing.tests)
    ; ("ingest",     Test_ingest.tests)
    ; ("admin",      Test_admin.tests)
    ; ("delete",     Test_delete.tests)
    ; ("query_flow", Test_query_flow.tests)
    ]
