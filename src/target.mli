open! Import

type t = Exec | Obj

val t : t Sexp.Of_sexp.t

val all : t list

val add_suffix: t -> string -> string

module Dict : sig
  type mode = t

  type 'a t =
    { obj   : 'a
    ; exec : 'a
    }

  module Set : sig
    type nonrec t = bool t
    val t : t Sexp.Of_sexp.t
    val all : t
    val exec_only: t
    val is_empty : t -> bool
    val to_list : t -> mode list
    val of_list : mode list -> t
    val iter : t -> f:(mode -> unit) -> unit
  end
end with type mode := t
