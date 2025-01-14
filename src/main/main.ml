(*
MSAT is free software, using the Apache license, see file LICENSE
Copyright 2014 Guillaume Bury
Copyright 2014 Simon Cruanes
*)

module E = CCResult
module Fmt = CCFormat
module Term = Sidekick_base.Term
module Solver = Sidekick_smtlib.Solver
module Process = Sidekick_smtlib.Process

open E.Infix

type 'a or_error = ('a, string) E.t

exception Out_of_time
exception Out_of_space

let file = ref ""
let p_cnf = ref false
let p_proof = ref false
let p_model = ref false
let check = ref false
let time_limit = ref 300.
let size_limit = ref 1000_000_000.
let restarts = ref true
let gc = ref true
let p_stat = ref false
let p_gc_stat = ref false
let p_progress = ref false
let proof_file = ref ""
let proof_store_memory = ref false
let proof_store_file = ref ""

(* Arguments parsing *)
let int_arg r arg =
  let l = String.length arg in
  let multiplier m =
    let arg1 = String.sub arg 0 (l-1) in
    r := m *. (float_of_string arg1)
  in
  if l = 0 then raise (Arg.Bad "bad numeric argument")
  else
    try
      match arg.[l-1] with
        | 'k' -> multiplier 1e3
        | 'M' -> multiplier 1e6
        | 'G' -> multiplier 1e9
        | 'T' -> multiplier 1e12
        | 's' -> multiplier 1.
        | 'm' -> multiplier 60.
        | 'h' -> multiplier 3600.
        | 'd' -> multiplier 86400.
        | '0'..'9' -> r := float_of_string arg
        | _ -> raise (Arg.Bad "bad numeric argument")
    with Failure _ -> raise (Arg.Bad "bad numeric argument")

let input_file = fun s -> file := s

let usage = "Usage : main [options] <file>"
let argspec = Arg.align [
    "--bt", Arg.Unit (fun () -> Printexc.record_backtrace true), " enable stack traces";
    "--cnf", Arg.Set p_cnf, " prints the cnf used.";
    "--check", Arg.Set check, " build, check and print the proof (if output is set), if unsat";
    "--no-check", Arg.Clear check, " inverse of -check";
    "--gc", Arg.Set gc, " enable garbage collection";
    "--no-gc", Arg.Clear gc, " disable garbage collection";
    "--restarts", Arg.Set restarts, " enable restarts";
    "--no-restarts", Arg.Clear restarts, " disable restarts";
    "--stat", Arg.Set p_stat, " print statistics";
    "--proof", Arg.Set p_proof, " print proof";
    "--no-proof", Arg.Clear p_proof, " do not print proof";
    "--proof-in-memory", Arg.Set proof_store_memory, " store temporary proof in memory";
    "--proof-trace-file", Arg.Set_string proof_store_file, " store temporary proof in given file (no cleanup)";
    "-o", Arg.Set_string proof_file, " file into which to output a proof";
    "--model", Arg.Set p_model, " print model";
    "--no-model", Arg.Clear p_model, " do not print model";
    "--gc-stat", Arg.Set p_gc_stat, " outputs statistics about the GC";
    "-p", Arg.Set p_progress, " print progress bar";
    "--no-p", Arg.Clear p_progress, " no progress bar";
    "--size", Arg.String (int_arg size_limit), " <s>[kMGT] sets the size limit for the sat solver";
    "--time", Arg.String (int_arg time_limit), " <t>[smhd] sets the time limit for the sat solver";
    "-t", Arg.String (int_arg time_limit), " short for --time";
    "--version", Arg.Unit (fun () -> Printf.printf "version: %s\n%!" Sidekick_version.version; exit 0), " show version and exit";
    "-d", Arg.Int Log.set_debug, "<lvl> sets the debug verbose level";
    "--debug", Arg.Int Log.set_debug, "<lvl> sets the debug verbose level";
  ] |> List.sort compare

(* Limits alarm *)
let check_limits () =
  let t = Sys.time () in
  let heap_size = (Gc.quick_stat ()).Gc.heap_words in
  let s = float heap_size *. float Sys.word_size /. 8. in
  if t > !time_limit then
    raise Out_of_time
  else if s > !size_limit then
    raise Out_of_space

