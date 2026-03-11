#!/bin/bash
# Creates or deletes the ServiceAccount, ClusterRole, ClusterRoleBinding,
# and token Secret used by the egress-steering reconciler.
#
# Extracts the API server URL and CA certificate from the current kubeconfig,
# and the ServiceAccount token from the created Secret.
#
# Usage:
#   ./setup-serviceaccount.sh create -o /tmp/creds   # create SA and extract creds
#   ./setup-serviceaccount.sh delete                  # remove all SA resources

set -euo pipefail

NAMESPACE="openshift-config"
SA_NAME="egress-steering"
SECRET_NAME="egress-steering-token"
CLUSTERROLE_NAME="egress-steering-node-reader"
CLUSTERROLEBINDING_NAME="egress-steering-node-reader"
OUTPUT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/egress-steering.conf"

usage() {
  echo "Usage: $0 <create|delete> [options]"
  echo ""
  echo "Commands:"
  echo "  create  Create ServiceAccount, RBAC, and token Secret"
  echo "  delete  Remove all egress-steering SA resources"
  echo ""
  echo "Options (create only):"
  echo "  -o  Directory to write ca.crt and token files (default: current directory)"
  echo "  -n  Namespace for ServiceAccount (default: ${NAMESPACE})"
  echo "  -h  Show this help"
  exit 0
}

extract_kubeconfig_info() {
  echo "Extracting API server URL and CA from kubeconfig..."

  local api_server ca_data
  api_server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  if [ -z "$api_server" ]; then
    echo "Error: could not extract API server URL from kubeconfig" >&2
    exit 1
  fi

  ca_data=$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)
  if [ -z "$ca_data" ]; then
    echo "Error: could not extract CA certificate from kubeconfig" >&2
    echo "  Ensure certificate-authority-data is embedded in the kubeconfig" >&2
    exit 1
  fi

  echo "$ca_data" | base64 -d > "${OUTPUT_DIR}/ca.crt"
  echo "  API server: ${api_server}"
  echo "  CA cert:    ${OUTPUT_DIR}/ca.crt"

  # Update API_SERVER in the config file if it exists
  if [ -f "$CONFIG_FILE" ]; then
    sed -i "s|^API_SERVER=.*|API_SERVER=\"${api_server}\"|" "$CONFIG_FILE"
    echo "  Updated API_SERVER in ${CONFIG_FILE}"
  fi
}

create() {
  extract_kubeconfig_info

  echo "Creating ServiceAccount ${SA_NAME} in ${NAMESPACE}..."
  oc create serviceaccount "$SA_NAME" -n "$NAMESPACE" 2>/dev/null \
    || echo "  ServiceAccount already exists"

  echo "Creating ClusterRole ${CLUSTERROLE_NAME}..."
  oc create clusterrole "$CLUSTERROLE_NAME" \
    --verb=get,list --resource=nodes 2>/dev/null \
    || echo "  ClusterRole already exists"

  echo "Creating ClusterRoleBinding ${CLUSTERROLEBINDING_NAME}..."
  oc create clusterrolebinding "$CLUSTERROLEBINDING_NAME" \
    --clusterrole="$CLUSTERROLE_NAME" \
    --serviceaccount="${NAMESPACE}:${SA_NAME}" 2>/dev/null \
    || echo "  ClusterRoleBinding already exists"

  echo "Creating token Secret ${SECRET_NAME}..."
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

  # Wait for the token to be populated by the token controller
  echo "Waiting for token to be populated..."
  local token=""
  for i in $(seq 1 30); do
    token=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.data.token}' 2>/dev/null)
    if [ -n "$token" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "$token" ]; then
    echo "Error: token was not populated after 30 seconds" >&2
    exit 1
  fi

  echo "Extracting token to ${OUTPUT_DIR}..."
  oc get secret "$SECRET_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.data.token}' | base64 -d > "${OUTPUT_DIR}/token"

  chmod 600 "${OUTPUT_DIR}/token"

  echo ""
  echo "Credentials written to:"
  echo "  CA certificate: ${OUTPUT_DIR}/ca.crt"
  echo "  Token:          ${OUTPUT_DIR}/token"
  echo ""
  echo "Generate the MachineConfig with:"
  echo "  ./generate-machineconfig.sh -a ${OUTPUT_DIR}/ca.crt -k ${OUTPUT_DIR}/token"
}

delete() {
  echo "Deleting egress-steering SA resources..."
  oc delete clusterrolebinding "$CLUSTERROLEBINDING_NAME" 2>/dev/null \
    && echo "  Deleted ClusterRoleBinding" || echo "  ClusterRoleBinding not found"
  oc delete clusterrole "$CLUSTERROLE_NAME" 2>/dev/null \
    && echo "  Deleted ClusterRole" || echo "  ClusterRole not found"
  oc delete secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null \
    && echo "  Deleted Secret" || echo "  Secret not found"
  oc delete serviceaccount "$SA_NAME" -n "$NAMESPACE" 2>/dev/null \
    && echo "  Deleted ServiceAccount" || echo "  ServiceAccount not found"
  echo "Done."
}

# Parse command
COMMAND="${1:-}"
shift || true

while getopts "o:n:h" opt; do
  case "$opt" in
    o) OUTPUT_DIR="$OPTARG" ;;
    n) NAMESPACE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

case "$COMMAND" in
  create)
    OUTPUT_DIR="${OUTPUT_DIR:-.}"
    mkdir -p "$OUTPUT_DIR"
    create
    ;;
  delete)
    delete
    ;;
  *)
    usage
    ;;
esac
