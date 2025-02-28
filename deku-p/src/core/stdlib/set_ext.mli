module type OrderedType = sig
  include Map.OrderedType

  val t_of_yojson : Yojson.Safe.t -> t
  val yojson_of_t : t -> Yojson.Safe.t
end

module type S = sig
  include Set.S

  val t_of_yojson : Yojson.Safe.t -> t
  val yojson_of_t : t -> Yojson.Safe.t
end

module Make (Ord : OrderedType) : S with type elt = Ord.t
