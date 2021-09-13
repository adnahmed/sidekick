

module type ARG = sig
  module Solver : Sidekick_core.SOLVER
  type term = Solver.T.Term.t

  val term_as_eqn : Solver.T.Term.store -> term -> (term*term) option

  val mk_eqn : Solver.T.Term.store -> term -> term -> term

  val proof_trans : Solver.Lit.t list -> Solver.P.t -> unit
end

module type S = sig
  module Solver : Sidekick_core.SOLVER
  val theory : Solver.theory
end

module Make(A: ARG)
  : S with module Solver = A.Solver
= struct
  module Solver = A.Solver
  module SI = Solver.Solver_internal
  module CC = SI.CC
  module SAT = Solver.Sat_solver
  module Lit = Solver.Lit
  module Term = Solver.T.Term

  let[@inline] is_eqn_ tstore (t:Term.t) : bool =
    match A.term_as_eqn tstore t with
    | Some _ -> true
    | None -> false

  module Instantiation = struct
    (** A deduction [l1 \/ l2 \/ concl],
        where [l1] is [t =/ u], [l2] is [u /= v], and [concl] is [t = v] *)
    type t = {l1: Lit.t; l2: Lit.t; concl: Lit.t}

    let equal a b =
      Lit.equal a.l1 b.l1 &&
      Lit.equal a.l2 b.l2 &&
      Lit.equal a.concl b.concl

    let hash a = CCHash.(combine3 (Lit.hash a.l1) (Lit.hash a.l2) (Lit.hash a.concl))

    let make (tst:Term.store) l1 l2 concl : t =
      assert (not (Lit.sign l1) && is_eqn_ tst (Lit.term l1));
      assert (not (Lit.sign l2) && is_eqn_ tst (Lit.term l2));
      assert (Lit.sign concl && is_eqn_ tst (Lit.term concl));
      let l1, l2 =
        if Term.compare (Lit.term l1) (Lit.term l2) < 0
        then l1, l2 else l2, l1 in
      {l1; l2; concl}
  end

  module Inst_tbl = CCHashtbl.Make(Instantiation)

  type t = {
    tstore: Term.store;
    cc: CC.t;
    sat: SAT.t;
    cpool: SAT.clause_pool_id;
    done_inst: unit Inst_tbl.t;
    stat_cc_confl: int Stat.counter;
    stat_inst: int Stat.counter;
  }

  (* TODO: some rate limiting system (a counter that goes up when cc conflict,
     goes down by 5 when a new axiom is instantiated, cannot go below 0?) *)

  (* TODO: maybe the clause pool should automatically discard already present
     clauses, so that theories don't have to remember what they did *)

  let inst_from_conflict (self:t) (cc:CC.t) lits : unit =
    Log.debugf 50 (fun k->k "(@[dyn-trans.confl@ %a@])"
                     (Util.pp_list Lit.pp) lits);
    Stat.incr self.stat_cc_confl;

    (* list of tuples [(t, u, v, (t=u), (u=v), (t=v))] where [t=u]
       and [u=v] are in [lits] *)
    let candidates = Vec.create () in
    begin
      (* table [term -> {lit \in lits | lit = (term=term')}] *)
      let tbl = Term.Tbl.create 8 in

      let on_eqn t u lit =
        assert (not (Lit.sign lit));
        begin match Term.Tbl.get tbl t with
          | Some (u',lit') ->
            if not (Term.equal u u') then (
              (* see if [t=u, t=u' => u=u'] has not been instantiated yet *)
              let concl = Lit.atom self.tstore (A.mk_eqn self.tstore u u') in
              let inst = Instantiation.make self.tstore lit lit' concl in
              if not (Inst_tbl.mem self.done_inst inst) then (
                Vec.push candidates (t,u,u',lit,lit',concl)
              )
            )
          | None -> Term.Tbl.add tbl t (u,lit);
        end
      in

      Iter.of_list lits
      |> Iter.filter (fun lit -> not (Lit.sign lit))
      |> Iter.filter_map
        (fun lit ->
           match A.term_as_eqn self.tstore (Lit.term lit) with
           | Some (t,u) when not (Term.equal t u) -> Some (t,u,lit)
           | _ -> None)
      |> Iter.iter
        (fun (t,u,lit) ->
           on_eqn t u lit;
           on_eqn u t lit;
        )
    end;

    if not (Vec.is_empty candidates) then (
      let pp_cand out (t,u,v,l1,l2,concl) =
        Fmt.fprintf out "(@[%a,@ %a,@ %a,@ %a,@ %a,@ ==> %a@])"
          Term.pp t Term.pp u Term.pp v Lit.pp l1 Lit.pp l2 Lit.pp concl in
      Log.debugf 20 (fun k->k "@[candidates: %a@]" (Vec.pp pp_cand) candidates);
    );

    begin
      Vec.to_iter candidates
      |> Iter.take 2 (* at most 2 for now *)
      |> Iter.iter
        (fun (_,_,_,l1,l2,concl) ->
           let c = [l1; l2; concl] in
           (* remember we did that instantiation *)
           Inst_tbl.replace self.done_inst (Instantiation.make self.tstore l1 l2 concl) ();
           Stat.incr self.stat_inst;
           Log.debugf 10 (fun k->k "add dyn-trans %a" (Fmt.Dump.list Lit.pp) c);
           let emit_proof = A.proof_trans c in
           CC.add_clause ~pool:self.cpool cc c emit_proof)
    end;

    (* TODO: find some potential dyn-trans axioms; add them to self.sat
       if they're not in done_inst *)
    ()

  let on_conflict (self:t) (cc:CC.t) ~th lits : unit =
    if not th then (
      inst_from_conflict self cc lits
    )

  let create_and_setup si sat : unit =
    Log.debugf 1 (fun k->k "(dyn-trans.setup)");
    let self = {
      tstore=SI.tst si;
      cc=SI.cc si;
      sat;
      done_inst=Inst_tbl.create 32;
      cpool=SAT.new_clause_pool_gc_fixed_size
          ~descr:"dyn-trans clauses" ~size:200 sat;
      stat_cc_confl=Stat.mk_int (SI.stats si) "dyn-trans-confl";
      stat_inst=Stat.mk_int (SI.stats si) "dyn-trans-inst";
    } in
    CC.on_conflict self.cc (on_conflict self);
    ()

  let theory =
    Solver.mk_theory
      ~name:"dyn-trans"
      ~create_and_setup ()
end
