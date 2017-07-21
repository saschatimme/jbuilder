open! Import

type t = Exec | Obj

let all = [Exec; Obj]

let t =
  let open Sexp.Of_sexp in
  enum
    [ "executable"   , Exec
    ; "object" , Obj
    ]

let add_suffix t s =
  match t with
  | Exec -> s
  | Obj -> sprintf "%s.o" s

module Dict = struct
  type 'a t =
    { obj   : 'a
    ; exec : 'a
    }
  module Set = struct
    type nonrec t = bool t

    let all =
      { obj   = true
      ; exec = true
      }
    
    let exec_only =
      { obj   = false
      ; exec = true
      }

    let to_list t =
      let l = [] in
      let l = if t.exec then Exec :: l else l in
      let l = if t.obj   then Obj   :: l else l in
      l

    let of_list l =
      { obj   = List.mem Obj   ~set:l
      ; exec = List.mem Exec ~set:l
      }

    let t sexp = of_list (Sexp.Of_sexp.list t sexp)

    let is_empty t = not (t.obj || t.exec)

    let iter t ~f =
      if t.obj   then f Obj;
      if t.exec then f Exec
  end
end
