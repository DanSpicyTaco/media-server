#!/usr/bin/env bash
# One-shot service initialisation for the media server stack.
# Idempotent: safe to re-run; skips steps that are already configured.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INIT_DIR="${ROOT_DIR}/config/init"
STATE_FILE="${ROOT_DIR}/config/.init-state"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "${ROOT_DIR}/.env" && set +a
fi

log() { echo "[init] $*"; }
die() { echo "[init] ERROR: $*" >&2; exit 1; }

mark_done() { echo "$1" >> "${STATE_FILE}"; }
is_done() { [[ -f "${STATE_FILE}" ]] && grep -qxF "$1" "${STATE_FILE}"; }

wait_for_http() {
  local url="$1" label="$2" retries="${3:-60}" delay="${4:-5}"
  log "Waiting for ${label} at ${url}..."
  for ((i = 1; i <= retries; i++)); do
    if curl -sf "${url}" >/dev/null 2>&1; then
      log "${label} is ready"
      return 0
    fi
    sleep "${delay}"
  done
  die "${label} did not become ready (${url})"
}

# --- Jellyfin -----------------------------------------------------------------

setup_jellyfin() {
  if is_done "jellyfin"; then
    log "Jellyfin already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${JELLYFIN_PORT}"
  wait_for_http "${base}/System/Info/Public" "Jellyfin"

  local wizard_done
  wizard_done="$(curl -sf "${base}/System/Info/Public" | python3 -c "import sys,json; print(json.load(sys.stdin).get('StartupWizardCompleted', False))")"

  local token=""
  if [[ "${wizard_done}" != "True" ]]; then
    log "Creating Jellyfin admin user"
    curl -sf -X POST "${base}/Users/New" \
      -H "Content-Type: application/json" \
      -d "{\"Name\":\"${JELLYFIN_USERNAME}\",\"Password\":\"${JELLYFIN_PASSWORD}\"}" >/dev/null || true

    curl -sf -X POST "${base}/Startup/Complete" \
      -H "Content-Type: application/json" \
      -d "{}" >/dev/null || true
  fi

  token="$(curl -sf -X POST "${base}/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"init\", Device=\"init\", DeviceId=\"init-script\", Version=\"1.0.0\"" \
    -d "{\"Username\":\"${JELLYFIN_USERNAME}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])")"

  [[ -n "${token}" ]] || die "Failed to obtain Jellyfin access token"

  local auth_header="Authorization: MediaBrowser Token=${token}"

  local existing_libs
  existing_libs="$(curl -sf "${base}/Library/VirtualFolders" -H "${auth_header}" || echo "[]")"

  if ! echo "${existing_libs}" | python3 -c "import sys,json; libs=json.load(sys.stdin); sys.exit(0 if any(l.get('Name')=='Movies' for l in libs) else 1)" 2>/dev/null; then
    log "Creating Jellyfin Movies library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/movies"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if ! echo "${existing_libs}" | python3 -c "import sys,json; libs=json.load(sys.stdin); sys.exit(0 if any(l.get('Name')=='TV Shows' for l in libs) else 1)" 2>/dev/null; then
    log "Creating Jellyfin TV Shows library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=TV%20Shows&collectionType=tvshows&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/tv"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
    log "Generating Jellyfin API key for Seerr"
    JELLYFIN_API_KEY="$(curl -sf -X POST "${base}/Auth/Keys?app=Seerr" \
      -H "${auth_header}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessToken'])")"
    if grep -q '^JELLYFIN_API_KEY=' "${ROOT_DIR}/.env"; then
      sed -i "s|^JELLYFIN_API_KEY=.*|JELLYFIN_API_KEY=${JELLYFIN_API_KEY}|" "${ROOT_DIR}/.env"
    else
      echo "JELLYFIN_API_KEY=${JELLYFIN_API_KEY}" >> "${ROOT_DIR}/.env"
    fi
  fi

  mark_done "jellyfin"
}

# --- *arr apps ----------------------------------------------------------------

