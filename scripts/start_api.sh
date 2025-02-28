dune build || exit 1

dir=$(dirname $0)
source $dir/common.sh

vm=${1:-"wasm-vm"}

# Starting only one API node for the node 0
export DEKU_TEZOS_RPC_NODE=${DEKU_TEZOS_RPC_NODE:-http://localhost:20000}
export DEKU_TEZOS_CONSENSUS_ADDRESS="$(tezos_client --endpoint $DEKU_TEZOS_RPC_NODE show known contract consensus | grep KT1 | tr -d '\r')"
export DEKU_API_NODE_URI="127.0.0.1:4440"
export DEKU_API_PORT=8080
export DEKU_API_DATABASE_URI="sqlite3:/tmp/api_database.db"
export DEKU_API_DOMAINS=8
export DEKU_API_VM="./chain/data/0/api_vm_pipe"
export DEKU_API_DATA_FOLDER="./chain/data/0/"

## The api needs its own vm
nix run ".#$vm" -- "./chain/data/0/api_vm_pipe" &
sleep 1
echo Start the API

# Start the API
./_build/install/default/bin/deku-api
