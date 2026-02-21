(*
  ThunderRAG Quality Test Harness

  Ingests a synthetic corpus, runs test questions through the full 3-phase
  query flow, scores answers, detects anomalies.

  Usage:
    dune exec test/quality_harness.exe
    dune exec test/quality_harness.exe -- --base-url http://localhost:9090
    dune exec test/quality_harness.exe -- --skip-ingest
*)

let base_url = ref "http://localhost:8080"
let skip_ingest = ref false
let the_client : Cohttp_eio.Client.t option ref = ref None
let the_sw : Eio.Switch.t option ref = ref None
let client () = Option.get !the_client
let sw () = Option.get !the_sw

(* ---- HTTP ---- *)

let json_hdrs = Http.Header.of_list [("Content-Type", "application/json")]

let call_post ?(hdrs=json_hdrs) path data =
  let uri = Uri.of_string (!base_url ^ path) in
  let body = Cohttp_eio.Body.of_string data in
  let resp, rb = Cohttp_eio.Client.call (client ()) ~sw:(sw ()) ~headers:hdrs ~body `POST uri in
  (Http.Response.status resp |> Cohttp.Code.code_of_status,
   Eio.Buf_read.(parse_exn take_all) rb ~max_size:max_int)

let post_json p b = call_post p b
let post_rfc822 p raw mid =
  call_post ~hdrs:(Http.Header.of_list [
    "Content-Type","message/rfc822"; "X-Thunderbird-Message-Id",mid]) p raw
let post_evidence p raw rid mid =
  call_post ~hdrs:(Http.Header.of_list [
    "Content-Type","message/rfc822"; "X-RAG-Request-Id",rid; "X-Thunderbird-Message-Id",mid]) p raw

(* ---- JSON helpers ---- *)

let jstr k = function `Assoc kv -> (match List.assoc_opt k kv with Some (`String s) -> s | _ -> "") | _ -> ""
let jlist k = function `Assoc kv -> (match List.assoc_opt k kv with Some (`List l) -> l | _ -> []) | _ -> []
let jbool k = function `Assoc kv -> (match List.assoc_opt k kv with Some (`Bool b) -> b | _ -> false) | _ -> false
let parse s = try Yojson.Safe.from_string s with _ -> `Null

let load_json path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic) |> Yojson.Safe.from_string)

(* ---- String helpers ---- *)

let contains_ci hay needle =
  let h = String.lowercase_ascii hay and n = String.lowercase_ascii needle in
  let nl = String.length n and hl = String.length h in
  nl = 0 || (nl <= hl && let found = ref false in
    for i = 0 to hl - nl do if not !found && String.sub h i nl = n then found := true done; !found)

let extract_citations text =
  let nums = ref [] and len = String.length text and i = ref 0 in
  while !i < len - 7 do
    if String.sub text !i 7 = "[Email " then begin
      let j = ref (!i + 7) in
      while !j < len && text.[!j] >= '0' && text.[!j] <= '9' do incr j done;
      if !j > !i + 7 && !j < len && text.[!j] = ']' then
        nums := int_of_string (String.sub text (!i+7) (!j - !i - 7)) :: !nums;
      i := !j end
    else incr i
  done; List.rev !nums

(* ---- find data files ---- *)

let find_tests_dir () =
  ["tests"; "ocaml-server/tests"; "../tests"]
  |> List.find (fun d -> Sys.file_exists (Filename.concat d "corpus.json"))

(* ---- phases ---- *)

let reset_session sid =
  ignore (post_json "/admin/session/reset" (Printf.sprintf {|{"session_id":"%s"}|} sid))

let reset () =
  Printf.printf "[reset] Resetting index...\n%!";
  let c,b = post_json "/admin/reset" "{}" in
  if c <> 200 then Printf.printf "  WARNING: %d %s\n%!" c (String.sub b 0 (min 200 (String.length b)))

let ingest_corpus corpus =
  let emails = jlist "emails" corpus in
  let tbl = Hashtbl.create 32 in
  Printf.printf "\n[ingest] %d emails...\n%!" (List.length emails);
  List.iteri (fun i e ->
    let mid = jstr "message_id" e and rfc = jstr "rfc822" e and eid = jstr "id" e in
    Hashtbl.replace tbl mid rfc;
    let c,_ = post_rfc822 "/ingest" rfc mid in
    Printf.printf "  [%d/%d] %s %s\n%!" (i+1) (List.length emails) (if c=200 then "OK" else Printf.sprintf "FAIL(%d)" c) eid
  ) emails;
  List.iter (fun e -> if jbool "mark_processed" e then begin
    let mid = jstr "message_id" e in
    let c,_ = post_json "/admin/mark_processed" (Printf.sprintf {|{"id":"%s"}|} mid) in
    Printf.printf "  mark_processed %s: %d\n%!" (jstr "id" e) c end) emails;
  tbl

let run_query sid question user_name corpus_tbl =
  let c1,b1 = post_json "/query" (Printf.sprintf
    {|{"session_id":"%s","question":"%s","user_name":"%s","top_k":5}|}
    sid (String.escaped question) (String.escaped user_name)) in
  if c1 <> 200 then `Assoc ["error", `String (Printf.sprintf "Phase1: %d" c1)]
  else
    let q = parse b1 in
    let rid = jstr "request_id" q in
    let mids = jlist "message_ids" q |> List.filter_map (function `String s -> Some s | _ -> None) in
    List.iter (fun mid ->
      let rfc = match Hashtbl.find_opt corpus_tbl mid with
        | Some r -> r
        | None ->
          let bare = String.trim mid in
          let brk = if bare <> "" && bare.[0] <> '<' then "<"^bare^">" else bare in
          (match Hashtbl.find_opt corpus_tbl brk with Some r -> r | None ->
           Printf.printf "    WARNING: %s not in corpus\n%!" mid;
           Printf.sprintf "From: x@x.com\r\nTo: y@y.com\r\nSubject: placeholder\r\nMessage-Id: %s\r\nDate: Mon, 01 Jan 2025 00:00:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nN/A" mid)
      in
      let c,_ = post_evidence "/query/evidence" rfc rid mid in
      if c<>200 then Printf.printf "    Evidence %s: %d\n%!" mid c
    ) mids;
    let c3,b3 = post_json "/query/complete" (Printf.sprintf {|{"session_id":"%s","request_id":"%s"}|} sid rid) in
    let complete = if c3=200 then parse b3 else `Assoc ["error",`String (Printf.sprintf "Phase3: %d" c3)] in
    let _,db = post_json "/admin/session/debug" (Printf.sprintf {|{"session_id":"%s"}|} sid) in
    `Assoc ["query_response",q; "complete_response",complete; "session_debug",parse db; "question",`String question]

(* ---- analysis ---- *)

let analyze result corpus =
  let a = ref [] in let add s = a := s :: !a in
  let complete = match result with `Assoc kv -> (match List.assoc_opt "complete_response" kv with Some j -> j | _ -> `Null) | _ -> `Null in
  (match jstr "error" complete with "" -> () | e -> add ("ERROR: "^e));
  let answer = jstr "answer" complete and sources = jlist "sources" complete in
  let ns = List.length sources in
  let cited = extract_citations answer in
  List.iter (fun n -> if n < 1 then add (Printf.sprintf "CITATION INVALID: [Email %d]" n)) cited;
  (match cited with [] -> () | _ -> let mx = List.fold_left max 0 cited in
    if mx > ns then add (Printf.sprintf "CITATION OUT OF RANGE: [Email %d] vs %d sources" mx ns));
  let al = String.length (String.trim answer) in
  if al < 10 then add (Printf.sprintf "ANSWER TOO SHORT: %d chars" al);
  if al > 5000 then add (Printf.sprintf "ANSWER VERY LONG: %d chars" al);
  let al_lower = String.lowercase_ascii answer in
  let senders = Hashtbl.create 32 in
  List.iter (fun e -> let rfc = jstr "rfc822" e in
    String.split_on_char '\n' rfc |> List.iter (fun l ->
      let ll = String.lowercase_ascii l in
      if String.length ll > 5 && String.sub ll 0 5 = "from:" then
        Hashtbl.replace senders (String.trim (String.sub ll 5 (String.length ll - 5))) true)
  ) (jlist "emails" corpus);
  ["john";"jane";"mike";"sarah";"tom";"jennifer";"james";"mary"]
  |> List.filter (fun n -> contains_ci al_lower n && not (Hashtbl.fold (fun k _ acc -> acc || contains_ci k n) senders false))
  |> (function [] -> () | fab -> add (Printf.sprintf "POSSIBLE HALLUCINATED NAMES: %s" (String.concat ", " fab)));
  List.rev !a

let score result criteria =
  let complete = match result with `Assoc kv -> (match List.assoc_opt "complete_response" kv with Some j -> j | _ -> `Null) | _ -> `Null in
  if jstr "error" complete <> "" then 0.0
  else
    let answer = jstr "answer" complete and al = String.lowercase_ascii (jstr "answer" complete) in
    let sources = jlist "sources" complete in
    let ss = ref [] in let add s = ss := s :: !ss in
    let strs k = jlist k criteria |> List.filter_map (function `String s -> Some s | _ -> None) in
    (match strs "must_contain_any" with [] -> add 1.0 | mc -> add (if List.exists (fun kw -> contains_ci al kw) mc then 1.0 else 0.0));
    (match strs "must_not_contain" with [] -> add 1.0 | mn -> add (if List.for_all (fun kw -> not (contains_ci al kw)) mn then 1.0 else 0.0));
    if jbool "must_cite_emails" criteria then begin
      let cited = extract_citations answer in
      add (if cited<>[] then 1.0 else 0.0);
      add (if cited<>[] && sources<>[] && List.for_all (fun n -> n>=1 && n<=List.length sources) cited then 1.0 else 0.0)
    end else begin add 1.0; add 1.0 end;
    (match strs "expected_email_subjects_any" with [] -> add 1.0 | exp ->
      let subjs = List.filter_map (fun s -> match s with `Assoc kv ->
        (match List.assoc_opt "metadata" kv with Some m -> Some (String.lowercase_ascii (jstr "subject" m)) | _ -> None) | _ -> None) sources in
      add (if List.exists (fun e -> List.exists (fun s -> contains_ci s e) subjs) exp then 1.0 else 0.0));
    (match strs "hallucination_keywords" with [] -> add 1.0 | hk ->
      let neg = contains_ci answer "no " || contains_ci answer "not " || contains_ci answer "none" in
      add (if neg then 1.0 else if List.for_all (fun k -> not (contains_ci al k)) hk then 1.0 else 0.0));
    let v = !ss in List.fold_left (+.) 0.0 v /. float_of_int (max 1 (List.length v))

(* ---- main ---- *)

let () =
  let args = Array.to_list Sys.argv in
  let rec parse_args = function
    | "--base-url" :: u :: rest -> base_url := u; parse_args rest
    | "--skip-ingest" :: rest -> skip_ingest := true; parse_args rest
    | _ :: rest -> parse_args rest
    | [] -> ()
  in parse_args (List.tl args);

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw_ ->
  the_client := Some (Cohttp_eio.Client.make ~https:None env#net);
  the_sw := Some sw_;

  (* Check server *)
  Printf.printf "[init] Checking server at %s...\n%!" !base_url;
  (try let c,_ = call_post "/" "" in Printf.printf "  reachable (status %d)\n%!" c
   with _ -> Printf.eprintf "  ERROR: server not reachable\n%!"; exit 1);

  let tdir = find_tests_dir () in
  let corpus = load_json (Filename.concat tdir "corpus.json") in
  let test_cases = load_json (Filename.concat tdir "test_cases.json") in
  Printf.printf "[init] %d emails, %d cases\n%!" (List.length (jlist "emails" corpus)) (List.length (jlist "cases" test_cases));

  let ts = Unix.localtime (Unix.gettimeofday ()) in
  let run_name = Printf.sprintf "%04d%02d%02d_%02d%02d%02d" (ts.tm_year+1900) (ts.tm_mon+1) ts.tm_mday ts.tm_hour ts.tm_min ts.tm_sec in
  let runs_dir = Filename.concat tdir "runs" in
  (try Unix.mkdir runs_dir 0o755 with Unix.Unix_error (Unix.EEXIST,_,_) -> ());
  let run_dir = Filename.concat runs_dir run_name in
  Unix.mkdir run_dir 0o755;
  Printf.printf "[init] Run: %s\n%!" run_dir;

  let t0 = Unix.gettimeofday () in

  let corpus_tbl =
    if !skip_ingest then begin
      Printf.printf "[init] Skipping ingest (--skip-ingest)\n%!";
      let tbl = Hashtbl.create 32 in
      List.iter (fun e -> Hashtbl.replace tbl (jstr "message_id" e) (jstr "rfc822" e)) (jlist "emails" corpus);
      tbl
    end else begin
      reset ();
      let sgs = Hashtbl.create 8 in
      List.iter (fun tc ->
        let sg = match jstr "session_group" tc with "" -> "session_"^(jstr "id" tc) | s -> s in
        Hashtbl.replace sgs ("quality-test-"^sg) true) (jlist "cases" test_cases);
      Hashtbl.iter (fun sg _ -> reset_session sg) sgs;
      ingest_corpus corpus
    end
  in

  let user_name = jstr "user_name" test_cases in
  let cases = jlist "cases" test_cases in
  let completed = Hashtbl.create 16 in
  Printf.printf "\n[test] Running %d cases...\n%!" (List.length cases);

  let results = List.mapi (fun i tc ->
    let tc_id = jstr "id" tc and cat = jstr "category" tc in
    let sg = match jstr "session_group" tc with "" -> "session_"^tc_id | s -> s in
    let dep = jstr "depends_on" tc in
    if dep <> "" && not (Hashtbl.mem completed dep) then begin
      Printf.printf "\n  [%d/%d] SKIP %s (dep %s)\n%!" (i+1) (List.length cases) tc_id dep;
      (tc_id, cat, `Null, `Null)
    end else begin
      Printf.printf "\n  [%d/%d] %s (%s)\n%!" (i+1) (List.length cases) tc_id cat;
      Printf.printf "    Q: %s\n%!" (jstr "question" tc);
      let sid = "quality-test-"^sg in
      let r = run_query sid (jstr "question" tc) user_name corpus_tbl in
      Hashtbl.replace completed tc_id true;
      let cr = match r with `Assoc kv -> (match List.assoc_opt "complete_response" kv with Some c -> c | _ -> `Null) | _ -> `Null in
      let answer = jstr "answer" cr in
      let preview = String.concat " " (String.split_on_char '\n' (if String.length answer > 150 then String.sub answer 0 150^"..." else answer)) in
      Printf.printf "    A: %s\n%!" preview;
      let criteria = match tc with `Assoc kv -> (match List.assoc_opt "criteria" kv with Some c -> c | _ -> `Null) | _ -> `Null in
      (tc_id, cat, r, criteria)
    end
  ) cases in

  let elapsed = Unix.gettimeofday () -. t0 in

  (* Save results.json *)
  let results_json = `List (List.map (fun (tid,cat,r,_) -> `Assoc ["test_id",`String tid;"category",`String cat;"result",r]) results) in
  let oc = open_out (Filename.concat run_dir "results.json") in
  output_string oc (Yojson.Safe.pretty_to_string results_json);
  close_out oc;

  (* Summary *)
  let buf = Buffer.create 4096 in
  let pr fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in
  let sep () = pr "%s" (String.make 80 '=') in
  let dsep () = pr "%s" (String.make 80 '-') in
  sep (); pr "ThunderRAG Quality Test Report"; pr "Run: %s  Duration: %.1fs  Cases: %d" run_name elapsed (List.length results); sep ();
  let all_anom = ref [] and all_sc = ref [] in
  List.iter (fun (tid, cat, r, criteria) ->
    pr ""; dsep (); pr "TEST: %s [%s]" tid cat;
    match r with `Null -> pr "  SKIPPED" | _ ->
    let cr = match r with `Assoc kv -> (match List.assoc_opt "complete_response" kv with Some c -> c | _ -> `Null) | _ -> `Null in
    let answer = jstr "answer" cr in
    let preview = String.concat " " (String.split_on_char '\n' (if String.length answer > 200 then String.sub answer 0 200^"..." else answer)) in
    pr "  A: %s" preview;
    let anoms = analyze r corpus in
    List.iter (fun a -> all_anom := (tid,a) :: !all_anom) anoms;
    if anoms<>[] then (pr "  ANOMALIES (%d):" (List.length anoms); List.iter (fun a -> pr "    - %s" a) anoms)
    else pr "  No anomalies.";
    let sc = score r criteria in
    all_sc := (tid,cat,sc) :: !all_sc;
    pr "  SCORE: %.2f" sc
  ) results;
  pr ""; sep (); pr "SUMMARY"; sep ();
  pr "Anomalies: %d" (List.length !all_anom);
  List.iter (fun (t,a) -> pr "  [%s] %s" t a) (List.rev !all_anom);
  (match !all_sc with [] -> () | sc ->
    let vals = List.map (fun (_,_,s) -> s) sc in
    pr "Mean score: %.2f" (List.fold_left (+.) 0.0 vals /. float_of_int (List.length vals));
    pr ""; pr "Per-case:";
    List.iter (fun (t,c,s) -> pr "  %s [%s]: %.2f%s" t c s (if s < 0.7 then " *** LOW ***" else "")) (List.rev sc));
  sep ();

  let summary = Buffer.contents buf in
  print_string summary;
  let oc2 = open_out (Filename.concat run_dir "summary.txt") in
  output_string oc2 summary; close_out oc2;
  Printf.printf "\n[output] %s/results.json\n[output] %s/summary.txt\n%!" run_dir run_dir
