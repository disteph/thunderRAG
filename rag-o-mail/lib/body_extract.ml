(*
  Email body extraction pipeline

  Extracts readable text from raw RFC822 messages by:
  1. Trying mrmime's streaming parser (handles well-formed MIME)
  2. Falling back to manual MIME leaf-part collection (handles partially malformed messages)
  3. Last resort: taking everything after the RFC822 header block

  Splits extracted text into "new content" vs "quoted context" for both
  plain text (heuristic line-based) and HTML (DOM-based via lambdasoup).
*)

open Text_util
open Html
open Mime

(* Represents the split result of an email body: freshly-written content vs
   quoted/forwarded thread context. Both fields are used for ingestion metadata
   (new_text → indexed, quoted_text → optionally summarized). *)
type body_parts =
  { new_text : string
  ; quoted_text : string
  }

(* Split plain text into new content vs quoted context using heuristics:
   - "On ... wrote:" headers, "> "-prefixed lines, forwarded message markers.
   - Falls back to trailing-quote detection if no explicit header is found. *)
let split_new_vs_quoted_plain (text : string) : body_parts =
  let lines = String.split_on_char '\n' text in
  let norm (s : string) : string = String.trim s |> String.lowercase_ascii in
  let is_quote_header (line : string) : bool =
    let t = norm line in
    t = "-----original message-----"
    || t = "begin forwarded message:"
    || t = "---------- forwarded message ----------"
    || t = "----- forwarded message -----"
    || t = "-----original message-----"
    || t = "----- original message -----"
    || (starts_with "on " t && ends_with " wrote:" t)
    || (starts_with "from:" t && String.contains t '@')
    || (starts_with "sent:" t)
    || (starts_with "subject:" t)
  in
  let is_quote_line (line : string) : bool =
    let t = String.trim line in
    t <> "" && t.[0] = '>'
  in

  let rec next_nonempty = function
    | [] -> None
    | l :: rest -> if String.trim l = "" then next_nonempty rest else Some l
  in

  let is_quote_intro (line : string) (rest : string list) : bool =
    let t = String.trim line in
    if t = "" then false
    else if not (ends_with ":" t) then false
    else
      match next_nonempty rest with
      | Some nxt -> is_quote_line nxt
      | None -> false
  in

  let rec find_header idx = function
    | [] -> None
    | l :: rest ->
        if is_quote_header l || is_quote_intro l rest then Some idx
        else find_header (idx + 1) rest
  in
  let split_at i =
    let rec take n xs acc =
      if n <= 0 then (List.rev acc, xs)
      else
        match xs with
        | [] -> (List.rev acc, [])
        | x :: rest -> take (n - 1) rest (x :: acc)
    in
    take i lines []
  in
  match find_header 0 lines with
  | Some i ->
      let new_lines, quoted_lines = split_at i in
      { new_text = String.concat "\n" new_lines |> String.trim
      ; quoted_text = String.concat "\n" quoted_lines |> String.trim
      }
  | None ->
      let rec take_trailing_quote acc = function
        | [] -> ([], List.rev acc)
        | l :: rest ->
            let t = String.trim l in
            if t = "" || is_quote_line l then take_trailing_quote (l :: acc) rest
            else (List.rev (l :: rest), List.rev acc)
      in
      let rev_lines = List.rev lines in
      let kept, trailing_quote = take_trailing_quote [] rev_lines in
      let quoted_text = String.concat "\n" trailing_quote |> String.trim in
      let new_text = String.concat "\n" kept |> String.trim in
      if quoted_text = "" then { new_text; quoted_text = "" }
      else { new_text; quoted_text }

(* Split HTML content into new vs quoted using DOM structure via lambdasoup.
   Looks for <blockquote>, .gmail_quote, .yahoo_quoted, etc.  Falls back to
   strip_html + plain-text splitting on parse failure. *)
let split_new_vs_quoted_html (html : string) : body_parts =
  try
    let open Soup in
    let soup = parse html in
    let drop selector = soup $$ selector |> iter delete in
    drop "script";
    drop "style";
    drop "head";
    drop "noscript";

    let quote_selector = "blockquote, .gmail_quote, .yahoo_quoted, #divRplyFwdMsg, blockquote[type='cite']" in
    let quoted_text =
      soup $$ quote_selector
      |> fold
           (fun acc node ->
             let t = node |> trimmed_texts |> String.concat "\n" |> String.trim in
             if t = "" then acc else acc @ [ t ])
           []
      |> String.concat "\n\n"
      |> String.trim
    in
    drop quote_selector;
    let new_text = soup |> trimmed_texts |> String.concat "\n" |> String.trim in
    { new_text; quoted_text }
  with _ -> split_new_vs_quoted_plain (strip_html html)

(* Last-resort fallback: return everything after the first blank line (header/body separator). *)
let fallback_body_after_headers (raw : string) : string =
  let raw = normalize_newlines_for_parsing raw in
  let marker = "\n\n" in
  let mlen = String.length marker in
  let len = String.length raw in
  let rec find i =
    if i + mlen > len then None
    else if String.sub raw i mlen = marker then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> ""
  | Some idx ->
      let start = idx + mlen in
      if start >= len then "" else String.sub raw start (len - start)

