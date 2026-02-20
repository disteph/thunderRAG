(*
  MIME/RFC822 parsing utilities

  Provides header parsing, multipart body splitting, MIME leaf-part collection,
  and content-type helpers for text/plain and text/html detection.
*)

open Text_util

(* Parse RFC822 headers into a hashtable keyed by lowercase header name.
   Handles header folding (continuation lines starting with whitespace)
   and merges duplicate headers with ", ". *)
let parse_headers (raw : string) : (string, string) Hashtbl.t =
  let raw = normalize_newlines_for_parsing raw in
  let len = String.length raw in
  let find_sub ~sub =
    let sublen = String.length sub in
    let rec loop i =
      if i + sublen > len then None
      else if String.sub raw i sublen = sub then Some i
      else loop (i + 1)
    in
    loop 0
  in
  let header_end =
    match find_sub ~sub:"\n\n" with
    | Some i -> Some (i, 2)
    | None -> None
  in
  let header_text =
    match header_end with
    | Some (i, _sep_len) -> String.sub raw 0 i
    | None -> raw
  in
  let lines =
    header_text
    |> String.split_on_char '\n'
    |> List.map (fun s ->
           let s =
             if String.length s > 0 && s.[String.length s - 1] = '\r' then
               String.sub s 0 (String.length s - 1)
             else s
           in
           s)
  in
  let unfolded =
    let rec loop acc current_name current_value = function
      | [] -> (
          match current_name with
          | None -> List.rev acc
          | Some n -> List.rev ((n, current_value) :: acc))
      | line :: rest -> (
          match (line, current_name) with
          | "", _ ->
              (* End of headers. *)
              loop acc current_name current_value []
          | ( _
            , Some _ )
            when String.length line > 0
                 && (line.[0] = ' ' || line.[0] = '\t') ->
              let v = current_value ^ " " ^ String.trim line in
              loop acc current_name v rest
          | _ -> (
              let acc =
                match current_name with
                | None -> acc
                | Some n -> (n, current_value) :: acc
              in
              match String.index_opt line ':' with
              | None -> loop acc None "" rest
              | Some idx ->
                  let name = String.sub line 0 idx |> String.lowercase_ascii in
                  let value =
                    String.sub line (idx + 1) (String.length line - idx - 1)
                    |> String.trim
                  in
                  loop acc (Some name) value rest))
    in
    loop [] None "" lines
  in
  let tbl = Hashtbl.create 16 in
  let add name value =
    match Hashtbl.find_opt tbl name with
    | None -> Hashtbl.add tbl name value
    | Some existing -> Hashtbl.replace tbl name (existing ^ ", " ^ value)
  in
  List.iter (fun (k, v) -> add k v) unfolded;
  tbl

(* Look up a header by name (case-insensitive); returns "" if not found. *)
let header_or_empty (headers : (string, string) Hashtbl.t) (name : string) :
    string =
  match Hashtbl.find_opt headers (String.lowercase_ascii name) with
  | Some v -> v
  | None -> ""

(* Split a raw RFC822 message at the first blank line into (headers, body). *)
let split_headers_and_body (raw : string) : (string * string) =
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
  | None -> (raw, "")
  | Some idx ->
      let headers = String.sub raw 0 idx in
      let start = idx + mlen in
      let body = if start >= len then "" else String.sub raw start (len - start) in
      (headers, body)

(* A single leaf-level MIME part with its own headers and decoded body text. *)
type mime_leaf_part =
  { headers : (string, string) Hashtbl.t
  ; body : string
  }

let is_multipart_content_type (ct : string) : bool =
  let t = String.lowercase_ascii (String.trim ct) in
  starts_with "multipart/" t

(* Extract the MIME boundary parameter from a Content-Type header value. *)
let boundary_of_content_type (ct : string) : string option =
  match find_param ~name:"boundary" ct with
  | None -> None
  | Some b ->
      let b = b |> decode_rfc2231_value |> decode_rfc2047 |> sanitize_utf8 |> strip_quotes |> String.trim in
      if b = "" then None else Some b

(* Split a multipart body into its constituent parts using the MIME boundary delimiter. *)
let parse_multipart_body ~(boundary : string) (body : string) : string list =
  let lines = String.split_on_char '\n' body in
  let delim = "--" ^ boundary in
  let close_delim = delim ^ "--" in
  let parts = ref [] in
  let cur = Buffer.create 4096 in
  let in_part = ref false in
  let flush_part () =
    if Buffer.length cur > 0 then (
      parts := Buffer.contents cur :: !parts;
      Buffer.clear cur)
  in
  List.iter
    (fun line ->
      let t = String.trim line in
      if t = delim then (
        if !in_part then flush_part ();
        in_part := true)
      else if t = close_delim then (
        if !in_part then flush_part ();
        in_part := false)
      else if !in_part then (
        Buffer.add_string cur line;
        Buffer.add_char cur '\n'))
    lines;
  flush_part ();
  List.rev !parts

(* Recursively collect all leaf-level MIME parts from a raw message.
   Descends into multipart containers; returns leaf parts with their headers. *)
