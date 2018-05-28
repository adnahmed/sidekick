
module Vec = Sidekick_sat.Vec
module Log = Sidekick_sat.Log
open Solver_types

type node = Equiv_class.t
type repr = Equiv_class.t
type conflict = Theory.conflict

(** A signature is a shallow term shape where immediate subterms
    are representative *)
module Signature = struct
  type t = node Term.view
  include Term_cell.Make_eq(Equiv_class)
end

module Sig_tbl = CCHashtbl.Make(Signature)

type merge_op = node * node * explanation
(* a merge operation to perform *)

module type ACTIONS = sig
  val on_backtrack: (unit -> unit) -> unit
  (** Register a callback to be invoked upon backtracking below the current level *)

  val on_merge: repr -> repr -> explanation -> unit
  (** Call this when two classes are merged *)

  val raise_conflict: conflict -> 'a
  (** Report a conflict *)

  val propagate: Lit.t -> Lit.t list -> unit
  (** Propagate a literal *)
end

type actions = (module ACTIONS)

type t = {
  tst: Term.state;
  acts: actions;
  tbl: node Term.Tbl.t;
  (* internalization [term -> node] *)
  signatures_tbl : node Sig_tbl.t;
  (* map a signature to the corresponding node in some equivalence class.
     A signature is a [term_cell] in which every immediate subterm
     that participates in the congruence/evaluation relation
     is normalized (i.e. is its own representative).
     The critical property is that all members of an equivalence class
     that have the same "shape" (including head symbol)
     have the same signature *)
  pending: node Vec.t;
  (* nodes to check, maybe their new signature is in {!signatures_tbl} *)
  combine: merge_op Vec.t;
  (* pairs of terms to merge *)
  mutable ps_lits: Lit.Set.t;
  (* proof state *)
  ps_queue: (node*node) Vec.t;
  (* pairs to explain *)
  true_ : node lazy_t;
  false_ : node lazy_t;
}
(* TODO: an additional union-find to keep track, for each term,
   of the terms they are known to be equal to, according
   to the current explanation. That allows not to prove some equality
   several times.
   See "fast congruence closure and extensions", Nieuwenhis&al, page 14 *)

let[@inline] on_backtrack cc f : unit =
  let (module A) = cc.acts in
  A.on_backtrack f

let[@inline] is_root_ (n:node) : bool = n.n_root == n

let[@inline] size_ (r:repr) =
  assert (is_root_ (r:>node));
  Bag.size (r :> node).n_parents

(* check if [t] is in the congruence closure.
   Invariant: [in_cc t => in_cc u, forall u subterm t] *)
let[@inline] mem (cc:t) (t:term): bool =
  Term.Tbl.mem cc.tbl t

(* TODO: remove path compression, point to new root explicitely during `union` *)

(* find representative, recursively, and perform path compression *)
let rec find_rec cc (n:node) : repr =
  if n==n.n_root then (
    n
  ) else (
    let old_root = n.n_root in
    let root = find_rec cc old_root in
    (* path compression *)
    if (root :> node) != old_root then (
      on_backtrack cc (fun () -> n.n_root <- old_root);
      n.n_root <- (root :> node);
    );
    root
  )

let[@inline] true_ cc = Lazy.force cc.true_
let[@inline] false_ cc = Lazy.force cc.false_

(* get term that should be there *)
let[@inline] get_ cc (t:term) : node =
  try Term.Tbl.find cc.tbl t
  with Not_found ->
    Log.debugf 5 (fun k->k "(@[<hv1>missing@ %a@])" Term.pp t);
    assert false

(* non-recursive, inlinable function for [find] *)
let[@inline] find st (n:node) : repr =
  if n == n.n_root then n else find_rec st n

let[@inline] find_tn cc (t:term) : repr = get_ cc t |> find cc
let[@inline] find_tt cc (t:term) : term = find_tn cc t |> Equiv_class.term

let[@inline] same_class cc (n1:node)(n2:node): bool =
  Equiv_class.equal (find cc n1) (find cc n2)

let[@inline] same_class_t cc (t1:term)(t2:term): bool =
  Equiv_class.equal (find_tn cc t1) (find_tn cc t2)

(* compute signature *)
let signature cc (t:term): node Term.view option =
  let find = find_tn cc in
  begin match Term.view t with
    | App_cst (_, a) when IArray.is_empty a -> None
    | App_cst ({cst_view=Cst_def {do_cc=false;_}; _}, _) -> None (* no CC *)
    | App_cst (f, a) -> App_cst (f, IArray.map find a) |> CCOpt.return (* FIXME: relevance *)
    | Bool _ | If _
      -> None (* no congruence for these *)
   end

