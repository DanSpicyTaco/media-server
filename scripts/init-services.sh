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

log() { echo "[init] $*" >&2; }
die() { echo "[init] ERROR: $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (installed by the playbook's prerequisites task)"

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

  # Wait for Jellyfin to serve valid JSON
  log "Waiting for Jellyfin at ${base}/System/Info/Public..."
  local info_json=""
  for ((i = 1; i <= 60; i++)); do
    info_json="$(curl -sf "${base}/System/Info/Public" 2>/dev/null || true)"
    if echo "${info_json}" | jq -e . >/dev/null 2>&1; then
      log "Jellyfin is ready"
      break
    fi
    info_json=""
    sleep 5
  done
  [[ -n "${info_json}" ]] || die "Jellyfin did not become ready"

  local wizard_done
  wizard_done="$(echo "${info_json}" | jq -r '.StartupWizardCompleted')"

  if [[ "${wizard_done}" != "true" ]]; then
    log "Running Jellyfin startup wizard"
    curl -sf "${base}/Startup/FirstUser" >/dev/null
    curl -sf -X POST "${base}/Startup/User" \
      -H "Content-Type: application/json" \
      -d "{\"Name\":\"${JELLYFIN_USERNAME}\",\"Password\":\"${JELLYFIN_PASSWORD}\"}" >/dev/null
    curl -sf -X POST "${base}/Startup/Complete" \
      -H "Content-Type: application/json" \
      -d "{}" >/dev/null
    log "Jellyfin wizard complete"
  fi

  local token=""
  local auth_response
  auth_response="$(curl -sf -X POST "${base}/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"init\", Device=\"init\", DeviceId=\"init-script\", Version=\"1.0.0\"" \
    -d "{\"Username\":\"${JELLYFIN_USERNAME}\",\"Pw\":\"${JELLYFIN_PASSWORD}\"}" 2>/dev/null || true)"
  log "Auth response: ${auth_response}"
  token="$(echo "${auth_response}" | jq -r '.AccessToken // empty' || true)"

  [[ -n "${token}" ]] || die "Failed to obtain Jellyfin access token"

  local auth_header="Authorization: MediaBrowser Token=${token}"

  local existing_libs
  existing_libs="$(curl -sf "${base}/Library/VirtualFolders" -H "${auth_header}" || echo "[]")"

  if ! echo "${existing_libs}" | jq -e 'any(.[]; .Name == "Movies")' >/dev/null 2>&1; then
    log "Creating Jellyfin Movies library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/movies"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if ! echo "${existing_libs}" | jq -e 'any(.[]; .Name == "TV Shows")' >/dev/null 2>&1; then
    log "Creating Jellyfin TV Shows library"
    curl -sf -X POST "${base}/Library/VirtualFolders?name=TV%20Shows&collectionType=tvshows&refreshLibrary=false" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      -d '{"LibraryOptions":{"PathInfos":[{"Path":"/data/media/tv"}],"EnableRealtimeMonitor":true}}' >/dev/null
  fi

  if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
    log "Generating Jellyfin API key for Seerr"
    curl -sf -X POST "${base}/Auth/Keys?app=Seerr" \
      -H "${auth_header}" >/dev/null
    local keys_response
    keys_response="$(curl -sf "${base}/Auth/Keys" -H "X-Emby-Token: ${token}" || true)"
    log "Auth/Keys response: ${keys_response}"
    JELLYFIN_API_KEY="$(echo "${keys_response}" | jq -r '[.Items[] | select(.AppName == "Seerr")] | last.AccessToken // empty' || true)"
    [[ -n "${JELLYFIN_API_KEY}" ]] || die "Failed to generate Jellyfin API key"
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
  local config="${INIT_DIR}/radarr.json"
  wait_for_http "${base}/ping" "Radarr"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(jq -c '.downloadClient' "${config}")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    -d "$(jq -c '.namingConfig' "${config}")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${RADARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | jq -e 'any(.[]; .path == "/data/media/movies")' >/dev/null 2>&1; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${RADARR_API_KEY}" \
      -d "$(jq -c '.rootFolder' "${config}")" >/dev/null
  fi

  mark_done "radarr"
}