let main_smt () : _ result =
  let module Proof = Sidekick_smtlib.Proof in
  let tst = Term.create ~size:4_096 () in

  let enable_proof_ = !check || !p_proof || !proof_file <> "" in
  Log.debugf 1 (fun k->k"(@[proof-enable@ %B@])" enable_proof_);

  (* call [k] with the name of a temporary proof file, and cleanup if necessary *)
  let run_with_tmp_file k =
    (* TODO: use memory writer if [!proof_store_memory] *)
    if enable_proof_ then (
      if !proof_store_file <> "" then (
        let file = !proof_store_file in
        k file
      ) else (
        CCIO.File.with_temp
          ~temp_dir:"." ~prefix:".sidekick-proof" ~suffix:".dat" k
      )
    ) else (
      k "/dev/null"
    )
  in

  run_with_tmp_file @@ fun temp_proof_file ->
  Log.debugf 1 (fun k->k"(@[temp-proof-file@ %S@])" temp_proof_file);

  let config =
    if enable_proof_ then (
      Proof.Config.default
      |> Proof.Config.enable true
      |> Proof.Config.store_on_disk_at temp_proof_file
    ) else (
      Proof.Config.empty
    )
  in

  (* main proof object *)
  let proof = Proof.create ~config () in

  let solver =
    let theories =
      (* TODO: probes, to load only required theories *)
      [
        Process.th_bool;
        Process.th_data;
        Process.th_lra;
      ]
    in
    Process.Solver.create ~proof ~theories tst () ()
  in

  (* FIXME: emit an actual proof *)
  let proof_file = if !proof_file ="" then None else Some !proof_file in
  if !check then (
    (* might have to check conflicts *)
    Solver.add_theory solver Process.Check_cc.theory;
  );
  begin
    Sidekick_smtlib.parse tst !file
  end
  >>= fun input ->
  (* process statements *)
  let res =
    try
      E.fold_l
        (fun () ->
           Process.process_stmt
             ~gc:!gc ~restarts:!restarts ~pp_cnf:!p_cnf
             ~time:!time_limit ~memory:!size_limit
             ~pp_model:!p_model ?proof_file
             ~check:!check ~progress:!p_progress
             solver)
        () input
    with Exit ->
      E.return()
  in
  if !p_stat then (
    Format.printf "%a@." Solver.pp_stats solver;
  );
  res

let main_cnf () : _ result =
  let module Proof = Pure_sat_solver.Proof in
  let module S = Pure_sat_solver in

  let proof, in_memory_proof =
    if !check then (
      let pr, inmp = Proof.create_in_memory () in
      pr, Some inmp
    ) else if !proof_file <> "" then (
      Proof.create_to_file !proof_file, None
    ) else (
      Proof.dummy, None
    )
  in

  let stat = Stat.create () in
  let solver = S.SAT.create ~size:`Big ~proof ~stat () in

  S.Dimacs.parse_file solver !file >>= fun () ->
  let r = S.solve ~check:!check ?in_memory_proof solver in

  (* FIXME: if in memory proof and !proof_file<>"",
     then dump proof into file now *)

  Proof.close proof;
  if !p_stat then (
    Fmt.printf "%a@." Stat.pp_all (Stat.all stat);
  );
  r

let main () =

  (* instrumentation and tracing *)
  Sidekick_tef.setup();
  at_exit Sidekick_tef.teardown;
  Sidekick_memtrace.trace_if_requested ~context:"sidekick" ();

  CCFormat.set_color_default true;
  (* Administrative duties *)
  Arg.parse argspec input_file usage;
  if !file = "" then (
    Arg.usage argspec usage;
    exit 2
  );
  let al = Gc.create_alarm check_limits in
  Util.setup_gc();
  let is_cnf = Filename.check_suffix !file ".cnf" in
  let res =
    if is_cnf then (
      main_cnf ()
    ) else (
      main_smt ()
    )
  in
  if !p_gc_stat then (
    Printf.printf "(gc_stats\n%t)\n" Gc.print_stat;
  );
  Gc.delete_alarm al;
  res

let () = match main() with
  | E.Ok () -> ()
  | E.Error msg ->
    Format.printf "@{<Red>Error@}: %s@." msg;
    exit 1
  | exception e ->
    let b = Printexc.get_backtrace () in
    let exit_ n =
      if Printexc.backtrace_status () then (
        Format.fprintf Format.std_formatter "%s@." b
      );
      CCShims_.Stdlib.exit n
    in
    begin match e with
      | Error.Error msg ->
        Format.printf "@{<Red>Error@}: %s@." msg;
        ignore @@ exit_ 1
      | Out_of_time ->
        Format.printf "Timeout@.";
        exit_ 2
      | Out_of_space ->
        Format.printf "Spaceout@.";
        exit_ 3
      | Invalid_argument e ->
        Format.printf "invalid argument:\n%s@." e;
        exit_ 127
      | _ -> raise e
    end

