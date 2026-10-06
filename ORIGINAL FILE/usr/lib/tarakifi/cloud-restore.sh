#!/bin/sh
set -u

BACKUP_ID="${1:-}"
WORKDIR="/tmp/tarakifi-cloud-restore-$$"
TOKEN_RESPONSE="/tmp/tarakifi-cloud-restore-$$.token"
DOWNLOAD_RESPONSE="/tmp/tarakifi-cloud-restore-$$.download"
DOWNLOAD_ENV="/tmp/tarakifi-cloud-restore-$$.env"
ENCRYPTED_FILE="/tmp/tarakifi-cloud-restore-$$.enc"
KEY_FILE="/tmp/tarakifi-cloud-restore-$$.key"
ARCHIVE_FILE="/tmp/tarakifi-cloud-restore-$$.tar.gz"
RESTORE_DIR="/tmp/tarakifi-cloud-restore-$$.payload"

LUA_BIN="${TARAKIFI_LUA_BIN:-/usr/bin/lua}"
LUA_ROOT="${TARAKIFI_LUA_ROOT:-/opt/tarakifi/lua}"
UCLIENT_BIN="${TARAKIFI_UCLIENT_BIN:-/bin/uclient-fetch}"
CCRYPT_BIN="${TARAKIFI_CCRYPT_BIN:-/usr/bin/ccrypt}"
SHA256_BIN="${TARAKIFI_SHA256_BIN:-/usr/bin/sha256sum}"
TARAKIFI_RESTART_COMMAND="${TARAKIFI_RESTART_COMMAND:-/etc/init.d/tarakifi restart}"
export TARAKIFI_LUA_ROOT="$LUA_ROOT"

cleanup() {
  rm -rf "$WORKDIR" "$TOKEN_RESPONSE" "$DOWNLOAD_RESPONSE" "$DOWNLOAD_ENV" \
    "$ENCRYPTED_FILE" "$KEY_FILE" "$ARCHIVE_FILE" "$RESTORE_DIR"
}
trap cleanup EXIT INT TERM

command -v "$LUA_BIN" >/dev/null 2>&1 || exit 1
command -v "$UCLIENT_BIN" >/dev/null 2>&1 || exit 1
command -v "$CCRYPT_BIN" >/dev/null 2>&1 || exit 1
command -v "$SHA256_BIN" >/dev/null 2>&1 || exit 1

mkdir -p "$WORKDIR" "$RESTORE_DIR" || exit 1
df -k /tmp 2>/dev/null | awk 'NR==2 {exit ($4 >= 1024 ? 0 : 1)}' || exit 1

WORKDIR="$WORKDIR" TARAKIFI_RESTORE_BACKUP_ID="$BACKUP_ID" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").prepare_restore_request(os.getenv("WORKDIR"), os.getenv("TARAKIFI_RESTORE_BACKUP_ID")); os.exit(ok and 0 or 1)' \
  >/dev/null 2>&1 || exit 1

. "$WORKDIR/meta.env"

"$UCLIENT_BIN" --timeout=30 \
  --header="Content-Type: application/json" \
  --header="X-Board-Secret: ${BOARD_SECRET}" \
  --post-file="$WORKDIR/restore-token-request.json" \
  -q -O "$TOKEN_RESPONSE" \
  "${CLOUD_URL}/api/router/backup/restore-token" >/dev/null 2>&1 || exit 1

RESTORE_TOKEN="$(TOKEN_RESPONSE="$TOKEN_RESPONSE" "$LUA_BIN" -e 'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").print_restore_token(os.getenv("TOKEN_RESPONSE")); os.exit(ok and 0 or 1)' 2>/dev/null)" || exit 1
[ -n "$RESTORE_TOKEN" ] || exit 1

"$UCLIENT_BIN" --timeout=30 \
  -q -O "$DOWNLOAD_RESPONSE" \
  "${CLOUD_URL}/api/router/backup/download?token=${RESTORE_TOKEN}" >/dev/null 2>&1 || exit 1

DOWNLOAD_RESPONSE="$DOWNLOAD_RESPONSE" DOWNLOAD_ENV="$DOWNLOAD_ENV" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").write_download_env(os.getenv("DOWNLOAD_RESPONSE"), os.getenv("DOWNLOAD_ENV")); os.exit(ok and 0 or 1)' \
  >/dev/null 2>&1 || exit 1
. "$DOWNLOAD_ENV"

"$UCLIENT_BIN" --timeout=120 -q -O "$ENCRYPTED_FILE" "$DOWNLOAD_URL" >/dev/null 2>&1 || exit 1
ACTUAL_SHA="$("$SHA256_BIN" "$ENCRYPTED_FILE" | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || exit 1

KEY="$(printf '%s' "${LICENSE_KEY}${DEVICE_ID}${BOARD_SECRET}" | "$SHA256_BIN" | awk '{print $1}')"
[ -n "$KEY" ] || exit 1
printf '%s\n' "$KEY" > "$KEY_FILE" || exit 1
chmod 0600 "$KEY_FILE" 2>/dev/null || true

"$CCRYPT_BIN" -d -q -k "$KEY_FILE" < "$ENCRYPTED_FILE" > "$ARCHIVE_FILE" || exit 1
tar -xzf "$ARCHIVE_FILE" -C "$RESTORE_DIR" >/dev/null 2>&1 || exit 1

RESTORE_DIR="$RESTORE_DIR" "$LUA_BIN" -e \
  'package.path=os.getenv("TARAKIFI_LUA_ROOT").."/?.lua;"..os.getenv("TARAKIFI_LUA_ROOT").."/lib/?.lua;"..package.path; local ok=require("lib.cloud_backup").restore_payload(os.getenv("RESTORE_DIR")); os.exit(ok and 0 or 1)' \
  >/dev/null 2>&1 || exit 1

logger -t tarakifi-restore "Cloud restore completed"
sh -c "$TARAKIFI_RESTART_COMMAND" >/dev/null 2>&1 &
exit 0
