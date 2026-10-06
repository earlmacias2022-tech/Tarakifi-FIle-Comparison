#!/bin/sh
set -eu

PRIMARY_CONFIG=/etc/pisowifi/reverse-ssh.conf
PRIMARY_KEY=/etc/pisowifi/reverse-ssh.key
LEGACY_CONFIG=/etc/kemofi/reverse-ssh.conf
LEGACY_KEY=/etc/kemofi/reverse-ssh.key
CONFIG=$PRIMARY_CONFIG
KEY=$PRIMARY_KEY

# Wait for the HTTPS agent to enroll this router and publish a signed relay
# assignment. The script never accepts inbound SSH on the router.
while :; do
    if [ -s "$PRIMARY_CONFIG" ] && [ -s "$PRIMARY_KEY" ]; then
        CONFIG=$PRIMARY_CONFIG
        KEY=$PRIMARY_KEY
        break
    fi
    if [ -s "$LEGACY_CONFIG" ] && [ -s "$LEGACY_KEY" ]; then
        CONFIG=$LEGACY_CONFIG
        KEY=$LEGACY_KEY
        break
    fi
    sleep 10
done

. "$CONFIG"

case "${ssh_host:-}" in
    ""|*[!A-Za-z0-9.-]*) exit 1 ;;
esac
case "${ssh_user:-}" in
    ""|*[!A-Za-z0-9_-]*) exit 1 ;;
esac
case "${ssh_port:-}" in
    ''|*[!0-9]*) exit 1 ;;
esac
case "${remote_port:-}" in
    ''|*[!0-9]*) exit 1 ;;
esac
case "${host_key_algorithm:-}" in
    ssh-ed25519) ;;
    *) exit 1 ;;
esac
case "${host_key:-}" in
    ''|*[!A-Za-z0-9+/=]*) exit 1 ;;
esac

[ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ] || exit 1
[ "$remote_port" -ge 20000 ] && [ "$remote_port" -le 39999 ] || exit 1

mkdir -p /root/.ssh
chmod 700 /root/.ssh
export HOME=/root
printf '%s %s %s\n' "$ssh_host" "$host_key_algorithm" "$host_key" > /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

# The VPS broker exposes only this router's assigned port. Forward it to the
# local admin listener; customer portal and WAN paths remain local.
# Keepalive is enabled; disable Dropbear's local idle timeout so an idle admin
# relay remains established until the broker or procd detects a real failure.
exec /usr/bin/dbclient -N -T -K 30 -I 0 -p "$ssh_port" -i "$KEY" \
    -R "127.0.0.1:${remote_port}:127.0.0.1:8080" "${ssh_user}@${ssh_host}"