(* Extract human-readable summary from decoded iCalendar (RFC 5545) text.
   Unfolds continuation lines and picks out key event fields. *)
let extract_ical_summary (ical : string) : string =
  let lines = String.split_on_char '\n' (normalize_newlines_for_parsing ical) in
  (* Unfold continuation lines: a line starting with space/tab continues the previous line. *)
  let unfolded =
    let rec loop acc = function
      | [] -> List.rev acc
      | l :: rest ->
          if String.length l > 0 && (l.[0] = ' ' || l.[0] = '\t') then (
            let cont = String.sub l 1 (String.length l - 1) in
            match acc with
            | prev :: acc_rest -> loop ((prev ^ cont) :: acc_rest) rest
            | [] -> loop [cont] rest)
          else loop (l :: acc) rest
    in
    loop [] lines
  in
  (* Parse "KEY;params:VALUE" or "KEY:VALUE" *)
  let parse_prop line =
    match String.index_opt line ':' with
    | None -> None
    | Some ci ->
        let key_part = String.sub line 0 ci |> String.uppercase_ascii in
        let value = String.sub line (ci + 1) (String.length line - ci - 1) |> String.trim in
        let key_base = match String.index_opt key_part ';' with
          | Some si -> String.sub key_part 0 si
          | None -> key_part
        in
        Some (key_base, value)
  in
  let props = List.filter_map parse_prop unfolded in
  let find key = List.assoc_opt key props in
  let find_all key = List.filter_map (fun (k, v) -> if k = key then Some v else None) props in
  (* Extract CN= from a value like "CN=Some Name:mailto:..." *)
  let extract_cn (s : string) : string =
    let parts = String.split_on_char ';' s in
    let cn = List.find_map (fun p ->
      let p = String.trim p in
      if starts_with "CN=" (String.uppercase_ascii p) then
        Some (String.sub p 3 (String.length p - 3))
      else None) parts
    in
    match cn with Some n -> n | None -> s
  in
  let buf = Buffer.create 256 in
  let add label value =
    if String.trim value <> "" then
      Buffer.add_string buf (Printf.sprintf "%s: %s\n" label value)
  in
  (match find "SUMMARY" with Some s -> add "Event" s | None -> ());
  (match find "DTSTART" with Some s -> add "Start" s | None -> ());
  (match find "DTEND" with Some s -> add "End" s | None -> ());
  (match find "LOCATION" with Some s -> add "Location" s | None -> ());
  (match find "DESCRIPTION" with Some s -> add "Description" s | None -> ());
  let organizer = find_all "ORGANIZER" in
  List.iter (fun o -> add "Organizer" (extract_cn o)) organizer;
  let attendees = find_all "ATTENDEE" in
  if attendees <> [] then
    add "Attendees" (String.concat ", " (List.map extract_cn attendees));
  let result = Buffer.contents buf |> String.trim in
  if result = "" then ical else result

(* Collect MIME leaf parts and pick the best text/plain, text/html, and
   text/calendar bodies.  Skips attachment parts.
   Decodes Content-Transfer-Encoding per part. *)
let best_body_parts_from_simple_mime (raw : string) : (string option * string option * string option) =
  let parts = collect_mime_leaf_parts raw in
  let decode_with_headers (headers : (string, string) Hashtbl.t) (body : string) : string option =
    let cte = String.lowercase_ascii (header_or_empty headers "content-transfer-encoding") |> String.trim in
    let raw_body = String.trim body in
    if raw_body = "" then None
    else if cte = "quoted-printable" then Some (decode_quoted_printable raw_body)
    else if cte = "base64" then (
      match decode_base64 raw_body with
      | Some d -> Some d
      | None -> None)
    else Some raw_body
  in
  let is_text_plain_ct (ct : string) : bool = starts_with "text/plain" (String.lowercase_ascii (String.trim ct)) in
  let is_text_html_ct (ct : string) : bool = starts_with "text/html" (String.lowercase_ascii (String.trim ct)) in
  let is_text_calendar_ct (ct : string) : bool = starts_with "text/calendar" (String.lowercase_ascii (String.trim ct)) in
  let pick ct_pred =
    parts
    |> List.filter (fun p -> not (is_attachment_part p.headers))
    |> List.find_map (fun p ->
           let ct = header_or_empty p.headers "content-type" in
           if not (ct_pred ct) then None
           else
             match decode_with_headers p.headers p.body with
             | None -> None
             | Some s ->
                 let s = s |> decode_html_entities |> String.trim in
                 if s = "" then None else Some s)
  in
  let plain = pick is_text_plain_ct in
  let html = pick is_text_html_ct in
  let cal = pick is_text_calendar_ct in
  (plain, html, cal)

(* Shared fallback used when the mrmime streaming parser fails or produces empty buffers.
   Tries manual MIME leaf-part collection, then raw body-after-headers as last resort. *)
