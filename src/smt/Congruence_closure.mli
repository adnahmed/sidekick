(** {2 Congruence Closure} *)

open Solver_types

type t
(** Global state of the congruence closure *)

type node = Equiv_class.t
(** Node in the congruence closure *)

type repr = Equiv_class.t
(** Node that is currently a representative *)

type conflict = Theory.conflict

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

val create :
  ?size:int ->
  actions:actions ->
  Term.state ->
  t
(** Create a new congruence closure.
    @param acts the actions available to the congruence closure
*)

val find : t -> node -> repr
(** Current representative *)

val add : t -> term -> node
(** Add the term to the congruence closure, if not present already.
    Will be backtracked. *)

val add_seq : t -> term Sequence.t -> unit
(** Add a sequence of terms to the congruence closure *)

val all_classes : t -> repr Sequence.t
(** All current classes *)

val assert_lit : t -> Lit.t -> unit
(** Given a literal, assume it in the congruence closure and propagate
    its consequences. Will be backtracked. *)

val assert_eq : t -> term -> term -> Lit.t list -> unit

val assert_distinct : t -> term list -> neq:term -> Lit.t -> unit
(** [assert_distinct l ~expl:u e] asserts all elements of [l] are distinct
    with explanation [e]
    precond: [u = distinct l] *)

val final_check : t -> unit

val post_backtrack : t -> unit

val mk_model : t -> Model.t -> Model.t
(** Enrich a model by mapping terms to their representative's value,
    if any. Otherwise map the representative to a fresh value *)

(**/**)
val check_invariants : t -> unit
val pp_full : t Fmt.printer
(**/**)
