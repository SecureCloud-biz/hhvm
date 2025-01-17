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

(*****************************************************************************)
(* Error. *)
(*****************************************************************************)

let canon_set names =
  names
  |> SSet.elements
  |> List.map ~f:NamingGlobal.canon_key
  |> List.fold_right ~f:SSet.add ~init:SSet.empty

let report_error exn =
  let exn_str = Printexc.to_string exn in
  Printf.printf "Could not auto-complete because of errors: %s\n" exn_str;
  flush stdout;
  ()

let oldify_funs names =
  Naming_heap.FunPosHeap.oldify_batch names;
  Naming_heap.FunCanonHeap.oldify_batch @@ canon_set names;
  Naming_heap.FunHeap.oldify_batch names;
  Typing_env.Funs.oldify_batch names;
  ()

let oldify_classes names =
  Naming_heap.TypeIdHeap.oldify_batch names;
  Naming_heap.TypeCanonHeap.oldify_batch @@ canon_set names;
  Naming_heap.ClassHeap.oldify_batch names;
  Typing_env.Classes.oldify_batch names;
  ()

let revive funs classes =
  Naming_heap.FunHeap.revive_batch funs;
  Typing_env.Funs.revive_batch funs;
  Naming_heap.FunPosHeap.revive_batch funs;
  Naming_heap.FunCanonHeap.revive_batch @@ canon_set funs;

  Naming_heap.ClassHeap.revive_batch classes;
  Typing_env.Classes.revive_batch classes;
  Naming_heap.TypeIdHeap.revive_batch classes;
  Naming_heap.TypeCanonHeap.revive_batch @@ canon_set classes

(* This will parse, name and declare all functions and classes in content
 * buffer.
 *
 * Naming and declaring will overwrite definitions on shared heap, so before
 * doing this, the function will also "oldify" them (see functions above and
 * SharedMem.S.oldify_batch) - after working with local content is done,
 * original definitions can (and should) be restored using "revive".
 *)
let declare path content =
  let tcopt = TypecheckerOptions.permissive in
  Autocomplete.auto_complete := false;
  Autocomplete.auto_complete_for_global := "";
  let declared_funs = ref SSet.empty in
  let declared_classes = ref SSet.empty in
  try
    Errors.ignore_ begin fun () ->
      let {Parser_hack.file_mode; comments; ast} =
        Parser_hack.program path content
      in
      let funs, classes = List.fold_left ast ~f:begin fun (funs, classes) def ->
        match def with
          | Ast.Fun { Ast.f_name; _ } ->
            declared_funs := SSet.add (snd f_name) !declared_funs;
            f_name::funs, classes
          | Ast.Class { Ast.c_name; _ } ->
            declared_classes := SSet.add (snd c_name) !declared_classes;
            funs, c_name::classes
          | _ -> funs, classes
      end ~init:([], []) in
      oldify_funs !declared_funs;
      oldify_classes !declared_classes;
      NamingGlobal.make_env ~funs ~classes ~typedefs:[] ~consts:[];
      List.iter ast begin fun def ->
        match def with
        | Ast.Fun f ->
            let f = Naming.fun_ tcopt f in
            Naming_heap.FunHeap.add (snd f.Nast.f_name) f;
            Typing_decl.fun_decl tcopt f;
        | Ast.Class c ->
            let c = Naming.class_ tcopt c in
            Naming_heap.ClassHeap.add (snd c.Nast.c_name) c;
            Typing_decl.class_decl tcopt c;
        | _ -> ()
      end;
      !declared_funs, !declared_classes
    end
  with e ->
    report_error e;
    SSet.empty, SSet.empty

let typecheck funs classes = try
    let tcopt = TypecheckerOptions.permissive in
    Errors.ignore_ begin fun () ->
      SSet.iter begin fun name ->
        Option.iter (Naming_heap.FunHeap.get name)
          (fun f -> Typing.fun_def tcopt (snd f.Nast.f_name) f)
      end funs;
      SSet.iter begin fun name ->
        Option.iter (Naming_heap.ClassHeap.get name)
          (fun c -> Typing.class_def tcopt (snd c.Nast.c_name) c)
      end classes;
    end
  with e ->
    report_error e

let recheck tcopt fileinfo_l =
  SharedMem.invalidate_caches();
  List.iter fileinfo_l begin fun defs ->
    ignore @@ Typing_check_utils.check_defs tcopt defs
  end

let check_file_input tcopt files_info fi =
  match fi with
  | ServerUtils.FileContent content ->
      let path = Relative_path.default in
      let funs, classes = declare path content in
      typecheck funs classes;
      revive funs classes;
      path
  | ServerUtils.FileName fn ->
      let path = Relative_path.create Relative_path.Root fn in
      let () = match Relative_path.Map.get path files_info with
      | Some fileinfo -> recheck tcopt [fileinfo]
      | None -> () in
      path
