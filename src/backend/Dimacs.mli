(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

(** Dimacs backend for problems

    This module provides functiosn to export problems to the dimacs and
    iCNF formats.
*)

module type S = sig
  type st

  type clause
  (** The type of clauses *)

  val export :
    st ->
    Format.formatter ->
    clauses:clause Vec.t ->
    unit
  (** Export the given clause vectors to the dimacs format.
      The arguments should be transmitted directly from the corresponding
      function of the {Internal} module. *)

end

module Make(St: Sidekick_sat.S) : S with type clause := St.clause and type st = St.t
(** Functor to create a module for exporting probems to the dimacs (& iCNF) formats. *)