setup_sonarr() {
  if is_done "sonarr"; then
    log "Sonarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${SONARR_PORT}"
  local config="${INIT_DIR}/sonarr.json"
  wait_for_http "${base}/ping" "Sonarr"

  curl -sf -X POST "${base}/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(jq -c '.downloadClient' "${config}")" >/dev/null || true

  curl -sf -X PUT "${base}/api/v3/config/naming/1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    -d "$(jq -c '.namingConfig' "${config}")" >/dev/null || true

  local existing_roots
  existing_roots="$(curl -sf "${base}/api/v3/rootfolder" -H "X-Api-Key: ${SONARR_API_KEY}" || echo "[]")"
  if ! echo "${existing_roots}" | jq -e 'any(.[]; .path == "/data/media/tv")' >/dev/null 2>&1; then
    curl -sf -X POST "${base}/api/v3/rootfolder" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${SONARR_API_KEY}" \
      -d "$(jq -c '.rootFolder' "${config}")" >/dev/null
  fi

  mark_done "sonarr"
}

setup_prowlarr() {
  if is_done "prowlarr"; then
    log "Prowlarr already initialised, skipping"
    return
  fi

  local base="http://127.0.0.1:${PROWLARR_PORT}"
  local config="${INIT_DIR}/prowlarr.json"
  wait_for_http "${base}/ping" "Prowlarr"

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(jq -c '.radarrApplicationConfig' "${config}")" >/dev/null || true

  curl -sf -X POST "${base}/api/v1/applications" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${PROWLARR_API_KEY}" \
    -d "$(jq -c '.sonarrApplicationConfig' "${config}")" >/dev/null || true

  mark_done "prowlarr"
}

# --- Codec policy (block x265/HEVC) --------------------------------------------
# Chromecast (non-Ultra) can only direct-play H.264. Create an "x265/HEVC"
# custom format, score it -10000 in every quality profile, and set the
# minimum custom format score to 0 so x265/HEVC releases are never grabbed.

apply_codec_policy() {
  local app="$1" base="$2" api_key="$3" config_file="$4"
  local step="${app}-codec-policy"

  if is_done "${step}"; then
    log "${app} codec policy already applied, skipping"
    return
  fi

  wait_for_http "${base}/ping" "${app}"

  local cf_payload cf_name
  cf_payload="$(jq -c '.customFormat' "${config_file}")"
  cf_name="$(echo "${cf_payload}" | jq -r '.name')"

  # Create the custom format if it doesn't already exist
  local existing_cfs cf_id
  existing_cfs="$(curl -sf "${base}/api/v3/customformat" -H "X-Api-Key: ${api_key}" || echo "[]")"
  cf_id="$(echo "${existing_cfs}" | jq -r --arg name "${cf_name}" '[.[] | select(.name == $name)] | first.id // empty')"

  if [[ -z "${cf_id}" ]]; then
    log "Creating ${app} custom format '${cf_name}'"
    cf_id="$(curl -sf -X POST "${base}/api/v3/customformat" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${api_key}" \
      -d "${cf_payload}" | jq -r '.id // empty')"
  fi
  [[ -n "${cf_id}" ]] || die "Failed to create ${app} custom format '${cf_name}'"

  # Score it -10000 in every quality profile and refuse anything below 0
  local updated_profiles
  updated_profiles="$(curl -sf "${base}/api/v3/qualityprofile" -H "X-Api-Key: ${api_key}" \
    | jq -c --argjson cf_id "${cf_id}" \
        '.[] | (.formatItems[] | select(.format == $cf_id)).score = -10000 | .minFormatScore = 0')"

  local profile profile_id
  while IFS= read -r profile; do
    [[ -n "${profile}" ]] || continue
    profile_id="$(echo "${profile}" | jq -r '.id')"
    log "Scoring '${cf_name}' in ${app} quality profile ${profile_id}"
    curl -sf -X PUT "${base}/api/v3/qualityprofile/${profile_id}" \
      -H "Content-Type: application/json" \
      -H "X-Api-Key: ${api_key}" \
      -d "${profile}" >/dev/null
  done <<< "${updated_profiles}"

  mark_done "${step}"
  log "${app} codec policy applied"
}

# --- Seerr --------------------------------------------------------------------

