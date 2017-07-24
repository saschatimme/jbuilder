open Import
open Sexp.Of_sexp

(* This file defines the jbuild types as well as the S-expression syntax for the various
   supported version of the specification.

   [vN] is for the version [N] of the specification and [vjs] is for the rolling
   [jane_street] version, when needed.
*)

module Jbuild_version = struct
  type t =
    | V1

  let t =
    enum
      [ "1", V1
      ]

  let latest_stable = V1
end

let invalid_module_name sexp =
  of_sexp_error sexp "invalid module name"

let module_name sexp =
  match string sexp with
  | "" -> invalid_module_name sexp
  | s ->
    if s.[0] = '_' then invalid_module_name sexp;
    String.iter s ~f:(function
      | 'A'..'Z' | 'a'..'z' | '_' -> ()
      | _ -> invalid_module_name sexp);
    String.capitalize_ascii s

let module_names sexp = String_set.of_list (list module_name sexp)

let invalid_lib_name sexp =
  of_sexp_error sexp "invalid library name"

let library_name sexp =
  match string sexp with
  | "" -> invalid_lib_name sexp
  | s ->
    if s.[0] = '.' then invalid_lib_name sexp;
    String.iter s ~f:(function
      | 'A'..'Z' | 'a'..'z' | '_' | '.' | '0'..'9' -> ()
      | _ -> invalid_lib_name sexp);
    s

let file sexp =
  match string sexp with
  | "." | ".." ->
    of_sexp_error sexp "'.' and '..' are not valid filenames"
  | fn -> fn

let file_in_current_dir sexp =
  match string sexp with
  | "." | ".." ->
    of_sexp_error sexp "'.' and '..' are not valid filenames"
  | fn ->
    if Filename.dirname fn <> Filename.current_dir_name then
      of_sexp_error sexp "file in current directory expected";
    fn

module Scope = struct
  type t =
    { name     : string option
    ; packages : Package.t String_map.t
    ; root     : Path.t
    }

  let empty =
    { name     = None
    ; packages = String_map.empty
    ; root     = Path.root
    }

  let make = function
    | [] -> empty
    | pkg :: rest as pkgs ->
      let name =
        List.fold_left rest ~init:pkg.Package.name ~f:(fun acc pkg ->
          min acc pkg.Package.name)
      in
      let root = pkg.path in
      List.iter rest ~f:(fun pkg -> assert (pkg.Package.path = root));
      { name = Some name
      ; packages =
          String_map.of_alist_exn (List.map pkgs ~f:(fun pkg ->
            pkg.Package.name, pkg))
      ; root
      }

  let package_listing packages =
    let longest_pkg = List.longest_map packages ~f:(fun p -> p.Package.name) in
    String.concat ~sep:"\n"
      (List.map packages ~f:(fun pkg ->
         sprintf "- %-*s (because of %s)" longest_pkg pkg.Package.name
           (Path.to_string (Path.relative pkg.path (pkg.name ^ ".opam")))))

  let default t =
    match String_map.values t.packages with
    | [pkg] -> Ok pkg
    | [] ->
      Error
        "The current scope defines no packages.\n\
         What do you want me to do with this (install ...) stanzas?.\n\
         You need to add a <package>.opam file at the root \
         of your project so that\n\
         I know that you want to install things as part of package <package>."
    | _ :: _ :: _ ->
      Error
        (sprintf
           "I can't determine automatically which package this (install ...) \
            stanza is for. I have the choice between these ones:\n\
            %s\n\
            You need to add a (package ...) field in this (install ...) stanza"
           (package_listing (String_map.values t.packages)))

  let resolve t name =
    match String_map.find name t.packages with
    | Some pkg ->
      Ok pkg
    | None ->
      if String_map.is_empty t.packages then
        Error (sprintf
                 "You cannot declare items to be installed without \
                  adding a <package>.opam file at the root of your project.\n\
                  To declare elements to be installed as part of package %S, \
                  add a %S file at the root of your project."
                 name (name ^ ".opam"))
      else
        Error (sprintf
                 "The current scope doesn't define package %S.\n\
                  The only packages for which you can declare \
                  elements to be installed in this directory are:\n\
                  %s%s"
                 name
                 (package_listing (String_map.values t.packages))
                 (hint name (String_map.keys t.packages)))

  let package t sexp =
    match resolve t (string sexp) with
    | Ok p -> p
    | Error s -> Loc.fail (Sexp.Ast.loc sexp) "%s" s

  let package_field t =
    map_validate (field_o "package" string) ~f:(function
      | None -> default t
      | Some name -> resolve t name)