let rec collect_mime_leaf_parts (raw : string) : mime_leaf_part list =
  let headers_text, body = split_headers_and_body raw in
  let headers = parse_headers (headers_text ^ "\n\n") in
  let ct = header_or_empty headers "content-type" in
  if is_multipart_content_type ct then (
    match boundary_of_content_type ct with
    | None -> [ { headers; body } ]
    | Some boundary ->
        parse_multipart_body ~boundary body |> List.concat_map collect_mime_leaf_parts)
  else [ { headers; body } ]

(* Extract the filename from Content-Disposition or Content-Type parameters.
   Tries filename*, filename, name*, name in priority order (RFC 2231 + RFC 2047 decoded). *)
let filename_of_part_headers (headers : (string, string) Hashtbl.t) : string option =
  let cd = header_or_empty headers "content-disposition" in
  let ct = header_or_empty headers "content-type" in
  let pick = function
    | Some v -> Some (v |> decode_rfc2231_value |> decode_rfc2047 |> sanitize_utf8 |> String.trim)
    | None -> None
  in
  let fn =
    match find_param ~name:"filename*" cd with
    | Some _ as v -> pick v
    | None -> (
        match find_param ~name:"filename" cd with
        | Some _ as v -> pick v
        | None -> (
            match find_param ~name:"name*" ct with
            | Some _ as v -> pick v
            | None -> (
                match find_param ~name:"name" ct with
                | Some _ as v -> pick v
                | None -> None)))
  in
  match fn with
  | Some s when s <> "" -> Some s
  | _ -> None

(* Heuristic: does this part look like an attachment (has disposition or filename)? *)
let is_attachment_part (headers : (string, string) Hashtbl.t) : bool =
  let cd = String.lowercase_ascii (header_or_empty headers "content-disposition") in
  (String.contains cd 'a' && String.contains cd 't' && String.contains cd 'c')
  || filename_of_part_headers headers <> None

(* Check if a mrmime header indicates text/plain content type. *)
let is_text_plain (header : Mrmime.Header.t) : bool =
  let ct = Mrmime.Header.content_type header in
  let ty = Mrmime.Content_type.ty ct in
  let subty = Mrmime.Content_type.subty ct |> Mrmime.Content_type.Subtype.to_string in
  match ty with
  | `Text -> String.lowercase_ascii subty = "plain"
  | _ -> false

(* Check if a mrmime header indicates text/html content type. *)
let is_text_html (header : Mrmime.Header.t) : bool =
  let ct = Mrmime.Header.content_type header in
  let ty = Mrmime.Content_type.ty ct in
  let subty = Mrmime.Content_type.subty ct |> Mrmime.Content_type.Subtype.to_string in
  match ty with
  | `Text -> String.lowercase_ascii subty = "html"
  | _ -> false

(* Scan raw RFC822 text for Content-Disposition/Content-Type headers and collect
   all unique attachment filenames.  Used to populate metadata.attachments. *)
let extract_attachment_filenames (raw : string) : string list =
  let raw = normalize_newlines_for_parsing raw in
  let lines = String.split_on_char '\n' raw |> Array.of_list in
  let acc = Hashtbl.create 16 in
  let add_name (v : string) : unit =
    let v = v |> decode_rfc2231_value |> decode_rfc2047 |> sanitize_utf8 |> String.trim in
    if v <> "" then Hashtbl.replace acc v ()
  in
  let n = Array.length lines in
  let collect_folded (start_idx : int) (prefix_len : int) : (string * int) =
    let buf = Buffer.create 128 in
    let first = String.trim lines.(start_idx) in
    let rest =
      if String.length first > prefix_len then String.sub first prefix_len (String.length first - prefix_len)
      else ""
    in
    Buffer.add_string buf (String.trim rest);
    let j = ref (start_idx + 1) in
    let continue = ref true in
    while !continue && !j < n do
      let l = lines.(!j) in
      if String.length l > 0 && (l.[0] = ' ' || l.[0] = '\t') then (
        Buffer.add_char buf ' ';
        Buffer.add_string buf (String.trim l);
        incr j)
      else continue := false
    done;
    (Buffer.contents buf, !j)
  in
  let rec loop i =
    if i >= n then ()
    else
      let trimmed = String.trim lines.(i) in
      if trimmed = "" then loop (i + 1)
      else
        let lower = String.lowercase_ascii trimmed in
        if String.length lower >= 19 && String.sub lower 0 19 = "content-disposition:" then (
          let hv, j = collect_folded i 19 in
          (match find_param ~name:"filename*" hv with
          | Some v -> add_name v
          | None -> (
              match find_param ~name:"filename" hv with
              | Some v -> add_name v
              | None -> ()));
          loop j)
        else if String.length lower >= 13 && String.sub lower 0 13 = "content-type:" then (
          let hv, j = collect_folded i 13 in
          (match find_param ~name:"name*" hv with
          | Some v -> add_name v
          | None -> (
              match find_param ~name:"name" hv with
              | Some v -> add_name v
              | None -> ()));
          loop j)
        else loop (i + 1)
  in
  loop 0;
  Hashtbl.to_seq_keys acc |> List.of_seq
