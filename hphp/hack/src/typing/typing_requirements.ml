(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open Nast
open Typing_defs

module Env = Typing_env
module Inst = Typing_instantiate
module Reason = Typing_reason
module TUtils = Typing_utils

(*****************************************************************************)
(* Called from the type-decl phase *)
(*****************************************************************************)

let check_arity pos class_name class_type class_parameters =
  let arity = List.length class_type.tc_tparams in
  if List.length class_parameters <> arity
  then Errors.class_arity pos class_type.tc_pos class_name arity;
  ()

let make_substitution pos class_name class_type class_parameters =
  check_arity pos class_name class_type class_parameters;
  Inst.make_subst class_type.tc_tparams class_parameters

(* Accumulate requirements so that we can successfully check the bodies
 * of trait methods / check that classes satisfy these requirements *)
let flatten_parent_class_reqs class_nast
    (env, req_ancestors, req_ancestors_extends) parent_hint =
  let parent_pos, parent_name, parent_params =
    TUtils.unwrap_class_hint parent_hint in
  let env, parent_params = List.map_env env parent_params Typing_hint.hint in
  let parent_type = Env.get_class_dep env parent_name in

  match parent_type with
  | None ->
    (* The class lives in PHP *)
    env, req_ancestors, req_ancestors_extends
  | Some parent_type ->
    let subst =
      make_substitution parent_pos parent_name parent_type parent_params in
    let req_ancestors =
      List.rev_map_append parent_type.tc_req_ancestors req_ancestors
        begin fun (_p, ty) ->
          let ty = Inst.instantiate subst ty in
          parent_pos, ty
        end in
    match class_nast.c_kind with
    | Ast.Cnormal | Ast.Cabstract ->
      (* not necessary to accumulate req_ancestors_extends for classes --
       * it's not used *)
      env, req_ancestors, SSet.empty
    | Ast.Ctrait | Ast.Cinterface ->
      let req_ancestors_extends = SSet.union
        parent_type.tc_req_ancestors_extends req_ancestors_extends in
      env, req_ancestors, req_ancestors_extends
    | Ast.Cenum -> assert false

let declared_class_req (env, requirements, req_extends) hint =
  let env, req_ty = Typing_hint.hint env hint in
  let req_pos, req_name, req_params = TUtils.unwrap_class_hint hint in
  let env, _ = List.map_env env req_params Typing_hint.hint in
  let req_type = Env.get_class_dep env req_name in
  let req_extends = SSet.add req_name req_extends in
  (* since the req is declared on this class, we should
   * emphatically *not* substitute: a require extends Foo<T> is
   * going to be this class's <T> *)
  let requirements = (req_pos, req_ty) :: requirements in
  match req_type with
  | None -> (* The class lives in PHP : error?? *)
    env, requirements, req_extends
  | Some parent_type -> (* The parent class lives in Hack *)
    let req_extends = SSet.union parent_type.tc_extends req_extends in
    (* the req may be of an interface that has reqs of its own; the
     * flattened ancestry required by *those* reqs need to be added
     * in to, e.g., interpret accesses to protected functions inside
     * traits *)
    let req_extends =
      SSet.union parent_type.tc_req_ancestors_extends req_extends in
    env, requirements, req_extends

(* Cheap hack: we cannot do unification / subtyping in the decl phase because
 * the type arguments of the types that we are trying to unify may not have
 * been declared yet. See the test iface_require_circular.php for details.
 *
 * However, we don't want a super long req_extends list because of the perf
 * overhead. And while we can't do proper unification we can dedup types
 * that are syntactically equivalent.
 *
 * A nicer solution might be to add a phase in between type-decl and type-check
 * that prunes the list via proper subtyping, but that's a little more work
 * than I'm willing to do now. *)
let naive_dedup req_extends =
  (* maps class names to type params *)
  let h = Hashtbl.create 0 in
  List.rev_filter_map req_extends begin fun (parent_pos, ty) ->
    match ty with
    | _r, Tapply (name, hl) ->
      let hl = List.map hl Typing_pos_utils.NormalizeSig.ty in
      begin try
        let hl' = Hashtbl.find h name in
        if List.compare ~cmp:Pervasives.compare hl hl' <> 0 then
          raise Exit
        else
          None
      with
      | Exit
      | Not_found ->
        Hashtbl.add h name hl;
        Some (parent_pos, ty)
      end
    | _ -> Some (parent_pos, ty)
  end

let get_class_requirements env class_nast =
  let req_ancestors_extends = SSet.empty in
  let acc = (env, [], req_ancestors_extends) in
  let acc =
    List.fold_left ~f:declared_class_req ~init:acc class_nast.c_req_extends in
  let acc =
    List.fold_left ~f:declared_class_req
      ~init:acc class_nast.c_req_implements in
  let acc =
    List.fold_left ~f:(flatten_parent_class_reqs class_nast)
      ~init:acc class_nast.c_uses in
  let acc =
    List.fold_left ~f:(flatten_parent_class_reqs class_nast)
      ~init:acc (if class_nast.c_kind = Ast.Cinterface then
          class_nast.c_extends else class_nast.c_implements) in
  let env, req_extends, req_ancestors_extends = acc in
  let req_extends = naive_dedup req_extends in
  env, req_extends, req_ancestors_extends

(*****************************************************************************)
(* Called from the type-check phase *)
(*****************************************************************************)

(* Only applied to classes. Checks that all the requirements of the traits
 * and interfaces it uses are satisfied. *)
let check_fulfillment env impls (parent_pos, req_ty) =
  match TUtils.try_unwrap_class_type req_ty with
  | None -> ()
  | Some (_r, (_p, req_name), _paraml) ->
    match SMap.get req_name impls with
    | None ->
      let req_pos = Reason.to_pos (fst req_ty) in
      Errors.unsatisfied_req parent_pos req_name req_pos;
      ()
    | Some impl_ty ->
      ignore @@ Typing_ops.sub_type_decl parent_pos Reason.URclass_req env
        req_ty impl_ty

let check_class env tc =
  match tc.tc_kind with
  | Ast.Cnormal | Ast.Cabstract ->
    List.iter tc.tc_req_ancestors (check_fulfillment env tc.tc_ancestors)
  | Ast.Ctrait | Ast.Cinterface | Ast.Cenum -> ()