(* find whether the given (parent) term corresponds to some signature
   in [signatures_] *)
let find_by_signature cc (t:term) : repr option = match signature cc t with
  | None -> None
  | Some s -> Sig_tbl.get cc.signatures_tbl s

let add_signature cc (t:term) (r:node): unit = match signature cc t with
  | None -> ()
  | Some s ->
    (* add, but only if not present already *)
    begin match Sig_tbl.find cc.signatures_tbl s with
      | exception Not_found ->
        on_backtrack cc (fun () -> Sig_tbl.remove cc.signatures_tbl s);
        Sig_tbl.add cc.signatures_tbl s r;
      | r' ->
        assert (same_class cc r r');
    end

let is_done (cc:t): bool =
  Vec.is_empty cc.pending &&
  Vec.is_empty cc.combine

let push_pending cc t : unit =
  Log.debugf 5 (fun k->k "(@[<hv1>cc.push_pending@ %a@])" Equiv_class.pp t);
  Vec.push cc.pending t

let push_combine cc t u e : unit =
  Log.debugf 5
    (fun k->k "(@[<hv1>cc.push_combine@ :t1 %a@ :t2 %a@ :expl %a@])"
      Equiv_class.pp t Equiv_class.pp u Explanation.pp e);
  Vec.push cc.combine (t,u,e)

let[@inline] union cc (a:node) (b:node) (e:Lit.t list): unit =
  if not (same_class cc a b) then (
    let e = Explanation.E_lits e in
    push_combine cc a b e; (* start by merging [a=b] *)
  )

(* re-root the explanation tree of the equivalence class of [n]
   so that it points to [n].
   postcondition: [n.n_expl = None] *)
let rec reroot_expl (cc:t) (n:node): unit =
  let old_expl = n.n_expl in
  on_backtrack cc (fun () -> n.n_expl <- old_expl);
  begin match old_expl with
    | E_none -> () (* already root *)
    | E_some {next=u; expl=e_n_u} ->
      reroot_expl cc u;
      u.n_expl <- E_some {next=n; expl=e_n_u};
      n.n_expl <- E_none;
  end

let[@inline] raise_conflict (cc:t) (e:conflict): _ =
  let (module A) = cc.acts in
  A.raise_conflict e

let[@inline] all_classes cc : repr Sequence.t =
  Term.Tbl.values cc.tbl
  |> Sequence.filter is_root_

(* distance from [t] to its root in the proof forest *)
let[@inline][@unroll 2] rec distance_to_root (n:node): int = match n.n_expl with
  | E_none -> 0
  | E_some {next=t'; _} -> 1 + distance_to_root t'

(* find the closest common ancestor of [a] and [b] in the proof forest *)
let find_common_ancestor (a:node) (b:node) : node =
  let d_a = distance_to_root a in
  let d_b = distance_to_root b in
  (* drop [n] nodes in the path from [t] to its root *)
  let rec drop_ n t =
    if n=0 then t
    else match t.n_expl with
      | E_none -> assert false
      | E_some {next=t'; _} -> drop_ (n-1) t'
  in
  (* reduce to the problem where [a] and [b] have the same distance to root *)
  let a, b =
    if d_a > d_b then drop_ (d_a-d_b) a, b
    else if d_a < d_b then a, drop_ (d_b-d_a) b
    else a, b
  in
  (* traverse stepwise until a==b *)
  let rec aux_same_dist a b =
    if a==b then a
    else match a.n_expl, b.n_expl with
      | E_none, _ | _, E_none -> assert false
      | E_some {next=a'; _}, E_some {next=b'; _} -> aux_same_dist a' b'
  in
  aux_same_dist a b

let[@inline] ps_add_obligation (cc:t) a b = Vec.push cc.ps_queue (a,b)
let[@inline] ps_add_lit ps l = ps.ps_lits <- Lit.Set.add l ps.ps_lits

and ps_add_obligation_t cc (t1:term) (t2:term) =
  let n1 = get_ cc t1 in
  let n2 = get_ cc t2 in
  ps_add_obligation cc n1 n2

let ps_clear (cc:t) =
  cc.ps_lits <- Lit.Set.empty;
  Vec.clear cc.ps_queue;
  ()

let rec decompose_explain cc (e:explanation): unit =
  Log.debugf 5 (fun k->k "(@[cc.decompose_expl@ %a@])" Explanation.pp e);
  begin match e with
    | E_reduction -> ()
    | E_lit lit -> ps_add_lit cc lit
    | E_lits l -> List.iter (ps_add_lit cc) l
    | E_merges l ->
      (* need to explain each merge in [l] *)
      IArray.iter (fun (t,u) -> ps_add_obligation cc t u) l
  end

(* explain why [a = parent_a], where [a -> ... -> parent_a] in the
   proof forest *)
let rec explain_along_path ps (a:node) (parent_a:node) : unit =
  if a!=parent_a then (
    match a.n_expl with
      | E_none -> assert false
      | E_some {next=next_a; expl=e_a_b} ->
        decompose_explain ps e_a_b;
        (* now prove [next_a = parent_a] *)
        explain_along_path ps next_a parent_a
  )

(* find explanation *)
let explain_loop (cc : t) : Lit.Set.t =
  while not (Vec.is_empty cc.ps_queue) do
    let a, b = Vec.pop_last cc.ps_queue in
    Log.debugf 5
      (fun k->k "(@[cc.explain_loop at@ %a@ %a@])" Equiv_class.pp a Equiv_class.pp b);
    assert (Equiv_class.equal (find cc a) (find cc b));
    let c = find_common_ancestor a b in
    explain_along_path cc a c;
    explain_along_path cc b c;
  done;
  cc.ps_lits

let explain_eq_n ?(init=Lit.Set.empty) cc (n1:node) (n2:node) : Lit.Set.t =
  ps_clear cc;
  cc.ps_lits <- init;
  ps_add_obligation cc n1 n2;
  explain_loop cc

let explain_eq_t ?(init=Lit.Set.empty) cc (t1:term) (t2:term) : Lit.Set.t =
  ps_clear cc;
  cc.ps_lits <- init;
  ps_add_obligation_t cc t1 t2;
  explain_loop cc

let explain_unfold ?(init=Lit.Set.empty) cc (e:explanation) : Lit.Set.t =
  ps_clear cc;
  cc.ps_lits <- init;
  decompose_explain cc e;
  explain_loop cc

let explain_unfold_seq ?(init=Lit.Set.empty) cc (seq:explanation Sequence.t): Lit.Set.t =
  ps_clear cc;
  cc.ps_lits <- init;
  Sequence.iter (decompose_explain cc) seq;
  explain_loop cc

let explain_unfold_bag ?(init=Lit.Set.empty) cc (b:explanation Bag.t) : Lit.Set.t =
  match b with
  | Bag.E -> init
  | Bag.L (E_lit lit) -> Lit.Set.add lit init
  | _ ->
    ps_clear cc;
    cc.ps_lits <- init;
    Sequence.iter (decompose_explain cc) (Bag.to_seq b);
    explain_loop cc

(* add [tag] to [n]
   precond: [n] is a representative *)
let add_tag_n cc (n:node) (tag:int) (expl:explanation) : unit =
  assert (is_root_ n);
  if not (Util.Int_map.mem tag n.n_tags) then (
    on_backtrack cc
      (fun () -> n.n_tags <- Util.Int_map.remove tag n.n_tags);
    n.n_tags <- Util.Int_map.add tag (n,expl) n.n_tags;
  )

(* main CC algo: add terms from [pending] to the signature table,
   check for collisions *)
let rec update_pending (cc:t): unit =
  (* step 2 deal with pending (parent) terms whose equiv class
     might have changed *)
  while not (Vec.is_empty cc.pending) do
    let n = Vec.pop_last cc.pending in
    (* check if some parent collided *)
    begin match find_by_signature cc n.n_term with
      | None ->
        (* add to the signature table [sig(n) --> n] *)
        add_signature cc n.n_term n
      | Some u ->
        (* must combine [t] with [r] *)
        if not @@ same_class cc n u then (
          (* [t1] and [t2] must be applications of the same symbol to
             arguments that are pairwise equal *)
          assert (n != u);
          let expl = match n.n_term.term_view, u.n_term.term_view with
            | App_cst (f1, a1), App_cst (f2, a2) ->
              assert (Cst.equal f1 f2);
              assert (IArray.length a1 = IArray.length a2);
              Explanation.mk_merges @@
              IArray.map2 (fun u1 u2 -> add_ cc u1, add_ cc u2) a1 a2
            | If _, _ | App_cst _, _ | Bool _, _
              -> assert false
          in
          push_combine cc n u expl
        )
    end;
    (* FIXME: when to actually evaluate?
    eval_pending cc;
    *)
  done;
  if not (is_done cc) then (
    update_combine cc (* repeat *)
  )

(* main CC algo: merge equivalence classes in [st.combine].
   @raise Exn_unsat if merge fails *)
and update_combine cc =
  while not (Vec.is_empty cc.combine) do
    let a, b, e_ab = Vec.pop_last cc.combine in
    let ra = find cc a in
    let rb = find cc b in
    if not (Equiv_class.equal ra rb) then (
      assert (is_root_ ra);
      assert (is_root_ rb);
      (* We will merge [r_from] into [r_into].
         we try to ensure that [size ra <= size rb] in general *)
      let r_from, r_into = if size_ ra > size_ rb then rb, ra else ra, rb in
      let new_tags =
        Util.Int_map.union
          (fun _i (n1,e1) (n2,e2) ->
             (* both maps contain same tag [_i]. conflict clause:
                 [e1 & e2 & e_ab] impossible *)
             Log.debugf 5
               (fun k->k "(@[<hv>cc.merge.distinct_conflict@ :tag %d@ \
                          @[:r1 %a@ :e1 %a@]@ @[:r2 %a@ :e2 %a@]@ :e_ab %a@])"
                   _i Equiv_class.pp n1 Explanation.pp e1
                   Equiv_class.pp n2 Explanation.pp e2 Explanation.pp e_ab);
             let lits = explain_unfold cc e1 in
             let lits = explain_unfold ~init:lits cc e2 in
             let lits = explain_unfold ~init:lits cc e_ab in
             let lits = explain_eq_n ~init:lits cc a n1 in
             let lits = explain_eq_n ~init:lits cc b n2 in
             raise_conflict cc @@ Lit.Set.elements lits)
          ra.n_tags rb.n_tags
      in
      (* remove [ra.parents] from signature, put them into [st.pending] *)
      begin
        Bag.to_seq (r_from:>node).n_parents
        |> Sequence.iter
          (fun parent -> push_pending cc parent)
      end;
      (* perform [union ra rb] *)
      begin
        let r_from = (r_from :> node) in
        let r_into = (r_into :> node) in
        let r_into_old_parents = r_into.n_parents in
        let r_into_old_tags = r_into.n_tags in
        on_backtrack cc
          (fun () ->
             Log.debugf 5
               (fun k->k "(@[cc.undo_merge@ :of %a :into %a@])"
                   Term.pp r_from.n_term Term.pp r_into.n_term);
             r_from.n_root <- r_from;
             r_into.n_tags <- r_into_old_tags;
             r_into.n_parents <- r_into_old_parents);
        r_from.n_root <- r_into;
        r_into.n_tags <- new_tags;
        r_from.n_parents <- Bag.append r_into_old_parents r_from.n_parents;
      end;
      (* update explanations (a -> b), arbitrarily *)
      begin
        reroot_expl cc a;
        assert (a.n_expl = E_none);
        on_backtrack cc (fun () -> a.n_expl <- E_none);
        a.n_expl <- E_some {next=b; expl=e_ab};
      end;
      (* notify listeners of the merge *)
      notify_merge cc r_from ~into:r_into e_ab;
    )
  done;
  (* now update pending terms again *)
  update_pending cc

(* Checks if [ra] and [~into] have compatible normal forms and can
   be merged w.r.t. the theories.
   Side effect: also pushes sub-tasks *)
and notify_merge cc (ra:repr) ~into:(rb:repr) (e:explanation): unit =
  assert (is_root_ rb);
  let (module A) = cc.acts in
  A.on_merge ra rb e

(* add [t] to [cc] when not present already *)
and add_new_term cc (t:term) : node =
  assert (not @@ mem cc t);
  Log.debugf 20 (fun k->k "(@[cc.add_term@ %a@])" Term.pp t);
  let n = Equiv_class.make t in
  (* how to add a subterm *)
  let add_to_parents_of_sub_node (sub:node) : unit =
    let old_parents = sub.n_parents in
    on_backtrack cc
      (fun () -> sub.n_parents <- old_parents);
    sub.n_parents <- Bag.cons n sub.n_parents;
    push_pending cc sub
  in
  (* add sub-term to [cc], and register [n] to its parents *)
  let add_sub_t (u:term) : unit =
    let n_u = add_ cc u in
    add_to_parents_of_sub_node n_u
  in
  (* register sub-terms, add [t] to their parent list *)
  begin match t.term_view with
    | Bool _-> ()
    | App_cst (_, a) -> IArray.iter add_sub_t a
    | If (a,b,c) ->
      (* TODO: relevancy? only [a] needs be decided for now *)
      add_sub_t a;
      add_sub_t b;
      add_sub_t c
  end;
  (* remove term when we backtrack *)
  on_backtrack cc
    (fun () ->
       Log.debugf 20 (fun k->k "(@[cc.remove_term@ %a@])" Term.pp t);
       Term.Tbl.remove cc.tbl t);
  (* add term to the table *)
  Term.Tbl.add cc.tbl t n;
  (* [n] might be merged with other equiv classes *)
  push_pending cc n;
  n

(* add a term *)
and[@inline] add_ cc t : node =
  try Term.Tbl.find cc.tbl t
  with Not_found -> add_new_term cc t

let add cc t : node =
  let n = add_ cc t in
  update_pending cc;
  n

let add_seq cc seq =
  seq (fun t -> ignore @@ add_ cc t);
  update_pending cc

(* before we push tasks into [pending], ensure they are removed when we backtrack *)
let reset_on_backtrack cc : unit =
  if Vec.is_empty cc.pending then (
    on_backtrack cc (fun () -> Vec.clear cc.pending);
  )

(* assert that this boolean literal holds *)
let assert_lit cc lit : unit = match Lit.view lit with
  | Lit_fresh _ -> ()
  | Lit_atom t ->
    assert (Ty.is_prop t.term_ty);
    Log.debugf 5 (fun k->k "(@[cc.assert_lit@ %a@])" Lit.pp lit);
    let sign = Lit.sign lit in
    (* equate t and true/false *)
    let rhs = if sign then true_ cc else false_ cc in
    let n = add cc t in
    (* TODO: ensure that this is O(1).
       basically, just have [n] point to true/false and thus acquire
       the corresponding value, so its superterms (like [ite]) can evaluate
       properly *)
    reset_on_backtrack cc;
    push_combine cc n rhs (E_lit lit);
    ()

let assert_eq cc (t:term) (u:term) expl : unit =
  let n1 = add cc t in
  let n2 = add cc u in
  if not (same_class cc n1 n2) then (
    reset_on_backtrack cc;
    union cc n1 n2 expl
  )

let assert_distinct cc (l:term list) ~neq (lit:Lit.t) : unit =
  assert (match l with[] | [_] -> false | _ -> true);
  let tag = Term.id neq in
  Log.debugf 5
    (fun k->k "(@[cc.assert_distinct@ (@[%a@])@ :tag %d@])" (Util.pp_list Term.pp) l tag);
  let l = List.map (fun t -> t, add cc t |> find cc) l in
  let coll =
    Sequence.diagonal_l l
    |> Sequence.find_pred (fun ((_,n1),(_,n2)) -> Equiv_class.equal n1 n2)
  in
  begin match coll with
    | Some ((t1,_n1),(t2,_n2)) ->
      (* two classes are already equal *)
      Log.debugf 5 (fun k->k "(@[cc.assert_distinct.conflict@ %a = %a@])" Term.pp t1 Term.pp t2);
      let lits = Lit.Set.singleton lit in
      let lits = explain_eq_t ~init:lits cc t1 t2 in
      raise_conflict cc @@ Lit.Set.to_list lits
    | None ->
      (* put a tag on all equivalence classes, that will make their merge fail *)
      List.iter (fun (_,n) -> add_tag_n cc n tag @@ Explanation.lit lit) l
  end

(* handling "distinct" constraints *)
module Distinct_ = struct
  module Int_set = Util.Int_set

  type Equiv_class.payload +=
    | P_dist of {
        mutable tags: Int_set.t;
      }

  let add_tag (tag:int) (n:Equiv_class.t) : unit =
    if not @@
      CCList.exists
        (function
          | P_dist r -> r.tags <- Int_set.add tag r.tags; true
          | _ -> false)
        (Equiv_class.payload n)
    then (
      Equiv_class.set_payload n (P_dist {tags=Int_set.singleton tag})
    )
end

let create ?(size=2048) ~actions (tst:Term.state) : t =
  let nd = Equiv_class.dummy in
  let rec cc = {
    tst;
    acts=actions;
    tbl = Term.Tbl.create size;
    signatures_tbl = Sig_tbl.create size;
    pending=Vec.make_empty Equiv_class.dummy;
    combine= Vec.make_empty (nd,nd,E_reduction);
    ps_lits=Lit.Set.empty;
    ps_queue=Vec.make_empty (nd,nd);
    true_ = lazy (add cc (Term.true_ tst));
    false_ = lazy (add cc (Term.false_ tst));
  } in
  ignore (Lazy.force cc.true_);
  ignore (Lazy.force cc.false_);
  cc
(* check satisfiability, update congruence closure *)
let check (cc:t) : unit =
  Log.debug 5 "(cc.check)";
  update_pending cc

let final_check cc : unit =
  Log.debug 5 "(CC.final_check)";
  update_pending cc
