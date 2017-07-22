open Import
open Jbuild
open Build.O
open! No_io

(* +-----------------------------------------------------------------+
   | Utils                                                           |
   +-----------------------------------------------------------------+ *)

module type Params = sig
  val sctx : Super_context.t
end

module Gen(P : Params) = struct
  module SC = Super_context
  open P

  let ctx = SC.context sctx

  (* +-----------------------------------------------------------------+
     | Interpretation of [modules] fields                              |
     +-----------------------------------------------------------------+ *)

  let parse_modules ~dir ~all_modules ~modules_written_by_user =
    if Ordered_set_lang.is_standard modules_written_by_user then
      all_modules
    else begin
      let units =
        Ordered_set_lang.eval_with_standard
          modules_written_by_user
          ~standard:(String_map.keys all_modules)
      in
      List.iter units ~f:(fun unit ->
        if not (String_map.mem unit all_modules) then
          die "no implementation for module %s in %s"
            unit (Path.to_string dir));
      let units = String_set.of_list units in
      String_map.filter all_modules ~f:(fun unit _ -> String_set.mem unit units)
    end

  (* +-----------------------------------------------------------------+
     | Library stuff                                                   |
     +-----------------------------------------------------------------+ *)

  let lib_archive (lib : Library.t) ~dir ~ext = Path.relative dir (lib.name ^ ext)

  let stubs_archive lib ~dir =
    Library.stubs_archive lib ~dir ~ext_lib:ctx.ext_lib

  let dll (lib : Library.t) ~dir =
    Path.relative dir (sprintf "dll%s_stubs%s" lib.name ctx.ext_dll)

  let msvc_hack_cclibs cclibs =
    let f lib =
      if String.is_prefix lib ~prefix:"-l" then
        String.sub lib ~pos:2 ~len:(String.length lib - 2) ^ ".lib"
      else
        lib
    in
    let cclibs = List.map cclibs ~f in
    let f lib =
      if String.is_prefix lib ~prefix:"-l" then
        String.sub lib ~pos:2 ~len:(String.length lib - 2)
      else
        lib
    in
    List.map cclibs ~f

  let build_lib (lib : Library.t) ~scope ~flags ~dir ~mode ~modules ~dep_graph =
    Option.iter (Context.compiler ctx mode) ~f:(fun compiler ->
      let target = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext mode) in
      let dep_graph = Ml_kind.Dict.get dep_graph Impl in
      let stubs_flags =
        if not (Library.has_stubs lib) then
          []
        else
          let stubs_name = lib.name ^ "_stubs" in
          match mode with
          | Byte -> ["-dllib"; "-l" ^ stubs_name; "-cclib"; "-l" ^ stubs_name]
          | Native -> ["-cclib"; "-l" ^ stubs_name]
      in
      let map_cclibs =
        (* https://github.com/janestreet/jbuilder/issues/119 *)
        if ctx.ccomp_type = "msvc" then
          msvc_hack_cclibs
        else
          fun x -> x
      in
      SC.add_rule sctx
        (Build.fanout
           (dep_graph >>>
            Build.arr (fun dep_graph ->
              Ocamldep.names_to_top_closed_cm_files
                ~dir
                ~dep_graph
                ~modules
                ~mode
                (String_map.keys modules)))
           (SC.expand_and_eval_set ~dir lib.c_library_flags ~standard:[])
         >>>
         Build.run ~context:ctx (Dep compiler)
           ~extra_targets:(
             match mode with
             | Byte -> []
             | Native -> [lib_archive lib ~dir ~ext:ctx.ext_lib])
           [ Ocaml_flags.get flags mode
           ; A "-a"; A "-o"; Target target
           ; As stubs_flags
           ; Dyn (fun (_, cclibs) -> Arg_spec.quote_args "-cclib" (map_cclibs cclibs))
           ; As (List.map lib.library_flags ~f:(SC.expand_vars sctx ~scope ~dir))
           ; As (match lib.kind with
               | Normal -> []
               | Ppx_deriver | Ppx_rewriter -> ["-linkall"])
           ; Dyn (fun (cm_files, _) -> Deps cm_files)
           ]))

  let build_c_file (lib : Library.t) ~dir ~requires ~h_files c_name =
    let src = Path.relative dir (c_name ^ ".c") in
    let dst = Path.relative dir (c_name ^ ctx.ext_obj) in
    SC.add_rule sctx
      (Build.paths h_files
       >>>
       Build.fanout
         (SC.expand_and_eval_set ~dir lib.c_flags ~standard:(Context.cc_g ctx))
         requires
       >>>
       Build.run ~context:ctx
         (* We have to execute the rule in the library directory as the .o is produced in
            the current directory *)
         ~dir
         (Dep ctx.ocamlc)
         [ As (Utils.g ())
         ; Dyn (fun (c_flags, libs) ->
             S [ Lib.c_include_flags libs
               ; Arg_spec.quote_args "-ccopt" c_flags
               ])
         ; A "-o"; Target dst
         ; Dep src
         ]);
    dst

  let build_cxx_file (lib : Library.t) ~dir ~requires ~h_files c_name =
    let src = Path.relative dir (c_name ^ ".cpp") in
    let dst = Path.relative dir (c_name ^ ctx.ext_obj) in
    SC.add_rule sctx
      (Build.paths h_files
       >>>
       Build.fanout
         (SC.expand_and_eval_set ~dir lib.cxx_flags ~standard:(Context.cc_g ctx))
         requires
       >>>
       Build.run ~context:ctx
         (* We have to execute the rule in the library directory as the .o is produced in
            the current directory *)
         ~dir
         (SC.resolve_program sctx ctx.c_compiler
            (* The C compiler surely is not in the tree *)
            ~in_the_tree:false)
         [ S [A "-I"; Path ctx.stdlib_dir]
         ; As (SC.cxx_flags sctx)
         ; Dyn (fun (cxx_flags, libs) ->
             S [ Lib.c_include_flags libs
               ; As cxx_flags
               ])
         ; A "-o"; Target dst
         ; A "-c"; Dep src
         ]);
    dst

  (* Hack for the install file *)
  let modules_by_lib : (string, Module.t list) Hashtbl.t = Hashtbl.create 32

  (* In 4.02, the compiler reads the cmi for module alias even with [-w -49
     -no-alias-deps], so we must sandbox the build of the alias module since the modules
     it references are built after. *)
  let alias_module_build_sandbox = Scanf.sscanf ctx.version "%u.%u"
     (fun a b -> a, b) <= (4, 02)

  let library_rules (lib : Library.t) ~dir ~all_modules ~files ~scope =
    let dep_kind = if lib.optional then Build.Optional else Required in
    let flags = Ocaml_flags.make lib.buildable in
    let modules =
      parse_modules ~dir ~all_modules ~modules_written_by_user:lib.buildable.modules
    in
    let main_module_name = String.capitalize_ascii lib.name in
    let modules =
      String_map.map modules ~f:(fun (m : Module.t) ->
        if not lib.wrapped || m.name = main_module_name then
          { m with obj_name = Utils.obj_name_of_basename m.impl.name }
        else
          { m with obj_name = sprintf "%s__%s" lib.name m.name })
    in
    let alias_module =
      if not lib.wrapped ||
         (String_map.cardinal modules = 1 &&
          String_map.mem main_module_name modules) then
        None
      else
        let suf =
          if String_map.mem main_module_name modules then
            "__"
          else
            ""
        in
        Some
          { Module.name = main_module_name ^ suf
          ; impl = { name = lib.name ^ suf ^ ".ml-gen" ; syntax = OCaml }
          ; intf = None
          ; obj_name = lib.name ^ suf
          }
    in
    (* Add the modules before preprocessing, otherwise the install rules are going to pick
       up the pre-processed modules *)
    Hashtbl.add modules_by_lib
      ~key:lib.name
      ~data:(
        let modules =
          match alias_module with
          | None -> modules
          | Some m -> String_map.add modules ~key:m.name ~data:m
        in
        String_map.values modules);
    (* Preprocess before adding the alias module as it doesn't need preprocessing *)
    let modules =
      SC.PP.pped_modules sctx ~dir ~dep_kind ~modules ~preprocess:lib.buildable.preprocess
        ~preprocessor_deps:lib.buildable.preprocessor_deps
        ~lib_name:(Some lib.name)
        ~scope
    in
    let modules =
      match alias_module with
      | None -> modules
      | Some m -> String_map.add modules ~key:m.name ~data:m
    in

    let dep_graph =
      Ocamldep.rules sctx ~dir ~item:lib.name ~modules ~alias_module
        ~lib_interface_module:(if lib.wrapped then
                                 String_map.find main_module_name modules
                               else
                                 None)
    in

    Option.iter alias_module ~f:(fun m ->
      SC.add_rule sctx
        (Build.return
           (String_map.values (String_map.remove m.name modules)
            |> List.map ~f:(fun (m : Module.t) ->
              sprintf "(** @canonical %s.%s *)\n\
                       module %s = %s\n"
                main_module_name m.name
                m.name (Module.real_unit_name m))
            |> String.concat ~sep:"\n")
         >>> Build.update_file_dyn (Path.relative dir m.impl.name)));

    let requires, real_requires =
      SC.Libs.requires sctx ~dir ~dep_kind ~item:lib.name
        ~libraries:lib.buildable.libraries
        ~preprocess:lib.buildable.preprocess
        ~virtual_deps:lib.virtual_deps
    in

    SC.Libs.setup_runtime_deps sctx ~dir ~dep_kind ~item:lib.name
      ~libraries:lib.buildable.libraries
      ~ppx_runtime_libraries:lib.ppx_runtime_libraries;
    SC.Libs.add_select_rules sctx ~dir lib.buildable.libraries;

    let dynlink = lib.dynlink in
    let js_of_ocaml = lib.buildable.js_of_ocaml in
    Module_compilation.build_modules sctx
      ~js_of_ocaml ~dynlink ~flags ~dir ~dep_graph ~modules ~requires ~alias_module;
    Option.iter alias_module ~f:(fun m ->
      let flags = Ocaml_flags.default () in
      Module_compilation.build_module sctx m
         ~js_of_ocaml
        ~dynlink
        ~sandbox:alias_module_build_sandbox
        ~flags:{ flags with common = flags.common @ ["-w"; "-49"] }
        ~dir
        ~modules:(String_map.singleton m.name m)
        ~dep_graph:(Ml_kind.Dict.make_both (Build.return (String_map.singleton m.name [])))
        ~requires:(
          let requires =
            if String_map.is_empty modules then
              (* Just so that we setup lib dependencies for empty libraries *)
              requires
            else
              Build.return []
          in
          Cm_kind.Dict.of_func (fun ~cm_kind:_ -> requires))
        ~alias_module:None);

    if Library.has_stubs lib then begin
      let h_files =
        String_set.elements files
        |> List.filter_map ~f:(fun fn ->
          if String.is_suffix fn ~suffix:".h" then
            Some (Path.relative dir fn)
          else
            None)
      in
      let o_files =
        let requires =
          Build.memoize "header files"
            (requires >>> SC.Libs.file_deps sctx ~ext:".h")
        in
        List.map lib.c_names   ~f:(build_c_file   lib ~dir ~requires ~h_files) @
        List.map lib.cxx_names ~f:(build_cxx_file lib ~dir ~requires ~h_files)
      in
      match lib.self_build_stubs_archive with
      | Some _ -> ()
      | None ->
        let ocamlmklib ~sandbox ~custom ~targets =
          SC.add_rule sctx ~sandbox
            (SC.expand_and_eval_set ~dir lib.c_library_flags ~standard:[]
             >>>
             Build.run ~context:ctx
               ~extra_targets:targets
               (Dep ctx.ocamlmklib)
               [ As (Utils.g ())
               ; if custom then A "-custom" else As []
               ; A "-o"
               ; Path (Path.relative dir (sprintf "%s_stubs" lib.name))
               ; Deps o_files
               ; Dyn (fun cclibs ->
                   (* https://github.com/janestreet/jbuilder/issues/119 *)
                   if ctx.ccomp_type = "msvc" then
                     let cclibs = msvc_hack_cclibs cclibs in
                     Arg_spec.quote_args "-ldopt" cclibs
                   else
                     As cclibs
                 )
               ])
        in
        let static = stubs_archive lib ~dir in
        let dynamic = dll lib ~dir in
        if lib.modes.native &&
           lib.modes.byte   &&
           lib.dynlink
        then begin
          (* If we build for both modes and support dynlink, use a single invocation to
             build both the static and dynamic libraries *)
          ocamlmklib ~sandbox:false ~custom:false ~targets:[static; dynamic]
        end else begin
          ocamlmklib ~sandbox:false ~custom:true ~targets:[static];
          (* We can't tell ocamlmklib to build only the dll, so we sandbox the action to
             avoid overriding the static archive *)
          ocamlmklib ~sandbox:true ~custom:false ~targets:[dynamic]
        end
    end;

    List.iter Cm_kind.all ~f:(fun cm_kind ->
      let files =
        String_map.fold modules ~init:[] ~f:(fun ~key:_ ~data:m acc ->
          Module.cm_file m ~dir cm_kind :: acc)
      in
      SC.Libs.setup_file_deps_alias sctx (dir, lib) ~ext:(Cm_kind.ext cm_kind)
        files);
    SC.Libs.setup_file_deps_group_alias sctx (dir, lib) ~exts:[".cmi"; ".cmx"];
    SC.Libs.setup_file_deps_alias sctx (dir, lib) ~ext:".h"
      (List.map lib.install_c_headers ~f:(fun header ->
         Path.relative dir (header ^ ".h")));

    List.iter Mode.all ~f:(fun mode ->
      build_lib lib ~scope ~flags ~dir ~mode ~modules ~dep_graph);
    (* Build *.cma.js *)
    SC.add_rules sctx (
      let src = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext Mode.Byte) in
      Js_of_ocaml_rules.build_cm sctx ~dir ~js_of_ocaml:lib.buildable.js_of_ocaml ~src);

    if ctx.natdynlink_supported then
      Option.iter ctx.ocamlopt ~f:(fun ocamlopt ->
        let src = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext Native) in
        let dst = lib_archive lib ~dir ~ext:".cmxs" in
        let build =
          Build.run ~context:ctx
            (Dep ocamlopt)
            [ Ocaml_flags.get flags Native
            ; A "-shared"; A "-linkall"
            ; A "-I"; Path dir
            ; A "-o"; Target dst
            ; Dep src
            ]
        in
        let build =
          if Library.has_stubs lib then
            Build.path (stubs_archive ~dir lib)
            >>>
            build
          else
            build
        in
        SC.add_rule sctx build
      );

    (* Odoc *)
    Odoc.setup_library_rules sctx lib ~dir ~requires ~modules ~dep_graph;

    let flags =
      match alias_module with
      | None -> flags.common
      | Some m -> "-open" :: m.name :: flags.common
    in
    { Merlin.
      requires = real_requires
    ; flags
    ; preprocess = Buildable.single_preprocess lib.buildable
    ; libname = Some lib.name
    }

  (* +-----------------------------------------------------------------+
     | Executables stuff                                               |
     +-----------------------------------------------------------------+ *)

  let build_exe ~js_of_ocaml ~flags ~dir ~requires ~name ~mode ~target ~modules ~dep_graph
        ~link_flags ~force_custom_bytecode =
    let exe_ext = (Target.add_suffix target (Mode.exe_ext mode)) in
    let exe = Path.relative dir (name ^ exe_ext) in
    let mode, link_flags, compiler =
      match force_custom_bytecode, Context.compiler ctx mode with
      | false, Some compiler -> (mode, link_flags, compiler)
      | _                    -> (Byte, "-custom" :: link_flags, ctx.ocamlc)
    in
    let dep_graph = Ml_kind.Dict.get dep_graph Impl in
    let libs_and_cm =
      Build.fanout
        (requires
         >>> Build.dyn_paths (Build.arr (Lib.archive_files ~mode ~ext_lib:ctx.ext_lib)))
        (dep_graph
         >>> Build.arr (fun dep_graph ->
           Ocamldep.names_to_top_closed_cm_files
             ~dir
             ~dep_graph
             ~modules
             ~mode
             [String.capitalize_ascii name]))
    in
    let add_rule specific_flags =
      SC.add_rule sctx
        (libs_and_cm >>>
        Build.run ~context:ctx
          (Dep compiler)
          [ Ocaml_flags.get flags mode
          ; As specific_flags
          ; A "-o"; Target exe
          ; As link_flags
          ; Dyn (fun (libs, _) -> Lib.link_flags libs ~mode)
          ; Dyn (fun (_, cm_files) -> Deps cm_files)
          ]);
      if mode = Mode.Byte then
        let rules = Js_of_ocaml_rules.build_exe sctx ~dir ~js_of_ocaml ~src:exe in
        SC.add_rules sctx (List.map rules ~f:(fun r -> libs_and_cm >>> r))
    in
    match target with
      | Target.Exec -> add_rule []
      | Target.Obj -> add_rule ["-output-obj"]

  let executables_rules (exes : Executables.t) ~dir ~all_modules ~scope =
    let dep_kind = Build.Required in
    let flags = Ocaml_flags.make exes.buildable in
    let modules =
      parse_modules ~dir ~all_modules ~modules_written_by_user:exes.buildable.modules
    in
    let modules =
      String_map.map modules ~f:(fun (m : Module.t) ->
        { m with obj_name = Utils.obj_name_of_basename m.impl.name })
    in
    List.iter exes.names ~f:(fun name ->
      if not (String_map.mem (String.capitalize_ascii name) modules) then
        die "executable %s in %s doesn't have a corresponding .ml file"
          name (Path.to_string dir));
    let modules =
      SC.PP.pped_modules sctx ~dir ~dep_kind ~modules
        ~preprocess:exes.buildable.preprocess
        ~preprocessor_deps:exes.buildable.preprocessor_deps
        ~lib_name:None
        ~scope
    in
    let item = List.hd exes.names in
    let dep_graph =
      Ocamldep.rules sctx ~dir ~item ~modules ~alias_module:None
        ~lib_interface_module:None
    in

    let requires, real_requires =
      SC.Libs.requires sctx ~dir ~dep_kind ~item
        ~libraries:exes.buildable.libraries
        ~preprocess:exes.buildable.preprocess
        ~virtual_deps:[]
    in

    SC.Libs.add_select_rules sctx ~dir exes.buildable.libraries;

    (* CR-someday jdimino: this should probably say [~dynlink:false] *)
    Module_compilation.build_modules sctx
      ~js_of_ocaml:exes.buildable.js_of_ocaml
      ~dynlink:true ~flags ~dir ~dep_graph ~modules
      ~requires ~alias_module:None;

    List.iter exes.names ~f:(fun name ->
      List.iter Mode.all ~f:(fun mode ->
        List.iter (Target.Dict.Set.to_list exes.targets) ~f:(fun target ->
        build_exe ~js_of_ocaml:exes.buildable.js_of_ocaml ~flags ~dir ~requires ~name
          ~mode ~target ~modules ~dep_graph ~link_flags:exes.link_flags
          ~force_custom_bytecode:(mode = Native && not exes.modes.native))));
    { Merlin.
      requires   = real_requires
    ; flags      = flags.common
    ; preprocess = Buildable.single_preprocess exes.buildable
    ; libname    = None
    }

  (* +-----------------------------------------------------------------+
     | User rules                                                      |
     +-----------------------------------------------------------------+ *)

  let user_rule (rule : Rule.t) ~dir ~scope =
    let targets : SC.Action.targets =
      match rule.targets with
      | Infer -> Infer
      | Static fns -> Static (List.map fns ~f:(Path.relative dir))
    in
    SC.add_rule sctx
      (SC.Deps.interpret sctx ~scope ~dir rule.deps
       >>>
       SC.Action.run
         sctx
         rule.action
         ~dir
         ~dep_kind:Required
         ~targets
         ~scope)

  let alias_rules (alias_conf : Alias_conf.t) ~dir ~scope =
    let digest =
      let deps =
        Sexp.To_sexp.list Dep_conf.sexp_of_t alias_conf.deps in
      let action =
        match alias_conf.action with
        | None -> Sexp.Atom "none"
        | Some a -> List [Atom "some" ; Action.Unexpanded.sexp_of_t a]
      in
      Sexp.List [deps ; action]
      |> Sexp.to_string
      |> Digest.string
    in
    let alias = Alias.make alias_conf.name ~dir in
    let digest_path = Alias.file_with_digest_suffix alias ~digest in
    Alias.add_deps (SC.aliases sctx) alias [digest_path];
    let deps = SC.Deps.interpret sctx ~scope ~dir alias_conf.deps in
    SC.add_rule sctx
      (match alias_conf.action with
       | None ->
         deps
         >>>
         Build.create_file digest_path
       | Some action ->
         deps
         >>>
         Build.progn
           [ SC.Action.run
               sctx
               action
               ~dir
               ~dep_kind:Required
               ~targets:(Static [])
               ~scope
           ; Build.create_file digest_path
           ])

  (* +-----------------------------------------------------------------+
     | Modules listing                                                 |
     +-----------------------------------------------------------------+ *)

  let ml_of_mli : _ format =
{|(with-stdout-to %s
       (progn
        (echo "[@@@warning \"-a\"]\nmodule rec HACK : sig\n")
        (cat %s)
        (echo "\nend = HACK\ninclude HACK\n")))|}

  let re_of_rei : _ format =
{|(with-stdout-to %s
       (progn
        (echo "[@@@warning \"-a\"];\nmodule type HACK = {\n")
        (cat %s)
        (echo "\n};\nmodule rec HACK : HACK = HACK;\ninclude HACK;\n")))|}

  let no_impl_warning : _ format =
    {|@{<warning>Warning@}: Module %s in %s doesn't have a corresponding .%s file.
Modules without an implementation are not recommended, see this discussion:

  https://github.com/janestreet/jbuilder/issues/9

In the meantime I'm implicitely adding this rule:

(rule %s)

Add it to your jbuild file to remove this warning.
|}

  let guess_modules ~dir ~files =
    let impl_files, intf_files =
      String_set.elements files
      |> List.filter_map ~f:(fun fn ->
        (* we aren't using Filename.extension because we want to handle
           filenames such as foo.cppo.ml *)
        match String.lsplit2 fn ~on:'.' with
        | Some (_, "ml") -> Some (Inl { Module.File.syntax=OCaml ; name=fn })
        | Some (_, "re") -> Some (Inl { Module.File.syntax=Reason ; name=fn })
        | Some (_, "mli") -> Some (Inr { Module.File.syntax=OCaml ; name=fn })
        | Some (_, "rei") -> Some (Inr { Module.File.syntax=Reason ; name=fn })
        | _ -> None)
      |> List.partition_map ~f:(fun x -> x) in
    let parse_one_set files =
      List.map files ~f:(fun (f : Module.File.t) ->
        (String.capitalize_ascii (Filename.chop_extension f.name), f))
      |> String_map.of_alist
      |> function
      | Ok x -> x
      | Error (name, f1, f2) ->
        die "too many files for module %s in %s: %s and %s"
          name (Path.to_string dir) f1.name f2.name
    in
    let impls = parse_one_set impl_files in
    let intfs = parse_one_set intf_files in
    let setup_intf_only name (intf : Module.File.t) =
      let impl_fname = String.sub intf.name ~pos:0 ~len:(String.length intf.name - 1) in
      let action_str =
        sprintf
          (match intf.syntax with
           | OCaml  -> ml_of_mli
           | Reason -> re_of_rei)
          impl_fname intf.name
      in
      Format.eprintf no_impl_warning
        name (Path.to_string dir)
        (match intf.syntax with
         | OCaml  -> "ml"
         | Reason -> "re")
        action_str;
      let dir = Path.append ctx.build_dir dir in
      let action =
        Lexing.from_string action_str
        |> Sexp_lexer.single
        |> Action.Unexpanded.t
      in
      SC.add_rule sctx
        (Build.return []
         >>>
         SC.Action.run sctx action
           ~dir
           ~dep_kind:Required
           ~targets:Infer
           ~scope:Scope.empty);
      { intf with name = impl_fname } in
    String_map.merge impls intfs ~f:(fun name impl intf ->
      let impl =
        match impl with
        | None -> setup_intf_only name (Option.value_exn intf)
        | Some i -> i in
      Some
        { Module.name
        ; impl
        ; intf
        ; obj_name = "" }
    )

  (* +-----------------------------------------------------------------+
     | Stanza                                                          |
     +-----------------------------------------------------------------+ *)

  let rules { SC.Dir_with_jbuild. src_dir; ctx_dir; stanzas; scope } =
    (* Interpret user rules and other simple stanzas first in order to populate the known
       target table, which is needed for guessing the list of modules. *)
    List.iter stanzas ~f:(fun stanza ->
      let dir = ctx_dir in
      match (stanza : Stanza.t) with
      | Rule         rule  -> user_rule   rule  ~dir ~scope
      | Alias        alias -> alias_rules alias ~dir ~scope
      | Library _ | Executables _ | Provides _ | Install _ -> ());
    let files = lazy (
      let files = SC.sources_and_targets_known_so_far sctx ~src_path:src_dir in
      (* Manually add files generated by the (select ...) dependencies since we haven't
         interpreted libraries and executables yet. *)
      List.fold_left stanzas ~init:files ~f:(fun acc stanza ->
        match (stanza : Stanza.t) with
        | Library { buildable; _ } | Executables { buildable; _ } ->
          List.fold_left buildable.libraries ~init:acc ~f:(fun acc dep ->
            match (dep : Jbuild.Lib_dep.t) with
            | Direct _ -> acc
            | Select s -> String_set.add s.result_fn acc)
        | _ -> acc)
    ) in
    let all_modules = lazy (
      guess_modules ~dir:src_dir
        ~files:(Lazy.force files))
    in
    List.filter_map stanzas ~f:(fun stanza ->
      let dir = ctx_dir in
      match (stanza : Stanza.t) with
      | Library lib  ->
        Some (library_rules lib ~dir
                ~all_modules:(Lazy.force all_modules) ~files:(Lazy.force files)
                ~scope)
      | Executables  exes ->
        Some (executables_rules exes ~dir ~all_modules:(Lazy.force all_modules)
                ~scope)
      | _ -> None)
    |> Merlin.add_rules sctx ~dir:ctx_dir

  let () = List.iter (SC.stanzas sctx) ~f:rules
  let () =
    SC.add_rules sctx (Js_of_ocaml_rules.setup_separate_compilation_rules sctx)
  let () = Odoc.setup_css_rule sctx

  (* +-----------------------------------------------------------------+
     | META                                                            |
     +-----------------------------------------------------------------+ *)

  (* The rules for META files must come after the interpretation of the jbuild stanzas
     since a user rule might generate a META.<package> file *)

  (* META files that must be installed. Either because there is an explicit or user
     generated one, or because *)
  let packages_with_explicit_or_user_generated_meta =
    String_map.values (SC.packages sctx)
    |> List.filter_map ~f:(fun (pkg : Package.t) ->
      let path = Path.append ctx.build_dir pkg.path in
      let meta_fn = "META." ^ pkg.name in
      let meta_templ_fn = meta_fn ^ ".template" in

      let files =
        SC.sources_and_targets_known_so_far sctx ~src_path:pkg.path
      in
      let has_meta, has_meta_tmpl =
        (String_set.mem meta_fn files,
         String_set.mem meta_templ_fn files)
      in

      let meta_fn =
        if has_meta then
          meta_fn ^ ".from-jbuilder"
        else
          meta_fn
      in
      let meta_path = Path.relative path meta_fn in

      let version =
        let get =
          match pkg.version_from_opam_file with
          | Some s -> Build.return (Some s)
          | None ->
            let rec loop = function
              | [] -> Build.return None
              | candidate :: rest ->
                let p = Path.relative path candidate in
                Build.if_file_exists p
                  ~then_:(Build.lines_of p
                          >>^ function
                          | ver :: _ -> Some ver
                          | _ -> Some "")
                  ~else_:(loop rest)
            in
            loop
              [ pkg.name ^ ".version"
              ; "version"
              ; "VERSION"
              ]
        in
        Super_context.Pkg_version.set sctx pkg get
      in

      let template =
        if has_meta_tmpl then
          let meta_templ_path = Path.relative path meta_templ_fn in
          Build.lines_of meta_templ_path
        else
          Build.return ["# JBUILDER_GEN"]
      in
      let meta =
        Gen_meta.gen ~package:pkg.name
          ~version
          ~stanzas:(SC.stanzas_to_consider_for_install sctx)
          ~lib_deps:(fun ~dir jbuild ->
            match jbuild with
            | Library lib ->
              Build.arr ignore
              >>>
              SC.Libs.load_requires sctx ~dir ~item:lib.name
              >>^ List.map ~f:Lib.best_name
            | Executables exes ->
              let item = List.hd exes.names in
              Build.arr ignore
              >>>
              SC.Libs.load_requires sctx ~dir ~item
              >>^ List.map ~f:Lib.best_name
            | _ -> Build.arr (fun _ -> []))
          ~ppx_runtime_deps:(fun ~dir jbuild ->
            match jbuild with
            | Library lib ->
              Build.arr ignore
              >>>
              SC.Libs.load_runtime_deps sctx ~dir ~item:lib.name
              >>^ List.map ~f:Lib.best_name
            | _ -> Build.arr (fun _ -> []))
      in
      SC.add_rule sctx
        (Build.fanout meta template
         >>^ (fun ((meta : Meta.t), template) ->
           let buf = Buffer.create 1024 in
           let ppf = Format.formatter_of_buffer buf in
           Format.pp_open_vbox ppf 0;
           List.iter template ~f:(fun s ->
             if String.is_prefix s ~prefix:"#" then
               match
                 String.extract_blank_separated_words
                   (String.sub s ~pos:1 ~len:(String.length s - 1))
               with
               | ["JBUILDER_GEN"] -> Format.fprintf ppf "%a@," Meta.pp meta.entries
               | _ -> Format.fprintf ppf "%s@," s
             else
               Format.fprintf ppf "%s@," s);
           Format.pp_close_box ppf ();
           Format.pp_print_flush ppf ();
           Buffer.contents buf)
         >>>
         Build.update_file_dyn meta_path);

      if has_meta || has_meta_tmpl then
        Some pkg.name
      else
        None)
    |> String_set.of_list

  (* +-----------------------------------------------------------------+
     | Installation                                                    |
     +-----------------------------------------------------------------+ *)

  let lib_install_files ~dir ~sub_dir (lib : Library.t) =
    let make_entry section fn =
      Install.Entry.make section fn
        ?dst:(Option.map sub_dir ~f:(fun d -> sprintf "%s/%s" d (Path.basename fn)))
    in
    let { Mode.Dict. byte; native } = lib.modes in
    let if_ cond l = if cond then l else [] in
    let files =
      let modules =
        Hashtbl.find_exn modules_by_lib lib.name
          ~string_of_key:(sprintf "%S")
          ~table_desc:(fun _ ->
            sprintf "<module table for context %s>"
              (Path.to_string ctx.build_dir))
      in
      List.concat
        [ List.concat_map modules ~f:(fun m ->
            List.concat
              [ [ Module.cm_file m ~dir Cmi ]
              ; if_ native [ Module.cm_file m ~dir Cmx ]
              ; List.filter_map Ml_kind.all ~f:(Module.cmt_file m ~dir)
              ; [ match Module.file m ~dir Intf with
                  | Some fn -> fn
                  | None    -> Path.relative dir m.impl.name ]
              ])
        ; if_ byte [ lib_archive ~dir lib ~ext:".cma" ]
        ; if_ (Library.has_stubs lib) [ stubs_archive ~dir lib ]
        ; if_ native
            (match ctx.ocamlopt with
             | None -> []
             | Some _ ->
               let files =
                 [ lib_archive ~dir lib ~ext:".cmxa"
                 ; lib_archive ~dir lib ~ext:ctx.ext_lib
                 ]
               in
               if ctx.natdynlink_supported && lib.dynlink then
                 files @ [ lib_archive ~dir lib ~ext:".cmxs" ]
               else
                 files
            )
        ; List.map lib.buildable.js_of_ocaml.javascript_files ~f:(Path.relative dir)
        ; List.map lib.install_c_headers ~f:(fun fn ->
            Path.relative dir (fn ^ ".h"))
        ]
    in
    let dlls  = if_ (byte && Library.has_stubs lib && lib.dynlink) [dll ~dir lib] in
    let execs =
      match lib.kind with
      | Normal | Ppx_deriver -> []
      | Ppx_rewriter ->
        let pps = [Pp.of_string lib.name] in
        let pps =
          (* This is a temporary hack until we get a standard driver *)
          let deps = List.concat_map lib.buildable.libraries ~f:Lib_dep.to_lib_names in
          if List.exists deps ~f:(function
            | "ppx_driver" | "ppx_type_conv" -> true
            | _ -> false) then
            pps @ [Pp.of_string "ppx_driver.runner"]
          else
            pps
        in
        let ppx_exe =
          SC.PP.get_ppx_driver sctx pps
            ~dir ~dep_kind:(if lib.optional then Build.Optional else Required)
        in
        [ppx_exe]
    in
    List.concat
      [ List.map files ~f:(make_entry Lib    )
      ; List.map execs ~f:(make_entry Libexec)
      ; List.map dlls  ~f:(Install.Entry.make Stublibs)
      ]

  let is_odig_doc_file fn =
    List.exists [ "README"; "LICENSE"; "CHANGE"; "HISTORY"]
      ~f:(fun prefix -> String.is_prefix fn ~prefix)

  let local_install_rules (entries : Install.Entry.t list) ~package =
    let install_dir = Config.local_install_dir ~context:ctx.name in
    List.map entries ~f:(fun entry ->
      let dst =
        Path.append install_dir (Install.Entry.relative_installed_path entry ~package)
      in
      SC.add_rule sctx (Build.symlink ~src:entry.src ~dst);
      Install.Entry.set_src entry dst)

  let install_file package_path package entries =
    let entries =
      let files = SC.sources_and_targets_known_so_far sctx ~src_path:Path.root in
      String_set.fold files ~init:entries ~f:(fun fn acc ->
        if is_odig_doc_file fn then
          Install.Entry.make Doc (Path.relative ctx.build_dir fn) :: acc
        else
          acc)
    in
    let entries =
      let opam = Path.relative package_path (package ^ ".opam") in
      Install.Entry.make Lib opam ~dst:"opam" :: entries
    in
    let entries =
      (* Install a META file if the user wrote one or setup a rule to generate one, or if
         we have at least another file to install in the lib/ directory *)
      let meta_fn = "META." ^ package in
      if String_set.mem package packages_with_explicit_or_user_generated_meta ||
         List.exists entries ~f:(fun (e : Install.Entry.t) -> e.section = Lib) then
        let meta = Path.append ctx.build_dir (Path.relative package_path meta_fn) in
        Install.Entry.make Lib meta ~dst:"META" :: entries
      else
        entries
    in
    let fn =
      Path.relative (Path.append ctx.build_dir package_path) (package ^ ".install")
    in
    let entries = local_install_rules entries ~package in
    SC.add_rule sctx
      (Build.path_set (Install.files entries)
       >>^ (fun () ->
         Install.gen_install_file entries)
       >>>
       Build.update_file_dyn fn)

  let () =
    let entries_per_package =
      List.concat_map (SC.stanzas_to_consider_for_install sctx)
        ~f:(fun (dir, stanza) ->
          match stanza with
          | Library ({ public = Some { package; sub_dir; _ }; _ } as lib) ->
            List.map (lib_install_files ~dir ~sub_dir lib) ~f:(fun x ->
              package.name, x)
          | Install { section; files; package}->
            List.map files ~f:(fun { Install_conf. src; dst } ->
              (package.name, Install.Entry.make section (Path.relative dir src) ?dst))
          | _ -> [])
      |> String_map.of_alist_multi
    in
    String_map.iter (SC.packages sctx) ~f:(fun ~key:_ ~data:(pkg : Package.t) ->
      let stanzas = String_map.find_default pkg.name entries_per_package ~default:[] in
      install_file pkg.path pkg.name stanzas)

  let () =
    let is_default = Path.basename ctx.build_dir = "default" in
    String_map.iter (SC.packages sctx)
      ~f:(fun ~key:pkg ~data:{ Package.path = src_path; _ } ->
        let install_fn = pkg ^ ".install" in

        let ctx_path = Path.append ctx.build_dir src_path in
        let ctx_install_alias = Alias.install ~dir:ctx_path in
        let ctx_install_file = Path.relative ctx_path install_fn in
        Alias.add_deps (SC.aliases sctx) ctx_install_alias [ctx_install_file];

        if is_default then begin
          let src_install_alias = Alias.install ~dir:src_path in
          let src_install_file = Path.relative src_path install_fn in
          SC.add_rule sctx (Build.copy ~src:ctx_install_file ~dst:src_install_file);
          Alias.add_deps (SC.aliases sctx) src_install_alias [src_install_file]
        end)
