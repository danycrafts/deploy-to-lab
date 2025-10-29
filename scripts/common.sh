#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALL_SERVICES=(mailcow nextcloud n8n pgadmin postgres qdrant nginx-proxy-manager)

: "${COMPOSE_CMD:=docker compose}"
: "${SSH_PORT:=22}"

ensure_local_dependencies() {
  local dependencies=(ssh scp rsync git)
  for dependency in "${dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      echo "Missing required command: $dependency" >&2
      exit 1
    fi
  done
}

service_dir() {
  local service="$1"
  echo "$ROOT_DIR/services/$service"
}

env_file_for_service() {
  local service="$1"
  local env_file
  env_file="$(service_dir "$service")/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "No .env file found for service '$service' at $env_file" >&2
    exit 1
  fi
  echo "$env_file"
}

is_valid_service() {
  local candidate="$1"
  local service
  for service in "${ALL_SERVICES[@]}"; do
    if [[ "$candidate" == "$service" ]]; then
      return 0
    fi
  done
  return 1
}

require_valid_service() {
  local service="$1"
  if ! is_valid_service "$service"; then
    echo "Unknown service: $service" >&2
    echo "Supported services: ${ALL_SERVICES[*]}" >&2
    exit 1
  fi
}

get_env_value() {
  local service="$1" key="$2"
  local env_file
  env_file="$(env_file_for_service "$service")"
  (
    set -euo pipefail
    set -a
    source "$env_file"
    set +a
    eval "printf '%s' \"\${$key:-}\""
  )
}

get_data_path() {
  local service="$1"
  local data_path
  data_path="$(get_env_value "$service" DATA_PATH)"
  if [[ -z "$data_path" ]]; then
    echo "DATA_PATH not set for service '$service'" >&2
    exit 1
  fi
  echo "$data_path"
}

remote_exec() {
  local target="$1"
  shift
  local command="$*"
  ssh -p "$SSH_PORT" "$target" "bash -lc $(printf '%q' "set -euo pipefail; $command")"
}

sync_compose_service() {
  local target="$1" service="$2"
  local src_dir dest_dir
  src_dir="$(service_dir "$service")"
  dest_dir="$(get_data_path "$service")"
  remote_exec "$target" "mkdir -p '$dest_dir'"
  rsync -az -e "ssh -p $SSH_PORT" "$src_dir/" "$target:$dest_dir/"
}

mailcow_generate_config() {
  local output_file="$1"
  local env_file
  env_file="$(env_file_for_service mailcow)"
  (
    set -euo pipefail
    source "$env_file"
    cat <<MAILCOW
# Managed by deploy-to-lab scripts
MAILCOW_HOSTNAME=$MAILCOW_HOSTNAME
MAILCOW_LETSENCRYPT=${MAILCOW_LETSENCRYPT:-enable}
MAILCOW_TZ=$MAILCOW_TIMEZONE
HTTP_PORT=$MAILCOW_HTTP_PORT
HTTPS_PORT=$MAILCOW_HTTPS_PORT
SKIP_CLAMD=${MAILCOW_SKIP_CLAMD:-n}
ENABLE_AUTODISCOVER=${MAILCOW_ENABLE_AUTODISCOVER:-y}
SKIP_SOLR=${MAILCOW_SKIP_SOLR:-n}
ADDITIONAL_SAN=${MAILCOW_ADDITIONAL_SAN:-}
IPV4_NETWORK=$MAILCOW_IPV4_NETWORK
REDIS_PASSWORD=$MAILCOW_REDIS_PASSWORD
DBUSER=mailcow
DBPASS=$MAILCOW_DB_PASSWORD
DBNAME=mailcow
DBHOST=mariadb
DBROOT=$MAILCOW_DB_PASSWORD
RSPAMD_PASSWORD=$MAILCOW_RSPAMD_PASSWORD
MAILCOW
  ) >"$output_file"
}

configure_mailcow() {
  local target="$1"
  local data_path
  data_path="$(get_data_path mailcow)"
  if ! ssh -p "$SSH_PORT" "$target" "[ -d '$data_path/.git' ]" >/dev/null 2>&1; then
    echo "Mailcow repository is not present at $data_path on $target" >&2
    echo "Run the install script for mailcow before configuring it." >&2
    return 1
  fi
  local tmp
  tmp=$(mktemp)
  mailcow_generate_config "$tmp"
  scp -P "$SSH_PORT" "$tmp" "$target:$data_path/mailcow.conf"
  rm -f "$tmp"
}

install_mailcow() {
  local target="$1"
  local data_path repo version
  data_path="$(get_data_path mailcow)"
  repo="$(get_env_value mailcow MAILCOW_REPOSITORY)"
  version="$(get_env_value mailcow MAILCOW_VERSION)"
  remote_exec "$target" "mkdir -p '$data_path'"
  if ! ssh -p "$SSH_PORT" "$target" "[ -d '$data_path/.git' ]" >/dev/null 2>&1; then
    remote_exec "$target" "rm -rf '$data_path'"
    remote_exec "$target" "git clone 'https://github.com/$repo.git' '$data_path'"
  fi
  remote_exec "$target" "cd '$data_path' && git fetch --tags && git checkout '$version'"
  configure_mailcow "$target"
  remote_exec "$target" "cd '$data_path' && $COMPOSE_CMD pull"
  remote_exec "$target" "cd '$data_path' && $COMPOSE_CMD up -d"
}

uninstall_mailcow() {
  local target="$1"
  local data_path
  data_path="$(get_data_path mailcow)"
  if ssh -p "$SSH_PORT" "$target" "[ -d '$data_path' ]" >/dev/null 2>&1; then
    remote_exec "$target" "cd '$data_path' && $COMPOSE_CMD down --remove-orphans"
    remote_exec "$target" "rm -rf '$data_path'"
  fi
}

configure_compose_service() {
  local target="$1" service="$2"
  sync_compose_service "$target" "$service"
}

install_compose_service() {
  local target="$1" service="$2"
  sync_compose_service "$target" "$service"
  local dest_dir
  dest_dir="$(get_data_path "$service")"
  remote_exec "$target" "cd '$dest_dir' && $COMPOSE_CMD pull"
  remote_exec "$target" "cd '$dest_dir' && $COMPOSE_CMD up -d"
}

uninstall_compose_service() {
  local target="$1" service="$2"
  local dest_dir
  dest_dir="$(get_data_path "$service")"
  if ssh -p "$SSH_PORT" "$target" "[ -d '$dest_dir' ]" >/dev/null 2>&1; then
    remote_exec "$target" "cd '$dest_dir' && $COMPOSE_CMD down --remove-orphans"
    remote_exec "$target" "rm -rf '$dest_dir'"
  fi
}

install_service() {
  local target="$1" service="$2"
  if [[ "$service" == "mailcow" ]]; then
    install_mailcow "$target"
  else
    install_compose_service "$target" "$service"
  fi
}

configure_service() {
  local target="$1" service="$2"
  if [[ "$service" == "mailcow" ]]; then
    configure_mailcow "$target"
  else
    configure_compose_service "$target" "$service"
  fi
}

uninstall_service() {
  local target="$1" service="$2"
  if [[ "$service" == "mailcow" ]]; then
    uninstall_mailcow "$target"
  else
    uninstall_compose_service "$target" "$service"
  fi
}
