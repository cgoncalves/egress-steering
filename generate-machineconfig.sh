#!/bin/bash
# Generates the final MachineConfig with base64-encoded script, config,
# ServiceAccount CA certificate, and token.
#
# Usage:
#   ./generate-machineconfig.sh -a ca.crt -k token
#   ./generate-machineconfig.sh -a ca.crt -k token -c my-config.conf -o custom-output.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRIPT_FILE="${SCRIPT_DIR}/egress-steering-reconciler.sh"
CONFIG_FILE="${SCRIPT_DIR}/egress-steering.conf"
TEMPLATE_FILE="${SCRIPT_DIR}/machineconfig-egress-steering.yaml"
OUTPUT_FILE="${SCRIPT_DIR}/machineconfig-egress-steering-final.yaml"
CA_FILE=""
TOKEN_FILE=""

usage() {
  echo "Usage: $0 -a <ca-cert> -k <token-file> [options]"
  echo ""
  echo "Required:"
  echo "  -a  Path to API server CA certificate"
  echo "  -k  Path to ServiceAccount token file"
  echo ""
  echo "Options:"
  echo "  -s  Path to reconciler script      (default: ${SCRIPT_FILE})"
  echo "  -c  Path to config file            (default: ${CONFIG_FILE})"
  echo "  -t  Path to MachineConfig template (default: ${TEMPLATE_FILE})"
  echo "  -o  Path to output file            (default: ${OUTPUT_FILE})"
  echo "  -h  Show this help"
  exit 0
}

while getopts "s:c:t:o:a:k:h" opt; do
  case "$opt" in
    s) SCRIPT_FILE="$OPTARG" ;;
    c) CONFIG_FILE="$OPTARG" ;;
    t) TEMPLATE_FILE="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    a) CA_FILE="$OPTARG" ;;
    k) TOKEN_FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$CA_FILE" ] || [ -z "$TOKEN_FILE" ]; then
  echo "Error: -a <ca-cert> and -k <token-file> are required" >&2
  echo "" >&2
  usage
fi

for f in "$SCRIPT_FILE" "$CONFIG_FILE" "$TEMPLATE_FILE" "$CA_FILE" "$TOKEN_FILE"; do
  if [ ! -f "$f" ]; then
    echo "Error: file not found: ${f}" >&2
    exit 1
  fi
done

BASE64_SCRIPT=$(base64 -w0 < "$SCRIPT_FILE")
BASE64_CONFIG=$(base64 -w0 < "$CONFIG_FILE")
BASE64_CA=$(base64 -w0 < "$CA_FILE")
BASE64_TOKEN=$(base64 -w0 < "$TOKEN_FILE")

sed \
  -e "s|<BASE64_ENCODED_SCRIPT>|${BASE64_SCRIPT}|" \
  -e "s|<BASE64_ENCODED_CONFIG>|${BASE64_CONFIG}|" \
  -e "s|<BASE64_ENCODED_CA>|${BASE64_CA}|" \
  -e "s|<BASE64_ENCODED_TOKEN>|${BASE64_TOKEN}|" \
  "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Generated: ${OUTPUT_FILE}"
