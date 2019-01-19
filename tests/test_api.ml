(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

(* Tests that require the API *)

module F = Msat_sat.Int_lit
module S = Msat_sat

let (|>) x f = f x

let time_limit = ref 300.
let size_limit = ref 1000_000_000.

let error_msg opt arg l =
  Format.fprintf Format.str_formatter "'%s' is not a valid argument for '%s', valid arguments are : %a"
    arg opt (fun fmt -> List.iter (fun (s, _) -> Format.fprintf fmt "%s, " s)) l;
  Format.flush_str_formatter ()

let set_flag opt arg flag l =
  try
    flag := List.assoc arg l
  with Not_found ->
    invalid_arg (error_msg opt arg l)

let usage = "Usage : test_api [options]"
let argspec = Arg.align [
    "-v", Arg.Int (fun i -> Log.set_debug i),
    "<lvl> Sets the debug verbose level";
  ]

type solver_res =
  | R_sat
  | R_unsat

exception Incorrect_model

let mk_solver () : S.t = S.create ~size:`Big ()

exception Error of string

let error msg = raise (Error msg)
let errorf msg = Format.ksprintf error msg

module Test = struct
  type action =
    | A_assume of F.t list list
    | A_solve of F.t list * [`Expect_sat | `Expect_unsat]

  type t = {
    name: string;
    actions: action list;
  }

  let mk_test name l = {name; actions=l}
  let assume l = A_assume (List.map (List.map F.make) l)
  let assume1 c = assume [c]
  let solve ?(assumptions=[]) e =
    let assumptions = List.map F.make assumptions in
    A_solve (assumptions, e)

  type result =
    | Pass
    | Fail of string

  let run (t:t): result =
  (* Interesting stuff happening *)
    let st = mk_solver() in
    try
      List.iter
        (function
          | A_assume cs ->
            S.assume st cs
          | A_solve (assumptions, expect) ->
            let assumptions = List.map (S.make_atom st) assumptions in
            match S.solve st ~assumptions (), expect with
              | S.Sat _, `Expect_sat -> ()
              | S.Unsat us, `Expect_unsat ->
                let p = us.Msat.get_proof () in
                S.Proof.check p;
              | S.Unsat _, `Expect_sat ->
                error "expect sat, got unsat"
              | S.Sat _, `Expect_unsat ->
                error "expect unsat, got sat"
        )
        t.actions;
      Pass
    with Error msg ->
      Fail msg

  (* basic test *)
  let test1 =
    [ assume [[-1;2]; [-1;3]];
      solve `Expect_sat;
      assume [[-2;4]; [-3;-4]];
      solve `Expect_sat;
      assume [[1]];
      solve `Expect_unsat;
    ] |> mk_test "test1"

  (* same as test1 but with assumptions *)
  let test2 =
    [ solve `Expect_sat;
      assume [[-1;2]; [-1;3]];
      solve `Expect_sat;
      assume [[-2;4]; [-3;-4]];
      solve `Expect_sat;
      solve ~assumptions:[1] `Expect_unsat;
      solve `Expect_sat;
    ] |> mk_test "test2"

  (* repeat assumptions *)
  let test3 =
    [ assume [[-1;2]; [-1;3]];
      solve `Expect_sat;
      assume [[-2;4]; [-3;-4]];
      solve `Expect_sat;
      solve ~assumptions:[1] `Expect_unsat;
      solve `Expect_sat;
      solve ~assumptions:[1] `Expect_unsat;
      solve `Expect_sat;
      solve ~assumptions:[1] `Expect_unsat;
      solve `Expect_sat;
      solve ~assumptions:[2] `Expect_sat;
      assume [[1]];
      solve `Expect_unsat;
    ] |> mk_test "test3"

  (* Conflict at level 0 *)
  let test4 =
    [ assume [[-1; -2]];
      solve `Expect_sat;
      assume [[1]];
      solve `Expect_sat;
      assume [[2]];
      solve ~assumptions:[3] `Expect_unsat;
      solve ~assumptions:[] `Expect_unsat;
      solve ~assumptions:[] `Expect_unsat;
    ] |> mk_test "conflict0"

  (* just check that we do create new solvers *)
  let test_clean =
    [ solve `Expect_sat
    ] |> mk_test "test_clean"

  let suite =
    [ test1;
      test2;
      test3;
      test4;
      test_clean; (* after test3 *)
    ]
end

let main () =
  (* Administrative duties *)
  Arg.parse argspec (fun _ -> ()) usage;
  let failed = ref false in
  List.iter
    (fun test ->
       Printf.printf "%-10s... %!" test.Test.name;
       match Test.run test with
       | Test.Pass -> Printf.printf "ok\n%!"
       | Test.Fail msg ->
         failed := true;
         Printf.printf "fail (%s)\n%!" msg)
    Test.suite;
  if !failed then exit 1

let () = main()
