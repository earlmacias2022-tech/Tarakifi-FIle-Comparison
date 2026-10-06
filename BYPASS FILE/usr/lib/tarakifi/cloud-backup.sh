#!/bin/sh
set -u

REASON="${1:-scheduled}"
case "$REASON" in
  voucher_change|settings_change|license_activation|coin_node_change|scheduled|pre_ota|manual) ;;
  *) REASON="manual" ;;
esac

WORKDIR="/tmp/tarakifi-cloud-backup-$$"
ARCHIVE_FILE="/tmp/tarakifi-cloud-backup-$$.tar.gz"
KEY_FILE="/tmp/tarakifi-cloud-backup-$$.key"
ENCRYPTED_FILE="/tmp/tarakifi-cloud-backup-$$.enc"
BACKUP_DATA_FILE="/tmp/tarakifi-cloud-backup-$$.b64"
UPLOAD_FILE="/tmp/tarakifi-cloud-backup-$$.json"
RESPONSE_FILE="/tmp/tarakifi-cloud-backup-$$.response"

LUA_BIN="${TARAKIFI_LUA_BIN:-/usr/bin/lua}"
LUA_ROOT="${TARAKIFI_LUA_ROOT:-/opt/tarakifi/lua}"
UCLIENT_BIN="${TARAKIFI_UCLIENT_BIN:-/bin/uclient-fetch}"
CCRYPT_BIN="${TARAKIFI_CCRYPT_BIN:-/usr/bin/ccrypt}"
SHA256_BIN="${TARAKIFI_SHA256_BIN:-/usr/bin/sha256sum}"
MAX_BYTES="${TARAKIFI_CLOUD_BACKUP_MAX_BYTES:-2097152}"
WAN_STATUS_PATH="${TARAKIFI_WAN_STATUS_PATH:-/tmp/tarakifi/wan.status}"
export TARAKIFI_LUA_ROOT="$LUA_ROOT"

cleanup() {
  rm -rf "$WORKDIR" "$ARCHIVE_FILE" "$KEY_FILE" \
    "$ENCRYPTED_FILE" "$BACKUP_DATA_FILE" "$UPLOAD_FILE" "$RESPONSE_FILE"
}
trap cleanup EXIT INT TERM

wan_online() {
  if [ -s "$WAN_STATUS_PATH" ]; then
    now="$(date +%s)"
    checked="$(sed -n 's/^\([0-9][0-9]*\)|[01].*/\1/p' "$WAN_STATUS_PATH" 2>/dev/null)"
    result="$(sed -n 's/^[0-9][0-9]*|\([01]\).*/\1/p' "$WAN_STATUS_PATH" 2>/dev/null)"
    if [ "$result" = "1" ] && [ -n "$checked" ] && [ $((now - checked)) -ge 0 ] && [ $((now - checked)) -le 120 ]; then
      return 0
    fi
  fi
  ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}

wan_online || exit 0
command -v "$LUA_BIN" >/dev/null 2>&1 || exit 0
command -v "$UCLIENT_BIN" >/dev/null 2>&1 || exit 0
command -v "$CCRYPT_BIN" >/dev/null 2>&1 || exit 0
command -v "$SHA256_BIN" >/dev/null 2>&1 || exit 0

if [ "$REASON" = "scheduled" ]; then
  "$LUA_BIN" -e \
    'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").claim_scheduled_day(); os.exit(ok and 0 or 1)' \
    >/dev/null 2>&1 || exit 0
fi

mkdir -p "$WORKDIR" || exit 0
WORKDIR="$WORKDIR" TARAKIFI_BACKUP_REASON="$REASON" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").export_payload(os.getenv("WORKDIR"), os.getenv("TARAKIFI_BACKUP_REASON")); os.exit(ok and 0 or 1)' \
  >/dev/null 2>&1 || exit 0

. "$WORKDIR/meta.env"

tar -czf "$ARCHIVE_FILE" -C "$WORKDIR/payload" . >/dev/null 2>&1 || exit 0
archive_size="$(wc -c < "$ARCHIVE_FILE" 2>/dev/null | tr -d ' ')"
[ -n "$archive_size" ] || exit 0
[ "$archive_size" -le "$MAX_BYTES" ] || exit 0

KEY="$(printf '%s' "${LICENSE_KEY}${DEVICE_ID}${BOARD_SECRET}" | "$SHA256_BIN" | awk '{print $1}')"
[ -n "$KEY" ] || exit 0
printf '%s\n' "$KEY" > "$KEY_FILE" || exit 0
chmod 0600 "$KEY_FILE" 2>/dev/null || true

"$CCRYPT_BIN" -e -q -k "$KEY_FILE" < "$ARCHIVE_FILE" > "$ENCRYPTED_FILE" || exit 0

encrypted_size="$(wc -c < "$ENCRYPTED_FILE" 2>/dev/null | tr -d ' ')"
[ -n "$encrypted_size" ] || exit 0
[ "$encrypted_size" -le "$MAX_BYTES" ] || exit 0

SHA256="$("$SHA256_BIN" "$ENCRYPTED_FILE" | awk '{print $1}')"
ENCODE_FILE="$ENCRYPTED_FILE" BACKUP_DATA_FILE="$BACKUP_DATA_FILE" "$LUA_BIN" -e \
  'local nixio=require("nixio"); local src=assert(io.open(os.getenv("ENCODE_FILE"),"rb")); local data=src:read("*a") or ""; src:close(); local out=assert(io.open(os.getenv("BACKUP_DATA_FILE"),"wb")); out:write(nixio.bin.b64encode(data)); out:close()' \
  >/dev/null 2>&1 || exit 0

WORKDIR="$WORKDIR" BACKUP_DATA_FILE="$BACKUP_DATA_FILE" UPLOAD_FILE="$UPLOAD_FILE" TARAKIFI_BACKUP_SHA256="$SHA256" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").write_upload_request(os.getenv("WORKDIR"), os.getenv("BACKUP_DATA_FILE"), os.getenv("TARAKIFI_BACKUP_SHA256"), os.getenv("UPLOAD_FILE")); os.exit(ok and 0 or 1)' \
  >/dev/null 2>&1 || exit 0

"$UCLIENT_BIN" --timeout=30 \
  --header="Content-Type: application/json" \
  --header="X-Board-Secret: ${BOARD_SECRET}" \
  --post-file="$UPLOAD_FILE" \
  -q -O "$RESPONSE_FILE" \
  "${CLOUD_URL}/api/router/backup/upload" >/dev/null 2>&1 || exit 0

RESPONSE_FILE="$RESPONSE_FILE" TARAKIFI_BACKUP_REASON="$REASON" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; require("lib.cloud_backup").record_upload_result(os.getenv("RESPONSE_FILE"), os.getenv("TARAKIFI_BACKUP_REASON"))' \
  >/dev/null 2>&1 || true

logger -t tarakifi-backup "Cloud backup uploaded"
exit 0
