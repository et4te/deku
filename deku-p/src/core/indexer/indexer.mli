open Deku_consensus
open Deku_concepts

type indexer
type t = indexer
type config = { save_messages : bool; save_blocks : bool }

val make : uri:Uri.t -> config:config -> indexer
val async_save_block : sw:Eio.Switch.t -> block:Block.t -> indexer -> unit
val save_block : block:Block.t -> indexer -> unit
val find_block_by_level : level:Level.t -> indexer -> Yojson.Safe.t option

val find_block_by_hash :
  block_hash:Block_hash.t -> indexer -> Yojson.Safe.t option