let fallback_via_simple_mime (raw : string) : body_parts =
  let plain2, html2, cal2 = best_body_parts_from_simple_mime raw in
  match plain2, html2 with
  | Some p, _ -> split_new_vs_quoted_plain p
  | None, Some h -> split_new_vs_quoted_html h
  | None, None ->
      (* Try text/calendar before giving up *)
      match cal2 with
      | Some c -> split_new_vs_quoted_plain (extract_ical_summary c)
      | None ->
      let fb = fallback_body_after_headers raw |> String.trim in
      if looks_like_base64 fb || looks_like_base64_chars fb then
        split_new_vs_quoted_plain
          "[ERROR: body appears encrypted/encoded (base64/ciphertext). Decrypt upstream in Thunderbird before ingestion.]"
      else if contains_substring ~sub:"Content-Transfer-Encoding" fb
           && contains_substring ~sub:"Content-Type" fb then
        (* Raw MIME structure leaked through — all decoders failed *)
        split_new_vs_quoted_plain
          "[ERROR: body contains raw MIME structure that could not be decoded.]"
      else split_new_vs_quoted_plain fb

(* Primary entry point: extract body text from a raw RFC822 message.
   Uses mrmime's streaming parser for well-formed MIME, with fallback to manual
   leaf-part collection for partially malformed messages.
   Returns split new_text / quoted_text ready for ingestion or evidence display. *)
(* Defence-in-depth: try to decode base64 content that a parser failed to decode.
   Uses both strict (trial decode) and broad (character frequency) checks. *)
let maybe_decode_b64 (s : string) : string =
  if looks_like_base64 s then (match decode_base64 s with Some d -> d | None -> s)
  else if looks_like_base64_chars s then (
    (* Broad match but strict decode failed — flag as undecodable *)
    Printf.eprintf "[body_extract] broad base64 detected (%d chars) but trial decode failed\n%!" (String.length s);
    s)
  else s

let extract_body_parts (raw : string) : body_parts =
  (* Pass original raw (with \r\n) to mrmime — its QP decoder expects \r\n for
     soft breaks (=\r\n) and hard breaks (\r\n).  Normalizing to \n beforehand
     breaks QP decoding: soft breaks become literal "=\n" and hard breaks vanish. *)
  let plain_buf = Buffer.create 4096 in
  let html_buf = Buffer.create 4096 in
  let cal_buf = Buffer.create 4096 in
  let emitters (header : Mrmime.Header.t) =
    if is_text_plain header then
      let emitter = function None -> () | Some chunk -> Buffer.add_string plain_buf chunk in
      (emitter, ())
    else if is_text_html header then
      let emitter = function None -> () | Some chunk -> Buffer.add_string html_buf chunk in
      (emitter, ())
    else if is_text_calendar header then
      let emitter = function None -> () | Some chunk -> Buffer.add_string cal_buf chunk in
      (emitter, ())
    else
      let emitter = function None -> () | Some _chunk -> () in
      (emitter, ())
  in
  match Angstrom.parse_string ~consume:Prefix (Mrmime.Mail.stream emitters) raw with
  | Error _msg ->
      (* Fallback paths use \n-based header/body splitting, so normalize here. *)
      fallback_via_simple_mime (normalize_newlines_for_parsing raw)
  | Ok _ ->
      (* mrmime's Mail.stream already decodes Content-Transfer-Encoding (QP, base64),
         so we must NOT call maybe_decode_transfer_encoding here — that would double-decode.
         Normalize \r\n → \n in the decoded output for consistent downstream handling.
         Defence-in-depth: if mrmime emitted raw base64 without decoding, decode it now. *)
      let plain = Buffer.contents plain_buf |> maybe_decode_b64 |> normalize_newlines_for_parsing |> decode_html_entities |> String.trim in
      let plain = if looks_like_html_markup plain then strip_html plain |> String.trim else plain in
      let html = Buffer.contents html_buf |> maybe_decode_b64 |> normalize_newlines_for_parsing |> String.trim in
      let html = if looks_like_base64_chars html then "" else html in
      if plain <> "" then (
        if html <> "" then (
          let p = split_new_vs_quoted_plain plain in
          let h = split_new_vs_quoted_html html in
          if String.trim p.quoted_text = "" && String.trim h.quoted_text <> "" then
            { new_text = if String.trim p.new_text <> "" then p.new_text else h.new_text; quoted_text = h.quoted_text }
          else p)
        else split_new_vs_quoted_plain plain)
      else if html <> "" then split_new_vs_quoted_html html
      else
        (* Both plain and html empty — try calendar buffer before fallback *)
        let cal = Buffer.contents cal_buf |> maybe_decode_b64 |> normalize_newlines_for_parsing |> String.trim in
        if cal <> "" && not (looks_like_base64_chars cal) then
          split_new_vs_quoted_plain (extract_ical_summary cal)
        else fallback_via_simple_mime (normalize_newlines_for_parsing raw)
