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
RP_FILTER_ORIG_FILE="/run/egress-steering-rp-filter.orig"
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

  # L4 hash so flows to the same dest IP can spread across egress nodes
  sysctl -qw net.ipv4.fib_multipath_hash_policy=1

  # Intentionally unquoted: word splitting expands nexthop arguments
  ip route replace default ${nexthops} table "$RT_TABLE"
}

cleanup_worker() {
  nft delete table inet "$NFT_TABLE_WORKER" 2>/dev/null || true
  ip rule del fwmark "$FWMARK" table "$RT_TABLE" 2>/dev/null || true
  ip route flush table "$RT_TABLE" 2>/dev/null || true
}

setup_egress() {
  # Save original rp_filter values before overwriting
  if [ ! -f "$RP_FILTER_ORIG_FILE" ]; then
    sysctl -a 2>/dev/null | grep '\.rp_filter\s*=' > "$RP_FILTER_ORIG_FILE"
  fi

  # Set rp_filter to loose mode on all interfaces so packets with Pod source
  # IPs are not dropped regardless of which interface they arrive on
  for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 2 > "$f"
  done

  # SNAT rule — remove this block if existing node SNAT rules already
  # cover these Pod CIDRs (check: nft list ruleset / iptables -t nat -L -n -v).
  # No oifname constraint: the egress interface depends on the destination
  # route in the main routing table. Cluster-internal destinations are
  # excluded to avoid masquerading OVN overlay traffic.
  nft -f - <<EOF
table inet ${NFT_TABLE_EGRESS}
flush table inet ${NFT_TABLE_EGRESS}
table inet ${NFT_TABLE_EGRESS} {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${POD_CIDRS} ip daddr != { ${CLUSTER_CIDRS} } masquerade
  }
}
EOF
}

cleanup_egress() {
  nft delete table inet "$NFT_TABLE_EGRESS" 2>/dev/null || true
  if [ -f "$RP_FILTER_ORIG_FILE" ]; then
    while IFS='= ' read -r key value; do
      [ -z "$key" ] && continue
      sysctl -qw "${key}=${value}" 2>/dev/null || true
    done < "$RP_FILTER_ORIG_FILE"
    rm -f "$RP_FILTER_ORIG_FILE"
  fi
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
