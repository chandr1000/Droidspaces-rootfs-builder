# Dockerfile (Fedora CoreOS - Server)
# Stage 1: Build and customize the rootfs for development
#
# Base: official Fedora CoreOS container payload (same content as the OS
# image minus kernel/initramfs/bootloader, which the Android host provides).
# The :stable tag floats; every CI rebuild picks up the latest FCOS stable.
ARG TARGETPLATFORM
FROM quay.io/fedora/fedora-coreos:stable AS customizer

# ------------------------------------------------------------------
# 1. Base refresh + lean server toolset
#    (nano/vim-minimal/less are already in FCOS; htop is not)
# ------------------------------------------------------------------
RUN dnf -y upgrade && \
    dnf -y install --setopt=install_weak_deps=False \
    # CLI comfort
    htop \
    nano \
    vim-enhanced \
    less \
    tmux \
    bash-completion \
    # File / archive
    tar \
    gzip \
    unzip \
    bzip2 \
    xz \
    # System / troubleshooting
    procps-ng \
    psmisc \
    lsof \
    # Network / SSH
    iproute \
    iputils \
    net-tools \
    bind-utils \
    curl \
    wget \
    openssh-server \
    openssh-clients \
    # Misc
    git \
    sudo \
    glibc-langpack-en \
    && dnf clean all

# ------------------------------------------------------------------
# 2. Docker CE (download.docker.com/linux/fedora, stable channel)
#    Version-matched: docker-ce + cli + containerd.io + buildx + compose
#    NOTE: FCOS base ships Fedora's moby-engine/containerd, which conflict
#    with docker-ce/containerd.io -> evict exactly the installed ones
#    (self-maintaining: no-ops if a future FCOS base drops them).
# ------------------------------------------------------------------
RUN curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo \
      -o /etc/yum.repos.d/docker-ce.repo && \
    rpm -qa --qf '%{NAME}\n' | grep -xE 'moby-engine|containerd|runc|podman-docker|docker-cli|docker-compose|docker' | xargs -r dnf -y remove && \
    dnf -y install --allowerasing \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    && dnf clean all

# House rule: legacy iptables is MANDATORY on Android kernels.
# Fedora base may ship only the nft variant -> install the legacy one,
# select it via alternatives when configured, symlink as fallback,
# and assert the resolved binary really is legacy.
RUN dnf -y install iptables-legacy && \
    (alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || \
     ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables) && \
    (alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || \
     ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables) && \
    iptables --version | grep -q '(legacy)' && \
    ip6tables --version | grep -q '(legacy)' && \
    dnf clean all

# ------------------------------------------------------------------
# 3. Android compatibility (aid_* network groups)
# ------------------------------------------------------------------
RUN groupadd -g 3003 aid_inet 2>/dev/null || true && \
    groupadd -g 3004 aid_net_raw 2>/dev/null || true && \
    groupadd -g 3005 aid_net_admin 2>/dev/null || true && \
    usermod -a -G aid_inet,aid_net_raw,tty root 2>/dev/null || true

# ------------------------------------------------------------------
# 4. Identity: hostname, timezone, locale
# ------------------------------------------------------------------
RUN echo "akari" > /etc/hostname && \
    ln -sf /usr/share/zoneinfo/Asia/Makassar /etc/localtime && \
    echo "Asia/Makassar" > /etc/timezone

# ------------------------------------------------------------------
# 5. Guest SELinux: permissive (nested under Android SELinux anyway)
# ------------------------------------------------------------------
RUN sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true

# ------------------------------------------------------------------
# 6. core user (FCOS default admin user) + SSH key-only access
#    Docs: core exists with wheel/sudo but is locked by default.
#    We ensure it deterministically (idempotent if base lacks it).
# ------------------------------------------------------------------
RUN <<EOF_RUN
id core &>/dev/null || useradd -m -u 1000 -G wheel,sudo,docker core
# ensure admin + docker groups even if the base image shipped its own core
usermod -aG wheel,sudo,docker core 2>/dev/null || true
install -d -m 700 -o core -g core /home/core/.ssh
cat > /home/core/.ssh/authorized_keys <<'KEYEOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGimLq9GUsk+zbBeuDdMLB3RuPGKAqeSqqlSsrDaH6Ux chandr1000 global v2.1
KEYEOF
chown core:core /home/core/.ssh/authorized_keys
chmod 600 /home/core/.ssh/authorized_keys
echo 'core ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/50-droidspaces-core
chmod 0440 /etc/sudoers.d/50-droidspaces-core
EOF_RUN

# SSH: key-only, no root login (matches FCOS upstream posture).
# Drop-in wins over the main config (sshd include order), seds as backup.
RUN mkdir -p /etc/ssh/sshd_config.d && \
    printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' \
      > /etc/ssh/sshd_config.d/99-droidspaces.conf && \
    sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# ------------------------------------------------------------------