end


module Pp : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
end = struct
  type t = string

  let of_string s =
    assert (not (String.is_prefix s ~prefix:"-"));
    s

  let to_string t = t

  let compare = String.compare
end

module Pp_or_flags = struct
  type t =
    | PP of Pp.t
    | Flags of string list

  let of_string s =
    if String.is_prefix s ~prefix:"-" then
      Flags [s]
    else
      PP (Pp.of_string s)

  let t = function
    | Atom (_, s) -> of_string s
    | List (_, l) -> Flags (List.map l ~f:string)

  let split l =
    let pps, flags =
      List.partition_map l ~f:(function
        | PP pp  -> Inl pp
        | Flags s -> Inr s)
    in
    (pps, List.concat flags)
end

module Dep_conf = struct
  type t =
    | File of String_with_vars.t
    | Alias of String_with_vars.t
    | Glob_files of String_with_vars.t
    | Files_recursively_in of String_with_vars.t

  let t =
    let t =
      let cstr name f =
        cstr name (String_with_vars.t @> nil) f
      in
      sum
        [ cstr "file"                 (fun x -> File x)
        ; cstr "alias"                (fun x -> Alias x)
        ; cstr "glob_files"           (fun x -> Glob_files x)
        ; cstr "files_recursively_in" (fun x -> Files_recursively_in x)
        ]
    in
    fun sexp ->
      match sexp with
      | Atom _ -> File (String_with_vars.t sexp)
      | List _ -> t sexp

  open Sexp
  let sexp_of_t = function
    | File t ->
      List [Atom "file" ; String_with_vars.sexp_of_t t]
    | Alias t ->
      List [Atom "alias" ; String_with_vars.sexp_of_t t]
    | Glob_files t ->
      List [Atom "glob_files" ; String_with_vars.sexp_of_t t]
    | Files_recursively_in t ->
      List [Atom "files_recursively_in" ; String_with_vars.sexp_of_t t]
end

module Preprocess = struct
  type pps = { pps : Pp.t list; flags : string list }
  type t =
    | No_preprocessing
    | Action of Action.Unexpanded.t
    | Pps    of pps

  let t =
    sum
      [ cstr "no_preprocessing" nil No_preprocessing
      ; cstr "action" (Action.Unexpanded.t @> nil) (fun x -> Action x)
      ; cstr "pps" (list Pp_or_flags.t @> nil) (fun l ->
          let pps, flags = Pp_or_flags.split l in
          Pps { pps; flags })
      ]

  let pps = function
    | Pps { pps; _ } -> pps
    | _ -> []
end

module Per_module = struct
  type 'a t =
    | For_all    of 'a
    | Per_module of 'a String_map.t

  let t a sexp =
    match sexp with
    | List (_, Atom (loc, ("per_module" | "per_file" as kwd)) :: rest) -> begin
        if kwd = "per_file" then
          Loc.warn loc
            "'per_file' was renamed 'per_module'. 'per_file' will be re-purposed \
             in a future version and will take a list of  file names rather \
             than module names.";
        List.concat_map rest ~f:(fun sexp ->
          let pp, names = pair a module_names sexp in
          List.map (String_set.elements names) ~f:(fun name -> (name, pp)))
        |> String_map.of_alist
        |> function
        | Ok map -> Per_module map
        | Error (name, _, _) ->
          of_sexp_error sexp (sprintf "module %s present in two different sets" name)
      end
    | sexp -> For_all (a sexp)
end

module Preprocess_map = struct
  type t = Preprocess.t Per_module.t
  let t = Per_module.t Preprocess.t

  let find module_name (t : t) =
    match t with
    | For_all pp -> pp
    | Per_module map -> String_map.find_default module_name map ~default:No_preprocessing

  let default : t = For_all No_preprocessing

  module Pp_set = Set.Make(Pp)

  let pps : t -> _ = function
    | For_all pp -> Preprocess.pps pp
    | Per_module map ->
      String_map.fold map ~init:Pp_set.empty ~f:(fun ~key:_ ~data:pp acc ->
        Pp_set.union acc (Pp_set.of_list (Preprocess.pps pp)))
      |> Pp_set.elements
