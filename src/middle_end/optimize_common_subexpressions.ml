open Anftree
open Grain_typed
open Types

module ExpressionHash =
  struct
    type t = comp_expression_desc
    let compare_lists l1 l2 = List.fold_left2 (fun is_equal {imm_desc=exp1} {imm_desc=exp2} -> is_equal && exp1 = exp2) true l1 l2
    let equal i j = match (i, j) with
      | CImmExpr({imm_desc=desc1}), CImmExpr({imm_desc=desc2}) -> 
        desc1 = desc2
      | CPrim1(p1, {imm_desc=desc1}), CPrim1(p2, {imm_desc=desc2}) -> 
        desc1 = desc2 && p1 = p2
      | CPrim2(p1, {imm_desc=x1}, {imm_desc=y1}), CPrim2(p2, {imm_desc=x2}, {imm_desc=y2}) -> 
        p1 = p2 && x1 = x2 && y1 = y2
      | CTuple(exps1), CTuple(exps2) -> 
        compare_lists exps1 exps2
      | CApp({imm_desc=desc1}, args1), CApp({imm_desc=desc2}, args2) -> 
        desc1 = desc2 && compare_lists args1 args2
      | CAppBuiltin(_module1, name1, args1), CAppBuiltin(_module2, name2, args2) -> 
        _module1 = _module2 && name1 = name2 && compare_lists args1 args2
      | CString(string1), CString(string2) ->
        string1 = string2
      | _ -> false
    let hash i = match i with
      | CImmExpr({imm_desc=desc}) -> 
        100 lxor Hashtbl.hash desc
      | CPrim1(p, {imm_desc=desc}) -> 
        200 lxor Hashtbl.hash p lxor Hashtbl.hash desc
      | CPrim2(p, {imm_desc=x}, {imm_desc=y}) -> 
        300 lxor Hashtbl.hash p lxor Hashtbl.hash x lxor Hashtbl.hash y
      | CTuple(exps) -> 
        List.fold_left (fun hash {imm_desc} -> hash lxor Hashtbl.hash imm_desc) 400 exps
      | CApp({imm_desc=desc}, args) -> 
        500 lxor List.fold_left (fun hash {imm_desc} -> hash lxor Hashtbl.hash imm_desc) (Hashtbl.hash desc) args
      | CAppBuiltin(_module, name, args) -> 
        600 lxor Hashtbl.hash _module lxor List.fold_left (fun hash {imm_desc} -> hash lxor Hashtbl.hash imm_desc) (Hashtbl.hash name) args
      | CString(string) ->
        700 lxor Hashtbl.hash string
      | _ -> Hashtbl.hash i
  end

module ExpressionHashtbl = Hashtbl.Make(ExpressionHash)


let pure_identifiers = ref (Ident.empty : bool Ident.tbl)
let rewrite_rules = ref (Ident.empty : Ident.t Ident.tbl)
let known_expressions = ExpressionHashtbl.create 50


let create_rewrite_rule a b =
  rewrite_rules := Ident.add a b !rewrite_rules

let get_rewrite_rule id =
  try
    Ident.find_same id !rewrite_rules
  with
  | Not_found -> id

let push_expression e id =
  ExpressionHashtbl.add known_expressions e id

let pop_expression e =
  ExpressionHashtbl.remove known_expressions e

let get_known_expression e =
  ExpressionHashtbl.find_opt known_expressions e

let is_pure_identifier id =
  try
    Ident.find_same id !pure_identifiers
  with
  | Not_found -> false

module CSEArg : Anf_mapper.MapArgument = struct
  include Anf_mapper.DefaultMapArgument

  let enter_anf_expression ({anf_desc = desc} as a) =
    begin match desc with
    | AELet(_, _, binds, _) ->
      List.iter (fun (id, {comp_desc}) ->
        ignore @@ is_pure_identifier id;
        match get_known_expression comp_desc with
        | Some(known_id) -> create_rewrite_rule id known_id
        | None -> if is_pure_identifier id then push_expression comp_desc id
      ) binds
    | _ -> ()
    end;
    a

  let leave_imm_expression ({imm_desc = desc} as i) =
    match desc with
    | ImmId(id) -> {i with imm_desc=ImmId(get_rewrite_rule id)}
    | _ -> i

  let leave_anf_expression ({anf_desc = desc} as a) =
    begin match desc with
    | AELet(_, _, binds, _) ->
      List.iter (fun (id, {comp_desc}) ->
        match get_known_expression comp_desc with
        | Some(known_id) when id = known_id -> pop_expression comp_desc
        | _ -> ()
      ) binds
    | _ -> ()
    end;
    a

end

module CSEMapper = Anf_mapper.MakeMap(CSEArg)

let optimize anfprog =
  (* Reset state *)
  pure_identifiers := Analyze_purity.pure_identifiers anfprog;
  rewrite_rules := Ident.empty;
  ExpressionHashtbl.reset known_expressions;
  CSEMapper.map_anf_program anfprog