#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# shelley-opencode-switch.sh
#
# Purpose:
#   - Switch between Shelley and OpenCode on an exe.dev VM.
#   - Automatically installs opencode if missing.
#   - On -start:
#       * stop shelley and shelley.socket (systemd)
#       * bootstrap OpenCode CLI with latest Shelley project context
#       * start OpenCode Web UI on port 9999
#   - On -stop:
#       * stop OpenCode Web UI
#       * restart shelley
###############################################################################

PORT="${PORT:-9999}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/shelley-opencode-switch"
PIDFILE="${PIDFILE:-${CACHE_DIR}/opencode.pid}"
LOGFILE="${LOGFILE:-${CACHE_DIR}/opencode.log}"

PROJECT_DIR="${PROJECT_DIR:-$(pwd -P)}"
SHELLEY_DB="${SHELLEY_DB:-}"
FORCE_BOOTSTRAP="false"
MAX_MESSAGES="${MAX_MESSAGES:-80}"

STATE_DIR_REL=".opencode-handoff"
STATE_DIR=""
HANDOFF_MD=""
HANDOFF_JSONL=""
BOOTSTRAP_MARKER=""
BOOTSTRAP_PROMPT_FILE=""

usage() {
  cat <<'USAGE'
Usage:
  $0 -start [options]
  $0 -stop

Options:
  --project-dir PATH      Project directory to use (default: current directory)
  --shelley-db PATH       Path to Shelley sqlite database (REQUIRED for bootstrap)
  --force-bootstrap       Recreate bootstrap even if marker exists
  --max-messages N        Recent Shelley messages to include (default: 80)
  --port N                OpenCode port (default: 9999)
  -h, --help              Show this help
USAGE
}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ensure_opencode_installed() {
  if ! command -v opencode >/dev/null 2>&1; then
    log "opencode not found. Installing via curl..."
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v opencode >/dev/null 2>&1; then
      die "Installation failed. Please install opencode manually."
    fi
  fi
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

canon_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1"
  fi
}

setup_paths() {
  PROJECT_DIR="$(canon_path "${PROJECT_DIR}")"
  STATE_DIR="${PROJECT_DIR}/${STATE_DIR_REL}"
  HANDOFF_MD="${STATE_DIR}/shelley-bootstrap.md"
  HANDOFF_JSONL="${STATE_DIR}/shelley-bootstrap.jsonl"
  BOOTSTRAP_MARKER="${STATE_DIR}/opencode-bootstrap.done"
  BOOTSTRAP_PROMPT_FILE="${STATE_DIR}/bootstrap-prompt.txt"
}

require_sudo_for_systemctl() {
  if ! sudo -n true 2>/dev/null; then
    die "sudo access required for systemctl (shelley service control)."
  fi
}

require_opencode_auth() {
  if ! opencode auth status >/dev/null 2>&1; then
    log "WARNING: Could not verify OpenCode auth status. If operations fail, run 'opencode auth' manually."
  fi
}

stop_shelley() {
  if systemctl is-active --quiet shelley; then
    log "Stopping shelley service..."
    sudo systemctl stop shelley shelley.socket
  else
    log "shelley service already stopped."
  fi
}

start_shelley() {
  log "Restoring shelley service..."
  sudo systemctl start shelley shelley.socket
}