end

module Lint = struct
  type t = Pps of Preprocess.pps

  let t =
    sum
      [ cstr "pps" (list Pp_or_flags.t @> nil) (fun l ->
          let pps, flags = Pp_or_flags.split l in
          Pps { pps; flags })
      ]
end

let field_osl name =
  field name Ordered_set_lang.t ~default:Ordered_set_lang.standard

let field_oslu name =
  field name Ordered_set_lang.Unexpanded.t ~default:Ordered_set_lang.Unexpanded.standard

module Js_of_ocaml = struct

  type t =
    { flags            : Ordered_set_lang.t
    ; javascript_files : string list
    }

  let t =
    record
      (field_osl "flags"                                      >>= fun flags ->
       field     "javascript_files" (list string) ~default:[] >>= fun javascript_files ->
       return { flags; javascript_files })

  let default =
    { flags = Ordered_set_lang.standard
    ; javascript_files = [] }
end

module Lib_dep = struct
  type choice =
    { required  : String_set.t
    ; forbidden : String_set.t
    ; file      : string
    }

  type select =
    { result_fn : string
    ; choices   : choice list
    ; loc       : Loc.t (* For error messages *)
    }

  type t =
    | Direct of string
    | Select of select

  let choice = function
    | List (_, l) as sexp ->
      let rec loop required forbidden = function
        | [Atom (_, "->"); fsexp] ->
          let common = String_set.inter required forbidden in
          if not (String_set.is_empty common) then
            of_sexp_errorf sexp
              "library %S is both required and forbidden in this clause"
              (String_set.choose common);
          { required
          ; forbidden
          ; file = file fsexp
          }
        | Atom (_, "->") :: _ | List _ :: _ | [] ->
          of_sexp_error sexp "(<[!]libraries>... -> <file>) expected"
        | Atom (_, s) :: l ->
          let len = String.length s in
          if len > 0 && s.[0] = '!' then
            let s = String.sub s ~pos:1 ~len:(len - 1) in
            loop required (String_set.add s forbidden) l
          else
            loop (String_set.add s required) forbidden l
      in
      loop String_set.empty String_set.empty l
    | sexp -> of_sexp_error sexp "(<library-name> <code>) expected"

  let t = function
    | Atom (_, s) ->
      Direct s
    | List (loc, Atom (_, "select") :: m :: Atom (_, "from") :: libs) ->
      Select { result_fn = file m
             ; choices   = List.map libs ~f:choice
             ; loc
             }
    | sexp ->
      of_sexp_error sexp "<library> or (select <module> from <libraries...>) expected"

  let to_lib_names = function
    | Direct s -> [s]
    | Select s ->
      List.fold_left s.choices ~init:String_set.empty ~f:(fun acc x ->
        String_set.union acc (String_set.union x.required x.forbidden))
      |> String_set.elements

  let direct s = Direct s
end

module Lib_deps = struct
  type t = Lib_dep.t list

  type kind =
    | Required
    | Optional
    | Forbidden

  let t sexp =
    let t = list Lib_dep.t sexp in
    let add kind name acc =
      match String_map.find name acc with
      | None -> String_map.add acc ~key:name ~data:kind
      | Some kind' ->
        match kind, kind' with
        | Required, Required ->
          of_sexp_errorf sexp "library %S is present twice" name
        | (Optional|Forbidden), (Optional|Forbidden) ->
          acc
        | Optional, Required | Required, Optional ->
          of_sexp_errorf sexp
            "library %S is present both as an optional and required dependency"
            name
        | Forbidden, Required | Required, Forbidden ->
          of_sexp_errorf sexp
            "library %S is present both as a forbidden and required dependency"
            name
    in
    ignore (
      List.fold_left t ~init:String_map.empty ~f:(fun acc x ->
        match x with
        | Lib_dep.Direct s -> add Required s acc
        | Select { choices; _ } ->
          List.fold_left choices ~init:acc ~f:(fun acc c ->
            let acc = String_set.fold c.Lib_dep.required ~init:acc ~f:(add Optional) in
            String_set.fold c.forbidden ~init:acc ~f:(add Forbidden)))
      : kind String_map.t);
    t
