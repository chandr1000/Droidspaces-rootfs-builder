#!/bin/bash
# install-unlock.sh - restore the original Droidspaces unlock tooling
# (ds-ro-root, ds-unlock, ds-lock, ds-ro-root.service, /etc/ds/README)
# from this recovery directory onto a running Droidspaces container, or
# into a bare rootfs tree with --root. Playbook: ./README.md
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
UNLOCK_USR=1

usage() {
    echo "usage: sudo $0 [--root <dir>] [--no-unlock]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)      ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --no-unlock) UNLOCK_USR=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage ;;
    esac
done

msg() { echo "[install-unlock] $*"; }

# sanity: the payloads must sit next to this script
for f in ds-ro-root ds-unlock ds-lock ds-ro-root.service etc-ds-README; do
    [ -f "$SRC/$f" ] || { echo "[install-unlock] missing payload: $SRC/$f" >&2; exit 1; }
done

if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[install-unlock] run with sudo (or use --root <dir> on a tree image)" >&2
    exit 1
fi

# 1. Immutable root active? /usr is then a read-only bind -> unlock it with
#    the original one-liner so we can write /usr/local/sbin. The failure
#    branch is the good case: /usr already writable (feature absent or
#    already unlocked).
if [ "$UNLOCK_USR" = 1 ] && [ -z "$ROOT" ]; then
    if mount -o remount,rw,bind /usr 2>/dev/null; then
        msg "/usr remounted rw for this boot (re-lock later with: sudo ds-lock)"
    else
        msg "/usr not a read-only bind - nothing to unlock"
    fi
fi

# 2. Files (identical to the v4 template heredocs, commit 133934e)
install -D -m 0755 "$SRC/ds-ro-root"         "$ROOT/usr/local/sbin/ds-ro-root"
install -D -m 0755 "$SRC/ds-unlock"          "$ROOT/usr/local/sbin/ds-unlock"
install -D -m 0755 "$SRC/ds-lock"            "$ROOT/usr/local/sbin/ds-lock"
install -D -m 0644 "$SRC/ds-ro-root.service" "$ROOT/etc/systemd/system/ds-ro-root.service"
install -D -m 0644 "$SRC/etc-ds-README"      "$ROOT/etc/ds/README"

# 3. Enable the unit exactly like the template does (manual symlink)
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/ds-ro-root.service \
       "$ROOT/etc/systemd/system/multi-user.target.wants/ds-ro-root.service"

# 4. Live systemd? reload it. In a --root tree this is skipped on purpose;
#    the unit is picked up on next boot.
if [ -z "$ROOT" ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload 2>/dev/null || true
    msg "systemd state: ds-ro-root is $(systemctl is-active ds-ro-root.service 2>/dev/null || echo inactive)"
fi

msg "installed: ds-ro-root ds-unlock ds-lock ds-ro-root.service /etc/ds/README${ROOT:+ -> $ROOT}"
msg "next: sudo ds-unlock (rw /usr) | sudo ds-lock (re-lock)"
msg "permanent writable root: sudo touch /etc/ds/immutability-off && restart container"
msg "unit runs again on next container start: journalctl -u ds-ro-root.service"