stop_opencode_webui() {
  log "Stopping OpenCode Web UI if running..."
  if [[ -f "${PIDFILE}" ]]; then
    local pid
    pid=$(cat "${PIDFILE}")
    kill "${pid}" 2>/dev/null || true
    rm -f "${PIDFILE}"
  fi
  pkill -f "opencode serve" || true
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

write_handoff_from_shelley() {
  log "Extracting context from Shelley DB: ${SHELLEY_DB}"
  mkdir -p "${STATE_DIR}"

  local conv_id
  conv_id=$(sqlite3 -noheader -batch "${SHELLEY_DB}" "
    SELECT conversation_id FROM conversations
    WHERE cwd = '$(sql_escape "${PROJECT_DIR}")'
    AND COALESCE(archived, 0) = 0 ORDER BY updated_at DESC LIMIT 1;")

  if [[ -z "${conv_id}" ]]; then
    log "No matching Shelley conversation found for project: ${PROJECT_DIR}"
    return 1
  fi

  sqlite3 -json "${SHELLEY_DB}" "
    SELECT sequence_id, type, created_at, COALESCE(user_data, '{}') as user_data, COALESCE(llm_data, '{}') as llm_data
    FROM messages WHERE conversation_id = '${conv_id}'
    AND COALESCE(excluded_from_context, 0) = 0
    ORDER BY sequence_id DESC LIMIT ${MAX_MESSAGES};" \
    | jq 'reverse' | jq -c '.[]' > "${HANDOFF_JSONL}"

  cat > "${HANDOFF_MD}" <<EOF
# Shelley -> OpenCode Handoff
Generated: $(date)
Project: ${PROJECT_DIR}

Review the attached ${HANDOFF_JSONL} for full message history.
EOF
  log "Context files written to ${STATE_DIR}"
  return 0
}

bootstrap_opencode() {
  if [[ "${FORCE_BOOTSTRAP}" != "true" && -f "${BOOTSTRAP_MARKER}" ]]; then
    log "Bootstrap marker exists. Skipping CLI stage."
    return
  fi

  if ! write_handoff_from_shelley; then
    log "Skipping bootstrap (no Shelley history found)."
    return
  fi

  cat > "${BOOTSTRAP_PROMPT_FILE}" <<EOF
Read ${HANDOFF_MD} and ${HANDOFF_JSONL}.
Absorb the project context, state current progress, and propose next steps.
Do not modify files yet.
EOF

  log "Running OpenCode CLI Bootstrap..."
  (
    cd "${PROJECT_DIR}"
    opencode run "$(cat "${BOOTSTRAP_PROMPT_FILE}")"
  )

  touch "${BOOTSTRAP_MARKER}"
}

start_opencode_webui() {
  log "Starting OpenCode Web UI on port ${PORT}..."
  mkdir -p "${CACHE_DIR}"

  if ss -tlnp | grep -q ":${PORT}[^0-9]"; then
    die "Port ${PORT} is still in use."
  fi

  touch "${LOGFILE}"
  (
    cd "${PROJECT_DIR}"
    nohup opencode serve --port "${PORT}" >> "${LOGFILE}" 2>&1 &
    echo $! > "${PIDFILE}"
  )

  local started=0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if [[ -f "${PIDFILE}" ]] && kill -0 "
$(cat "${PIDFILE}")" 2>/dev/null; then
      started=1
      break
    fi
  done

  if [[ "${started}" -eq 1 ]]; then
    log "OpenCode Web UI active at http://localhost:${PORT}"
  else
    die "OpenCode failed to start after 10s. See ${LOGFILE}"
  fi
}

main() {
  local ACTION=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -start)            ACTION="-start"; shift ;;  
      -stop)             ACTION="-stop";  shift ;;  
      --project-dir)     PROJECT_DIR="$2"; shift 2 ;;  
      --shelley-db)      SHELLEY_DB="$2";  shift 2 ;;  
      --force-bootstrap) FORCE_BOOTSTRAP="true"; shift ;;  
      --max-messages)    MAX_MESSAGES="$2"; shift 2 ;;  
      --port)            PORT="$2"; shift 2 ;;  
      -h|--help)         usage; exit 0 ;;  
      *)                 die "Unknown argument: $1" ;;  
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; exit 1; }
  setup_paths

  if [[ "${ACTION}" == "-start" ]]; then
    [[ -n "${SHELLEY_DB}" ]] || die "--shelley-db is required for -start"
    ensure_opencode_installed
    require_cmd sqlite3
    require_cmd jq

    require_sudo_for_systemctl
    require_opencode_auth

    stop_opencode_webui
    stop_shelley
    bootstrap_opencode
    start_opencode_webui

  elif [[ "${ACTION}" == "-stop" ]]; then
    require_sudo_for_systemctl
    stop_opencode_webui
    start_shelley
  fi
}

main "$@"