setup_radarr() {
  if is_done "radarr"; then
    log "Radarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${RADARR_PORT}"
  wait_for_http "${base}/ping" "Radarr"

  local config
  config="$(cat "${INIT_DIR}/radarr.json")"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['downloadClient']))")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['namingConfig']))")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${RADARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | python3 -c "import sys,json; roots=json.load(sys.stdin); sys.exit(0 if any(r.get('path')=='/data/media/movies' for r in roots) else 1)" 2>/dev/null; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${RADARR_API_KEY}" \
      -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['rootFolder']))")" >/dev/null
  fi

  mark_done "radarr"
}

setup_sonarr() {
  if is_done "sonarr"; then
    log "Sonarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${SONARR_PORT}"
  wait_for_http "${base}/ping" "Sonarr"

  local config
  config="$(cat "${INIT_DIR}/sonarr.json")"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['downloadClient']))")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['namingConfig']))")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${SONARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | python3 -c "import sys,json; roots=json.load(sys.stdin); sys.exit(0 if any(r.get('path')=='/data/media/tv' for r in roots) else 1)" 2>/dev/null; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${SONARR_API_KEY}" \
      -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['rootFolder']))")" >/dev/null
  fi

  mark_done "sonarr"
}

setup_prowlarr() {
  if is_done "prowlarr"; then
    log "Prowlarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${PROWLARR_PORT}"
  wait_for_http "${base}/ping" "Prowlarr"

  local config
  config="$(cat "${INIT_DIR}/prowlarr.json")"

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['radarrApplicationConfig']))")" >/dev/null || true

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['sonarrApplicationConfig']))")" >/dev/null || true

  mark_done "prowlarr"
}

# --- Seerr --------------------------------------------------------------------

setup_seerr() {
  if is_done "seerr"; then
    log "Seerr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${SEERR_PORT}"
  wait_for_http "${base}/api/v1/status" "Seerr"

  # Reload .env in case Jellyfin step appended JELLYFIN_API_KEY
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a && source "${ROOT_DIR}/.env" && set +a
  fi

  [[ -n "${JELLYFIN_API_KEY:-}" ]] || die "JELLYFIN_API_KEY is required for Seerr setup"

  local session_cookie=""
  local register_status
  register_status="$(curl -s -o /dev/null -w "%{http_code}" -X POST "${base}/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${SEERR_ADMIN_EMAIL}\",\"password\":\"${SEERR_ADMIN_PASSWORD}\",\"username\":\"${SEERR_ADMIN_USERNAME}\"}")"

  if [[ "${register_status}" == "200" || "${register_status}" == "201" ]]; then
    log "Created Seerr admin account"
  fi

  local auth_response
  auth_response="$(curl -si -X POST "${base}/api/v1/auth/local" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${SEERR_ADMIN_EMAIL}\",\"password\":\"${SEERR_ADMIN_PASSWORD}\"}")"

  session_cookie="$(echo "${auth_response}" | grep -i '^set-cookie:' | head -1 | sed 's/[Ss]et-[Cc]ookie: //;s/;.*//')"
  [[ -n "${session_cookie}" ]] || die "Failed to authenticate with Seerr"

  local config
  config="$(cat "${INIT_DIR}/seerr.json")"

  curl -sf -X POST "${base}/api/v1/settings/jellyfin" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(echo "${config}" | JELLYFIN_API_KEY="${JELLYFIN_API_KEY}" python3 -c "
import json, os, sys
cfg = json.load(sys.stdin)
cfg['jellyfinSettings']['apiKey'] = os.environ['JELLYFIN_API_KEY']
print(json.dumps(cfg['jellyfinSettings']))
")" >/dev/null

  curl -sf -X POST "${base}/api/v1/settings/main" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['applicationSettings']))")" >/dev/null

  curl -sf -X POST "${base}/api/v1/settings/radarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['radarrServer']))")" >/dev/null || true

  curl -sf -X POST "${base}/api/v1/settings/sonarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(echo "${config}" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['sonarrServer']))")" >/dev/null || true

  curl -sf -X POST "${base}/api/v1/settings/initialize" \
    -H "Cookie: ${session_cookie}" >/dev/null

  mark_done "seerr"
  log "Seerr initialisation complete"
}

main() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  touch "${STATE_FILE}"

  setup_jellyfin
  setup_radarr
  setup_sonarr
  setup_prowlarr
  setup_seerr

  log "All services initialised"
}

main "$@"
