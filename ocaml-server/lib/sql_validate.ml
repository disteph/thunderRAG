(*
  SQL expression validator

  Wraps LLM-generated SQL fragments in a template SELECT, parses via
  libpg_query (Pg_query.parse), then walks the resulting JSON parse tree
  to ensure only allowlisted node types, column references, function
  names, and type casts are present.

  Two public entry points:
  - [validate_filter]  — for WHERE-clause fragments
  - [validate_score]   — for ORDER BY / score expressions
*)

(* ---------- allowlists ---------- *)

module SS = Set.Make(String)

let allowed_columns = SS.of_list
  [ "doc_id"; "sender"; "recipient"; "cc"; "bcc"; "subject"; "email_date"
  ; "attachments"; "action_score"; "importance_score"; "reply_by"
  ; "processed"; "ingested_at"
  (* virtual column — expanded to (ec.embedding <=> $1::vector) by OCaml *)
  ; "cosine_distance"
  ]

let allowed_functions = SS.of_list
  (List.map String.lowercase_ascii
    [ "LEAST"; "GREATEST"; "ABS"; "EXTRACT"; "DATE_PART"; "DATE_TRUNC"
    ; "LOWER"; "UPPER"; "LENGTH"; "COALESCE"; "NULLIF"; "NOW"; "AGE"
    ; "MAKE_INTERVAL"; "ARRAY_LENGTH"; "JSONB_ARRAY_LENGTH"
    ; "SIMILARITY"; "POSITION"; "SUBSTRING"; "TRIM"; "REPLACE"
    ; "REGEXP_MATCH"; "REGEXP_MATCHES"
    ])

let allowed_types = SS.of_list
  (List.map String.lowercase_ascii
    [ "float"; "float4"; "float8"; "int"; "int4"; "int8"; "integer"
    ; "bigint"; "text"; "varchar"; "boolean"; "bool"; "timestamptz"
    ; "timestamp"; "interval"; "vector"; "jsonb"; "date"
    ])

let allowed_node_types = SS.of_list
  [ "ColumnRef"; "A_Const"; "TypeCast"; "ParamRef"
  ; "FuncCall"; "A_Expr"; "BoolExpr"; "NullTest"; "CoalesceExpr"
  ; "CaseExpr"; "CaseWhen"; "A_ArrayExpr"; "SubLink"
  ; "BooleanTest"; "A_Indirection"; "A_Indices"
  ; "String"; "Integer"; "Float"; "Boolean"; "Null"
  (* structural wrappers the parser emits *)
  ; "ResTarget"; "SelectStmt"; "RawStmt"
  ]

(* ---------- JSON tree walker ---------- *)

type error = string

let fail msg = Error msg

let rec walk_with_template (tn : SS.t) (json : Yojson.Safe.t) : (unit, error) result =
  match json with
  | `Assoc kv -> walk_assoc tn kv
  | `List items -> walk_list tn items
  | _ -> Ok ()

and walk_list tn items =
  let rec go = function
    | [] -> Ok ()
    | x :: rest ->
        (match walk_with_template tn x with Ok () -> go rest | Error _ as e -> e)
  in
  go items

and walk_assoc tn kv =
  match kv with
  | [(node_type, children)] when String.length node_type > 0
      && Char.uppercase_ascii node_type.[0] = node_type.[0] ->
      check_node tn node_type children
  | _ ->
      walk_list tn (List.map snd kv)

and check_node tn (node_type : string) (children : Yojson.Safe.t) : (unit, error) result =
  (* Allow any node type that the wrapper template itself produces *)
  if SS.mem node_type tn then
    walk_with_template tn children
  else if not (SS.mem node_type allowed_node_types) then
    fail (Printf.sprintf "forbidden SQL node type: %s" node_type)
  else
    match node_type with
    | "ColumnRef" -> check_column_ref children
    | "FuncCall" -> check_func_call tn children
    | "TypeCast" -> check_type_cast tn children
    | "SubLink" -> fail "subqueries (SubLink) are not allowed"
    | _ -> walk_with_template tn children