end

module Buildable = struct
  type t =
    { modules                  : Ordered_set_lang.t
    ; libraries                : Lib_dep.t list
    ; preprocess               : Preprocess_map.t
    ; preprocessor_deps        : Dep_conf.t list
    ; flags                    : Ordered_set_lang.t
    ; ocamlc_flags             : Ordered_set_lang.t
    ; ocamlopt_flags           : Ordered_set_lang.t
    ; js_of_ocaml              : Js_of_ocaml.t
    }

  let v1 =
    field "preprocess" Preprocess_map.t ~default:Preprocess_map.default
    >>= fun preprocess ->
    field "preprocessor_deps" (list Dep_conf.t) ~default:[]
    >>= fun preprocessor_deps ->
    (* CR-someday jdimino: remove this. There are still a few Jane Street packages using
       this *)
    field_o "lint" (Per_module.t Lint.t)
    >>= fun _lint ->
    field "modules" (fun s -> Ordered_set_lang.(map (t s)) ~f:String.capitalize_ascii)
      ~default:Ordered_set_lang.standard
    >>= fun modules ->
    field "libraries" Lib_deps.t ~default:[]
    >>= fun libraries ->
    field_osl "flags"          >>= fun flags          ->
    field_osl "ocamlc_flags"   >>= fun ocamlc_flags   ->
    field_osl "ocamlopt_flags" >>= fun ocamlopt_flags ->
    field "js_of_ocaml" (Js_of_ocaml.t) ~default:Js_of_ocaml.default >>= fun js_of_ocaml ->
    return
      { preprocess
      ; preprocessor_deps
      ; modules
      ; libraries
      ; flags
      ; ocamlc_flags
      ; ocamlopt_flags
      ; js_of_ocaml
      }

  let single_preprocess t =
    match t.preprocess with
    | For_all pp -> pp
    | Per_module _ -> No_preprocessing
end

module Public_lib = struct
  type t =
    { name    : string
    ; package : Package.t
    ; sub_dir : string option
    }

  let public_name_field pkgs =
    map_validate (field_o "public_name" string) ~f:(function
      | None -> Ok None
      | Some s ->
        match String.split s ~on:'.' with
        | [] -> assert false
        | pkg :: rest ->
          match Scope.resolve pkgs pkg with
          | Ok pkg ->
            Ok (Some
                  { package = pkg
                  ; sub_dir = if rest = [] then None else Some (String.concat rest ~sep:"/")
                  ; name    = s
                  })
          | Error _ as e -> e)
end

