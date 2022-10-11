open Deku_repr
open Deku_crypto
open BLAKE2b

type request_hash = BLAKE2b.t
and t = request_hash [@@deriving eq, ord]

let to_blake2b request_hash = request_hash

include With_b58_and_encoding (struct
  let name = "Deku_gossip.Request_hash"
  let prefix = Prefix.deku_request_hash
end)

include With_yojson_of_b58 (struct
  type t = request_hash

  let of_b58 = of_b58
  let to_b58 = to_b58
end)

let hash = hash

module Set = Set
module Map = Map

let show = to_b58
let pp fmt t = Format.pp_print_string fmt (to_b58 t)
