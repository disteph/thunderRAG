(*
  Text normalization and decoding utilities

  Pure functions used both at ingestion time and at query/evidence time.
  Keeping normalization consistent is important so that embeddings and prompt evidence "see"
  similar text.
*)

(* Check whether [sub] appears anywhere in [s]. *)
let contains_substring ~(sub : string) (s : string) : bool =
  let sublen = String.length sub in
  let slen = String.length s in
  if sublen = 0 then true
  else if sublen > slen then false
  else
    let rec loop i =
      if i + sublen > slen then false
      else if String.sub s i sublen = sub then true
      else loop (i + 1)
    in
    loop 0

(* Normalize \r\n and bare \r to \n so that header/body splitting works uniformly. *)
let normalize_newlines_for_parsing (s : string) : string =
  if not (String.contains s '\r') then s
  else
    let len = String.length s in
    let b = Bytes.create len in
    let rec loop i j =
      if i >= len then Bytes.sub_string b 0 j
      else
        match s.[i] with
        | '\r' ->
            if i + 1 < len && s.[i + 1] = '\n' then (
              Bytes.set b j '\n';
              loop (i + 2) (j + 1))
            else (
              Bytes.set b j '\n';
              loop (i + 1) (j + 1))
        | c ->
            Bytes.set b j c;
            loop (i + 1) (j + 1)
    in
    loop 0 0

(* Repair double-encoded UTF-8 ("mojibake") at the byte level before Uutf processing.
   Common case: UTF-8 NBSP \xC2\xA0 misread as Latin-1 and re-encoded → \xC3\x82\xC2\xA0.
   General pattern for 2-byte UTF-8 \xCn\xYZ (n=0..3, YZ=80..BF):
     double-encoded → \xC3\x{80+n} \xC2\xYZ.
   We reverse this by scanning for \xC3[\x80-\x83] \xC2[\x80-\xBF] and emitting \xC{0+n}\xYZ. *)
let repair_double_utf8 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    if !i + 3 < len
       && Char.code s.[!i] = 0xC3
       && let b1 = Char.code s.[!i + 1] in b1 >= 0x80 && b1 <= 0x83
       && Char.code s.[!i + 2] = 0xC2
       && let b3 = Char.code s.[!i + 3] in b3 >= 0x80 && b3 <= 0xBF
    then (
      let n = Char.code s.[!i + 1] - 0x80 in  (* 0..3 *)
      Buffer.add_char buf (Char.chr (0xC0 + n));
      Buffer.add_char buf s.[!i + 3];
      i := !i + 4)
    else (
      Buffer.add_char buf s.[!i];
      i := !i + 1)
  done;
  Buffer.contents buf

(* Replace NUL bytes with spaces, normalize Unicode whitespace to ASCII space,
   and replace malformed UTF-8 sequences with '?' using Uutf.
   Applies repair_double_utf8 first to fix common mojibake. *)
let sanitize_utf8 (s : string) : string =
  let s = repair_double_utf8 s in
  let buf = Buffer.create (String.length s) in
  let d = Uutf.decoder ~encoding:`UTF_8 (`String s) in
  let rec loop () =
    match Uutf.decode d with
    | `End -> Buffer.contents buf
    | `Uchar u ->
        let cp = Uchar.to_int u in
        if cp = 0 || cp = 0x00A0 (* NBSP *) || cp = 0x2007 (* figure space *)
           || cp = 0x202F (* narrow NBSP *) || cp = 0xFEFF (* BOM/ZWNBSP *)
        then Buffer.add_char buf ' '
        else Buffer.add_utf_8_uchar buf u;
        loop ()
    | `Malformed _ -> Buffer.add_char buf '?'; loop ()
    | `Await -> assert false
  in
  loop ()

let starts_with (prefix : string) (s : string) : bool =
  String.starts_with ~prefix s

let ends_with (suffix : string) (s : string) : bool =
  String.ends_with ~suffix s

(* URI percent-decode via the Uri library. *)
let percent_decode (s : string) : string =
  Uri.pct_decode s

