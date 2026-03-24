#!/bin/bash
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"

# Adjust user/group IDs to match environment
groupmod -o -g "$PGID" abc 2>/dev/null || true
usermod -o -u "$PUID" -g "$PGID" abc 2>/dev/null || true

# Ensure directories exist and are owned correctly
mkdir -p /config/logs /temp/merge /backup
chown -R "$PUID:$PGID" /config /temp
chown "$PUID:$PGID" /input /output /backup

# Signal handling — forward to child
CHILD_PID=""
shutdown_handler() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Received shutdown signal, stopping..."
    if [[ -n "${CHILD_PID}" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null
        wait "$CHILD_PID" 2>/dev/null
    fi
    exit 0
}
trap shutdown_handler SIGTERM SIGINT

# Startup banner
echo "========================================="
echo " m4b-audiobook-converter"
echo "========================================="
echo "User:      abc (${PUID}:${PGID})"
echo "Sleep:     ${SLEEPTIME}"
echo "CPU Cores: ${CPU_CORES} (0=auto)"
echo "Backup:    ${MAKE_BACKUP}"
echo "Bitrate:   ${AUDIO_BITRATE}"
echo "Codec:     ${AUDIO_CODEC}"
echo "m4b-tool:  $(m4b-tool --version 2>&1 | head -1)"
echo "========================================="

# Launch main script as configured user
su-exec abc:abc /usr/local/bin/m4b-audiobook-converter.sh &
CHILD_PID=$!
wait "$CHILD_PID"
