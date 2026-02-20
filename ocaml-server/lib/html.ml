(*
  HTML -> text conversion and entity decoding

  HTML email bodies frequently contain large amounts of layout content (CSS, scripts, hidden elements).
  We parse and traverse the HTML DOM to extract just the readable free-text.

  This is intentionally deterministic (no LLM rewrite), so the same email always normalizes to the
  same text at ingestion and at evidence time.

  All HTML handling uses lambdasoup (which implements the HTML5 parsing spec).
*)

(* Decode HTML character entities (&amp; &lt; etc.) by round-tripping through
   lambdasoup's HTML5 parser.  Angle brackets are pre-escaped to prevent the
   parser from interpreting raw '<'/'>' as markup. *)
let decode_html_entities (s : string) : string =
  let escaped =
    s
    |> String.split_on_char '<' |> String.concat "&lt;"
    |> String.split_on_char '>' |> String.concat "&gt;"
  in
  try Soup.parse escaped |> Soup.texts |> String.concat ""
  with _ -> s

(* Heuristic check: does this string contain meaningful HTML elements?
   Used to decide whether to run strip_html on text/plain bodies that
   are actually mislabelled HTML. *)
let looks_like_html_markup (s : string) : bool =
  try
    let soup = Soup.parse (String.trim s) in
    match Soup.(soup $? "body") with
    | Some body -> Soup.(body $$ "*" |> count) > 0
    | None -> false
  with _ -> false

(* Convert HTML to plain text by removing script/style/head/noscript elements
   and extracting trimmed text nodes via lambdasoup.  Falls back gracefully
   on parse errors. *)
let strip_html (s : string) : string =
  try
    let open Soup in
    let soup = parse s in
    let drop selector = soup $$ selector |> iter delete in
    drop "script";
    drop "style";
    drop "head";
    drop "noscript";
    soup |> trimmed_texts |> String.concat "\n"
  with _ ->
    (* Fallback: simpler lambdasoup path without element deletion *)
    (try Soup.parse s |> Soup.trimmed_texts |> String.concat "\n"
     with _ -> decode_html_entities s)
