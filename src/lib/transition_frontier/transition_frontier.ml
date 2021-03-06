(** This module glues together the various components that compose
*  the transition frontier, wrapping high-level initialization
*  logic as well as gluing together the logic for adding items
*  to the frontier *)

open Core_kernel
open Async_kernel
open Coda_base
open Coda_transition
include Frontier_base
module Hash = Frontier_hash
module Full_frontier = Full_frontier
module Extensions = Extensions
module Persistent_root = Persistent_root
module Persistent_frontier = Persistent_frontier

let global_max_length (genesis_constants : Genesis_constants.t) =
  genesis_constants.protocol.k

type t =
  { logger: Logger.t
  ; verifier: Verifier.t
  ; consensus_local_state: Consensus.Data.Local_state.t
  ; full_frontier: Full_frontier.t
  ; persistent_root: Persistent_root.t
  ; persistent_root_instance: Persistent_root.Instance.t
  ; persistent_frontier: Persistent_frontier.t
  ; persistent_frontier_instance: Persistent_frontier.Instance.t
  ; extensions: Extensions.t
  ; genesis_state_hash: State_hash.t }

let genesis_root_data ~genesis_ledger ~base_proof ~genesis_constants =
  let open Root_data.Limited.Stable.Latest in
  let transition =
    External_transition.genesis ~genesis_ledger ~base_proof ~genesis_constants
  in
  let scan_state = Staged_ledger.Scan_state.empty () in
  let pending_coinbase = Or_error.ok_exn (Pending_coinbase.create ()) in
  {transition; scan_state; pending_coinbase}

let load_from_persistence_and_start ~logger ~verifier ~consensus_local_state
    ~max_length ~persistent_root ~persistent_root_instance ~persistent_frontier
    ~persistent_frontier_instance ~genesis_state_hash
    ignore_consensus_local_state ~genesis_constants =
  let open Deferred.Result.Let_syntax in
  let root_identifier =
    match
      Persistent_root.Instance.load_root_identifier persistent_root_instance
    with
    | Some root_identifier ->
        root_identifier
    | None ->
        failwith
          "no persistent root identifier found (should have been written \
           already)"
  in
  let%bind () =
    Deferred.return
      ( match
          Persistent_frontier.Instance.fast_forward
            persistent_frontier_instance root_identifier
        with
      | Ok () ->
          Ok ()
      | Error `Frontier_hash_does_not_match ->
          Logger.warn logger ~module_:__MODULE__ ~location:__LOC__
            ~metadata:
              [("frontier_hash", Hash.to_yojson root_identifier.frontier_hash)]
            "Persistent frontier hash did not match persistent root frontier \
             hash (resetting frontier hash)" ;
          Persistent_frontier.Instance.set_frontier_hash
            persistent_frontier_instance root_identifier.frontier_hash ;
          Ok ()
      | Error `Sync_cannot_be_running ->
          Error (`Failure "sync job is already running on persistent frontier")
      | Error `Bootstrap_required ->
          Error `Bootstrap_required
      | Error (`Failure msg) ->
          Logger.fatal logger ~module_:__MODULE__ ~location:__LOC__
            ~metadata:
              [("target_root", Root_identifier.to_yojson root_identifier)]
            "Unable to fast forward persistent frontier: %s" msg ;
          Error (`Failure msg) )
  in
  let%bind full_frontier, extensions =
    Deferred.map
      (Persistent_frontier.Instance.load_full_frontier
         persistent_frontier_instance ~max_length
         ~root_ledger:
           (Persistent_root.Instance.snarked_ledger persistent_root_instance)
         ~consensus_local_state ~ignore_consensus_local_state
         ~genesis_constants)
      ~f:
        (Result.map_error ~f:(function
          | `Sync_cannot_be_running ->
              `Failure "sync job is already running on persistent frontier"
          | `Failure _ as err ->
              err ))
  in
  let%map () =
    Deferred.return
      ( Persistent_frontier.Instance.start_sync persistent_frontier_instance
      |> Result.map_error ~f:(function
           | `Sync_cannot_be_running ->
               `Failure "sync job is already running on persistent frontier"
           | `Not_found _ as err ->
               `Failure
                 (Persistent_frontier.Database.Error.not_found_message err) )
      )
  in
  { logger
  ; verifier
  ; consensus_local_state
  ; full_frontier
  ; persistent_root
  ; persistent_root_instance
  ; persistent_frontier
  ; persistent_frontier_instance
  ; extensions
  ; genesis_state_hash }

