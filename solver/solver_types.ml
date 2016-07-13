(**************************************************************************)
(*                                                                        *)
(*                                  Cubicle                               *)
(*             Combining model checking algorithms and SMT solvers        *)
(*                                                                        *)
(*                  Sylvain Conchon and Alain Mebsout                     *)
(*                  Universite Paris-Sud 11                               *)
(*                                                                        *)
(*  Copyright 2011. This file is distributed under the terms of the       *)
(*  Apache Software License version 2.0                                   *)
(*                                                                        *)
(**************************************************************************)

open Printf

module type S = Solver_types_intf.S

(* Solver types for McSat Solving *)
(* ************************************************************************ *)

module McMake (E : Expr_intf.S)(Dummy : sig end) = struct

  (* Flag for Mcsat v.s Pure Sat *)
  let mcsat = true

  type term = E.Term.t
  type formula = E.Formula.t
  type proof = E.proof

  type lit = {
    lid : int;
    term : term;
    mutable l_level : int;
    mutable l_weight : float;
    mutable assigned : term option;
  }

  type var = {
    vid : int;
    pa : atom;
    na : atom;
    mutable seen : bool;
    mutable v_level : int;
    mutable v_weight : float;
    mutable reason : reason option;
  }

  and atom = {
    aid : int;
    var : var;
    neg : atom;
    lit : formula;
    mutable is_true : bool;
    mutable watched : clause Vec.t;
  }

  and clause = {
    name : string;
    tag : int option;
    atoms : atom Vec.t;
    learnt : bool;
    c_level : int;
    mutable cpremise : premise;
    mutable activity : float;
    mutable attached : bool;
    mutable visited : bool;
  }

  and reason =
    | Decision
    | Bcp of clause
    | Semantic of int

  and premise =
    | Hyp of int
    | Lemma of proof
    | History of clause list

  type elt = (lit, var) Either.t

  (* Dummy values *)
  let dummy_lit = E.dummy

  let rec dummy_var =
    { vid = -101;
      pa = dummy_atom;
      na = dummy_atom;
      seen = false;
      v_level = -1;
      v_weight = -1.;
      reason = None;
    }
  and dummy_atom =
    { var = dummy_var;
      lit = dummy_lit;
      watched = Obj.magic 0;
      (* should be [Vec.make_empty dummy_clause]
         but we have to break the cycle *)
      neg = dummy_atom;
      is_true = false;
      aid = -102 }
  let dummy_clause =
    { name = "";
      tag = None;
      atoms = Vec.make_empty dummy_atom;
      activity = -1.;
      attached = false;
      c_level = -1;
      learnt = false;
      visited = false;
      cpremise = History [] }

  let () =
    dummy_atom.watched <- Vec.make_empty dummy_clause

  (* Constructors *)
  module MF = Hashtbl.Make(E.Formula)
  module MT = Hashtbl.Make(E.Term)

  let f_map = MF.create 4096
  let t_map = MT.create 4096

  let vars = Vec.make 107 (Either.mk_right dummy_var)
  let nb_elt () = Vec.size vars
  let get_elt i = Vec.get vars i
  let iter_elt f = Vec.iter f vars

  let cpt_mk_var = ref 0

  let make_semantic_var t =
    try MT.find t_map t
    with Not_found ->
      let res = {
        lid = !cpt_mk_var;
        term = t;
        l_weight = 1.;
        l_level = -1;
        assigned = None;
      } in
      incr cpt_mk_var;
      MT.add t_map t res;
      Vec.push vars (Either.mk_left res);
      res

  let make_boolean_var =
    fun lit ->
      let lit, negated = E.norm lit in
      try MF.find f_map lit, negated
      with Not_found ->
        let cpt_fois_2 = !cpt_mk_var lsl 1 in
        let rec var  =
          { vid = !cpt_mk_var;
            pa = pa;
            na = na;
            seen = false;
            v_level = -1;
            v_weight = 0.;
            reason = None;
          }
        and pa =
          { var = var;
            lit = lit;
            watched = Vec.make 10 dummy_clause;
            neg = na;
            is_true = false;
            aid = cpt_fois_2 (* aid = vid*2 *) }
        and na =
          { var = var;
            lit = E.neg lit;
            watched = Vec.make 10 dummy_clause;
            neg = pa;
            is_true = false;
            aid = cpt_fois_2 + 1 (* aid = vid*2+1 *) } in
        MF.add f_map lit var;
        incr cpt_mk_var;
        Vec.push vars (Either.mk_right var);
        var, negated

  let add_term t = make_semantic_var t

  let add_atom lit =
    let var, negated = make_boolean_var lit in
    if negated then var.na else var.pa

  let make_clause ?tag name ali sz_ali is_learnt premise =
    let atoms = Vec.from_list ali sz_ali dummy_atom in
    let level =
      match premise with
      | Hyp lvl -> lvl
      | Lemma _ -> 0
      | History l -> List.fold_left (fun lvl c -> max lvl c.c_level) 0 l
    in
    { name  = name;
      tag = tag;
      atoms = atoms;
      attached = false;
      visited = false;
      learnt = is_learnt;
      c_level = level;
      activity = 0.;
      cpremise = premise}

  let empty_clause = make_clause "Empty" [] 0 false (History [])

  (* Decisions & propagations *)
  type t = (lit, atom) Either.t

  let of_lit = Either.mk_left
  let of_atom = Either.mk_right
  let destruct = Either.destruct

  (* Elements *)
  let elt_of_lit = Either.mk_left
  let elt_of_var = Either.mk_right

  let get_elt_id = function
    | Either.Left l -> l.lid | Either.Right v ->  v.vid
  let get_elt_level = function
    | Either.Left l -> l.l_level | Either.Right v ->  v.v_level
  let get_elt_weight = function
    | Either.Left l -> l.l_weight | Either.Right v ->  v.v_weight

  let set_elt_level e lvl = match e with
    | Either.Left l -> l.l_level <- lvl | Either.Right v ->  v.v_level <- lvl
  let set_elt_weight e w = match e with
    | Either.Left l -> l.l_weight <- w | Either.Right v ->  v.v_weight <- w

  (* Name generation *)
  let fresh_lname =
    let cpt = ref 0 in
    fun () -> incr cpt; "L" ^ (string_of_int !cpt)

  let fresh_hname =
    let cpt = ref 0 in
    fun () -> incr cpt; "H" ^ (string_of_int !cpt)

  let fresh_tname =
    let cpt = ref 0 in
    fun () -> incr cpt; "T" ^ (string_of_int !cpt)

  let fresh_name =
    let cpt = ref 0 in
    fun () -> incr cpt; "C" ^ (string_of_int !cpt)

  (* Pretty printing for atoms and clauses *)
  let print_lit fmt v = E.Term.print fmt v.term

  let print_atom fmt a = E.Formula.print fmt a.lit

  let print_atoms fmt v =
    if Vec.size v = 0 then
      Format.fprintf fmt "∅"
    else begin
      print_atom fmt (Vec.get v 0);
      if (Vec.size v) > 1 then begin
        for i = 1 to (Vec.size v) - 1 do
          Format.fprintf fmt " ∨ %a" print_atom (Vec.get v i)
        done
      end
    end

  let print_clause fmt c =
    Format.fprintf fmt "%s : %a" c.name print_atoms c.atoms

  (* Complete debug printing *)
  let sign a = if a == a.var.pa then "" else "-"

  let level a =
    match a.var.v_level, a.var.reason with
    | n, _ when n < 0 -> sprintf "%%"
    | n, None   -> sprintf "%d" n
    | n, Some Decision   -> sprintf "@@%d" n
    | n, Some Bcp c -> sprintf "->%d/%s" n c.name
    | n, Some Semantic lvl -> sprintf "::%d/%d" n lvl

  let value a =
    if a.is_true then sprintf "[T%s]" (level a)
    else if a.neg.is_true then sprintf "[F%s]" (level a)
    else "[]"

  let pp_premise out = function
    | Hyp _ -> Format.fprintf out "hyp"
    | Lemma _ -> Format.fprintf out "th_lemma"
    | History v -> List.iter (fun {name=name} -> Format.fprintf out "%s,@ " name) v

  let pp_assign out = function
    | None -> ()
    | Some t -> Format.fprintf out " ->@ %a" E.Term.print t

  let pp_lit out v =
    Format.fprintf out "%d [lit:%a%a]"
      (v.lid+1) E.Term.print v.term pp_assign v.assigned

  let pp_atom out a =
    Format.fprintf out "%s%d%s[atom:%a]"
      (sign a) (a.var.vid+1) (value a) E.Formula.print a.lit

  let pp_atoms_vec out vec =
    Vec.print ~sep:"@ " pp_atom out vec

  let pp_clause out {name=name; atoms=arr; cpremise=cp; learnt=learnt} =
    Format.fprintf out "@[<hov 2>%s%s{@[<hov 2>%a@]}@ cpremise={@[<hov2>%a@]}@]"
      name (if learnt then "!" else ":") pp_atoms_vec arr pp_premise cp

end


(* Solver types for pure SAT Solving *)
(* ************************************************************************ *)

module SatMake (E : Formula_intf.S)(Dummy : sig end) = struct
  include McMake(struct
      include E
      module Term = E
      module Formula = E
    end)(struct end)

  let mcsat = false
end