# 7. Docker daemon: Android kernel adjustments
#    - iptables=false: kernel lacks XT_MATCH_ADDRTYPE, so dockerd's own
#      rule programming would fail. docker-android-net.service does the
#      netfilter work instead; port publishing uses userland-proxy.
#    - ipv6=false: kernel has no IP6_NF_NAT.
# ------------------------------------------------------------------
RUN <<EOF_RUN
mkdir -p /etc/docker /usr/local/sbin
cat > /etc/docker/daemon.json <<'JSONEOF'
{
  "iptables": false,
  "ip6tables": false,
  "ipv6": false,
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSONEOF

cat > /usr/lib/sysctl.d/70-docker-android.conf <<'SYSCTLEOF'
net.ipv4.ip_forward = 1
SYSCTLEOF

cat > /usr/local/sbin/docker-android-net.sh <<'NETEOF'
#!/bin/bash
# Replaces dockerd's iptables management on Android kernels
# (XT_MATCH_ADDRTYPE missing -> dockerd must run with iptables=false).
# Best-effort by design: NEVER fails the unit. Every problem is logged
# loudly so `journalctl -u docker-android-net` tells the whole story.
set -u
LOG() { echo "[docker-android-net] $*"; }

# Stay out of host and none network modes (house rule)
if grep -qsE '^net_mode=(host|none)$' /run/droidspaces/container.config; then
    LOG "Skipping: host or none network mode"
    exit 0
fi

IPT="/usr/sbin/iptables-legacy"
[ -x "$IPT" ] || IPT="/usr/sbin/iptables"

# Kernel helpers may be modular on some GKI builds; load if possible.
# No-op when built-in; missing /lib/modules inside the container is fine.
for m in ip_tables iptable_filter iptable_nat nf_nat; do
    modprobe "$m" 2>/dev/null || true
done

# --- 1. ip_forward (per-netns; required for nested container egress) ---
fw() { cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0; }
if [ "$(fw)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
fi
if [ "$(fw)" = "1" ]; then
    LOG "ip_forward=1"
else
    LOG "WARNING: ip_forward could not be enabled (/proc/sys read-only?)"
    LOG "WARNING: nested containers get NO outbound network until this is fixed"
fi

# --- 2. Netfilter rules ---
# FORWARD policy stays ACCEPT (dockerd no longer touches iptables), so
# these ACCEPT rules are belt-and-braces; the NAT rule is the critical one.
fail=0
rule() {
    # Canonical iptables order: [-t table] -C/-A chain rule...
    # ("-C -t nat chain..." -> "Bad argument `nat'" on iptables-legacy;
    #  that exact bug failed the v1 unit on akari on 2026-10-31.)
    local table=filter
    if [ "$1" = "-t" ]; then table="$2"; shift 2; fi
    if ! "$IPT" -t "$table" -C "$@" 2>/dev/null; then
        if ! out=$("$IPT" -t "$table" -A "$@" 2>&1); then
            LOG "WARNING: rule failed: $IPT -t $table -A $*"
            LOG "  -> $out"
            fail=1
        fi
    fi
}
rule FORWARD -i docker0 -o docker0 -j ACCEPT
rule FORWARD -i docker0 ! -o docker0 -j ACCEPT
rule -t nat POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE

if ! ip link show docker0 >/dev/null 2>&1; then
    LOG "NOTE: docker0 not up yet (dockerd starts after this unit)"
fi
if [ "$fail" = 0 ]; then
    LOG "Netfilter ready (FORWARD accept + NAT for 172.17.0.0/16)"
else
    LOG "WARNING: some rules failed; 'docker run -p' still works via"
    LOG "WARNING: userland-proxy, but container->internet NAT may not."
fi
exit 0
NETEOF
chmod +x /usr/local/sbin/docker-android-net.sh

cat > /etc/systemd/system/docker-android-net.service <<'UNITEOF'
[Unit]
Description=Docker netfilter bootstrap for Android (Droidspaces)
Before=docker.service
After=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/docker-android-net.sh

[Install]
WantedBy=multi-user.target
UNITEOF
EOF_RUN

# ------------------------------------------------------------------
# 8. First boot: ssh host keys + welcome banner (then it's done)
# ------------------------------------------------------------------
RUN <<EOF_RUN
cat > /etc/systemd/system/ds-firstboot.service <<'UNITEOF'
[Unit]
Description=Droidspaces first boot (host keys, banner)
Before=sshd.service
ConditionPathExists=!/etc/ds-firstboot.done

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/sbin/ds-firstboot.sh

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /usr/local/sbin/ds-firstboot.sh <<'FBEOF'
#!/bin/bash
set -e
ssh-keygen -A
cat > /etc/motd <<'MOTDEOF'
  Fedora CoreOS on Droidspaces (akari)
  Docker: sudo docker run --rm hello-world
  Hello world service: sudo docker run -d -p 8080:80 --name web busybox httpd -f -p 80 -h /tmp
  Net bootstrap log: journalctl -u docker-android-net.service
  Immutability: / and /usr read-only (FCOS-style); /etc /var /root /home /tmp writable
  Maintenance:  sudo ds-unlock (rw /usr) | sudo ds-lock | disable: touch /etc/ds/immutability-off
  Ro-root log:  journalctl -u ds-ro-root.service
MOTDEOF
touch /etc/ds-firstboot.done
FBEOF
chmod +x /usr/local/sbin/ds-firstboot.sh
EOF_RUN

# ------------------------------------------------------------------
# 9. FCOS-style immutable root
#    True FCOS behavior on Droidspaces: / and /usr read-only,
#    /etc /var /root /home /tmp writable. Implemented at boot by
#    pivot_root into a read-only bind-clone of the root tree.
#    Validated live on akari (2026-10-31): touch / -> "Read-only file
#    system", dnf5 refuses with "/usr is configured to be read-only",
#    docker pull/run/-p publishing unaffected.
#    NOTE: an overmount (rbind / /run/.ds-stage + remount,ro,bind /) is
#    NOT sufficient - the namespace root mount is pinned underneath it,
#    so absolute-path resolution never crosses the read-only clone.
#    pivot_root replaces the ns root, which is what actually enforces.
#    Fail-soft by design: any failure = journal note + writable root.
#    Opt-out: touch /etc/ds/immutability-off and restart the container.
#    Backup: byte-identical copies of every file created below live in
#    /recovery (repo root, see recovery/README.md) together with an
#    installer and a diagnosis playbook. Keep them when gating this
#    feature - that directory is the restore source.
# ------------------------------------------------------------------
RUN <<EOF_RUN
mkdir -p /etc/ds /usr/local/sbin

cat > /usr/local/sbin/ds-ro-root <<'ROROOT'
#!/bin/bash
# Droidspaces: pivot into a FCOS-style read-only root view.
#   ro: / and /usr        rw: /etc /var /root /home /tmp (/run stays rw via
#   the cloned tmpfs). Never fails the unit: any problem is logged and the
#   root simply stays writable. Sequence validated end-to-end on akari.
set -u
LOG() { echo "[ds-ro-root] $*"; }
stage=/run/.ds-stage

# Already immutable? (touch on / fails once the pivot has been applied)
if ! touch /.ds-ro-probe 2>/dev/null; then
    LOG "root already read-only, nothing to do"
    exit 0
fi
rm -f /.ds-ro-probe

undo() {
    # best-effort teardown of everything we attached (lazy, recursive)
    umount -l -R "$stage" 2>/dev/null || true
}

# pivot_root refuses shared propagation
mount --make-rprivate / || { LOG "make-rprivate failed"; exit 0; }

mkdir -p "$stage" || { LOG "cannot create $stage"; exit 0; }

if ! mount --rbind / "$stage"; then
    LOG "stage rbind failed"; rmdir "$stage" 2>/dev/null; exit 0
fi
if ! mkdir "$stage/run/ds-old" 2>/dev/null; then
    LOG "cannot create put_old under $stage/run"; undo; exit 0
fi
if ! mount -o remount,ro,bind "$stage"; then
    LOG "stage ro flip failed"; undo; exit 0
fi

# FCOS-style writable whitelist (rebinds ON TOP of the ro stage)
for d in etc var root home tmp; do
    if ! mount --rbind "/$d" "$stage/$d" 2>/dev/null; then
        LOG "whitelist bind failed: /$d (dir stays read-only)"
    fi
done

# /usr as its own mount -> per-directory unlock via ds-unlock
if mount --rbind /usr "$stage/usr" 2>/dev/null; then
    mount -o remount,ro,bind "$stage/usr" 2>/dev/null \
        || LOG "/usr ro flip failed (stays stage-read-only)"
else
    LOG "/usr bind failed (stays stage-read-only)"
fi

if ! out=$(pivot_root "$stage" "$stage/run/ds-old" 2>&1); then
    LOG "pivot_root failed: $out (root stays writable)"
    undo
    exit 0
fi
if ! umount -l /run/ds-old 2>/dev/null; then
    LOG "WARNING: old rw root still visible under /run/ds-old (restart clears it)"
fi
LOG "root pivoted read-only (FCOS-style); writable: /etc /var /root /home /tmp"
LOG "unlock /usr: ds-unlock | re-lock: ds-lock | disable: touch /etc/ds/immutability-off"
exit 0
ROROOT
chmod +x /usr/local/sbin/ds-ro-root

cat > /usr/local/sbin/ds-unlock <<'UNLEOF'
#!/bin/bash
# Make /usr writable for maintenance (dnf install, edits under /usr).
# Re-lock afterwards with: ds-lock
if mount -o remount,rw,bind /usr 2>/dev/null; then
    echo "ds: /usr unlocked (rw) - re-lock with: sudo ds-lock"
else
    echo "ds: cannot unlock /usr (immutable root active? journalctl -u ds-ro-root)" >&2
    exit 1
fi
UNLEOF
chmod +x /usr/local/sbin/ds-unlock

cat > /usr/local/sbin/ds-lock <<'LKLEOF'
#!/bin/bash
# Re-apply read-only /usr after ds-unlock
if mount -o remount,ro,bind /usr 2>/dev/null; then
    echo "ds: /usr locked (read-only)"
else
    echo "ds: cannot lock /usr" >&2
    exit 1
fi
LKLEOF
chmod +x /usr/local/sbin/ds-lock

cat > /etc/ds/README <<'DSEOF'
/etc/ds - Droidspaces runtime switches

  immutability-off   create this file (touch) to boot with a fully writable
                     root instead of the FCOS-style read-only root view.
                     Takes effect on the next container start.
DSEOF

cat > /etc/systemd/system/ds-ro-root.service <<'UNITEOF'
[Unit]
Description=Droidspaces FCOS-style read-only root view
Documentation=https://github.com/chandr1000/Droidspaces-rootfs-builder/tree/akari-build
After=local-fs.target
Before=docker.service sshd.service
ConditionPathExists=!/etc/ds/immutability-off

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ds-ro-root

[Install]
WantedBy=multi-user.target
UNITEOF
EOF_RUN

# ------------------------------------------------------------------
# 10. Systemd tuning for Android kernels (house fixes)
# ------------------------------------------------------------------
RUN <<EOF_RUN
# --- 1. General Fixes ---
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# --- 2. Systemd-Specific Fixes ---
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

# Power key belongs to Android, not the container
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

# udev: only trigger container-relevant subsystems; skip on read-only paths
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Network clients stay out of host/none net modes (house rule)
for unit in NetworkManager.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "/usr/lib/systemd/system/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q '^net_mode=' /run/droidspaces/container.config && ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config"
EOF
    fi
done

# --- 3. Mask FCOS services that make no sense in a namespace container ---
for unit in zincati.service rpm-ostreed.service ostree-finalize-staged.service \
            ostree-boot-complete.service ostree-remount.service \
            afterburn.service afterburn-sshkeys@.service \
            coreos-check-ssh-keys.service ignition-setup-user.ign.service \
            chronyd.service auditd.service audit-rules.service \
            bootloader-update.service coreos-warn-invalid-mounts.service \
            var-lib-nfs-rpc_pipefs.mount; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
# NOTE: chronyd   = clock belongs to the Android host (shared kernel clock)
#       audit*    = global-kernel audit is not namespaced; cannot work here
#       bootloader-update / nfs rpc_pipefs / coreos-warn-invalid-mounts =
#       metal/ostree assumptions that never hold inside Droidspaces

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# House bashrc (shared repo script)
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# ------------------------------------------------------------------
# 11. Enable services (manual symlinks, offline-deterministic)
# ------------------------------------------------------------------
RUN <<EOF_RUN
mkdir -p /etc/systemd/system/multi-user.target.wants \
         /etc/systemd/system/sockets.target.wants
for service in NetworkManager.service systemd-udevd.service sshd.service \
               docker.service docker-android-net.service ds-firstboot.service \
               ds-ro-root.service; do
    if [ -f "/usr/lib/systemd/system/$service" ]; then
        ln -sf "/usr/lib/systemd/system/$service" \
               "/etc/systemd/system/multi-user.target.wants/$service"
    else
        ln -sf "/etc/systemd/system/$service" \
               "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done
ln -sf /usr/lib/systemd/system/docker.socket \
       /etc/systemd/system/sockets.target.wants/docker.socket
EOF_RUN

# ------------------------------------------------------------------
# 12. Final cleanup
# ------------------------------------------------------------------
RUN dnf clean all && \
    rm -rf /var/cache/libdnf5* /var/cache/dnf /var/log/* /tmp/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Fedora CoreOS 44 - Server" \
      droidspaces.distro="Fedora CoreOS" \
      droidspaces.description="Fedora CoreOS rootfs with Docker CE + compose, key-only SSH, FCOS-style read-only root (immutable / and /usr, writable /etc /var), tuned for Android/Droidspaces (GKI)." \
      droidspaces.author="chandr1000"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
