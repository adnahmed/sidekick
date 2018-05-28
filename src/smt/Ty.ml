
open Solver_types

type t = ty
type view = Solver_types.ty_view
type def = Solver_types.ty_def

let view t = t.ty_view

let equal a b = a.ty_id = b.ty_id
let compare a b = CCInt.compare a.ty_id b.ty_id
let hash a = a.ty_id

let equal_def d1 d2 = match d1, d2 with
  | Ty_uninterpreted id1, Ty_uninterpreted id2 -> ID.equal id1 id2
  | Ty_def d1, Ty_def d2 -> ID.equal d1.id d2.id
  | Ty_uninterpreted _, _ | Ty_def _, _
    -> false

module Tbl_cell = CCHashtbl.Make(struct
    type t = ty_view
    let equal a b = match a, b with
      | Ty_prop, Ty_prop -> true
      | Ty_atomic a1, Ty_atomic a2 ->
        equal_def a1.def a2.def && CCList.equal equal a1.args a2.args
      | Ty_prop, _ | Ty_atomic _, _
       -> false

    let hash t = match t with
      | Ty_prop -> 1
      | Ty_atomic {def=Ty_uninterpreted id; args; _} ->
        Hash.combine3 10 (ID.hash id) (Hash.list hash args)
      | Ty_atomic {def=Ty_def d; args; _} ->
        Hash.combine3 20 (ID.hash d.id) (Hash.list hash args)
  end)

(* build a type *)
let make_ : ty_view -> t =
  let tbl : t Tbl_cell.t = Tbl_cell.create 128 in
  let n = ref 0 in
  fun c ->
    try Tbl_cell.find tbl c
    with Not_found ->
      let ty_id = !n in
      incr n;
      let ty = {ty_id; ty_view=c; } in
      Tbl_cell.add tbl c ty;
      ty

let card t = match view t with
  | Ty_prop -> Finite
  | Ty_atomic {card=lazy c; _} -> c

let prop = make_ Ty_prop

let atomic def args : t =
  let card = lazy (
    match def with
    | Ty_uninterpreted _ ->
      if List.for_all (fun sub -> card sub = Finite) args then Finite else Infinite
    | Ty_def d -> d.card args
  ) in
  make_ (Ty_atomic {def; args; card})

let atomic_uninterpreted id = atomic (Ty_uninterpreted id) []

let is_prop t =
  match t.ty_view with | Ty_prop -> true | _ -> false

let is_uninterpreted t =
  match t.ty_view with | Ty_atomic {def=Ty_uninterpreted _; _} -> true | _ -> false

let pp = pp_ty

module Tbl = CCHashtbl.Make(struct
    type t = ty
    let equal = equal
    let hash = hash
  end)

module Fun = struct
  type t = fun_ty

  let[@inline] args f = f.fun_ty_args
  let[@inline] ret f = f.fun_ty_ret
  let[@inline] arity f = List.length @@ args f
  let[@inline] mk args ret : t = {fun_ty_args=args; fun_ty_ret=ret}
  let[@inline] unfold t = args t, ret t

  let pp out f : unit =
    match args f with
    | [] -> pp out (ret f)
    | args ->
      Format.fprintf out "(@[(@[%a@])@ %a@])" (Util.pp_list pp) args pp (ret f)
end