let rec load_with_max_length :
       max_length:int
    -> ?retry_with_fresh_db:bool
    -> logger:Logger.t
    -> verifier:Verifier.t
    -> consensus_local_state:Consensus.Data.Local_state.t
    -> persistent_root:Persistent_root.t
    -> persistent_frontier:Persistent_frontier.t
    -> genesis_state_hash:State_hash.t
    -> genesis_ledger:Ledger.t Lazy.t
    -> ?base_proof:Proof.t
    -> genesis_constants:Genesis_constants.t
    -> unit
    -> ( t
       , [> `Bootstrap_required
         | `Persistent_frontier_malformed
         | `Failure of string ] )
       Deferred.Result.t =
 fun ~max_length ?(retry_with_fresh_db = true) ~logger ~verifier
     ~consensus_local_state ~persistent_root ~persistent_frontier
     ~genesis_state_hash ~genesis_ledger
     ?(base_proof = Precomputed_values.base_proof) ~genesis_constants () ->
  let open Deferred.Let_syntax in
  (* TODO: #3053 *)
  let continue persistent_frontier_instance ~ignore_consensus_local_state =
    let persistent_root_instance =
      Persistent_root.create_instance_exn persistent_root
    in
    match%bind
      load_from_persistence_and_start ~logger ~verifier ~consensus_local_state
        ~max_length ~persistent_root ~persistent_root_instance
        ~persistent_frontier ~persistent_frontier_instance ~genesis_state_hash
        ~genesis_constants ignore_consensus_local_state
    with
    | Ok _ as result ->
        return result
    | Error _ as err ->
        let%map () =
          Persistent_frontier.Instance.destroy persistent_frontier_instance
        in
        Persistent_root.Instance.destroy persistent_root_instance ;
        err
  in
  let persistent_frontier_instance =
    Persistent_frontier.create_instance_exn persistent_frontier
  in
  let reset_and_continue () =
    let%bind () =
      Persistent_frontier.Instance.destroy persistent_frontier_instance
    in
    let%bind () =
      Persistent_frontier.reset_database_exn persistent_frontier
        ~root_data:
          (genesis_root_data ~genesis_ledger ~base_proof ~genesis_constants)
    in
    let%bind () =
      Persistent_root.reset_to_genesis_exn persistent_root ~genesis_ledger
        ~genesis_state_hash
    in
    continue
      (Persistent_frontier.create_instance_exn persistent_frontier)
      ~ignore_consensus_local_state:false
  in
  match
    Persistent_frontier.Instance.check_database persistent_frontier_instance
  with
  | Error `Not_initialized ->
      (* TODO: this case can be optimized to not create the
         * database twice through rocks -- currently on clean bootup,
         * this code path will reinitialize the rocksdb twice *)
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        "persistent frontier database does not exist" ;
      reset_and_continue ()
  | Error `Invalid_version ->
      Logger.info logger ~module_:__MODULE__ ~location:__LOC__
        "persistent frontier database out of date" ;
      reset_and_continue ()
  | Error (`Corrupt err) ->
      Logger.error logger ~module_:__MODULE__ ~location:__LOC__
        "Persistent frontier database is corrupt: %s"
        (Persistent_frontier.Database.Error.message err) ;
      if retry_with_fresh_db then (
        (* should retry be on by default? this could be unnecessarily destructive *)
        Logger.info logger ~module_:__MODULE__ ~location:__LOC__
          "destroying old persistent frontier database " ;
        let%bind () =
          Persistent_frontier.Instance.destroy persistent_frontier_instance
        in
        let%bind () =
          Persistent_frontier.destroy_database_exn persistent_frontier
        in
        load_with_max_length ~max_length ~logger ~verifier
          ~consensus_local_state ~persistent_root ~persistent_frontier
          ~retry_with_fresh_db:false () ~genesis_state_hash ~genesis_ledger
          ~base_proof ~genesis_constants
        >>| Result.map_error ~f:(function
              | `Persistent_frontier_malformed ->
                  `Failure
                    "failed to destroy and create new persistent frontier \
                     database"
              | err ->
                  err ) )
      else return (Error `Persistent_frontier_malformed)
  | Ok () ->
      continue persistent_frontier_instance ~ignore_consensus_local_state:true

let load ?(retry_with_fresh_db = true) ~logger ~verifier ~consensus_local_state
    ~persistent_root ~persistent_frontier ~genesis_state_hash ~genesis_ledger
    ?(base_proof = Precomputed_values.base_proof) ~genesis_constants () =
  let max_length = global_max_length genesis_constants in
  load_with_max_length ~max_length ~retry_with_fresh_db ~logger ~verifier
    ~consensus_local_state ~persistent_root ~persistent_frontier
    ~genesis_state_hash ~genesis_ledger ~base_proof ~genesis_constants ()

(* The persistent root and persistent frontier as safe to ignore here
 * because their lifecycle is longer than the transition frontier's *)
let close
    { logger
    ; verifier= _
    ; consensus_local_state= _
    ; full_frontier
    ; persistent_root= _safe_to_ignore_1
    ; persistent_root_instance
    ; persistent_frontier= _safe_to_ignore_2
    ; persistent_frontier_instance
    ; extensions
    ; genesis_state_hash= _ } =
  Logger.trace logger ~module_:__MODULE__ ~location:__LOC__
    "Closing transition frontier" ;
  Full_frontier.close full_frontier ;
  Extensions.close extensions ;
  let%map () =
    Persistent_frontier.Instance.destroy persistent_frontier_instance
  in
  Persistent_root.Instance.destroy persistent_root_instance

let persistent_root {persistent_root; _} = persistent_root

let persistent_frontier {persistent_frontier; _} = persistent_frontier

let extensions {extensions; _} = extensions

let genesis_state_hash {genesis_state_hash; _} = genesis_state_hash

let root_snarked_ledger {persistent_root_instance; _} =
  Persistent_root.Instance.snarked_ledger persistent_root_instance

let add_breadcrumb_exn t breadcrumb =
  let open Deferred.Let_syntax in
  let old_hash = Full_frontier.hash t.full_frontier in
  let diffs = Full_frontier.calculate_diffs t.full_frontier breadcrumb in
  Logger.trace t.logger ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ( "state_hash"
        , State_hash.to_yojson
            (Breadcrumb.state_hash @@ Full_frontier.best_tip t.full_frontier)
        )
      ; ( "n"
        , `Int (List.length @@ Full_frontier.all_breadcrumbs t.full_frontier)
        ) ]
    "PRE: ($state_hash, $n)" ;
  Logger.trace t.logger ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ( "diffs"
        , `List
            (List.map diffs ~f:(fun (Diff.Full.E.E diff) -> Diff.to_yojson diff))
        ) ]
    "Applying diffs: $diffs" ;
  let (`New_root_and_diffs_with_mutants
        (new_root_identifier, diffs_with_mutants)) =
    Full_frontier.apply_diffs t.full_frontier diffs
      ~ignore_consensus_local_state:false
  in
  Option.iter new_root_identifier
    ~f:
      (Persistent_root.Instance.set_root_identifier t.persistent_root_instance) ;
  Logger.trace t.logger ~module_:__MODULE__ ~location:__LOC__
    ~metadata:
      [ ( "state_hash"
        , State_hash.to_yojson
            (Breadcrumb.state_hash @@ Full_frontier.best_tip t.full_frontier)
        )
      ; ( "n"
        , `Int (List.length @@ Full_frontier.all_breadcrumbs t.full_frontier)
        ) ]
    "POST: ($state_hash, $n)" ;
  let lite_diffs =
    List.map diffs ~f:Diff.(fun (Full.E.E diff) -> Lite.E.E (to_lite diff))
  in
  let%bind sync_result =
    Persistent_frontier.Instance.notify_sync t.persistent_frontier_instance
      ~diffs:lite_diffs
      ~hash_transition:
        {source= old_hash; target= Full_frontier.hash t.full_frontier}
  in
  sync_result
  |> Result.map_error ~f:(fun `Sync_must_be_running ->
         Failure
           "Cannot add breadcrumb because persistent frontier sync job is not \
            running, which indicates that transition frontier initialization \
            has not been performed correctly" )
  |> Result.ok_exn ;
  Extensions.notify t.extensions ~frontier:t.full_frontier ~diffs_with_mutants

(* proxy full frontier functions *)
include struct
  open Full_frontier

  let proxy1 f {full_frontier; _} = f full_frontier

  let max_length = proxy1 max_length

  let consensus_local_state = proxy1 consensus_local_state

  let all_breadcrumbs = proxy1 all_breadcrumbs

  let visualize ~filename = proxy1 (visualize ~filename)

  let visualize_to_string = proxy1 visualize_to_string

  let iter = proxy1 iter

  let common_ancestor = proxy1 common_ancestor

  (* reduce sucessors functions (probably remove hashes special case *)
  let successors = proxy1 successors

  let successors_rec = proxy1 successors_rec

  let successor_hashes = proxy1 successor_hashes

  let successor_hashes_rec = proxy1 successor_hashes_rec

  let hash_path = proxy1 hash_path

  let best_tip = proxy1 best_tip

  let root = proxy1 root

  let find = proxy1 find

  let genesis_constants = proxy1 genesis_constants

  (* TODO: find -> option externally, find_exn internally *)
  let find_exn = proxy1 find_exn

  (* TODO: is this an abstraction leak? *)
  let root_length = proxy1 root_length

  (* TODO: probably shouldn't be an `_exn` function *)
  let best_tip_path = proxy1 best_tip_path

  let best_tip_path_length_exn = proxy1 best_tip_path_length_exn

  (* why can't this one be proxied? *)
  let path_map {full_frontier; _} breadcrumb ~f =
    path_map full_frontier breadcrumb ~f
end

module For_tests = struct
  open Signature_lib
  module Ledger_transfer = Ledger_transfer.Make (Ledger) (Ledger.Db)
  open Full_frontier.For_tests

  let proxy2 f {full_frontier= x; _} {full_frontier= y; _} = f x y

  let equal = proxy2 equal

  let load_with_max_length = load_with_max_length

  let rec deferred_rose_tree_iter (Rose_tree.T (root, trees)) ~f =
    let%bind () = f root in
    Deferred.List.iter trees ~f:(deferred_rose_tree_iter ~f)

  (*
  let with_frontier_from_rose_tree (Rose_tree.T (root, trees)) ~logger ~verifier ~consensus_local_state ~max_length ~root_snarked_ledger ~f =
    with_temp_persistence ~f:(fun ~persistent_root ~persistent_frontier ->
      Persistent_root.with_instance_exn persistent_root ~f:(fun instance ->
        Persistent_root.Instance.set_root_state_hash instance (Breadcrumb.state_hash @@ root);
        ignore @@ Ledger_transfer.transfer_accounts
          ~src:root_snarked_ledger
          ~dest:(Persistent_root.snarked_ledger instance));
      let frontier =
        let fail msg = failwith ("failed to load transition frontier: "^msg) in
        load_with_max_length
          {logger; verifier; consensus_local_state}
          ~persistent_root ~persistent_frontier
          ~max_length
        >>| Result.map_error ~f:(Fn.compose fail (function
          | `Bootstrap_required -> "bootstrap required"
          | `Persistent_frontier_malformed -> "persistent frontier malformed"
          | `Faliure msg -> msg))
        >>| Result.ok_or_failwith
      in
      let%bind () = Deferred.List.iter trees ~f:(deferred_rose_tree_iter ~f:(add_breadcrumb_exn frontier)) in
      f frontier)
  *)

  (* a helper quickcheck generator which always returns the genesis breadcrumb *)
  let gen_genesis_breadcrumb ?(logger = Logger.null ()) ?verifier () =
    let verifier =
      match verifier with
      | Some x ->
          x
      | None ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              Verifier.create ~logger ~conf_dir:None
                ~pids:(Child_processes.Termination.create_pid_table ()) )
    in
    Quickcheck.Generator.create (fun ~size:_ ~random:_ ->
        let genesis_transition = External_transition.For_tests.genesis () in
        let genesis_ledger = Lazy.force Test_genesis_ledger.t in
        let genesis_staged_ledger =
          Or_error.ok_exn
            (Async.Thread_safe.block_on_async_exn (fun () ->
                 Staged_ledger
                 .of_scan_state_pending_coinbases_and_snarked_ledger ~logger
                   ~verifier
                   ~scan_state:(Staged_ledger.Scan_state.empty ())
                   ~pending_coinbases:
                     (Or_error.ok_exn @@ Pending_coinbase.create ())
                   ~snarked_ledger:genesis_ledger
                   ~expected_merkle_root:(Ledger.merkle_root genesis_ledger) ))
        in
        Breadcrumb.create genesis_transition genesis_staged_ledger )

  let gen_persistence ?(logger = Logger.null ()) ?verifier () =
    let open Core in
    let verifier =
      match verifier with
      | Some x ->
          x
      | None ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              Verifier.create ~logger ~conf_dir:None
                ~pids:(Child_processes.Termination.create_pid_table ()) )
    in
    let root_dir = "/tmp/coda_unit_test" in
    Quickcheck.Generator.create (fun ~size:_ ~random:_ ->
        let uuid = Uuid_unix.create () in
        let temp_dir = root_dir ^/ Uuid.to_string uuid in
        let root_dir = temp_dir ^/ "root" in
        let frontier_dir = temp_dir ^/ "frontier" in
        let cleaned = ref false in
        let clean_temp_dirs _ =
          if not !cleaned then (
            let process_info =
              Unix.create_process ~prog:"rm" ~args:["-rf"; temp_dir]
            in
            Unix.waitpid process_info.pid
            |> Result.map_error ~f:(function
                 | `Exit_non_zero n ->
                     Printf.sprintf "error (exit code %d)" n
                 | `Signal _ ->
                     "error (received unexpected signal)" )
            |> Result.ok_or_failwith ;
            cleaned := true )
        in
        Unix.mkdir_p temp_dir ;
        Unix.mkdir root_dir ;
        Unix.mkdir frontier_dir ;
        let persistent_root =
          Persistent_root.create ~logger ~directory:root_dir
        in
        let persistent_frontier =
          Persistent_frontier.create ~logger ~verifier
            ~time_controller:(Block_time.Controller.basic ~logger)
            ~directory:frontier_dir
        in
        Gc.Expert.add_finalizer_exn persistent_root clean_temp_dirs ;
        Gc.Expert.add_finalizer_exn persistent_frontier (fun x ->
            Option.iter
              persistent_frontier.Persistent_frontier.Factory_type.instance
              ~f:(fun instance ->
                Persistent_frontier.Database.close instance.db ) ;
            clean_temp_dirs x ) ;
        (persistent_root, persistent_frontier) )

  let gen ?(logger = Logger.null ()) ?verifier ?trust_system
      ?consensus_local_state
      ?(root_ledger_and_accounts =
        ( Lazy.force Test_genesis_ledger.t
        , Lazy.force Test_genesis_ledger.accounts ))
      ?(gen_root_breadcrumb = gen_genesis_breadcrumb ~logger ?verifier ())
      ~max_length ~size () =
    let open Quickcheck.Generator.Let_syntax in
    let genesis_state_hash =
      Coda_state.Genesis_protocol_state.t ~genesis_ledger:Test_genesis_ledger.t
        ~genesis_constants:Genesis_constants.compiled
      |> With_hash.hash
    in
    let verifier =
      match verifier with
      | Some x ->
          x
      | None ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              Verifier.create ~logger ~conf_dir:None
                ~pids:(Child_processes.Termination.create_pid_table ()) )
    in
    let trust_system =
      Option.value trust_system ~default:(Trust_system.null ())
    in
    let consensus_local_state =
      Option.value consensus_local_state
        ~default:
          (Consensus.Data.Local_state.create
             ~genesis_ledger:Test_genesis_ledger.t
             Public_key.Compressed.Set.empty)
    in
    let root_snarked_ledger, root_ledger_accounts = root_ledger_and_accounts in
    (* TODO: ensure that rose_tree cannot be longer than k *)
    let%bind (Rose_tree.T (root, branches)) =
      Quickcheck.Generator.with_size ~size
        (Quickcheck_lib.gen_imperative_rose_tree gen_root_breadcrumb
           (Breadcrumb.For_tests.gen_non_deferred ~logger ~verifier
              ~trust_system ~accounts_with_secret_keys:root_ledger_accounts))
    in
    let root_data =
      { Root_data.Limited.Stable.Latest.transition=
          Breadcrumb.validated_transition root
      ; scan_state= Breadcrumb.staged_ledger root |> Staged_ledger.scan_state
      ; pending_coinbase=
          Breadcrumb.staged_ledger root
          |> Staged_ledger.pending_coinbase_collection }
    in
    let%map persistent_root, persistent_frontier =
      gen_persistence ~logger ()
    in
    Async.Thread_safe.block_on_async_exn (fun () ->
        Persistent_frontier.reset_database_exn persistent_frontier ~root_data
    ) ;
    Persistent_root.with_instance_exn persistent_root ~f:(fun instance ->
        Persistent_root.Instance.set_root_state_hash instance
          ~genesis_state_hash
          (External_transition.Validated.state_hash root_data.transition) ;
        ignore
        @@ Ledger_transfer.transfer_accounts ~src:root_snarked_ledger
             ~dest:(Persistent_root.Instance.snarked_ledger instance) ) ;
    let frontier_result =
      Async.Thread_safe.block_on_async_exn (fun () ->
          load_with_max_length ~max_length ~retry_with_fresh_db:false ~logger
            ~verifier ~consensus_local_state ~persistent_root
            ~persistent_frontier ~genesis_state_hash
            ~genesis_ledger:(lazy root_snarked_ledger)
            ~genesis_constants:Genesis_constants.compiled () )
    in
    let frontier =
      let fail msg = failwith ("failed to load transition frontier: " ^ msg) in
      match frontier_result with
      | Error `Bootstrap_required ->
          fail "bootstrap required"
      | Error `Persistent_frontier_malformed ->
          fail "persistent frontier malformed"
      | Error (`Failure msg) ->
          fail msg
      | Ok frontier ->
          frontier
    in
    Async.Thread_safe.block_on_async_exn (fun () ->
        Deferred.List.iter ~how:`Sequential branches
          ~f:(deferred_rose_tree_iter ~f:(add_breadcrumb_exn frontier)) ) ;
    frontier

  let gen_with_branch ?logger ?verifier ?trust_system ?consensus_local_state
      ?(root_ledger_and_accounts =
        ( Lazy.force Test_genesis_ledger.t
        , Lazy.force Test_genesis_ledger.accounts )) ?gen_root_breadcrumb
      ?(get_branch_root = root) ~max_length ~frontier_size ~branch_size () =
    let open Quickcheck.Generator.Let_syntax in
    let%bind frontier =
      gen ?logger ?verifier ?trust_system ?consensus_local_state
        ?gen_root_breadcrumb ~root_ledger_and_accounts ~max_length
        ~size:frontier_size ()
    in
    let%map make_branch =
      Breadcrumb.For_tests.gen_seq ?logger ?verifier ?trust_system
        ~accounts_with_secret_keys:(snd root_ledger_and_accounts)
        branch_size
    in
    let branch =
      Async.Thread_safe.block_on_async_exn (fun () ->
          make_branch (get_branch_root frontier) )
    in
    (frontier, branch)
end