module Library = struct
  module Kind = struct
    type t =
      | Normal
      | Ppx_deriver
      | Ppx_rewriter

    let t =
      enum
        [ "normal"       , Normal
        ; "ppx_deriver"  , Ppx_deriver
        ; "ppx_rewriter" , Ppx_rewriter
        ]
  end

  type t =
    { name                     : string
    ; public                   : Public_lib.t option
    ; synopsis                 : string option
    ; install_c_headers        : string list
    ; ppx_runtime_libraries    : string list
    ; modes                    : Mode.Dict.Set.t
    ; kind                     : Kind.t
    ; c_flags                  : Ordered_set_lang.Unexpanded.t
    ; c_names                  : string list
    ; cxx_flags                : Ordered_set_lang.Unexpanded.t
    ; cxx_names                : string list
    ; library_flags            : String_with_vars.t list
    ; c_library_flags          : Ordered_set_lang.Unexpanded.t
    ; self_build_stubs_archive : string option
    ; virtual_deps             : string list
    ; wrapped                  : bool
    ; optional                 : bool
    ; buildable                : Buildable.t
    ; dynlink                  : bool
    }

  let v1 pkgs =
    record
      (Buildable.v1 >>= fun buildable ->
       field      "name" library_name                                        >>= fun name                     ->
       Public_lib.public_name_field pkgs                                     >>= fun public                   ->
       field_o    "synopsis" string                                          >>= fun synopsis                 ->
       field      "install_c_headers" (list string) ~default:[]              >>= fun install_c_headers        ->
       field      "ppx_runtime_libraries" (list string) ~default:[]          >>= fun ppx_runtime_libraries    ->
       field_oslu "c_flags"                                                  >>= fun c_flags                  ->
       field_oslu "cxx_flags"                                                >>= fun cxx_flags                ->
       field      "c_names" (list string) ~default:[]                        >>= fun c_names                  ->
       field      "cxx_names" (list string) ~default:[]                      >>= fun cxx_names                ->
       field      "library_flags" (list String_with_vars.t) ~default:[]      >>= fun library_flags            ->
       field_oslu "c_library_flags"                                          >>= fun c_library_flags          ->
       field      "virtual_deps" (list string) ~default:[]                   >>= fun virtual_deps             ->
       field      "modes" Mode.Dict.Set.t ~default:Mode.Dict.Set.all         >>= fun modes                    ->
       field      "kind" Kind.t ~default:Kind.Normal                         >>= fun kind                     ->
       field      "wrapped" bool ~default:true                               >>= fun wrapped                  ->
       field_b    "optional"                                                 >>= fun optional                 ->
       field      "self_build_stubs_archive" (option string) ~default:None   >>= fun self_build_stubs_archive ->
       field_b    "no_dynlink"                                               >>= fun no_dynlink               ->
       return
         { name
         ; public
         ; synopsis
         ; install_c_headers
         ; ppx_runtime_libraries
         ; modes
         ; kind
         ; c_names
         ; c_flags
         ; cxx_names
         ; cxx_flags
         ; library_flags
         ; c_library_flags
         ; self_build_stubs_archive
         ; virtual_deps
         ; wrapped
         ; optional
         ; buildable
         ; dynlink = not no_dynlink
         })

  let has_stubs t =
    match t.c_names, t.cxx_names, t.self_build_stubs_archive with
    | [], [], None -> false
    | _            -> true

  let stubs_archive t ~dir ~ext_lib =
    Path.relative dir (sprintf "lib%s_stubs%s" t.name ext_lib)

  let all_lib_deps t =
    List.map t.virtual_deps ~f:(fun s -> Lib_dep.Direct s) @ t.buildable.libraries
end

module Install_conf = struct
  type file =
    { src : string
    ; dst : string option
    }

  let file sexp =
    match sexp with
    | Atom (_, src) -> { src; dst = None }
    | List (_, [Atom (_, src); Atom (_, "as"); Atom (_, dst)]) ->
      { src; dst = Some dst }
    | _ ->
      of_sexp_error sexp
        "invalid format, <name> or (<name> as <install-as>) expected"

  type t =
    { section : Install.Section.t
    ; files   : file list
    ; package : Package.t
    }

  let v1 pkgs =
    record
      (field   "section" Install.Section.t >>= fun section ->
       field   "files"   (list file)       >>= fun files ->
       Scope.package_field pkgs             >>= fun package ->
       return
         { section
         ; files
         ; package
         })
end

module Executables = struct
  type t =
    { names            : string list
    ; link_executables : bool
    ; link_flags       : string list
    ; modes            : Mode.Dict.Set.t
    ; targets           : Target.Dict.Set.t
    ; buildable        : Buildable.t
    }

  let common_v1 pkgs names public_names ~multi =
    Buildable.v1 >>= fun buildable ->
    field   "link_executables"   bool ~default:true >>= fun link_executables ->
    field   "link_flags"         (list string) ~default:[] >>= fun link_flags ->
    map_validate (field "modes" Mode.Dict.Set.t ~default:Mode.Dict.Set.all)
      ~f:(fun modes ->
        if Mode.Dict.Set.is_empty modes then
          Error "No compilation mode defined."
        else
          Ok modes)
    >>= fun modes ->
    map_validate (field "targets" Target.Dict.Set.t ~default:Target.Dict.Set.exec_only)
      ~f:(fun targets ->
        if Target.Dict.Set.is_empty targets then
          Error "No compilation target defined."
        else
          Ok targets)
    >>= fun targets ->
    let t =
      { names
      ; link_executables
      ; link_flags
      ; modes
      ; targets
      ; buildable
      }
    in
    let to_install =
      let ext = if modes.native then ".exe" else ".bc" in
      List.map2 names public_names
        ~f:(fun name pub ->
          match pub with
          | None -> None
          | Some pub -> Some ({ Install_conf. src = name ^ ext; dst = Some pub }))
      |> List.filter_map ~f:(fun x -> x)
    in
    match to_install with
    | [] ->
      (field_o "package" Sexp.Ast.loc >>= function
       | None -> return (t, None)
       | Some loc ->
         Loc.warn loc "This field is useless without a (public_name%s ...) field."
           (if multi then "s" else "");
         return (t, None))
    | files ->
      Scope.package_field pkgs >>= fun package ->
      return (t, Some { Install_conf. section = Bin; files; package })

  let public_name sexp =
    match string sexp with
    | "-" -> None
    | s   -> Some s

  let v1_multi pkgs =
    record
      (field "names" (list string) >>= fun names ->
       map_validate (field_o "public_names" (list public_name)) ~f:(function
         | None -> Ok (List.map names ~f:(fun _ -> None))
         | Some public_names ->
           if List.length public_names = List.length names then
             Ok public_names
           else
             Error "The list of public names must be of the same \
                    length as the list of names")
       >>= fun public_names ->
       common_v1 pkgs names public_names ~multi:true)

  let v1_single pkgs =
    record
      (field   "name" string        >>= fun name ->
       field_o "public_name" string >>= fun public_name ->
       common_v1 pkgs [name] [public_name] ~multi:false)
