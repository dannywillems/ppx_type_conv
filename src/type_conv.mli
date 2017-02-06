(** Ppx_type_conv: Preprocessing Module for Registering Type Conversions *)

open Ppx_core

(** Specification of generator arguments *)
module Args : sig
  type ('a, 'b) t
  type 'a param

  val empty  : ('m, 'm) t

  val arg
    :  string
    -> (expression, 'a -> 'a option, 'a option) Ast_pattern.t
    -> 'a option param

  (** Flag matches punned labelled argument, i.e. of the form [~foo]. It returns [true]
      iff the argument is present. *)
  val flag : string -> bool param

  val ( +> ) : ('m1, 'a -> 'm2) t -> 'a param -> ('m1, 'm2) t

  (** For convenience, so that one can write the following without having to open both
      [Ast_pattern] and [Type_conv.Args]:

      {[
        Type_conv.Args.(empty
                        +> arg_option "foo" (estring __)
                        +> arg_option "bar" (pack2 (eint __ ** eint __))
                        +> flag "dotdotdot"
                       )
      ]}
  *)
  include module type of struct include Ast_pattern end
  with type ('a, 'b, 'c) t := ('a, 'b, 'c) Ast_pattern.t
end

(** {6 Generator registration} *)

type t (** Type of registered type-conv derivers *)

module Generator : sig
  type ('output_ast, 'input_ast) t

  val make
    :  ?attributes:Attribute.packed list
    -> ('f, 'output_ast) Args.t
    -> (loc:Location.t -> path:string -> 'input_ast -> 'f)
    -> ('output_ast, 'input_ast) t

  val make_noarg
    :  ?attributes:Attribute.packed list
    -> (loc:Location.t -> path:string -> 'input_ast -> 'output_ast)
    -> ('output_ast, 'input_ast) t

  val apply
    :  ('output_ast, 'input_ast) t
    -> name:string
    -> loc:Location.t
    -> path:string
    -> 'input_ast
    -> (string * expression) list
    -> 'output_ast
end


(** Register a new type-conv generator.

    The various arguments are for the various items on which derivers can be attached in
    structure and signatures.

    We distinguish [exception] from [type_extension] as [exception E] is not exactly the
    same as [type exn += E]. Indeed if the type [exn] is redefined, then [type exn += E]
    will add [E] to the new [exn] type while [exception E] will add [E] to the predefined
    [exn] type.

    [extension] register an expander for extension with the name of the deriver. This is
    here mostly to support the ppx_deriving backend.
*)
val add
  :  ?str_type_decl:(structure, rec_flag * type_declaration list) Generator.t
  -> ?str_type_ext :(structure, type_extension                  ) Generator.t
  -> ?str_exception:(structure, extension_constructor           ) Generator.t
  -> ?sig_type_decl:(signature, rec_flag * type_declaration list) Generator.t
  -> ?sig_type_ext :(signature, type_extension                  ) Generator.t
  -> ?sig_exception:(signature, extension_constructor           ) Generator.t
  -> ?extension:(loc:Location.t -> path:string -> core_type -> expression)
  -> string
  -> t

(** [add_alias name set] add an alias. When the user write the alias, all the generator of
    [set] will be used instead.  It is possible to override the set for any of the context
    by passing the specific set in the approriate optional argument of [add_alias]. *)
val add_alias
  :  string
  -> ?str_type_decl:t list
  -> ?str_type_ext :t list
  -> ?str_exception:t list
  -> ?sig_type_decl:t list
  -> ?sig_type_ext :t list
  -> ?sig_exception:t list
  -> t list
  -> t

(** Ignore a deriver. So that one can write: [Type_conv.add ... |> Type_conv.ignore] *)
val ignore : t -> unit

(**/**)
(* This is used inside Jane Street to make ppx_deriving depend on ppx_type_conv. It's not
   meant to be used by casual users. *)
module Ppx_deriving_import : sig
  open Migrate_parsetree.OCaml_current.Ast
  open Parsetree

  type ('output_ast, 'input_ast) generator
    =  options:(string * expression) list
    -> path:string list
    -> 'input_ast
    -> 'output_ast

  type deriver =
    { name          : string
    ; core_type     : (core_type -> expression) option
    ; type_decl_str : (structure, type_declaration list) generator
    ; type_ext_str  : (structure, type_extension       ) generator
    ; type_decl_sig : (signature, type_declaration list) generator
    ; type_ext_sig  : (signature, type_extension       ) generator
    }

  val import : deriver -> unit
end
