open Deku_stdlib
open Deku_concepts
open Deku_crypto
open Deku_indexer
open Deku_storage
open Deku_chain
open Deku_external_vm
open Deku_protocol

let make_dump_loop ~sw ~env ~folder =
  let resolver_ref = Atomic.make None in
  let domains = Eio.Stdenv.domain_mgr env in

  let rec loop () : unit =
    let promise, resolver = Eio.Promise.create () in
    Atomic.set resolver_ref (Some resolver);
    let chain = Eio.Promise.await promise in
    (try Storage.Chain.write ~env ~folder chain
     with exn ->
       Format.eprintf "storage.failure: %s\n%!" (Printexc.to_string exn));
    loop ()
  in
  let dump chain =
    match Atomic.exchange resolver_ref None with
    | Some resolver -> Eio.Promise.resolve resolver chain
    | None -> ()
  in
  ( Eio.Fiber.fork_sub ~sw ~on_error:Deku_constants.async_on_error @@ fun _sw ->
    Eio.Domain_manager.run domains (fun () -> loop ()) );
  dump

type params = {
  domains : int; [@env "DEKU_DOMAINS"] [@default 8]
  secret : Ed25519.Secret.t; [@env "DEKU_SECRET"]
      (** The base58-encoded secret used as the Deku-node's identity. *)
  data_folder : string; [@env "DEKU_DATA_FOLDER"] [@default "/var/lib/deku"]
      (** Folder path where node's state is stored. *)
  validators : Key_hash.t list; [@env "DEKU_VALIDATORS"]
      (** A comma separeted list of the key hashes of all validators in the network. *)
  validator_uris : string list; [@env "DEKU_VALIDATOR_URIS"]
      (** A comma-separated list of the validator URI's used to join the network. *)
  port : int; [@default 4440] [@env "DEKU_PORT"]  (** The port to listen on. *)
  database_uri : Uri.t;
      [@env "DEKU_DATABASE_URI"]
      [@default Uri.of_string "sqlite3:/var/lib/deku/db.sqlite"]
      (** A URI-encoded path to a SQLite database. Will be created it if it doesn't exist already. *)
  save_blocks : bool; [@env "DEKU_DEBUG_SAVE_BLOCKS"] [@default true]
      (** Configures the debug indexer to save blocks. Defaults to true. *)
  save_messages : bool; [@env "DEKU_DEBUG_SAVE_MESSAGES"] [@default true]
      (** Configures the debug indexer to save consensus messages. Defaults to true. *)
  default_block_size : int; [@env "DEKU_DEFAULT_BLOCK_SIZE"] [@default 50_000]
      (** The threshold below which blocks are filled with no-op transactions. *)
  tezos_rpc_node : Uri.t; [@env "DEKU_TEZOS_RPC_NODE"]
      (** The URI of this validator's Tezos RPC node. *)
  tezos_secret : Ed25519.Secret.t; [@env "DEKU_TEZOS_SECRET"]
      (** The base58-encoded ED25519 secret to use as the wallet for submitting Tezos transactions. *)
  tezos_consensus_address : Deku_tezos.Address.t;
      [@env "DEKU_TEZOS_CONSENSUS_ADDRESS"]
      (** The address of the consensus contract on Tezos.  *)
  named_pipe_path : string;
      [@default "/run/deku/pipe"] [@env "DEKU_NAMED_PIPE_PATH"]
      (** Named pipe path to use for IPC with the VM *)
  api_uri : string; [@env "DEKU_API_URI"] [@default "127.0.0.1:5550"]
}
[@@deriving cmdliner]

let setup_log ?style_renderer ?log_level () =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level log_level;
  Logs.set_reporter (Logs_fmt.reporter ());
  (* disable all non-deku logs *)
  List.iter
    (fun src ->
      let src_name = Logs.Src.name src in
      if
        (not (String.starts_with ~prefix:"deku" src_name))
        && not (String.equal src_name "application")
      then Logs.Src.set_level src (Some Logs.Error))
    (Logs.Src.list ())

let main params style_renderer log_level =
  let {
    domains;
    secret;
    data_folder;
    validators;
    validator_uris;
    port;
    database_uri;
    save_blocks;
    save_messages;
    default_block_size;
    tezos_rpc_node;
    tezos_secret;
    tezos_consensus_address;
    named_pipe_path;
    api_uri;
  } =
    params
  in
  setup_log ?style_renderer ?log_level ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Parallel.Pool.run ~env ~domains @@ fun () ->
  Logs.info (fun m -> m "Using %d domains" domains);
  Logs.info (fun m -> m "Default block size: %d" default_block_size);
  let indexer =
    Indexer.make ~uri:database_uri
      ~config:Indexer.{ save_blocks; save_messages }
  in
  let validator_uris =
    List.map
      (fun s ->
        match String.split_on_char ':' s with
        | [ domain; port ] -> (domain, int_of_string port)
        | _ -> failwith "FIXME: error message")
      validator_uris
  in
  let api_uri =
    match String.split_on_char ':' api_uri with
    | [ api_host; api_port ] -> (api_host, int_of_string api_port)
    | _ -> failwith "FIXME: wrong api uri"
  in

  let validator_uris =
    if port = 4440 then api_uri :: validator_uris else validator_uris
  in

  (* The VM must be started before the node because this call is blocking  *)
  Logs.info (fun m ->
      m "Starting IPC with external vm at path %s" named_pipe_path);
  let () = External_vm_client.start_vm_ipc ~named_pipe_path in
  let identity = Identity.make (Secret.Ed25519 secret) in
  Logs.info (fun m ->
      m "Running as validator %s" (Identity.key_hash identity |> Key_hash.to_b58));
  (* TODO: one problem of loading from disk like this, is that there
       may be pending actions such as fragments being processed *)
  let chain = Storage.Chain.read ~env ~folder:data_folder in
  Logs.info (fun m -> m "Loaded chain from disk");
  let chain =
    match chain with
    | Some chain ->
        let (Chain { protocol; _ }) = chain in
        let (Protocol.Protocol { vm_state; _ }) = protocol in
        External_vm_client.set_initial_state vm_state;
        chain
    | None ->
        let vm_state = External_vm_client.get_initial_state () in
        Chain.make ~validators ~vm_state
  in
  let dump = make_dump_loop ~sw ~env ~folder:data_folder in
  let node =
    Node.make ~identity ~default_block_size ~dump ~chain ~indexer:(Some indexer)
  in

  let (Chain { consensus; _ }) = chain in
  let (Block { level; _ }) = Deku_consensus.Consensus.trusted_block consensus in
  Format.eprintf "Chain started at level: %a\n%!" Level.pp level;
  let tezos =
    (tezos_rpc_node, Secret.Ed25519 tezos_secret, tezos_consensus_address)
  in
  Node.start ~sw ~env ~port ~nodes:validator_uris ~tezos:(Some tezos) node

let main () =
  Sys.set_signal Sys.sigpipe
    (Sys.Signal_handle (fun _ -> Format.eprintf "SIGPIPE\n%!"));

  let control = Gc.get () in
  let control = { control with minor_heap_size = 2048; space_overhead = 60 } in
  Gc.set control;

  Logs.info (fun m -> m "Starting node");
  let info = Cmdliner.Cmd.info Sys.argv.(0) in
  let term =
    Cmdliner.Term.(
      const main $ params_cmdliner_term ()
      $ Fmt_cli.style_renderer ~env:(Cmdliner.Cmd.Env.info "DEKU_LOG_COLORS") ()
      $ Logs_cli.level
          ~env:
            (Cmdliner.Cmd.Env.info
               "DEKU_LOG_VERBOSITY"
               (* TODO: consolidate and document environment options *))
          ())
  in
  let cmd = Cmdliner.Cmd.v info term in
  exit (Cmdliner.Cmd.eval ~catch:true cmd)

(*
   let _ = main
   let main () = Node.test () *)
let () = main ()