end

module Rule = struct
  module Targets = struct
    type t =
      | Static of string list (* List of files in the current directory *)
      | Infer
  end

  type t =
    { targets : Targets.t
    ; deps    : Dep_conf.t list
    ; action  : Action.Unexpanded.t
    }

  let v1 sexp =
    match sexp with
    | List (_, (Atom _ :: _)) ->
      { targets = Infer
      ; deps    = []
      ; action  = Action.Unexpanded.t sexp
      }
    | _ ->
      record
        (field "targets" (list file_in_current_dir)    >>= fun targets ->
         field "deps"    (list Dep_conf.t) ~default:[] >>= fun deps ->
         field "action"  Action.Unexpanded.t           >>= fun action ->
         return { targets = Static targets; deps; action })
        sexp

  let ocamllex_v1 names =
    let module S = String_with_vars in
    List.map names ~f:(fun name ->
      let src = name ^ ".mll" in
      let dst = name ^ ".ml"  in
      { targets = Static [dst]
      ; deps    = [File (S.virt_text __POS__ src)]
      ; action  =
          Chdir
            (S.virt_var __POS__ "ROOT",
             Run (S.virt_text __POS__ "ocamllex",
                  [ S.virt_text __POS__ "-q"
                  ; S.virt_text __POS__ "-o"
                  ; S.virt_var __POS__ "@"
                  ; S.virt_var __POS__"<"
                  ]))
      })

  let ocamlyacc_v1 names =
    let module S = String_with_vars in
    List.map names ~f:(fun name ->
      let src = name ^ ".mly" in
      { targets = Static [name ^ ".ml"; name ^ ".mli"]
      ; deps    = [File (S.virt_text __POS__ src)]
      ; action  =
          Chdir
            (S.virt_var __POS__ "ROOT",
             Run (S.virt_text __POS__ "ocamlyacc",
                  [S.virt_var __POS__ "<"]))
      })
end

module Menhir = struct
  type t =
    { merge_into : string option
    ; flags      : String_with_vars.t list
    ; modules    : string list
    }

  let v1 =
    record
      (field_o "merge_into" string >>= fun merge_into ->
       field "flags" (list String_with_vars.t) ~default:[] >>= fun flags ->
       field "modules" (list string) >>= fun modules ->
       return
         { merge_into
         ; flags
         ; modules
         }
      )

  let v1_to_rule t =
    let module S = String_with_vars in
    let targets n = [n ^ ".ml"; n ^ ".mli"] in
    match t.merge_into with
    | None ->
      List.map t.modules ~f:(fun name ->
        let src = name ^ ".mly" in
        { Rule.
          targets = Static (targets name)
        ; deps    = [Dep_conf.File (S.virt_text __POS__ src)]
        ; action  =
            Chdir
              (S.virt_var __POS__ "ROOT",
               Run (S.virt_text __POS__ "menhir",
                    t.flags @ [S.virt_var __POS__ "<"]))
        })
    | Some merge_into ->
      let mly m = S.virt_text __POS__ (m ^ ".mly") in
      [{ Rule.
         targets = Static (targets merge_into)
       ; deps    = List.map ~f:(fun m -> Dep_conf.File (mly m)) t.modules
       ; action  =
           Chdir
             (S.virt_var __POS__ "ROOT",
              Run (S.virt_text __POS__ "menhir",
                   [ S.virt_text __POS__ "--base"
                   ; S.virt_text __POS__ merge_into
                   ]
                   @ t.flags
                   @ (List.map ~f:mly t.modules))
             )
       }]