and check_column_ref (children : Yojson.Safe.t) : (unit, error) result =
  let fields =
    match children with
    | `Assoc kv -> (
        match List.assoc_opt "fields" kv with
        | Some (`List fs) -> fs
        | _ -> [])
    | _ -> []
  in
  let col_parts = fields |> List.filter_map (fun f ->
    match f with
    | `Assoc [("String", `Assoc sv)] -> (
        match List.assoc_opt "sval" sv with
        | Some (`String s) -> Some s
        | _ -> None)
    | _ -> None)
  in
  let col_name = String.concat "." col_parts in
  if col_name = "" then Ok ()  (* e.g. A_Star *)
  else if SS.mem col_name allowed_columns || SS.mem (String.lowercase_ascii col_name) allowed_columns then
    Ok ()
  else
    fail (Printf.sprintf "forbidden column reference: %s" col_name)

and check_func_call tn (children : Yojson.Safe.t) : (unit, error) result =
  let funcname =
    match children with
    | `Assoc kv -> (
        match List.assoc_opt "funcname" kv with
        | Some (`List names) ->
            names |> List.filter_map (fun n ->
              match n with
              | `Assoc [("String", `Assoc sv)] -> (
                  match List.assoc_opt "sval" sv with
                  | Some (`String s) -> Some s
                  | _ -> None)
              | _ -> None)
            |> (fun parts -> String.concat "." parts)
        | _ -> "")
    | _ -> ""
  in
  if funcname = "" then walk_with_template tn children
  else if SS.mem (String.lowercase_ascii funcname) allowed_functions then
    walk_with_template tn children
  else
    fail (Printf.sprintf "forbidden function: %s" funcname)

and check_type_cast tn (children : Yojson.Safe.t) : (unit, error) result =
  let type_name =
    match children with
    | `Assoc kv -> (
        match List.assoc_opt "typeName" kv with
        | Some (`Assoc tn_kv) -> (
            match List.assoc_opt "names" tn_kv with
            | Some (`List names) ->
                names |> List.filter_map (fun n ->
                  match n with
                  | `Assoc [("String", `Assoc sv)] -> (
                      match List.assoc_opt "sval" sv with
                      | Some (`String s) -> Some s
                      | _ -> None)
                  | _ -> None)
                |> List.rev |> (fun l -> match l with [] -> "" | x :: _ -> x)
            | _ -> "")
        | _ -> "")
    | _ -> ""
  in
  if type_name <> "" && not (SS.mem (String.lowercase_ascii type_name) allowed_types) then
    fail (Printf.sprintf "forbidden type cast: %s" type_name)
  else
    walk_with_template tn children

(* ---------- template node discovery ---------- *)

let rec collect_node_types acc (json : Yojson.Safe.t) : SS.t =
  match json with
  | `Assoc [(node_type, children)] when String.length node_type > 0
      && Char.uppercase_ascii node_type.[0] = node_type.[0] ->
      collect_node_types (SS.add node_type acc) children
  | `Assoc kv -> List.fold_left (fun a (_, v) -> collect_node_types a v) acc kv
  | `List items -> List.fold_left collect_node_types acc items
  | _ -> acc

let template_node_types ~(wrapper : string) : SS.t =
  let sql = Scanf.format_from_string wrapper "%s" |> fun fmt -> Printf.sprintf fmt "1=1" in
  match Pg_query.parse sql with
  | Error _ -> SS.empty
  | Ok tree ->
      match Yojson.Safe.from_string tree with
      | exception _ -> SS.empty
      | json -> collect_node_types SS.empty json

(* ---------- public API ---------- *)

let validate_fragment ~(wrapper : string) ~(template_nodes : SS.t) (fragment : string) : (string, string) result =
  let fragment = String.trim fragment in
  if fragment = "" then Error "empty SQL fragment"
  else
    let sql = Scanf.format_from_string wrapper "%s" |> fun fmt -> Printf.sprintf fmt fragment in
    match Pg_query.parse sql with
    | Error msg -> Error (Printf.sprintf "SQL parse error: %s" msg)
    | Ok parse_tree ->
        match Yojson.Safe.from_string parse_tree with
        | exception _ -> Error "failed to parse libpg_query JSON output"
        | json ->
            match walk_with_template template_nodes json with
            | Ok () -> Ok fragment
            | Error msg -> Error msg

let filter_wrapper = "SELECT 1 FROM emails e JOIN email_chunks ec ON true WHERE (%s)"
let filter_template_nodes = template_node_types ~wrapper:filter_wrapper

let score_wrapper = "SELECT (%s) AS score FROM emails e JOIN email_chunks ec ON true"
let score_template_nodes = template_node_types ~wrapper:score_wrapper

let validate_filter (fragment : string) : (string, string) result =
  validate_fragment ~wrapper:filter_wrapper ~template_nodes:filter_template_nodes fragment

let validate_score (fragment : string) : (string, string) result =
  validate_fragment ~wrapper:score_wrapper ~template_nodes:score_template_nodes fragment
