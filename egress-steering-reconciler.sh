#!/bin/bash
# /usr/local/bin/egress-steering-reconciler.sh
#
# Steers egress traffic from configured Pod IPs/CIDRs through nodes labeled
# k8s.ovn.org/egress-assignable="", with SNAT on the egress node.
# Self-determines role (worker vs egress) each reconcile cycle.
#
# Health detection: filters NotReady nodes via API + parallel ping probes.
# ECMP: distributes traffic across all healthy egress nodes.
#
# Usage:
#   egress-steering-reconciler.sh           # run reconciler loop
#   egress-steering-reconciler.sh cleanup   # tear down all rules and exit

set -uo pipefail

# --- Configuration ---
CONFIG_FILE="/etc/egress-steering/egress-steering.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[error] configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Derived / internal
OC_ARGS="--server=${API_SERVER} --certificate-authority=${CA_FILE} --token=$(cat "${TOKEN_FILE}")"

# --- State tracking ---
LAST_STATE=""

# --- Helpers ---

get_self_ip() {
  ip route get 1.1.1.1 | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}

get_node_name() {
  local self_ip
  self_ip=$(get_self_ip)
  oc ${OC_ARGS} get nodes -o json 2>/dev/null \
  | jq -r --arg ip "$self_ip" '
    .items[]
    | select(.status.addresses[] | select(.type=="InternalIP" and .address==$ip))
    | .metadata.name
  ' | head -1
}

is_egress_node() {
  local labels
  labels=$(oc ${OC_ARGS} get node "$1" \
    -o jsonpath='{.metadata.labels}' 2>/dev/null)
  echo "$labels" | grep -q 'k8s.ovn.org/egress-assignable'
}

# Returns lines of "name,IP" for egress nodes that are Ready, sorted by name.
# Returns non-zero on API failure so the caller can distinguish "no nodes" from "API down".
get_egress_nodes() {
  local output rc
  output=$(oc ${OC_ARGS} get nodes \
    -l 'k8s.ovn.org/egress-assignable=' \
    -o json 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[error] API query failed: ${output}" >&2
    return 1
  fi
  echo "$output" | jq -r '
    .items[]
    | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))
    | "\(.metadata.name),\(.status.addresses[] | select(.type=="InternalIP").address)"
  ' | sort
}

# Returns newline-separated list of reachable egress node IPs.
# Pings all nodes in parallel to avoid sequential timeout accumulation.
get_healthy_egress_ips() {
  local egress_nodes="$1"
  local pids=() entries=()

  while IFS=',' read -r name ip; do
    [ -z "$ip" ] && continue
    entries+=("${name},${ip}")
    ping -c 1 -W "$PING_TIMEOUT" "$ip" &>/dev/null &
    pids+=($!)
  done <<< "$egress_nodes"

  for i in "${!pids[@]}"; do
    IFS=',' read -r name ip <<< "${entries[$i]}"
    if wait "${pids[$i]}"; then
      echo "$ip"
    else
      echo "[warn] egress node ${name} (${ip}) is Ready but unreachable" >&2
    fi
  done
}

# --- Setup / Cleanup ---

setup_worker() {
  local healthy_ips="$1"
  local nexthops=""

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    nexthops="${nexthops} nexthop via ${ip} weight 1"
  done <<< "$healthy_ips"

  # Atomic nftables swap: add new table then flush-and-replace in one transaction.
  # Avoids the brief window where no rules exist.
  #
  # prerouting (mangle): marks Pod-initiated egress traffic with fwmark for
  # policy routing. Uses ct direction original to skip ingress reply traffic.
  # OVN-K's MASQUERADE (ovn-kube-pod-subnet-masq) will then SNAT the source
  # to the worker node's IP in POSTROUTING. This is intentional — the egress
  # node will re-MASQUERADE to its own IP, and the return path comes back to
  # the worker via the physical network where conntrack un-SNATs back to the
  # Pod IP.
  nft -f - <<EOF
table inet ${NFT_TABLE_WORKER}
flush table inet ${NFT_TABLE_WORKER}
table inet ${NFT_TABLE_WORKER} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip saddr ${POD_CIDRS} ip daddr != { ${CLUSTER_CIDRS} } ct direction original meta mark set ${FWMARK}
  }
}
EOF

  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip rule add fwmark "$FWMARK" table "$RT_TABLE" priority "$RT_PRIO"

  # ECMP hash policy (default: L4 hash so flows to the same dest IP can spread)
  sysctl -qw net.ipv4.fib_multipath_hash_policy="${FIB_MULTIPATH_HASH_POLICY:-1}"

  # table must precede nexthop arguments; intentionally unquoted for word splitting
  ip route replace default table "$RT_TABLE" ${nexthops}
}

