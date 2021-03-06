open Core
open Async

let name = "coda-long-fork"

let main n waiting_time () =
  let consensus_constants = Consensus.Constants.compiled in
  let logger = Logger.create () in
  let keypairs =
    List.map
      (Lazy.force Test_genesis_ledger.accounts)
      ~f:Test_genesis_ledger.keypair_of_account_record_exn
  in
  let snark_work_public_keys i =
    Some
      ( (List.nth_exn keypairs i).public_key
      |> Signature_lib.Public_key.compress )
  in
  let%bind testnet =
    Coda_worker_testnet.test ~name logger n Option.some snark_work_public_keys
      Cli_lib.Arg_type.Work_selection_method.Sequence
      ~max_concurrent_connections:None
  in
  let epoch_duration =
    let block_window_duration_ms =
      Block_time.Span.to_ms consensus_constants.block_window_duration_ms
      |> Int64.to_int_exn
    in
    Unsigned.UInt32.(
      block_window_duration_ms * 3
      * to_int consensus_constants.c
      * to_int consensus_constants.k)
  in
  let%bind () =
    Coda_worker_testnet.Restarts.restart_node testnet ~logger ~node:1
      ~duration:(Time.Span.of_ms (2 * epoch_duration |> Float.of_int))
  in
  let%bind () = after (Time.Span.of_sec (waiting_time |> Float.of_int)) in
  Coda_worker_testnet.Api.teardown testnet ~logger

let command =
  let open Command.Let_syntax in
  Command.async ~summary:"Test that one worker goes offline for a long time"
    (let%map_open num_block_producers =
       flag "num-block-producers" ~doc:"NUM number of block producers to have"
         (required int)
     and waiting_time =
       flag "waiting-time"
         ~doc:"the waiting time after the nodes coming back alive"
         (optional_with_default 120 int)
     in
     main num_block_producers waiting_time)
