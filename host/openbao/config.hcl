# Single node with integrated (Raft) storage, the standard backend.
storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao-1"
}

# Plain HTTP: traffic only crosses the host's loopback and the cluster's docker
# bridge. Anything reachable over a real network needs TLS here.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://openbao:8200"
cluster_addr = "http://openbao:8201"
ui           = true

# Recommended with Raft storage.
disable_mlock = true
