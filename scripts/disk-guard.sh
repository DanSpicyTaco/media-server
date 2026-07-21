#!/bin/sh
# Disk-space guard: stops every actively-downloading qBittorrent torrent if
# free space on the mounted content volume drops below the threshold.
# Never deletes anything — only pauses new writes until you free up space.
set -eu

apk add --no-cache curl jq >/dev/null 2>&1

THRESHOLD_GB="${DISK_GUARD_THRESHOLD_GB:-10}"
CHECK_INTERVAL="${DISK_GUARD_CHECK_INTERVAL_SECONDS:-120}"
CHECK_PATH="/content"
QB_URL="${QBITTORRENT_URL:-http://qbittorrent:8080}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

log "disk-guard started: threshold=${THRESHOLD_GB}GB interval=${CHECK_INTERVAL}s path=${CHECK_PATH}"

while true; do
    free_kb=$(df -Pk "$CHECK_PATH" | tail -1 | awk '{print $4}')
    free_gb=$(( free_kb / 1024 / 1024 ))

    if [ "$free_gb" -lt "$THRESHOLD_GB" ]; then
        cookie_jar=$(mktemp)
        curl -s -c "$cookie_jar" -X POST "${QB_URL}/api/v2/auth/login" \
            -H "Referer: ${QB_URL}" \
            --data "username=${QBITTORRENT_USERNAME}&password=${QBITTORRENT_PASSWORD}" >/dev/null

        active_hashes=$(curl -s -b "$cookie_jar" "${QB_URL}/api/v2/torrents/info" \
            | jq -r '[.[] | select(.state as $s | ["downloading","stalledDL","metaDL","checkingDL","forcedDL","allocating"] | index($s))] | map(.hash) | join("|")')

        if [ -n "$active_hashes" ]; then
            curl -s -b "$cookie_jar" -X POST "${QB_URL}/api/v2/torrents/stop" \
                -H "Referer: ${QB_URL}" \
                --data "hashes=${active_hashes}" >/dev/null
            log "CRITICAL: ${free_gb}GB free (threshold ${THRESHOLD_GB}GB) - stopped active torrent(s)"
        else
            log "CRITICAL: ${free_gb}GB free (threshold ${THRESHOLD_GB}GB) - no active downloads to stop"
        fi
        rm -f "$cookie_jar"
    fi

    sleep "$CHECK_INTERVAL"
done
