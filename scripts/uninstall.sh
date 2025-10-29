#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SSH_PORT=22
COMPOSE_CMD="docker compose"

source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options] <user@host> [service...]

Options:
  -p, --port <port>          SSH port to use (default: 22)
  -c, --compose-cmd <cmd>    Remote docker compose command (default: "docker compose")
  -h, --help                 Show this help message
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      [[ $# -lt 2 ]] && { echo "Missing argument for $1" >&2; exit 1; }
      SSH_PORT="$2"
      shift 2
      ;;
    -c|--compose-cmd)
      [[ $# -lt 2 ]] && { echo "Missing argument for $1" >&2; exit 1; }
      COMPOSE_CMD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    * )
      break
      ;;
  esac
 done

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

target="$1"
shift

if [[ $# -gt 0 ]]; then
  services=("$@")
else
  services=("${ALL_SERVICES[@]}")
fi

ensure_local_dependencies

for service in "${services[@]}"; do
  require_valid_service "$service"
  uninstall_service "$target" "$service"
  echo "Uninstalled $service from $target"
done