(* Remove surrounding double-quotes from a header parameter value. *)
let strip_quotes (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

(* Decode RFC 2231 charset-encoded header parameter values (charset'language'value). *)
let decode_rfc2231_value (v : string) : string =
  let v = strip_quotes (String.trim v) in
  match String.split_on_char '\'' v with
  | charset :: _lang :: value :: _rest ->
      let charset = String.lowercase_ascii (String.trim charset) in
      if charset = "utf-8" || charset = "utf8" then percent_decode value else percent_decode value
  | _ -> percent_decode v

(* Extract a named parameter from a semicolon-delimited Content-Type header value. *)
let find_param ~(name : string) (header_value : string) : string option =
  let parts = String.split_on_char ';' header_value |> List.map String.trim in
  let name_l = String.lowercase_ascii name in
  let rec loop = function
    | [] -> None
    | p :: rest ->
        let p_l = String.lowercase_ascii p in
        if String.length p_l >= String.length name_l + 1
           && String.sub p_l 0 (String.length name_l + 1) = name_l ^ "="
        then
          let v = String.sub p (String.length name_l + 1) (String.length p - (String.length name_l + 1)) in
          Some (String.trim v)
        else loop rest
  in
  loop parts

(* Base64-decode after stripping whitespace.  Returns None on decode failure. *)
let decode_base64 (s : string) : string option =
  let cleaned =
    let b = Buffer.create (String.length s) in
    String.iter (fun c -> match c with ' ' | '\t' | '\r' | '\n' -> () | _ -> Buffer.add_char b c) s;
    Buffer.contents b
  in
  match Base64.decode ~pad:false cleaned with
  | Ok d -> Some d
  | Error _ -> None

(* Decode RFC 2047 encoded-word tokens (=?charset?encoding?payload?=) via mrmime.
   Handles both Q-encoding and B-encoding across all charsets that mrmime supports. *)
let decode_rfc2047 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let find_end i =
    let rec loop j =
      if j + 1 >= len then None
      else if s.[j] = '?' && s.[j + 1] = '=' then Some (j + 2)
      else loop (j + 1)
    in
    loop i
  in
  let rec loop i =
    if i >= len then ()
    else if i + 1 < len && s.[i] = '=' && s.[i + 1] = '?' then (
      match find_end (i + 2) with
      | Some end_pos ->
          let token = String.sub s i (end_pos - i) in
          (match Mrmime.Encoded_word.of_string token with
          | Ok ew ->
              let cs = Mrmime.Encoded_word.charset ew in
              (match Mrmime.Encoded_word.data ew with
              | Ok raw ->
                  (match Mrmime.Encoded_word.normalize_to_utf8 ~charset:cs raw with
                  | Ok utf8 -> Buffer.add_string buf utf8
                  | Error _ -> Buffer.add_string buf raw)
              | Error _ -> Buffer.add_string buf token);
              loop end_pos
          | Error _ -> Buffer.add_char buf s.[i]; loop (i + 1))
      | None -> Buffer.add_char buf s.[i]; loop (i + 1))
    else (Buffer.add_char buf s.[i]; loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

(* Decode quoted-printable encoding via the Pecu library. *)
let decode_quoted_printable (s : string) : string =
  let d = Pecu.decoder (`String s) in
  let buf = Buffer.create (String.length s) in
  let rec loop () =
    match Pecu.decode d with
    | `Await -> assert false
    | `End -> Buffer.contents buf
    | `Data chunk -> Buffer.add_string buf chunk; loop ()
    | `Line chunk -> Buffer.add_string buf chunk; Buffer.add_char buf '\n'; loop ()
    | `Malformed chunk -> Buffer.add_string buf chunk; loop ()
  in
  loop ()

(* Heuristic: does this string look like base64?  Requires ≥80 non-whitespace chars
   and successful trial decode. *)
let looks_like_base64 (s : string) : bool =
  let cleaned =
    let b = Buffer.create (String.length s) in
    String.iter (fun c -> match c with ' ' | '\t' | '\r' | '\n' -> () | _ -> Buffer.add_char b c) s;
    Buffer.contents b
  in
  String.length cleaned >= 80
  && Result.is_ok (Base64.decode ~pad:false cleaned)

(* Best-effort Content-Transfer-Encoding decode when the CTE header is unavailable.
   Tries quoted-printable (if '=' present), then base64 (if it looks like it). *)
let maybe_decode_transfer_encoding (s : string) : string =
  let s = String.trim s in
  if s = "" then ""
  else if String.contains s '=' then (
    (* heuristically treat as quoted-printable *)
    decode_quoted_printable s)
  else if looks_like_base64 s then (
    match decode_base64 s with
    | Some d -> d
    | None -> s)
  else s

(* Strip LLM-generated preamble lines ("Hello!", "Sure!", "I'm happy to help", etc.)
   from the beginning of a chat response so the answer starts with substance. *)
let strip_leading_boilerplate (s : string) : string =
  let normalize (x : string) : string = String.trim x |> String.lowercase_ascii in
  let is_boil (line : string) : bool =
    let t = normalize line in
    t = "" || (
      (String.length t <= 120)
      && (starts_with "hello" t
         || starts_with "hi" t
         || starts_with "hey" t
         || starts_with "i'm happy to help" t
         || starts_with "i am happy to help" t
         || starts_with "i'm ready to assist" t
         || starts_with "i am ready to assist" t
         || starts_with "sure" t
         || starts_with "of course" t
         || String.contains t '?' && (String.contains t 'q') && (String.contains t 'n')
         || (String.contains t 'n' && String.contains t 'e' && String.contains t 'x' && String.contains t 't' && String.contains t 'q')))
  in
  let lines = String.split_on_char '\n' (String.trim s) in
  let rec drop = function
    | [] -> []
    | l :: rest -> if is_boil l then drop rest else l :: rest
  in
  let stripped = String.concat "\n" (drop lines) |> String.trim in
  if stripped = "" then String.trim s else stripped

(* Take the first [n] elements of a list. *)
let take (n : int) (xs : 'a list) : 'a list =
  let rec loop k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | y :: ys -> loop (k - 1) (y :: acc) ys
  in
  if n <= 0 then [] else loop n [] xs

(* Take the last [n] elements of a list. *)
let take_last (n : int) (xs : 'a list) : 'a list =
  if n <= 0 then []
  else
    let len = List.length xs in
    let drop = len - n in
    let rec loop i = function
      | [] -> []
      | y :: ys -> if i <= 0 then y :: ys else loop (i - 1) ys
    in
    if drop <= 0 then xs else loop drop xs

(* Drop the last [n] elements of a list, keeping the prefix. *)
let drop_last (n : int) (xs : 'a list) : 'a list =
  if n <= 0 then xs
  else
    let len = List.length xs in
    let keep = len - n in
    let rec loop i = function
      | [] -> []
      | y :: ys -> if i <= 0 then [] else y :: loop (i - 1) ys
    in
    if keep <= 0 then [] else loop keep xs

(* Keep at most [max_lines] lines from the beginning of a string. *)
let truncate_lines (s : string) ~(max_lines : int) : string =
  if max_lines <= 0 then ""
  else String.split_on_char '\n' s |> take max_lines |> String.concat "\n"

(* Truncate a string to at most [max_chars] characters. *)
let truncate_chars (s : string) ~(max_chars : int) : string =
  if max_chars <= 0 then ""
  else if String.length s <= max_chars then s
  else String.sub s 0 max_chars

(* L2-normalize a vector so inner-product equals cosine similarity. *)
let l2_normalize (vec : float list) : float list =
  let s =
    List.fold_left
      (fun acc v -> acc +. (v *. v))
      0.0 vec
  in
  if s <= 0.0 then vec
  else
    let inv = 1.0 /. sqrt s in
    List.map (fun v -> v *. inv) vec

(* Split text into overlapping chunks for embedding.  Each chunk is at most
   chunk_size characters with overlap characters shared between consecutive chunks. *)
let chunk_text ?(chunk_size = Config.rag_chunk_size) ?(overlap = Config.rag_chunk_overlap) (text : string) : string list =
  let cleaned = String.trim text in
  let n = String.length cleaned in
  let rec loop start acc =
    if start >= n then List.rev acc
    else
      let end_ = min n (start + chunk_size) in
      let chunk = String.sub cleaned start (end_ - start) |> String.trim in
      let acc = if chunk = "" then acc else chunk :: acc in
      if end_ >= n then List.rev acc else loop (max 0 (end_ - overlap)) acc
  in
  if cleaned = "" then [] else loop 0 []