end

module Provides = struct
  type t =
    { name : string
    ; file : string
    }

(*  let v1 sexp =
    match sexp with
    | Atom (_, s) ->
      { name = s
      ; file =
          match String.lsplit2 s ~on:':' with
          | None        -> s
          | Some (_, s) -> s
      }
    | List (_, [Atom (_, s); List (_, [Atom (_, "file"); Atom (_, file)])]) ->
      { name = s
      ; file
      }
    | sexp ->
    of_sexp_error sexp "[<name>] or [<name> (file <file>)] expected"*)
end

module Alias_conf = struct
  type t =
    { name  : string
    ; deps  : Dep_conf.t list
    ; action : Action.Unexpanded.t option
    ; package : Package.t option
    }

  let v1 pkgs =
    record
      (field "name" string                              >>= fun name ->
       field "deps" (list Dep_conf.t) ~default:[]       >>= fun deps ->
       field_o "package" (Scope.package pkgs)            >>= fun package ->
       field_o "action" Action.Unexpanded.t  >>= fun action ->
       return
         { name
         ; deps
         ; action
         ; package
         })
end

module Stanza = struct
  type t =
    | Library     of Library.t
    | Executables of Executables.t
    | Rule        of Rule.t
    | Provides    of Provides.t
    | Install     of Install_conf.t
    | Alias       of Alias_conf.t

  let rules l = List.map l ~f:(fun x -> Rule x)

  let execs (exe, install) =
    match install with
    | None -> [Executables exe]
    | Some i -> [Executables exe; Install i]

  let v1 pkgs =
    sum
      [ cstr "library"     (Library.v1 pkgs @> nil)      (fun x -> [Library     x])
      ; cstr "executable"  (Executables.v1_single pkgs @> nil) execs
      ; cstr "executables" (Executables.v1_multi  pkgs @> nil) execs
      ; cstr "rule"        (Rule.v1 @> nil)              (fun x -> [Rule        x])
      ; cstr "ocamllex"    (list string @> nil)          (fun x -> rules (Rule.ocamllex_v1  x))
      ; cstr "ocamlyacc"   (list string @> nil)          (fun x -> rules (Rule.ocamlyacc_v1 x))
      ; cstr "menhir"      (Menhir.v1 @> nil)            (fun x -> rules (Menhir.v1_to_rule x))
      ; cstr "install"     (Install_conf.v1 pkgs @> nil) (fun x -> [Install     x])
      ; cstr "alias"       (Alias_conf.v1 pkgs @> nil)   (fun x -> [Alias       x])
      (* Just for validation and error messages *)
      ; cstr "jbuild_version" (Jbuild_version.t @> nil) (fun _ -> [])
      ]

  let select : Jbuild_version.t -> Scope.t -> t list Sexp.Of_sexp.t = function
    | V1  -> v1
end

module Stanzas = struct
  type t = Stanza.t list

  let parse pkgs sexps =
    let versions, sexps =
      List.partition_map sexps ~f:(function
          | List (loc, [Atom (_, "jbuild_version"); ver]) ->
            Inl (Jbuild_version.t ver, loc)
          | sexp -> Inr sexp)
    in
    let version =
      match versions with
      | [] -> Jbuild_version.latest_stable
      | [(v, _)] -> v
      | _ :: (_, loc) :: _ ->
        Loc.fail loc "jbuild_version specified too many times"
    in
    List.concat_map sexps ~f:(Stanza.select version pkgs)

  let lib_names ts =
    List.fold_left ts ~init:String_set.empty ~f:(fun acc (_, _, stanzas) ->
      List.fold_left stanzas ~init:acc ~f:(fun acc -> function
        | Stanza.Library lib ->
          String_set.add lib.name
            (match lib.public with
             | None -> acc
             | Some { name; _ } -> String_set.add name acc)
        | _ -> acc))
end
