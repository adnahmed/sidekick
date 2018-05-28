(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)


module Var_fields = Solver_intf.Var_fields

let v_field_seen_neg = Var_fields.mk_field()
let v_field_seen_pos = Var_fields.mk_field()
let () = Var_fields.freeze()

module C_fields = Solver_intf.C_fields

let c_field_attached = C_fields.mk_field () (* watching literals? *)
let c_field_dead = C_fields.mk_field () (* been removed once? *)
let c_field_visited = C_fields.mk_field () (* used during propagation and proof generation. *)

module Make (Th : Theory_intf.S) = struct
  type formula = Th.Form.t
  type lemma = Th.proof

  type var = {
    v_id : int;
    v_pa : atom;
    v_na : atom;
    mutable v_fields : Var_fields.t;
    mutable v_level : int;
    mutable v_idx: int; (** position in heap *)
    mutable v_weight : float; (** Weight (for the heap), tracking activity *)
    mutable reason : reason option;
  }

  and atom = {
    a_id : int;
    var : var;
    neg : atom;
    lit : formula;
    mutable is_true : bool;
    mutable watched : clause Vec.t;
  }

  and clause = {
    name : int;
    tag : int option;
    atoms : atom array;
    mutable c_premise : premise;
    mutable activity : float;
    mutable c_flags : C_fields.t
  }

  and reason =
    | Decision
    | Bcp of clause
    | Local of clause

  and premise =
    | Hyp
    | Lemma of lemma
    | Simplified of clause
    | History of clause list

  type proof = clause

  let rec dummy_var =
    { v_id = -101;
      v_pa = dummy_atom;
      v_na = dummy_atom;
      v_fields = Var_fields.empty;
      v_level = -1;
      v_weight = -1.;
      v_idx= -1;
      reason = None;
    }
  and dummy_atom =
    { var = dummy_var;
      lit = Th.Form.dummy;
      watched = Obj.magic 0;
      (* should be [Vec.make_empty dummy_clause]
         but we have to break the cycle *)
      neg = dummy_atom;
      is_true = false;
      a_id = -102;
    }
  let dummy_clause =
    { name = -1;
      tag = None;
      atoms = [| |];
      activity = -1.;
      c_flags = C_fields.empty;
      c_premise = History [];
    }

  let () = dummy_atom.watched <- Vec.make_empty dummy_clause

  (* Constructors *)
  module MF = Hashtbl.Make(Th.Form)

  let rec name_of_clause c = match c.c_premise with
    | Hyp -> "H" ^ string_of_int c.name
    | Lemma _ -> "T" ^ string_of_int c.name
    | History _ -> "C" ^ string_of_int c.name
    | Simplified d -> name_of_clause d

  module H = Heap.Make(struct
    type t = var
    let[@inline] cmp i j = j.v_weight < i.v_weight (* comparison by weight *)
    let dummy = dummy_var
    let[@inline] idx v = v.v_idx
    let[@inline] set_idx v i = v.v_idx <- i
  end)

  exception Sat
  exception Unsat
  exception UndecidedLit
  exception Restart
  exception Conflict of clause

  let var_decay : float = 1. /. 0.95
  (* inverse of the activity factor for variables. Default 1/0.999 *)

  let clause_decay : float = 1. /. 0.999
  (* inverse of the activity factor for clauses. Default 1/0.95 *)

  let restart_first : int = 100
  (* intial restart limit *)

  let learntsize_factor : float = 1. /. 3.
  (* initial limit for the number of learnt clauses, 1/3 of initial
      number of clauses by default *)

  let restart_inc : float = 1.5
  (* multiplicative factor for restart limit, default 1.5 *)

  let learntsize_inc : float = 1.1
  (* multiplicative factor for [learntsize_factor] at each restart, default 1.1 *)

  (* Singleton type containing the current state *)
  type t = {
    f_map: var MF.t;
    vars: var Vec.t;
    mutable cpt_mk_var: int;
    mutable cpt_mk_clause: int;

    th: Th.t lazy_t;

    clauses: clause Vec.t;

    mutable unsat_conflict : clause option;
    (* conflict clause at [base_level], if any *)
    mutable next_decision : atom option;
    (* When the last conflict was a semantic one, this stores the next decision to make *)

    trail : atom Vec.t;
    (* decision stack + propagated elements (atoms or assignments). *)

    elt_levels : int Vec.t;
    (* decision levels in [trail]  *)

    backtrack_levels : int Vec.t;
    (* user levels in [backtrack] *)

    backtrack : (unit -> unit) Vec.t;
    (** Actions to call when backtracking *)

    to_redo_after_backtrack: (unit -> unit) Vec.t;
    (** Actions to re-do after backtracking *)

    mutable th_head : int;
    (* Start offset in the queue {!trail} of
       unit facts not yet seen by the theory. *)
    mutable elt_head : int;
    (* Start offset in the queue {!trail} of
       unit facts to propagate, within the trail *)

    (* invariant:
       - during propagation, th_head <= elt_head
       - then, once elt_head reaches length trail, Th.assume is
         called so that th_head can catch up with elt_head
       - this is repeated until a fixpoint is reached;
       - before a decision (and after the fixpoint),
         th_head = elt_head = length trail
    *)

    order : H.t;
    (* Heap ordered by variable activity *)

    mutable var_incr : float;
    (* increment for variables' activity *)

    mutable clause_incr : float;
    (* increment for clauses' activity *)

    tmp_vec_seen : atom Vec.t;
    (* temporary vector used for conflict resolution *)

    to_add : (bool * clause) Vec.t;
    (* clauses to add, from the user *)
  }

  (* Starting environment. *)
  let create_ ~size_map ~size_vars ~size_trail ~size_lvl th : t = {
    f_map = MF.create size_map;
    vars = Vec.make size_vars dummy_var;
    cpt_mk_var = 0;
    cpt_mk_clause = 0;
    th;
    unsat_conflict = None;
    next_decision = None;

    clauses = Vec.make 0 dummy_clause;

    th_head = 0;
    elt_head = 0;

    trail = Vec.make size_trail dummy_atom;
    elt_levels = Vec.make size_lvl (-1);
    backtrack_levels = Vec.make size_lvl (-1);
    backtrack = Vec.make size_lvl (fun () -> ());
    to_redo_after_backtrack = Vec.make 10 (fun () -> ());

    order = H.create();
    to_add = Vec.make_empty (true, dummy_clause);
    tmp_vec_seen = Vec.make_empty dummy_atom;

    var_incr = 1.;
    clause_incr = 1.;
  }

  type state = t

  let[@inline] n_vars st = Vec.size st.vars
  let[@inline] get_var st i = Vec.get st.vars i

  module Var = struct
    type t = var
    let dummy = dummy_var
    let[@inline] level v = v.v_level
    let[@inline] pos v = v.v_pa
    let[@inline] neg v = v.v_na
    let[@inline] reason v = v.reason
    let[@inline] weight v = v.v_weight

    let[@inline] id v = v.v_id
    let[@inline] level v = v.v_level
    let[@inline] idx v = v.v_idx

    let[@inline] set_level v lvl = v.v_level <- lvl
    let[@inline] set_idx v i = v.v_idx <- i
    let[@inline] set_weight v w = v.v_weight <- w

    let[@inline] in_heap v = v.v_idx >= 0

    let make (st:state) (t:formula) : var * Theory_intf.negated =
      let lit, negated = Th.Form.norm t in
      try
        MF.find st.f_map lit, negated
      with Not_found ->
        let cpt_double = st.cpt_mk_var lsl 1 in
        let rec var  =
          { v_id = st.cpt_mk_var;
            v_pa = v_pa;
            v_na = v_na;
            v_fields = Var_fields.empty;
            v_level = -1;
            v_idx= -1;
            v_weight = 0.;
            reason = None;
          }
        and v_pa =
          { var = var;
            lit = lit;
            watched = Vec.make 10 dummy_clause;
            neg = v_na;
            is_true = false;
            a_id = cpt_double (* a_id = v_id*2 *) }
        and v_na =
          { var = var;
            lit = Th.Form.neg lit;
            watched = Vec.make 10 dummy_clause;
            neg = v_pa;
            is_true = false;
            a_id = cpt_double + 1 (* a_id = v_id*2+1 *) } in
        MF.add st.f_map lit var;
        st.cpt_mk_var <- st.cpt_mk_var + 1;
        Vec.push st.vars var;
        var, negated

    (* Marking helpers *)
    let[@inline] clear v =
      v.v_fields <- Var_fields.empty

    let[@inline] seen_both v =
      Var_fields.get v_field_seen_pos v.v_fields &&
      Var_fields.get v_field_seen_neg v.v_fields

    let pp out (v:t) = Th.Form.print out v.v_pa.lit
  end

  module Atom = struct
    type t = atom
    let dummy = dummy_atom
    let[@inline] level a = a.var.v_level
    let[@inline] var a = a.var
    let[@inline] neg a = a.neg
    let[@inline] abs a = a.var.v_pa
    let[@inline] get_formula a = a.lit
    let[@inline] equal a b = a == b
    let[@inline] is_pos a = a == abs a
    let[@inline] compare a b = Pervasives.compare a.a_id b.a_id
    let[@inline] reason a = Var.reason a.var
    let[@inline] id a = a.a_id
    let[@inline] is_true a = a.is_true
    let[@inline] is_false a = a.neg.is_true

    let[@inline] seen a =
      let pos = equal a (abs a) in
      if pos
      then Var_fields.get v_field_seen_pos a.var.v_fields
      else Var_fields.get v_field_seen_neg a.var.v_fields

    let[@inline] mark a =
      let pos = equal a (abs a) in
      if pos
      then a.var.v_fields <- Var_fields.set v_field_seen_pos true a.var.v_fields
      else a.var.v_fields <- Var_fields.set v_field_seen_neg true a.var.v_fields

    let[@inline] make st lit =
      let var, negated = Var.make st lit in
      match negated with
      | Theory_intf.Negated -> var.v_na
      | Theory_intf.Same_sign -> var.v_pa

    let pp fmt a = Th.Form.print fmt a.lit

    let pp_a fmt v =
      if Array.length v = 0 then (
        Format.fprintf fmt "∅"
      ) else (
        pp fmt v.(0);
        if (Array.length v) > 1 then begin
          for i = 1 to (Array.length v) - 1 do
            Format.fprintf fmt " ∨ %a" pp v.(i)
          done
        end
      )

    (* Complete debug printing *)
    let sign a = if a == a.var.v_pa then "+" else "-"

    let debug_reason fmt = function
      | n, _ when n < 0 ->
        Format.fprintf fmt "%%"
      | n, None ->
        Format.fprintf fmt "%d" n
      | n, Some Local _ ->
        Format.fprintf fmt "L%d" n
      | n, Some Decision ->
        Format.fprintf fmt "@@%d" n
      | n, Some Bcp c ->
        Format.fprintf fmt "->%d/%s" n (name_of_clause c)

    let pp_level fmt a =
      debug_reason fmt (a.var.v_level, a.var.reason)

    let debug_value out a =
      if a.is_true then (
        Format.fprintf out "[T%a]" pp_level a
      ) else if a.neg.is_true then (
        Format.fprintf out "[F%a]" pp_level a
      ) else (
        CCFormat.string out "[?]"
      )

    let debug out a =
      Format.fprintf out "@[@[%a@]%a@]" Th.Form.print a.lit debug_value a

    let debug_a out vec =
      Array.iteri (fun i a -> if i>0 then Format.fprintf out "@ "; debug out a) vec
  end

  module Clause = struct
    type t = clause
    let dummy = dummy_clause

    let make =
      let n = ref 0 in
      fun ?tag atoms premise ->
        let name = !n in
        incr n;
        { name;
          tag = tag;
          atoms = atoms;
          c_flags = C_fields.empty;
          activity = 0.;
          c_premise = premise;
        }

    let make_l ?tag l pr = make ?tag (Array.of_list l) pr

    let[@inline] copy (c:t) : t = make ?tag:c.tag c.atoms c.c_premise

    let empty = make [| |] (History [])
    let name = name_of_clause
    let[@inline] equal c1 c2 = c1==c2
    let[@inline] atoms c = c.atoms
    let[@inline] atoms_l c = Array.to_list c.atoms
    let[@inline] tag c = c.tag
    let hash cl = Array.fold_left (fun i a -> Hashtbl.hash (a.a_id, i)) 0 cl.atoms

    let[@inline] premise c = c.c_premise
    let[@inline] set_premise c p = c.c_premise <- p

    (* a dead clause is a clause that has been removed. It should never
       be added again *)
    let[@inline] dead c = C_fields.get c_field_dead c.c_flags
    let[@inline] mark_dead c = c.c_flags <- C_fields.set c_field_dead true c.c_flags

    let[@inline] visited c = C_fields.get c_field_visited c.c_flags
    let[@inline] set_visited c b = c.c_flags <- C_fields.set c_field_visited b c.c_flags

    let[@inline] attached c = C_fields.get c_field_attached c.c_flags
    let[@inline] set_attached c b = c.c_flags <- C_fields.set c_field_attached b c.c_flags

    let[@inline] activity c = c.activity
    let[@inline] set_activity c w = c.activity <- w

    let rec is_learnt c =
      match c.c_premise with
      | Simplified c' -> is_learnt c'
      | History _ -> true
      | Hyp | Lemma _ -> false

    module Tbl = Hashtbl.Make(struct
        type t = clause
        let hash = hash
        let equal = equal
      end)

    let pp fmt c = Format.fprintf fmt "%s : %a" (name c) Atom.pp_a c.atoms

    let rec debug_premise out = function
      | Hyp -> Format.fprintf out "hyp"
      | Lemma _ -> Format.fprintf out "th_lemma"
      | Simplified d -> debug_premise out d.c_premise
      | History v ->
        Format.fprintf out "[@[%a@]]"
          (Util.pp_list @@ CCFormat.of_to_string name_of_clause) v

    let debug out ({atoms=arr; c_premise=cp;_}as c) =
      Format.fprintf out "%s@[{@[%a@]}@ c_premise={@[%a@]}@]"
        (name c) Atom.debug_a arr debug_premise cp

    let pp_dimacs fmt {atoms;_} =
      let aux fmt a =
        Array.iter (fun p ->
          Format.fprintf fmt "%s%d "
            (if p == p.var.v_pa then "-" else "")
            (p.var.v_id+1)
        ) a
      in
      Format.fprintf fmt "%a0" aux atoms
  end

  module Formula = struct
    include Th.Form
    let pp = print
  end

  (* TODO: simplify this *)
  module Proof = struct
    type t = proof

    exception Resolution_error of string
    exception Insufficient_hyps
    (** Raised when a complete resolution derivation cannot be found using the current hypotheses. *)

    let equal_atoms = Atom.equal
    let compare_atoms = Atom.compare

    let merge = List.merge compare_atoms

    let _c = ref 0
    let fresh_pcl_name () = incr _c; "R" ^ (string_of_int !_c)

    (* Compute resolution of 2 clauses *)
    let resolve l =
      let rec aux resolved acc = function
        | [] -> resolved, acc
        | [a] -> resolved, a :: acc
        | a :: b :: r ->
          if equal_atoms a b then
            aux resolved (a :: acc) r
          else if equal_atoms (a.neg) b then
            aux ((a.var.v_pa) :: resolved) acc r
          else
            aux resolved (a :: acc) (b :: r)
      in
      let resolved, new_clause = aux [] [] l in
      resolved, List.rev new_clause

    (* Compute the set of doublons of a clause *)
    let list c = List.sort Atom.compare (Array.to_list (c.atoms))

    let analyze cl =
      let rec aux duplicates free = function
        | [] -> duplicates, free
        | [ x ] -> duplicates, x :: free
        | x :: ((y :: r) as l) ->
          if x == y then
            count duplicates (x :: free) x [y] r
          else
            aux duplicates (x :: free) l
      and count duplicates free x acc = function
        | (y :: r) when x == y ->
          count duplicates free x (y :: acc) r
        | l ->
          aux (acc :: duplicates) free l
      in
      let doublons, acc = aux [] [] cl in
      doublons, List.rev acc

    let to_list c =
      let cl = list c in
      let doublons, l = analyze cl in
      let conflicts, _ = resolve l in
      if doublons <> [] then
        Log.debug 5 "Input clause has redundancies";
      if conflicts <> [] then
        Log.debug 5 "Input clause is a tautology";
      cl

    (* Comparison of clauses *)
    let cmp_cl c d =
      let rec aux = function
        | [], [] -> 0
        | a :: r, a' :: r' ->
          begin match compare_atoms a a' with
            | 0 -> aux (r, r')
            | x -> x
          end
        | _ :: _ , [] -> -1
        | [], _ :: _ -> 1
      in
      aux (c, d)

    let[@inline] prove conclusion =
      assert (conclusion.c_premise <> History []);
      conclusion

    let rec set_atom_proof a =
      let aux acc b =
        if equal_atoms a.neg b then acc
        else set_atom_proof b :: acc
      in
      assert (a.var.v_level >= 0);
      match (a.var.reason) with
      | Some Bcp c ->
        Log.debugf 5 (fun k->k "Analysing: @[%a@ %a@]" Atom.debug a Clause.debug c);
        if Array.length c.atoms = 1 then (
          Log.debugf 5 (fun k -> k "Old reason: @[%a@]" Atom.debug a);
          c
        ) else (
          assert (a.neg.is_true);
          let r = History (c :: (Array.fold_left aux [] c.atoms)) in
          let c' = Clause.make [| a.neg |] r in
          a.var.reason <- Some (Bcp c');
          Log.debugf 5
            (fun k -> k "New reason: @[%a@ %a@]" Atom.debug a Clause.debug c');
          c'
        )
      | _ ->
        Log.debugf 1 (fun k -> k "Error while proving atom %a" Atom.debug a);
        raise (Resolution_error "Cannot prove atom")

    let prove_atom a =
      if (a.is_true && a.var.v_level = 0) then
        Some (set_atom_proof a)
      else
        None

    (* Interface exposed *)
    type node = {
      conclusion : clause;
      step : step;
    }
    and step =
      | Hypothesis
      | Assumption
      | Lemma of lemma
      | Duplicate of proof * atom list
      | Resolution of proof * proof * atom

    let rec chain_res (c, cl) = function
      | d :: r ->
        Log.debugf 5
          (fun k -> k "  Resolving clauses : @[%a@\n%a@]" Clause.debug c Clause.debug d);
        let dl = to_list d in
        begin match resolve (merge cl dl) with
          | [ a ], l ->
            begin match r with
              | [] -> (l, c, d, a)
              | _ ->
                let new_clause = Clause.make_l l (History [c; d]) in
                chain_res (new_clause, l) r
            end
          | _ ->
            Log.debugf 1
              (fun k -> k "While resolving clauses:@[<hov>%a@\n%a@]"
                  Clause.debug c Clause.debug d);
            raise (Resolution_error "Clause mismatch")
        end
      | _ ->
        raise (Resolution_error "Bad history")

    let[@inline] conclusion (p:proof) : clause = p

    let expand conclusion =
      Log.debugf 5 (fun k -> k "(@[proof.expand@ @[%a@]@])" Clause.debug conclusion);
      match conclusion.c_premise with
      | Lemma l ->
        {conclusion; step = Lemma l; }
      | Hyp ->
        { conclusion; step = Hypothesis; }
      | History [] ->
        Log.debugf 1 (fun k -> k "(@[proof.empty_history@ %a@]" Clause.debug conclusion);
        raise (Resolution_error "Empty history")
      | Simplified c ->
        let duplicates, res = analyze (list c) in
        assert (cmp_cl res (list conclusion) = 0);
        { conclusion; step = Duplicate (c, List.concat duplicates) }
      | History ( c :: ([_] as r)) ->
        let (l, c', d', a) = chain_res (c, to_list c) r in
        assert (cmp_cl l (to_list conclusion) = 0);
        { conclusion; step = Resolution (c', d', a); }
      | History ( c :: r ) ->
        let (l, c', d', a) = chain_res (c, to_list c) r in
        conclusion.c_premise <- History [c'; d'];
        assert (cmp_cl l (to_list conclusion) = 0);
        { conclusion; step = Resolution (c', d', a); }

    let[@inline] step p = (expand p).step

    (* Proof nodes manipulation *)
    let is_leaf = function
      | Hypothesis
      | Assumption
      | Lemma _ -> true
      | Duplicate _
      | Resolution _ -> false

    let parents = function
      | Hypothesis
      | Assumption
      | Lemma _ -> []
      | Duplicate (p, _) -> [p]
      | Resolution (p, p', _) -> [p; p']

    let expl = function
      | Hypothesis -> "hypothesis"
      | Assumption -> "assumption"
      | Lemma _ -> "lemma"
      | Duplicate _ -> "duplicate"
      | Resolution _ -> "resolution"

    (* Compute unsat-core
       TODO: replace visited bool by a int unique to each call
       of unsat_core, so that the cleanup can be removed ? *)
    let unsat_core proof =
      let rec aux res acc = function
        | [] -> res, acc
        | c :: r ->
          if not (Clause.visited c) then (
            Clause.set_visited c true;
            match c.c_premise with
            | Hyp | Lemma _ -> aux (c :: res) acc r
            | Simplified c -> aux res acc [c]
            | History h ->
              let l = List.fold_left (fun acc c ->
                  if not (Clause.visited c) then c :: acc else acc) r h in
              aux res (c :: acc) l
          ) else (
            aux res acc r
          )
      in
      let res, tmp = aux [] [] [proof] in
      List.iter (fun c -> Clause.set_visited c false) res;
      List.iter (fun c -> Clause.set_visited c false) tmp;
      res

    module Tbl = Clause.Tbl

    type task =
      | Enter of proof
      | Leaving of proof

    let spop s = try Some (Stack.pop s) with Stack.Empty -> None

    let rec fold_aux s h f acc =
      match spop s with
      | None -> acc
      | Some (Leaving c) ->
        Tbl.add h c true;
        fold_aux s h f (f acc (expand c))
      | Some (Enter c) ->
        if not (Tbl.mem h c) then begin
          Stack.push (Leaving c) s;
          let node = expand c in
          begin match node.step with
            | Duplicate (p1, _) ->
              Stack.push (Enter p1) s
            | Resolution (p1, p2, _) ->
              Stack.push (Enter p2) s;
              Stack.push (Enter p1) s
            | Hypothesis | Assumption | Lemma _ -> ()
          end
        end;
        fold_aux s h f acc

    let fold f acc p =
      let h = Tbl.create 42 in
      let s = Stack.create () in
      Stack.push (Enter p) s;
      fold_aux s h f acc

    let check p = fold (fun () _ -> ()) () p
  end

  let[@inline] theory st = Lazy.force st.th
  let[@inline] at_level_0 st : bool = Vec.is_empty st.backtrack_levels
  let[@inline] on_backtrack st f : unit =
    if not (at_level_0 st) then (
      Vec.push st.backtrack f
    )

  let[@inline] nb_clauses st = Vec.size st.clauses
  let[@inline] decision_level st = Vec.size st.elt_levels
  let[@inline] base_level _st = 0

  (* [redo_down_to_level_0 f ~undo] performs [f] now. Upon backtracking
     before current level, some undo actions scheduled by [f]
     might run;
     later [f] will be called again
     to re-perform the action, and this cycle [f(); backtrack; f(); …] is
     done until we backtrack at level 0.
     Once at level 0, [f()] is called and will never be undone again.
     *)
  let rec redo_down_to_level_0 (st:t) (f:unit->unit) : unit =
    if not (at_level_0 st) then (
      on_backtrack st
        (fun () ->
           Vec.push st.to_redo_after_backtrack
             (fun () -> redo_down_to_level_0 st f))
    );
    f()

  (* Are the assumptions currently unsat ? *)
  let[@inline] is_unsat st =
    match st.unsat_conflict with
    | Some _ -> true
    | None -> false

  (* Variable and literal activity.
     Activity is used to decide on which variable to decide when propagation
     is done. Uses a heap (implemented in {!Heap}), to keep track of variable activity.
  *)
  let insert_var_order st (v:var) : unit =
    if not (Var.in_heap v) && Var.level v < 0 then (
      (* new variable that is not assigned, add to heap and to theory. *)
      H.insert st.order v;
      Th.add_formula (Lazy.force st.th) v.v_pa.lit;
      Th.add_formula (Lazy.force st.th) v.v_na.lit;
    )

  (* attach an atom by deciding on its variable, if needed *)
  let[@inline] attach_atom (st:t) (a:atom) : unit = insert_var_order st a.var

  (* Rather than iterate over all the heap when we want to decrease all the
     variables/literals activity, we instead increase the value by which
     we increase the activity of 'interesting' var/lits. *)
  let[@inline] var_decay_activity st =
    st.var_incr <- st.var_incr *. var_decay

  let[@inline] clause_decay_activity st =
    st.clause_incr <- st.clause_incr *. clause_decay

  (* increase activity of [v] *)
  let var_bump_activity st v =
    v.v_weight <- v.v_weight +. st.var_incr;
    if v.v_weight > 1e100 then (
      Vec.iter
        (fun v -> Var.set_weight v (Var.weight v *. 1e-100))
        st.vars;
      st.var_incr <- st.var_incr *. 1e-100;
    );
    if H.in_heap v then (
      H.decrease st.order v
    )

  (* increase activity of clause [c] *)
  let clause_bump_activity st (c:clause) : unit =
    c.activity <- c.activity +. st.clause_incr;
    if c.activity > 1e20 then (
      Vec.iter
        (fun c -> c.activity <- c.activity *. 1e-20)
        st.clauses;
      st.clause_incr <- st.clause_incr *. 1e-20
    )

  exception Trivial

  (* [arr_to_list a i] converts [a.(i), ... a.(length a-1)] into a list *)
  let array_slice_to_list arr i : _ list =
    if i >= Array.length arr then []
    else Array.to_list (Array.sub arr i (Array.length arr - i))

  (* Eliminates atom doublons in clauses *)
  let eliminate_duplicates clause : clause =
    let trivial = ref false in
    let duplicates = ref [] in
    let res = ref [] in
    Array.iter
      (fun a ->
        if Atom.seen a then duplicates := a :: !duplicates
        else (
          Atom.mark a;
          res := a :: !res
        ))
      clause.atoms;
    List.iter
      (fun a ->
         if Var.seen_both a.var then trivial := true;
         Var.clear a.var)
      !res;
    if !trivial then (
      raise Trivial
    ) else if !duplicates = [] then (
      clause
    ) else (
      Clause.make_l !res (History [clause])
    )

  (* Sort literals for new clause, into:
     - true literals (maybe makes the clause trivial if the lit is proved true at level 0)
     - unassigned literals, yet to be decided
     - false literals (not suitable to watch)
  *)
  let sort_lits_by_level atoms : atom list =
    let rec aux trues unassigned falses i =
      if i >= Array.length atoms then (
        trues @ unassigned @ falses
      ) else (
        let a = atoms.(i) in
        if a.is_true then (
          let l = a.var.v_level in
          if l = 0 then
            raise Trivial (* A var true at level 0 gives a trivially true clause *)
          else
            (a :: trues) @ unassigned @ falses @ (array_slice_to_list atoms (i + 1))
        ) else if a.neg.is_true then (
          aux trues unassigned (a::falses) (i + 1)
        ) else (
          aux trues (a::unassigned) falses (i + 1)
        )
      )
    in
    try aux [] [] [] 0
    with Trivial -> Array.to_list atoms

  (* Making a decision.
     Before actually creatig a new decision level, we check that
     all propagations have been done and propagated to the theory,
     i.e that the theoriy state indeed takes into account the whole
     stack of literals
     i.e we have indeed reached a propagation fixpoint before making
     a new decision *)
  let new_decision_level st =
    assert (st.th_head = Vec.size st.trail);
    assert (st.elt_head = Vec.size st.trail);
    Vec.push st.elt_levels (Vec.size st.trail);
    Vec.push st.backtrack_levels (Vec.size st.backtrack); (* save the current theory state *)
    ()

  let[@inline] internalize_atoms (self:t) (c:clause) : unit =
    Array.iter (attach_atom self) c.atoms

  (* Attach a clause.
     A clause is attached (to its watching lits) when it is first added,
     either because it is assumed or learnt.
  *)
  let attach_clause (self:t) (c:clause) : unit =
    assert (not @@ Clause.dead c);
    if Array.length c.atoms >= 2 && not (Clause.attached c) then (
      Log.debugf 5 (fun k -> k "(@[sat.attach_clause@ %a@])" Clause.debug c);
      Vec.push c.atoms.(0).neg.watched c;
      Vec.push c.atoms.(1).neg.watched c;
      Clause.set_attached c true;
      internalize_atoms self c;
    )

  (* perform all backtracking actions down to level [l].
     To be called only from [cancel_until] *)
  let backtrack_down_to (st:t) (lvl:int): unit =
    Log.debugf 2 (fun k->k "(@[@{<Yellow>sat.backtrack@} now at stack depth %d@])" lvl);
    while Vec.size st.backtrack > lvl do
      let f = Vec.pop_last st.backtrack in
      f()
    done;
    (* now re-do permanent actions that were backtracked *)
    while not (Vec.is_empty st.to_redo_after_backtrack) do
      let f = Vec.pop_last st.to_redo_after_backtrack in
      f()
    done;
    ()

  (* Backtracking.
     Used to backtrack, i.e cancel down to [lvl] excluded,
     i.e we want to go back to the state the solver was in
         when decision level [lvl] was created. *)
  let cancel_until st lvl =
    Log.debugf 5
      (fun k -> k "(@[@{<yellow>sat.cancel_until@}@ :lvl %d :cur-decision-lvl %d@])" lvl @@ decision_level st);
    assert (lvl >= base_level st);
    (* Nothing to do if we try to backtrack to a non-existent level. *)
    if decision_level st <= lvl then (
    ) else (
      (* We set the head of the solver and theory queue to what it was. *)
      let head = ref (Vec.get st.elt_levels lvl) in
      st.elt_head <- !head;
      st.th_head <- !head;
      (* Now we need to cleanup the vars that are not valid anymore
         (i.e to the right of elt_head in the queue. *)
      for c = st.elt_head to Vec.size st.trail - 1 do
        let a = Vec.get st.trail c in
        (* A literal is unassigned, we nedd to add it back to
           the heap of potentially assignable literals, unless it has
           a level lower than [lvl], in which case we just move it back. *)
        if a.var.v_level <= lvl then (
          (* It is a late propagation, which has a level
             lower than where we backtrack, so we just move it to the head
             of the queue, to be propagated again. *)
          Vec.set st.trail !head a;
          head := !head + 1
        ) else (
          (* it is a result of bolean propagation, or a semantic propagation
             with a level higher than the level to which we backtrack,
             in that case, we simply unset its value and reinsert it into the heap. *)
          a.is_true <- false;
          a.neg.is_true <- false;
          a.var.v_level <- -1;
          a.var.reason <- None;
          insert_var_order st a.var
        )
      done;
      let b_lvl = Vec.get st.backtrack_levels lvl in
      (* Resize the vectors according to their new size. *)
      Vec.shrink st.trail !head;
      Vec.shrink st.elt_levels lvl;
      Vec.shrink st.backtrack_levels lvl;
      (* Recover the right theory state. *)
      backtrack_down_to st b_lvl;
    );
    assert (Vec.size st.elt_levels = Vec.size st.backtrack_levels);
    ()

  (* Unsatisfiability is signaled through an exception, since it can happen
     in multiple places (adding new clauses, or solving for instance). *)
  let report_unsat st confl : _ =
    Log.debugf 3 (fun k -> k "(@[sat.unsat_conflict@ %a@])" Clause.debug confl);
    st.unsat_conflict <- Some confl;
    raise Unsat

  (* Boolean propagation.
     Wrapper function for adding a new propagated formula. *)
  let enqueue_bool st a reason : unit =
    if a.neg.is_true then (
      Error.errorf "(@[sat.enqueue_bool.1@ :false-literal %a@])" Atom.debug a
    );
    let level = decision_level st in
    Log.debugf 5
      (fun k->k "(@[sat.enqueue_bool@ :lvl %d@ %a@ :reason %a@])"
          level Atom.debug a Atom.debug_reason (level,Some reason));
    (* backtrack assignment if needed. Trail is backtracked automatically. *)
    assert (not a.is_true && a.var.v_level < 0 && a.var.reason = None);
    a.is_true <- true;
    a.var.v_level <- level;
    a.var.reason <- Some reason;
    Vec.push st.trail a;
    ()

  (* swap elements of array *)
  let[@inline] swap_arr a i j =
    if i<>j then (
      let tmp = a.(i) in
      a.(i) <- a.(j);
      a.(j) <- tmp;
    )

  (* move atoms that are not assigned first,
     else put atoms assigned at high levels first *)
  let put_high_level_atoms_first (arr:atom array) : unit =
    (* move [a] in front of [b]? *)
    let[@inline] put_before a b =
      if Atom.level a < 0 then Atom.level b >= 0
      else (Atom.level b >= 0 && Atom.level a > Atom.level b)
    in
    Array.iteri
      (fun i a ->
         if i>0 && put_before a arr.(0) then (
           (* move first to second, [i]-th to first, second to [i] *)
           if i=1 then (
             swap_arr arr 0 1;
           ) else (
             let tmp = arr.(1) in
             arr.(1) <- arr.(0);
             arr.(0) <- arr.(i);
             arr.(i) <- tmp;
           );
         ) else if i>1 && put_before a arr.(1) then (
           swap_arr arr 1 i;
         ))
      arr

  (* find which level to backtrack to, given a conflict clause
     and a boolean stating whether it is
     a UIP ("Unique Implication Point")
     precond: the atom list is sorted by decreasing decision level *)
  let backtrack_lvl st : atom list -> int * bool = function
    | [] | [_] ->
      0, true
    | a :: b :: _ ->
      assert(a.var.v_level > base_level st);
      if a.var.v_level > b.var.v_level then (
        (* backtrack below [a], so we can propagate [not a] *)
        b.var.v_level, true
      ) else (
        assert (a.var.v_level = b.var.v_level);
        assert (a.var.v_level >= base_level st);
        max (a.var.v_level - 1) (base_level st), false
      )

  (* result of conflict analysis, containing the learnt clause and some
     additional 2.

     invariant: cr_history's order matters, as its head is later used
     during pop operations to determine the origin of a clause/conflict
     (boolean conflict i.e hypothesis, or theory lemma) *)
  type conflict_res = {
    cr_backtrack_lvl : int; (* level to backtrack to *)
    cr_learnt: atom list; (* lemma learnt from conflict *)
    cr_history: clause list; (* justification *)
    cr_is_uip: bool; (* conflict is UIP? *)
  }

  let[@inline] get_atom st i = Vec.get st.trail i

  (* conflict analysis for SAT
     Same idea as the mcsat analyze function (without semantic propagations),
     except we look the the Last UIP (TODO: check ?), and do it in an imperative
     and efficient manner. *)
  let analyze_sat st c_clause : conflict_res =
    let path_c = ref 0 in
    let learnt = ref [] in
    let cond   = ref true in
    let blevel = ref 0 in
    let seen   = st.tmp_vec_seen in
    Vec.clear seen;
    let c      = ref c_clause in
    let tr_ind = ref (Vec.size st.trail - 1) in
    let history = ref [] in
    assert (decision_level st > 0);
    let conflict_level =
      Array.fold_left (fun acc p -> max acc p.var.v_level) 0 c_clause.atoms
    in
    Log.debugf 5
      (fun k -> k "(@[sat.analyzing-conflict (%d)@ %a@])" conflict_level Clause.debug c_clause);
    while !cond do
      let clause = !c in
      Log.debugf 5 (fun k->k"(@[sat.resolving-clause@ %a@])"  Clause.debug clause);
      begin match clause.c_premise with
        | History _ | Simplified _ -> clause_bump_activity st clause
        | Hyp | Lemma _ -> ()
      end;
      history := clause :: !history;
      (* visit the current predecessors *)
      for j = 0 to Array.length clause.atoms - 1 do
        let q = clause.atoms.(j) in
        assert (q.is_true || q.neg.is_true && q.var.v_level >= 0); (* unsure? *)
        if q.var.v_level <= 0 then (
          assert (q.neg.is_true);
          match q.var.reason with
          | Some Bcp cl -> history := cl :: !history
          | _ -> assert false
        );
        if not (Var.seen_both q.var) then (
          Atom.mark q;
          Atom.mark q.neg;
          Vec.push seen q;
          if q.var.v_level > 0 then (
            var_bump_activity st q.var;
            if q.var.v_level >= conflict_level then (
              incr path_c;
            ) else (
              learnt := q :: !learnt;
              blevel := max !blevel q.var.v_level
            )
          )
        )
      done;

      (* look for the next node to expand *)
      while
        let a = Vec.get st.trail !tr_ind in
        Log.debugf 5 (fun k -> k "(@[sat.conflict.looking-at@ %a@])" Atom.debug a);
        (not (Var.seen_both a.var)) || (a.var.v_level < conflict_level)
      do
        decr tr_ind;
      done;
      let p = get_atom st !tr_ind in
      decr path_c;
      decr tr_ind;
      match !path_c, p.var.reason with
      | 0, _ ->
        cond := false;
        learnt := p.neg :: (List.rev !learnt)
      | n, Some Bcp cl ->
        assert (n > 0);
        assert (p.var.v_level >= conflict_level);
        c := cl
      | _ -> assert false
    done;
    Vec.iter (fun q -> Var.clear q.var) seen;
    Vec.clear seen;
    let l = List.fast_sort (fun p q -> compare q.var.v_level p.var.v_level) !learnt in
    let level, is_uip = backtrack_lvl st l in
    { cr_backtrack_lvl = level;
      cr_learnt = l;
      cr_history = List.rev !history;
      cr_is_uip = is_uip;
    }

  let[@inline] analyze st c_clause : conflict_res =
    analyze_sat st c_clause

  (* Add clause, accounting for backtracking semantics.
   - always add literals to queue if not decided yet
   - if clause is already true, probably just do nothing
   - if clause is unit, propagate lit immediately (with clause as justification)
     but do not add clause
   - permanent stuff: just re-add it on backtrack
   *)
  let rec add_clause_ st (c:clause) : unit =
    Log.debugf 5
      (fun k -> k "(@[@{<Yellow>sat.add_clause@}@ %a@])" Clause.debug c);
    assert (not @@ Clause.dead c);
    match eliminate_duplicates c with
    | exception Trivial ->
      Log.debugf 3 (fun k->k "(@[sat.add_clause.ignore-trivial@ %a@])" Clause.debug c)
    | c ->
      Log.debugf 5 (fun k -> k "(@[sat.add_clause.after_eliminate_dups@ %a@])" Clause.debug c);
      (* sort atoms by decreasing level of decision (undecided first) *)
      let atoms = sort_lits_by_level c.atoms in
      (* update order of atoms *)
      assert (List.length atoms = Array.length c.atoms);
      List.iteri (fun i a -> c.atoms.(i) <- a) atoms;
      Log.debugf 3 (fun k->k "(@[sat.add_clause.new_clause@ %a@])" Clause.debug c);
      match atoms with
      | [] ->
        (* report Unsat immediately *)
        report_unsat st c
      | [a] ->
        if a.neg.is_true then (
          Log.debug 5 "(sat.add_clause: false unit clause, report unsat)";
          report_unsat st c
        ) else if a.is_true then (
          (* ignore clause, will never be useful *)
          Log.debug 5 "(sat.add_clause: true unit clause, ignore)";
          assert (a.var.v_level >= base_level st);
        ) else (
          Log.debugf 5
            (fun k->k "(@[sat.add_clause.unit_clause@ :propagating %a@])" Atom.debug a);
          enqueue_bool st a (Bcp c)
        )
      | _::_::_ ->
        Vec.push st.clauses c;
        (* Atoms need to be sorted in decreasing order of decision level,
           or we might watch the wrong literals. *)
        put_high_level_atoms_first c.atoms;
        attach_clause st c;
        let a = c.atoms.(0) in
        let b = c.atoms.(1) in
        if a.neg.is_true then (
          (* conflict, even the last literal is false *)
          add_boolean_conflict st c
        ) else if b.neg.is_true && not a.is_true && not a.neg.is_true then (
          let lvl = List.fold_left (fun m a -> max m a.var.v_level) 0 atoms in
          cancel_until st (max lvl (base_level st));
          enqueue_bool st a (Bcp c)
        )

  (* Add a new clause, simplifying, propagating, and backtracking if
     the clause is false in the current trail *)
  and add_clause ~permanent st (c:clause) : unit =
    add_clause_ st c;
    if permanent then (
      (* need to re-internalize *)
      redo_down_to_level_0 st (fun () -> internalize_atoms st c)
    ) else (
      (* kill clause on backtrack *)
      on_backtrack st (fun () -> Clause.mark_dead c)
    )

  (* process a conflict:
     - learn clause
     - backtrack
     - report unsat if conflict at level 0
  *)
  and add_boolean_conflict st (confl:clause): unit =
    Log.debugf 3
      (fun k -> k "(@[@{<Yellow>sat.boolean-conflict@}@ %a@ :decision-lvl %d@])"
          Clause.debug confl (decision_level st));
    st.next_decision <- None;
    assert (decision_level st >= base_level st);
    if decision_level st = base_level st ||
       Array.for_all (fun a -> a.var.v_level <= base_level st) confl.atoms then (
      (* Top-level conflict *)
      report_unsat st confl;
    );
    (* compute learnt clause with conflict resolution *)
    let cr = analyze st confl in
    let confl = Clause.make_l cr.cr_learnt (History cr.cr_history) in
    Log.debugf 5 (fun k->k "(@[sat.conflict-clause@ %a@])" Clause.debug confl);
    cancel_until st (max cr.cr_backtrack_lvl (base_level st));
    (* make some progress *)
    var_decay_activity st;
    clause_decay_activity st;
    (* add the clause *)
    add_clause ~permanent:true st confl

  let[@inline] add_clause_user ~permanent st (c:clause): unit =
    Vec.push st.to_add (permanent,c)

  type watch_res =
    | Watch_kept
    | Watch_removed

  exception Exn_remove_watch

  (* boolean propagation.
     [a] is the false atom, one of [c]'s two watch literals
     [i] is the index of [c] in [a.watched]
     @return whether [c] was removed from [a.watched]
  *)
  let propagate_in_clause st (a:atom) (c:clause) : watch_res =
    let atoms = c.atoms in
    let first = atoms.(0) in
    if first == a.neg then (
      (* false lit must be at index 1 *)
      atoms.(0) <- atoms.(1);
      atoms.(1) <- first
    ) else (
      assert (a.neg == atoms.(1));
    );
    let first = atoms.(0) in
    if first.is_true
    then Watch_kept (* true clause, keep it in watched *)
    else (
      try (* look for another watch lit *)
        for k = 2 to Array.length atoms - 1 do
          let ak = atoms.(k) in
          if not (ak.neg.is_true) then (
            (* watch lit found: update and exit *)
            Array.unsafe_set atoms 1 ak;
            Array.unsafe_set atoms k a.neg;
            (* remove [c] from [a.watched], add it to [ak.neg.watched] *)
            Vec.push ak.neg.watched c;
            raise Exn_remove_watch
          )
        done;
        (* no watch lit found *)
        if first.neg.is_true then (
          (* clause is false *)
          st.elt_head <- Vec.size st.trail;
          raise (Conflict c)
        ) else (
          enqueue_bool st first (Bcp c)
        );
        Watch_kept
      with Exn_remove_watch ->
        Watch_removed
    )

  (* propagate atom [a], which was just decided. This checks every
     clause watching [a] to see if the clause is false, unit, or has
     other possible watches
     @param res the optional conflict clause that the propagation might trigger *)
  let propagate_atom st a : unit =
    let watched = a.watched in
    let i = ref 0 in
    while !i < Vec.size watched do
      let c = Vec.get watched !i in
      if not (Clause.attached c) then (
        Vec.fast_remove watched !i (* remove *)
      ) else (
        match propagate_in_clause st a c with
        | Watch_kept -> incr i
        | Watch_removed ->
          Vec.fast_remove watched !i;
          (* remove clause [c] from watches, then look again at [!i]
             since it's now another clause *)
      )
    done

  let slice_iter st (hd:int) (last:int) (f:_ -> unit) : unit =
    for i = hd to last-1 do
      let a = Vec.get st.trail i in
      f a.lit
    done

  let act_push_ ~permanent st (l:formula IArray.t) (lemma:lemma): unit =
    let atoms = IArray.to_array_map (Atom.make st) l in
    let c = Clause.make atoms (Lemma lemma) in
    Log.debugf 3
      (fun k->k "(@[sat.push_clause_from_theory@ :permanent %B@ %a@])"
          permanent Clause.debug c);
    add_clause ~permanent st c

  let act_push_local = act_push_ ~permanent:false
  let act_push_persistent = act_push_ ~permanent:true

  let act_propagate (st:t) f causes proof : unit =
    let l = List.rev_map (Atom.make st) causes in
    if List.for_all Atom.is_true l then (
      let p = Atom.make st f in
      let c = Clause.make_l (p :: List.map Atom.neg l) (Lemma proof) in
      if p.is_true then (
      ) else if p.neg.is_true then (
        (* propagate other lits in the clause *)
        add_clause ~permanent:false st c
      ) else (
        insert_var_order st p.var;
        enqueue_bool st p (Bcp c)
      )
    ) else (
      Error.errorf "(@[sat.act_propagate.invalid_guard@ :guard %a@ \
                   :1 all lits are not true@])"
        (Util.pp_list Atom.debug) l
    )

  let current_slice st head : formula Theory_intf.slice_actions =
    let module A = struct
      type form = formula
      let slice_iter = slice_iter st head (Vec.size st.trail)
    end in
    (module A)

  (* full slice, for [if_sat] final check *)
  let full_slice st : formula Theory_intf.slice_actions =
    let module A = struct
      type form = formula
      let slice_iter = slice_iter st 0 (Vec.size st.trail)
    end in
    (module A)

  let act_at_level_0 st () = at_level_0 st

  let actions st: (formula,lemma) Theory_intf.actions =
    let module A = struct
      type nonrec formula = formula
      type proof = lemma
      let push_persistent = act_push_persistent st
      let push_local = act_push_local st
      let on_backtrack = on_backtrack st
      let propagate = act_propagate st
    end in
    (module A)

  let create ?(size=`Big) () : t =
    let size_map, size_vars, size_trail, size_lvl = match size with
      | `Tiny -> 8, 0, 0, 0
      | `Small -> 16, 0, 32, 16
      | `Big -> 4096, 128, 600, 50
    in
    let rec solver = lazy (
      create_ ~size_map ~size_vars ~size_trail ~size_lvl th
    ) and th = lazy (
      Th.create (actions (Lazy.force solver))
    ) in
    Lazy.force solver

  let[@inline] propagation_fixpoint (st:t) : bool =
    st.elt_head = Vec.size st.trail &&
    st.th_head = st.elt_head

  (* some boolean literals were decided/propagated within the solver. Now we
     need to inform the theory of those assumptions, so it can do its job.
     @return the conflict clause, if the theory detects unsatisfiability *)
  let rec theory_propagate st : clause option =
    assert (st.elt_head = Vec.size st.trail);
    assert (st.th_head <= st.elt_head);
    if st.th_head = st.elt_head then (
      None (* fixpoint/no propagation *)
    ) else (
      let slice = current_slice st st.th_head in
      st.th_head <- st.elt_head; (* catch up *)
      match Th.assume (theory st) slice with
      | Theory_intf.Sat ->
        propagate st
      | Theory_intf.Unsat (l, p) ->
        (* conflict *)
        let l = List.rev_map (Atom.make st) l in
        (* TODO: do that when the conflict clause is added *)
        List.iter (fun a -> insert_var_order st a.var) l;
        let c = Clause.make_l l (Lemma p) in
        Some c
    )

  (* fixpoint between boolean propagation and theory propagation
     @return a conflict clause, if any *)
  and propagate (st:t) : clause option =
    (* Now, check that the situation is sane *)
    assert (st.elt_head <= Vec.size st.trail);
    if st.elt_head = Vec.size st.trail then (
      theory_propagate st
    ) else (
      let num_props = ref 0 in
      let res = ref None in
      while st.elt_head < Vec.size st.trail do
        let a = Vec.get st.trail st.elt_head in
        incr num_props;
        Log.debugf 5 (fun k->k "(@[sat.bcp.propagate_atom_on_trail@ %a@])" Atom.pp a);
        propagate_atom st a;
        st.elt_head <- st.elt_head + 1;
      done;
      match !res with
      | None -> theory_propagate st
      | _ -> !res
    )

  (* remove some learnt clauses
     NOTE: so far we do not forget learnt clauses. We could, as long as
     lemmas from the theory itself are kept. *)
  let reduce_db () = ()

  (* Decide on a new literal, and enqueue it into the trail *)
  let rec pick_branch_aux st atom : unit =
    let v = atom.var in
    if v.v_level >= 0 then (
      assert (v.v_pa.is_true || v.v_na.is_true);
      pick_branch_lit st
    ) else (
      new_decision_level st;
      enqueue_bool st atom Decision
    )

  and pick_branch_lit st =
    match st.next_decision with
    | Some atom ->
      st.next_decision <- None;
      pick_branch_aux st atom
    | None ->
      begin match H.remove_min st.order with
        | v -> pick_branch_aux st v.v_pa
        | exception Not_found -> raise Sat
      end

  (* do some amount of search, until the number of conflicts or clause learnt
     reaches the given parameters *)
  let search (st:t) n_of_conflicts n_of_learnts : unit =
    let conflictC = ref 0 in
    while true do
      match propagate st with
      | Some confl -> (* Conflict *)
        incr conflictC;
        add_boolean_conflict st confl

      | None -> (* No Conflict *)
        assert (st.elt_head = Vec.size st.trail);
        assert (st.elt_head = st.th_head);
        if Vec.size st.trail = n_vars st then raise Sat;
        if n_of_conflicts > 0 && !conflictC >= n_of_conflicts then (
          Log.debug 3 "(sat.restarting)";
          cancel_until st (base_level st);
          raise Restart
        );
        (* if decision_level() = 0 then simplify (); *)

        if n_of_learnts >= 0 &&
           Vec.size st.clauses - Vec.size st.trail >= n_of_learnts
        then reduce_db();

        pick_branch_lit st
    done

  let eval_level (st:t) lit =
    let var, negated = Var.make st lit in
    if not var.v_pa.is_true && not var.v_na.is_true
    then raise UndecidedLit
    else assert (var.v_level >= 0);
    let truth = var.v_pa.is_true in
    let value = match negated with
      | Theory_intf.Negated -> not truth
      | Theory_intf.Same_sign -> truth
    in
    value, var.v_level

  let[@inline] eval st lit = fst (eval_level st lit)
  let[@inline] unsat_conflict st = st.unsat_conflict

  let pp_trail st =
    Log.debugf 5
      (fun k -> k "(@[<v>sat.current_trail:@ %a@])"
          (Vec.print ~sep:"" Atom.debug) st.trail)

  (* Add local hyps to the current decision level *)
  let local (st:t) (assumptions:formula list) : unit =
    let add_lit lit : unit =
      let a = Atom.make st lit in
      Log.debugf 3 (fun k-> k "(@[sat.local_assumption@ %a@])" Atom.debug a);
      assert (decision_level st = base_level st);
      let c = Clause.make [|a|] Hyp in
      if not a.is_true then (
        if a.neg.is_true then (
          (* conflict between assumptions: UNSAT *)
          report_unsat st c;
        ) else (
          (* make a decision, propagate *)
          enqueue_bool st a (Local c);
        )
      )
    in
    match st.unsat_conflict with
    | None ->
      Log.debug 3 "(sat.adding_local_assumptions)";
      List.iter add_lit assumptions
    | Some _ ->
      Log.debug 2 "(sat.local_assumptions.1: already unsat)"

  (* fixpoint of propagation and decisions until a model is found, or a
     conflict is reached *)
  let solve ?(assumptions=[]) (st:t) : unit =
    Log.debug 5 "(sat.solve)";
    if is_unsat st then raise Unsat;
    let n_of_conflicts = ref (float_of_int restart_first) in
    let n_of_learnts = ref ((float_of_int (nb_clauses st)) *. learntsize_factor) in
    (* add clauses that are waiting in [to_add] *)
    let rec add_clauses () =
      match
        Vec.filter_in_place (fun (permanent,c) -> add_clause ~permanent st c; false) st.to_add
      with
      | () -> call_solve()
      | exception Conflict c ->
        add_boolean_conflict st c;
        call_solve()
    and call_solve() =
      match search st (int_of_float !n_of_conflicts) (int_of_float !n_of_learnts) with
      | () -> ()
      | exception Restart ->
        n_of_conflicts := !n_of_conflicts *. restart_inc;
        n_of_learnts   := !n_of_learnts *. learntsize_inc
      | exception Conflict c ->
        add_boolean_conflict st c;
        call_solve()
      | exception Sat ->
        assert (st.elt_head = Vec.size st.trail);
        begin match Th.if_sat (theory st) (full_slice st) with
          | Theory_intf.Sat ->
            (* if no propagation is to be done, exit;
               otherwise continue loop *)
            if propagation_fixpoint st then (
              pp_trail st;
              raise Sat
            ) else (
              add_clauses ()
            )
          | Theory_intf.Unsat (l, p) ->
            let atoms = List.rev_map (Atom.make st) l in
            let c = Clause.make_l atoms (Lemma p) in
            Log.debugf 3
              (fun k -> k "(@[@{<Yellow>sat.theory_conflict_clause@}@ %a@])" Clause.debug c);
            (* must backtrack *)
            add_boolean_conflict st c
        end
    in
    try
      cancel_until st 0;
      (* push decision level before calling [local] *)
      new_decision_level st;
      local st assumptions;
      add_clauses()
    with Sat -> ()

  let assume ~permanent st ?tag cnf =
    List.iter
      (fun atoms ->
         let atoms = List.rev_map (Atom.make st) atoms in
         let c = Clause.make_l ?tag atoms Hyp in
         add_clause_user st ~permanent c)
      cnf

  (* Unsafe access to internal data *)

  let trail st = st.trail

  let check_model st : unit =
    Log.debug 5 "(sat.check-model)";
    Vec.iter
      (fun c ->
         if not (Array.exists Atom.is_true c.atoms) then (
           Error.errorf "(@[sat.check-model.invalid-model@ :clause %a@])" Clause.debug c
         ))
      st.clauses
end
[@@inline]