setup_seerr() {
  if is_done "seerr"; then
    log "Seerr already initialised, skipping"
    return
  fi

  # Reload .env in case Jellyfin step appended JELLYFIN_API_KEY
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a && source "${ROOT_DIR}/.env" && set +a
  fi

  [[ -n "${JELLYFIN_API_KEY:-}" ]] || die "JELLYFIN_API_KEY is required for Seerr setup"

  local base="http://127.0.0.1:${SEERR_PORT}"
  local settings_file="${ROOT_DIR}/seerr/settings.json"
  local init_config="${INIT_DIR}/seerr.json"

  [[ -f "${settings_file}" ]] || die "Seerr settings.json not found at ${settings_file}"

  # Step 1: Stop Seerr, write a bootstrap settings.json with csrfProtection
  # disabled and initialized=false so Seerr runs its DB migrations on next
  # start without overwriting our Jellyfin config.
  #
  # Jellyfin config is cleared so the auth endpoint runs its full first-run
  # path, which both authenticates AND stores connection details in one step.
  # If we pre-set these, Seerr's guard logic returns 500 "Jellyfin login is
  # disabled". mediaServerType 4 = NOT_CONFIGURED, letting the auth endpoint
  # handle first-run setup.
  log "Stopping Seerr to write bootstrap settings"
  docker stop seerr >/dev/null

  local bootstrap_tmp
  bootstrap_tmp="$(mktemp)"
  jq '.jellyfin.ip = ""
      | .jellyfin.apiKey = ""
      | .main.mediaServerType = 4
      | .main.mediaServerLogin = true
      | .network.csrfProtection = false
      | .public.initialized = false' "${settings_file}" > "${bootstrap_tmp}"
  # Overwrite in place (cat, not mv) to preserve the file's owner — Seerr
  # runs as UID 1000 and must be able to write its own settings.
  cat "${bootstrap_tmp}" > "${settings_file}"
  rm -f "${bootstrap_tmp}"
  log "Bootstrap settings written"

  log "Starting Seerr to run DB migrations"
  docker start seerr >/dev/null
  wait_for_http "${base}/api/v1/status" "Seerr"

  # Wait for DB migrations to complete — the status endpoint returns 200 before
  # migrations finish, so hitting auth/jellyfin too early gives a 500.
  log "Waiting for Seerr DB migrations to complete"
  sleep 15

  # Step 2: Authenticate via Jellyfin to create the first admin user record.
  # The endpoint expects "hostname" (not "ip") as the connection field.
  # serverType: 2 = Jellyfin (1=Plex, 2=Jellyfin, 3=Emby, 4=NotConfigured)
  log "Authenticating with Seerr via Jellyfin"
  local auth_response session_cookie
  auth_response="$(curl -si -X POST "${base}/api/v1/auth/jellyfin" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${JELLYFIN_USERNAME}\",\"password\":\"${JELLYFIN_PASSWORD}\",\"hostname\":\"jellyfin\",\"port\":${JELLYFIN_PORT},\"useSsl\":false,\"urlBase\":\"\",\"serverType\":2}" \
    2>/dev/null || true)"
  log "Seerr auth status: $(echo "${auth_response}" | head -1)"
  session_cookie="$(echo "${auth_response}" | tr -d '\r' | grep -i '^set-cookie:' | head -1 | sed 's/[Ss]et-[Cc]ookie: //;s/;.*//' || true)"
  [[ -n "${session_cookie}" ]] || die "Failed to authenticate with Seerr — check Jellyfin credentials and connectivity"

  log "Got Seerr session cookie"

  # Step 3: Push full config via the API now that we have a valid session
  log "Configuring Seerr Jellyfin settings"
  local jellyfin_result
  jellyfin_result="$(curl -s -X POST "${base}/api/v1/settings/jellyfin" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c --arg key "${JELLYFIN_API_KEY}" \
          '.jellyfinSettings | .apiKey = $key | .hostname //= "jellyfin"' "${init_config}")")"
  log "Jellyfin settings result: ${jellyfin_result}"

  log "Configuring Seerr main settings"
  local main_result
  main_result="$(curl -s -X POST "${base}/api/v1/settings/main" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.applicationSettings' "${init_config}")")"
  log "Main settings result: ${main_result}"

  log "Configuring Seerr Radarr server"
  local radarr_result
  radarr_result="$(curl -s -X POST "${base}/api/v1/settings/radarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.radarrServer' "${init_config}")" || true)"
  log "Radarr settings result: ${radarr_result}"

  log "Configuring Seerr Sonarr server"
  local sonarr_result
  sonarr_result="$(curl -s -X POST "${base}/api/v1/settings/sonarr" \
    -H "Content-Type: application/json" \
    -H "Cookie: ${session_cookie}" \
    -d "$(jq -c '.sonarrServer' "${init_config}")" || true)"
  log "Sonarr settings result: ${sonarr_result}"

  log "Marking Seerr as initialized"
  local init_result
  init_result="$(curl -s -X POST "${base}/api/v1/settings/initialize" \
    -H "Cookie: ${session_cookie}")"
  log "Initialize result: ${init_result}"

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
  apply_codec_policy "radarr" "http://127.0.0.1:${RADARR_PORT}" "${RADARR_API_KEY}" "${INIT_DIR}/radarr.json"
  apply_codec_policy "sonarr" "http://127.0.0.1:${SONARR_PORT}" "${SONARR_API_KEY}" "${INIT_DIR}/sonarr.json"
  setup_seerr

  log "All services initialised"
}

main "$@"
