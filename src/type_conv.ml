(* Pa_type_conv: Preprocessing Module for Registering Type Conversions *)

open Ppx_core
open Ast_builder.Default

module Spellcheck   = Ppx_core.Spellcheck

let keep_w32_impl = ref false
let keep_w32_intf = ref false
let () =
  Ppx_driver.add_arg "-type-conv-keep-w32"
    (Symbol
       (["impl"; "intf"; "both"],
        (function
          | "impl" -> keep_w32_impl := true
          | "intf" -> keep_w32_intf := true
          | "both" ->
            keep_w32_impl := true;
            keep_w32_intf := true
          | _ -> assert false)))
    ~doc:" Do not try to disable warning 32 for the generated code"

let keep_w32_impl () = !keep_w32_impl || Ppx_driver.pretty ()
let keep_w32_intf () = !keep_w32_intf || Ppx_driver.pretty ()

module List = struct
  include List
  let concat_map xs ~f = concat (map xs ~f)

  let rec filter_map l ~f =
    match l with
    | [] -> []
    | x :: l ->
      match f x with
      | None   ->      filter_map l ~f
      | Some y -> y :: filter_map l ~f
end

module Args = struct
  include (Ast_pattern : module type of struct include Ast_pattern end
           with type ('a, 'b, 'c) t := ('a, 'b, 'c) Ast_pattern.t)

  type 'a param =
    { name    : string
    ; pattern : (expression, 'a) Ast_pattern.Packed.t
    ; default : 'a
    }

  let arg name pattern =
    { name
    ; default = None
    ; pattern = Ast_pattern.Packed.create pattern (fun x -> Some x)
    }
  ;;

  let flag name =
    let pattern = pexp_ident (lident (string name)) in
    { name
    ; default = false
    ; pattern = Ast_pattern.Packed.create pattern true
    }
  ;;

  type (_, _) t =
    | Nil  : ('m, 'm) t
    | Cons : ('m1, 'a -> 'm2) t * 'a param -> ('m1, 'm2) t

  let empty = Nil
  let ( +> ) a b = Cons (a, b)

  let rec names : type a b. (a, b) t -> string list = function
    | Nil -> []
    | Cons (t, p) -> p.name :: names t
  ;;

  module Instance = struct
    type (_, _) instance =
      | I_nil  : ('m, 'm) instance
      | I_cons : ('m1, 'a -> 'm2) instance * 'a -> ('m1, 'm2) instance

    let rec create
      : type a b. (a, b) t -> (string * expression) list -> (a, b) instance
      = fun spec args ->
        match spec with
        | Nil -> I_nil
        | Cons (t, p) ->
          let value =
            match List.Assoc.find args ~equal:String.equal p.name with
            | None -> p.default
            | Some expr -> Ast_pattern.Packed.parse p.pattern expr.pexp_loc expr
          in
          I_cons (create t args, value)
    ;;

    let rec apply : type a b. (a, b) instance -> a -> b = fun t f ->
      match t with
      | I_nil -> f
      | I_cons (t, x) -> apply t f x
    ;;
  end

  let apply t args f = Instance.apply (Instance.create t args) f
end

(* +-----------------------------------------------------------------+
   | Generators                                                      |
   +-----------------------------------------------------------------+ *)

type t = string
let ignore (_ : t) = ()

module Generator = struct
  type deriver = t
  type ('a, 'b) t =
    | T : { spec           : ('c, 'a) Args.t
          ; gen            : loc:Location.t -> path:string -> 'b -> 'c
          ; arg_names      : Set.M(String).t
          ; attributes     : Attribute.packed list
          ; deps           : deriver list
          } -> ('a, 'b) t

  let deps (T t) = t.deps

  let make ?(attributes=[]) ?(deps=[]) spec gen =
    let arg_names = Set.of_list (module String) (Args.names spec) in
    T { spec
      ; gen
      ; arg_names
      ; attributes
      ; deps
      }
  ;;

  let make_noarg ?attributes ?deps gen = make ?attributes ?deps Args.empty gen

  let merge_accepted_args l =
    let rec loop acc = function
      | [] -> acc
      | T t :: rest -> loop (Set.union acc t.arg_names) rest
    in
    loop (Set.empty (module String)) l

  let check_arguments name generators (args : (string * expression) list) =
    List.iter args ~f:(fun (label, e) ->
      if String.is_empty label then
        Location.raise_errorf ~loc:e.pexp_loc
          "ppx_type_conv: generator arguments must be labelled");
    Option.iter (List.find_a_dup args ~compare:(fun (a, _) (b, _) -> String.compare a b))
      ~f:(fun (label, e) ->
        Location.raise_errorf ~loc:e.pexp_loc
          "ppx_type_conv: argument labelled '%s' appears more than once" label);
    let accepted_args = merge_accepted_args generators in
    List.iter args ~f:(fun (label, e) ->
      if not (Set.mem accepted_args label) then
        let spellcheck_msg =
          match Spellcheck.spellcheck (Set.to_list accepted_args) label with
          | None -> ""
          | Some s -> ".\n" ^ s
        in
        Location.raise_errorf ~loc:e.pexp_loc
          "ppx_type_conv: generator '%s' doesn't accept argument '%s'%s"
          name label spellcheck_msg);
  ;;

  let apply (T t) ~name:_ ~loc ~path x args =
    Args.apply t.spec args (t.gen ~loc ~path x)
  ;;

  let apply_all ~loc ~path entry (name, generators, args) =
    check_arguments name.txt generators args;
    List.concat_map generators ~f:(fun t -> apply t ~name:name.txt ~loc ~path entry args)
  ;;

  let apply_all ~loc ~path entry generators =
    List.concat_map generators ~f:(apply_all ~loc ~path entry)
  ;;
end

module Deriver = struct
  module Actual_deriver = struct
    type t =
      { name          : string
      ; str_type_decl : (structure, rec_flag * type_declaration list) Generator.t option
      ; str_type_ext  : (structure, type_extension                  ) Generator.t option
      ; str_exception : (structure, extension_constructor           ) Generator.t option
      ; sig_type_decl : (signature, rec_flag * type_declaration list) Generator.t option
      ; sig_type_ext  : (signature, type_extension                  ) Generator.t option
      ; sig_exception : (signature, extension_constructor           ) Generator.t option
      ; extension     : (loc:Location.t -> path:string -> core_type -> expression) option
      }
  end

  module Alias = struct
    type t =
      { str_type_decl : string list
      ; str_type_ext  : string list
      ; str_exception : string list
      ; sig_type_decl : string list
      ; sig_type_ext  : string list
      ; sig_exception : string list
      }
  end

  module Field = struct
    type kind = Str | Sig

    type ('a, 'b) t =
      { name    : string
      ; kind    : kind
      ; get     : Actual_deriver.t -> ('a, 'b) Generator.t option
      ; get_set : Alias.t -> string list
      }

    let str_type_decl = { kind = Str; name = "type"
                        ; get     = (fun t -> t.str_type_decl)
                        ; get_set = (fun t -> t.str_type_decl) }
    let str_type_ext  = { kind = Str; name = "type extension"
                        ; get     = (fun t -> t.str_type_ext)
                        ; get_set = (fun t -> t.str_type_ext ) }
    let str_exception = { kind = Str; name = "exception"
                        ; get     = (fun t -> t.str_exception)
                        ; get_set = (fun t -> t.str_exception) }
    let sig_type_decl = { kind = Sig; name = "signature type"
                        ; get     = (fun t -> t.sig_type_decl)
                        ; get_set = (fun t -> t.sig_type_decl) }
    let sig_type_ext  = { kind = Sig; name = "signature type extension"
                        ; get     = (fun t -> t.sig_type_ext)
                        ; get_set = (fun t -> t.sig_type_ext ) }
    let sig_exception = { kind = Sig; name = "signature exception"
                        ; get     = (fun t -> t.sig_exception)
                        ; get_set = (fun t -> t.sig_exception) }
  end

  type t =
    | Actual_deriver of Actual_deriver.t
    | Alias of Alias.t

  type Ppx_derivers.deriver += T of t

  let derivers () =
    List.filter_map (Ppx_derivers.derivers ()) ~f:(function
      | name, T t -> Some (name, t)
      | _ -> None)

  exception Not_supported of string

  let resolve_actual_derivers (field : (_, _) Field.t) name =
    let rec loop name collected =
      if List.exists collected
           ~f:(fun (d : Actual_deriver.t) -> String.equal d.name name) then
        collected
      else
        match Ppx_derivers.lookup name with
        | Some (T (Actual_deriver drv)) -> drv :: collected
        | Some (T (Alias alias)) ->
          let set = field.get_set alias in
          List.fold_right set ~init:collected ~f:loop
        | _ -> raise (Not_supported name)
    in
    List.rev (loop name [])

  let resolve_internal (field : (_, _) Field.t) name =
    List.map (resolve_actual_derivers field name) ~f:(fun drv ->
      match field.get drv with
      | None -> raise (Not_supported name)
      | Some g -> (drv.name, g))
  ;;

  let supported_for field =
    List.fold_left (derivers ()) ~init:(Set.empty (module String))
      ~f:(fun acc (name, _) ->
        match resolve_internal field name with
        | _ -> Set.add acc name
        | exception Not_supported _ -> acc)
    |> Set.to_list
  ;;

  let not_supported (field : (_, _) Field.t) ?(spellcheck=true) name =
    let spellcheck_msg =
      if spellcheck then
        match Spellcheck.spellcheck (supported_for field) name.txt with
        | None -> ""
        | Some s -> ".\n" ^ s
      else
        ""
    in
    Location.raise_errorf ~loc:name.loc
      "ppx_type_conv: '%s' is not a supported %s type-conv generator%s"
      name.txt field.name spellcheck_msg
  ;;

  let resolve field name =
    try
      resolve_internal field name.txt
    with Not_supported name' ->
      not_supported field ~spellcheck:(String.equal name.txt name') name
  ;;

  let resolve_all field derivers =
    let derivers_and_args =
      List.filter_map derivers ~f:(fun (name, args) ->
        match Ppx_derivers.lookup name.txt with
        | None ->
          not_supported field name
        | Some (T _) ->
          (* It's one of ours, parse the arguments now. We can't do it before since
             ppx_deriving uses a different syntax for arguments. *)
          Some
            (name,
             List.map args ~f:(fun (label, expr) ->
               match label with
               | Labelled s -> (s, expr)
               | _ ->
                 Location.raise_errorf ~loc:expr.pexp_loc
                   "ppx_type_conv: non-optional labeled argument expected"))
        | Some _ ->
          (* It's not one of ours, ignore it. *)
          None)
    in
    (* Set of actual deriver names *)
    let seen = Hash_set.create (module String) () in
    List.map derivers_and_args ~f:(fun (name, args) ->
      let named_generators = resolve field name in
      List.iter named_generators ~f:(fun (actual_deriver_name, gen) ->
        List.iter (Generator.deps gen) ~f:(fun dep ->
          List.iter (resolve_actual_derivers field dep) ~f:(fun drv ->
            let dep_name = drv.name in
            if not (Hash_set.mem seen dep_name) then
              Location.raise_errorf ~loc:name.loc
                "Deriver %s is needed for %s, you need to add it before in the list"
                dep_name name.txt));
        Hash_set.add seen actual_deriver_name);
      (name, List.map named_generators ~f:snd, args))
  ;;

  let add
        ?str_type_decl
        ?str_type_ext
        ?str_exception
        ?sig_type_decl
        ?sig_type_ext
        ?sig_exception
        ?extension
        name
    =
    let actual_deriver : Actual_deriver.t =
      { name
      ; str_type_decl
      ; str_type_ext
      ; str_exception
      ; sig_type_decl
      ; sig_type_ext
      ; sig_exception
      ; extension
      }
    in
    Ppx_derivers.register name (T (Actual_deriver actual_deriver));
    (match extension with
     | None -> ()
     | Some f ->
       let extension = Extension.declare name Expression Ast_pattern.(ptyp __) f in
       Ppx_driver.register_transformation ("ppx_type_conv." ^ name)
         ~rules:[ Context_free.Rule.extension extension ]);
    name
  ;;

  let add_alias
        name
        ?str_type_decl
        ?str_type_ext
        ?str_exception
        ?sig_type_decl
        ?sig_type_ext
        ?sig_exception
        set
    =
    let alias : Alias.t =
      let get = function
        | None     -> set
        | Some set -> set
      in
      { str_type_decl = get str_type_decl
      ; str_type_ext  = get str_type_ext
      ; str_exception = get str_exception
      ; sig_type_decl = get sig_type_decl
      ; sig_type_ext  = get sig_type_ext
      ; sig_exception = get sig_exception
      }
    in
    Ppx_derivers.register name (T (Alias alias));
    name
  ;;
end

let add       = Deriver.add
let add_alias = Deriver.add_alias

(* +-----------------------------------------------------------------+
   | [@@deriving ] parsing                                           |
   +-----------------------------------------------------------------+ *)

let invalid_with ~loc = Location.raise_errorf ~loc "invalid [@@deriving ] attribute syntax"

let generator_name_of_id loc id =
  match Longident.flatten_exn id with
  | l -> { loc; txt = String.concat ~sep:"." l }
  | exception _ -> invalid_with ~loc:loc
;;

let mk_deriving_attr context ~suffix =
  Attribute.declare
    ("type_conv.deriving" ^ suffix)
    context
    Ast_pattern.(
      let generator_name () =
        map' (pexp_ident __) ~f:(fun loc f id -> f (generator_name_of_id loc id))
      in
      let generator () =
        map (generator_name ()) ~f:(fun f x -> f (x, [])) |||
        pack2 (pexp_apply (generator_name ()) (many __))
      in
      let generators =
        pexp_tuple (many (generator ())) |||
        map (generator ()) ~f:(fun f x -> f [x])
      in
      pstr (pstr_eval generators nil ^:: nil)
    )
    (fun x -> x)
;;

module Attr = struct
  let suffix = ""
  let td = mk_deriving_attr ~suffix Type_declaration
  let te = mk_deriving_attr ~suffix Type_extension
  let ec = mk_deriving_attr ~suffix Extension_constructor

  module Expect = struct
    let suffix = "_inline"
    let td = mk_deriving_attr ~suffix Type_declaration
    let te = mk_deriving_attr ~suffix Type_extension
    let ec = mk_deriving_attr ~suffix Extension_constructor
  end
end

(* +-----------------------------------------------------------------+
   | Unused warning stuff                                            |
   +-----------------------------------------------------------------+ *)

(* [do_insert_unused_warning_attribute] -- If true, generated code contains compiler
   attribute to disable unused warnings, instead of inserting [let _ = ... ].
   We wont enable this yet, otherwise it will make it much harder to compare the code
   generated by ppx with that of the pa version *)
let do_insert_unused_warning_attribute = false

let disable_unused_warning_attribute ~loc =
  ({ txt = "ocaml.warning"; loc }, PStr [%str "-32"])
;;

let disable_unused_warning_str ~loc st =
  if keep_w32_impl () then
    st
  else if not do_insert_unused_warning_attribute then
    Ignore_unused_warning.add_dummy_user_for_values#structure st
  else
    [pstr_include ~loc
       (include_infos ~loc
          (pmod_structure ~loc
             (pstr_attribute ~loc (disable_unused_warning_attribute ~loc)
              :: st)))]
;;

let disable_unused_warning_sig ~loc sg =
  if keep_w32_intf () then
    sg
  else
    [psig_include ~loc
       (include_infos ~loc
          (pmty_signature ~loc
             (psig_attribute ~loc (disable_unused_warning_attribute ~loc)
              :: sg)))]
;;

(* +-----------------------------------------------------------------+
   | Remove attributes used by syntax extensions                     |
   +-----------------------------------------------------------------+ *)
(*
let remove generators =
  let attributes =
    List.concat_map generators ~f:(fun (_, actual_generators, _) ->
      List.concat_map actual_generators ~f:(fun (Generator.T g) -> g.attributes))
  in
  object
    inherit Ast_traverse.map

    (* Don't recurse through attributes and extensions *)
    method! attribute x = x
    method! extension x = x

    method! label_declaration ld =
      Attribute.remove_seen Attribute.Context.label_declaration attributes ld

    method! constructor_declaration cd =
      Attribute.remove_seen Attribute.Context.constructor_declaration attributes cd
  end
*)
(* +-----------------------------------------------------------------+
   | Main expansion                                                  |
   +-----------------------------------------------------------------+ *)

let types_used_by_type_conv (tds : type_declaration list)
  : structure_item list =
  if keep_w32_impl () then
    []
  else
    List.map tds ~f:(fun td ->
      let typ = core_type_of_type_declaration td in
      let loc = td.ptype_loc in
      [%stri let _ = fun (_ : [%t typ]) -> () ]
    )

let merge_generators field l =
  List.filter_map l ~f:(fun x -> x)
  |> List.concat
  |> Deriver.resolve_all field

let expand_str_type_decls ~loc ~path rec_flag tds values =
  let generators = merge_generators Deriver.Field.str_type_decl values in
  let generated =
    types_used_by_type_conv tds
    @ Generator.apply_all ~loc ~path (rec_flag, tds) generators;
  in
  disable_unused_warning_str ~loc generated

let expand_sig_type_decls ~loc ~path rec_flag tds values =
  let generators = merge_generators Deriver.Field.sig_type_decl values in
  let generated = Generator.apply_all ~loc ~path (rec_flag, tds) generators in
  disable_unused_warning_sig ~loc generated

let expand_str_exception ~loc ~path ec generators =
  let generators = Deriver.resolve_all Deriver.Field.str_exception generators in
  let generated = Generator.apply_all ~loc ~path ec generators in
  disable_unused_warning_str ~loc generated

let expand_sig_exception ~loc ~path ec generators =
  let generators = Deriver.resolve_all Deriver.Field.sig_exception generators in
  let generated = Generator.apply_all ~loc ~path ec generators in
  disable_unused_warning_sig ~loc generated

let expand_str_type_ext ~loc ~path te generators =
  let generators = Deriver.resolve_all Deriver.Field.str_type_ext generators in
  let generated = Generator.apply_all ~loc ~path te generators in
  disable_unused_warning_str ~loc generated

let expand_sig_type_ext ~loc ~path te generators =
  let generators = Deriver.resolve_all Deriver.Field.sig_type_ext generators in
  let generated = Generator.apply_all ~loc ~path te generators in
  disable_unused_warning_sig ~loc generated

let () =
  Ppx_driver.register_transformation "type_conv"
    ~rules:[ Context_free.Rule.attr_str_type_decl
               Attr.td
               expand_str_type_decls
           ; Context_free.Rule.attr_sig_type_decl
               Attr.td
               expand_sig_type_decls
           ; Context_free.Rule.attr_str_type_ext
               Attr.te
               expand_str_type_ext
           ; Context_free.Rule.attr_sig_type_ext
               Attr.te
               expand_sig_type_ext
           ; Context_free.Rule.attr_str_exception
               Attr.ec
               expand_str_exception
           ; Context_free.Rule.attr_sig_exception
               Attr.ec
               expand_sig_exception

           (* [@@deriving_inline] *)
           ; Context_free.Rule.attr_str_type_decl_expect
               Attr.Expect.td
               expand_str_type_decls
           ; Context_free.Rule.attr_sig_type_decl_expect
               Attr.Expect.td
               expand_sig_type_decls
           ; Context_free.Rule.attr_str_type_ext_expect
               Attr.Expect.te
               expand_str_type_ext
           ; Context_free.Rule.attr_sig_type_ext_expect
               Attr.Expect.te
               expand_sig_type_ext
           ; Context_free.Rule.attr_str_exception_expect
               Attr.Expect.ec
               expand_str_exception
           ; Context_free.Rule.attr_sig_exception_expect
               Attr.Expect.ec
               expand_sig_exception
           ]
;;