cleanup_worker() {
  nft delete table inet "$NFT_TABLE_WORKER" 2>/dev/null || true
  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip route flush table "$RT_TABLE" 2>/dev/null || true
}

setup_egress() {
  # Forwarding and SNAT rules for steered traffic.
  #
  # Steered traffic arrives from worker nodes with the worker's IP as source
  # (OVN-K MASQUERADE on the worker already SNATed Pod IP → Worker IP).
  #
  # Prerequisites handled by OVN-K with ipForwarding: Global:
  # - ip_forward=1 (globally enabled)
  # - rp_filter=2 (loose mode on all interfaces)
  # - FORWARD chain policy accept (no need to insert rules into ip filter)
  #
  # - forward chain: marks forwarded traffic going to non-cluster destinations
  #   with FWMARK_FWD to identify it for MASQUERADE in postrouting.
  # - postrouting chain: MASQUERADE packets marked by the forward chain to the
  #   egress node's outbound IP.
  #
  # The return path delivers replies to the worker node via the physical
  # network, where the worker's conntrack un-SNATs back to the Pod IP.
  local fwmark_fwd="0x3000"
  nft -f - <<EOF
table inet ${NFT_TABLE_EGRESS}
flush table inet ${NFT_TABLE_EGRESS}
table inet ${NFT_TABLE_EGRESS} {
  chain forward {
    type filter hook forward priority filter - 1; policy accept;
    ip daddr != { ${CLUSTER_CIDRS} } meta mark set ${fwmark_fwd}
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    meta mark ${fwmark_fwd} masquerade
  }
}
EOF
}

cleanup_egress() {
  nft delete table inet "$NFT_TABLE_EGRESS" 2>/dev/null || true
}

cleanup_all() {
  cleanup_worker
  cleanup_egress
  echo "[cleanup] all egress-steering rules removed"
  LAST_STATE=""
}

# --- Main loop ---

main() {
  # Handle cleanup subcommand
  if [ "${1:-}" = "cleanup" ]; then
    cleanup_all
    exit 0
  fi

  # Validate API access before entering the loop
  if ! oc ${OC_ARGS} get nodes &>/dev/null; then
    echo "[error] cannot reach API at ${API_SERVER}"
    exit 1
  fi

  local node_name
  node_name=$(get_node_name)
  if [ -z "$node_name" ]; then
    echo "[error] cannot determine node name"
    exit 1
  fi

  echo "[init] node=${node_name} pod_cidrs=${POD_CIDRS}"

  trap 'cleanup_all; exit 0' SIGTERM SIGINT

  while true; do
    local egress_nodes

    if ! egress_nodes=$(get_egress_nodes); then
      echo "[warn] API unreachable, keeping current rules"
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    if [ -z "$egress_nodes" ]; then
      if [ -n "$LAST_STATE" ]; then
        echo "[warn] no Ready egress nodes found, cleaning up"
        cleanup_all
      fi
      sleep "$RECONCILE_INTERVAL"
      continue
    fi

    if is_egress_node "$node_name"; then
      local desired_state="egress"
      if [ "$desired_state" != "$LAST_STATE" ]; then
        echo "[egress] accepting steered traffic for ${POD_CIDRS}"
        cleanup_worker
        setup_egress
        LAST_STATE="$desired_state"
      fi
    else
      local self_ip healthy_ips
      self_ip=$(get_self_ip)
      healthy_ips=$(get_healthy_egress_ips "$egress_nodes" | grep -v "^${self_ip}$")

      if [ -z "$healthy_ips" ]; then
        if [ -n "$LAST_STATE" ]; then
          echo "[warn] no reachable egress nodes, cleaning up"
          cleanup_all
        fi
        sleep "$RECONCILE_INTERVAL"
        continue
      fi

      local desired_state="worker:${healthy_ips}"
      if [ "$desired_state" != "$LAST_STATE" ]; then
        echo "[worker] steering ${POD_CIDRS} -> egress ECMP [$(echo "$healthy_ips" | tr '\n' ' ')]"
        cleanup_egress
        setup_worker "$healthy_ips"
        LAST_STATE="$desired_state"
      fi
    fi

    sleep "$RECONCILE_INTERVAL"
  done
}

main "$@"