end

let gen ~contexts ?(filter_out_optional_stanzas_with_missing_deps=true)
      ?only_packages conf =
  let open Future in
  let { Jbuild_load. file_tree; tree; jbuilds; packages } = conf in
  let aliases = Alias.Store.create () in
  let dirs_with_dot_opam_files =
    String_map.fold packages ~init:Path.Set.empty
      ~f:(fun ~key:_ ~data:{ Package. path; _ } acc ->
        Path.Set.add path acc)
  in
  let packages =
    match only_packages with
    | None -> packages
    | Some pkgs ->
      String_map.filter packages ~f:(fun _ { Package.name; _ } ->
        String_set.mem name pkgs)
  in
  List.map contexts ~f:(fun context ->
    Jbuild_load.Jbuilds.eval ~context jbuilds >>| fun stanzas ->
    let stanzas =
      match only_packages with
      | None -> stanzas
      | Some pkgs ->
        List.map stanzas ~f:(fun (dir, pkgs_ctx, stanzas) ->
          (dir,
           pkgs_ctx,
           List.filter stanzas ~f:(fun stanza ->
             match (stanza : Stanza.t) with
             | Library { public = Some { package; _ }; _ }
             | Alias { package = Some package ;  _ }
             | Install { package; _ } ->
               String_set.mem package.name pkgs
             | _ -> true)))
    in
    let sctx =
      Super_context.create
        ~context
        ~aliases
        ~dirs_with_dot_opam_files
        ~file_tree
        ~packages
        ~filter_out_optional_stanzas_with_missing_deps
        ~stanzas
    in
    let module M = Gen(struct let sctx = sctx end) in
    (Super_context.rules sctx, (context.name, stanzas)))
  |> Future.all
  >>| fun l ->
  let rules, context_names_and_stanzas = List.split l in
  (Alias.rules aliases
     ~prefixes:(Path.root :: List.map contexts ~f:(fun c -> c.Context.build_dir)) ~tree
   @ List.concat rules,
   String_map.of_alist_exn context_names_and_stanzas)
