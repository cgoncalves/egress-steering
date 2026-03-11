#!/bin/bash
# Generates the final MachineConfig with base64-encoded script and config.
#
# Usage:
#   ./generate-machineconfig.sh
#   ./generate-machineconfig.sh -o custom-output.yaml
#   ./generate-machineconfig.sh -c my-config.conf -o custom-output.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRIPT_FILE="${SCRIPT_DIR}/egress-steering-reconciler.sh"
CONFIG_FILE="${SCRIPT_DIR}/egress-steering.conf"
TEMPLATE_FILE="${SCRIPT_DIR}/machineconfig-egress-steering.yaml"
OUTPUT_FILE="${SCRIPT_DIR}/machineconfig-egress-steering-final.yaml"

usage() {
  echo "Usage: $0 [-s script] [-c config] [-t template] [-o output]"
  echo ""
  echo "Options:"
  echo "  -s  Path to reconciler script   (default: ${SCRIPT_FILE})"
  echo "  -c  Path to config file         (default: ${CONFIG_FILE})"
  echo "  -t  Path to MachineConfig template (default: ${TEMPLATE_FILE})"
  echo "  -o  Path to output file         (default: ${OUTPUT_FILE})"
  echo "  -h  Show this help"
  exit 0
}

while getopts "s:c:t:o:h" opt; do
  case "$opt" in
    s) SCRIPT_FILE="$OPTARG" ;;
    c) CONFIG_FILE="$OPTARG" ;;
    t) TEMPLATE_FILE="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

for f in "$SCRIPT_FILE" "$CONFIG_FILE" "$TEMPLATE_FILE"; do
  if [ ! -f "$f" ]; then
    echo "Error: file not found: ${f}" >&2
    exit 1
  fi
done

BASE64_SCRIPT=$(base64 -w0 < "$SCRIPT_FILE")
BASE64_CONFIG=$(base64 -w0 < "$CONFIG_FILE")

sed \
  -e "s|<BASE64_ENCODED_SCRIPT>|${BASE64_SCRIPT}|" \
  -e "s|<BASE64_ENCODED_CONFIG>|${BASE64_CONFIG}|" \
  "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Generated: ${OUTPUT_FILE}"
