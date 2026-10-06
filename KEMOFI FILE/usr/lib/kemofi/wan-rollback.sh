#!/bin/sh
set -eu

# The WAN page creates this marker before changing network.wan. If the admin
# does not confirm the new connection before the deadline, restore the exact
# previous network file and restart only the WAN interface.
pending='/tmp/kemofi-wan-pending'
backup='/tmp/kemofi-wan-network.backup'
lock='/tmp/kemofi-wan-apply.lock'
rollback_seconds="${KEMOFI_WAN_ROLLBACK_SECONDS:-45}"
case "$rollback_seconds" in
    ''|*[!0-9]*) rollback_seconds=45 ;;
esac
[ "$rollback_seconds" -ge 30 ] 2>/dev/null || rollback_seconds=45
[ "$rollback_seconds" -le 180 ] 2>/dev/null || rollback_seconds=45

sleep "$rollback_seconds"
[ -f "$pending" ] || exit 0
[ -f "$backup" ] || exit 0

cp -f "$backup" /etc/config/network
uci -q revert network >/dev/null 2>&1 || true
ifdown wan >/dev/null 2>&1 || true
ifup wan >/dev/null 2>&1 || true
sync
rm -f "$pending" "$backup"
rmdir "$lock" >/dev/null 2>&1 || true
