(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

module FI = Formula_intf

module Fsat = struct

  exception Bad_atom

  type t = int
  type proof = unit

  let max_lit = max_int
  let max_fresh = ref (-1)
  let max_index = ref 0

  let _make i =
    if i <> 0 && (abs i) < max_lit then begin
      max_index := max !max_index (abs i);
      i
    end else
      raise Bad_atom

  let dummy = 0

  let neg a = - a
  let norm a = abs a, if a < 0 then FI.Negated else FI.Same_sign
  let abs = abs
  let sign i = i > 0
  let apply_sign b i = if b then i else neg i
  let set_sign b i = if b then abs i else neg (abs i)

  let hash (a:int) = a land max_int
  let equal (a:int) b = a=b
  let compare (a:int) b = Pervasives.compare a b

  let make i = _make (2 * i)

  let fresh, iter =
    let create () =
      incr max_fresh;
      _make (2 * !max_fresh + 1)
    in
    let iter: (t -> unit) -> unit = fun f ->
      for j = 1 to !max_index do
        f j
      done
    in
    create, iter

  let print fmt a =
    Format.fprintf fmt "%s%s%d"
      (if a < 0 then "~" else "")
      (if a mod 2 = 0 then "v" else "f")
      ((abs a) / 2)

end

module Tseitin = Tseitin.Make(Fsat)

module Make(Dummy : sig end) = struct

  module Tsat = Solver.DummyTheory(Fsat)
  include Solver.Make(Fsat)(Tsat)(struct end)

  let print_atom = Fsat.print
  let print_clause = St.print_clause
  let print_proof out p =
    let module Dot = Dot.Make(Proof)(struct
        let clause_name c = St.(c.name)
        let print_atom = St.print_atom
        let lemma_info () = "()", None, []
      end)
    in
    Dot.print out p

  let print_dimacs_clause fmt l =
    Format.fprintf fmt "%a0" (fun fmt l ->
        List.iter (fun i -> Format.fprintf fmt "%d " i) l) l

  let print_dimacs fmt l =
    let l = List.map (fun c ->
        List.map (fun a -> a.St.lit) (Proof.to_list c)) l in
    let n, m = List.fold_left (fun (n, m) c ->
        let m' = List.fold_left (fun i j -> max i (abs j)) m c in
        (n + 1, m')) (0, 0) l in
    Format.fprintf fmt "p cnf %d %d@\n" n m;
    List.iter (fun c -> Format.fprintf fmt "%a@\n" print_dimacs_clause c) l

end