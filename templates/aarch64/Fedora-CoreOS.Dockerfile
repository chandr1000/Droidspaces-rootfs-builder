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
set -u
# Stay out of host and none network modes (house rule)
if grep -qs '^net_mode=' /run/droidspaces/container.config && \
   grep -qsE '^net_mode=(host|none)$' /run/droidspaces/container.config; then
    echo "Skipping docker net bootstrap: host or none network mode"
    exit 0
fi
IPT="/usr/sbin/iptables-legacy"
[ -x "$IPT" ] || IPT="/usr/sbin/iptables"
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
rule() { "$IPT" -C "$@" 2>/dev/null || "$IPT" -A "$@"; }
rule FORWARD -i docker0 -o docker0 -j ACCEPT
rule FORWARD -i docker0 ! -o docker0 -j ACCEPT
rule FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
rule -t nat POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
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
MOTDEOF
touch /etc/ds-firstboot.done
FBEOF
chmod +x /usr/local/sbin/ds-firstboot.sh
EOF_RUN

# ------------------------------------------------------------------
# 9. Systemd tuning for Android kernels (house fixes)
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
            coreos-check-ssh-keys.service ignition-setup-user.ign.service; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# House bashrc (shared repo script)
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# ------------------------------------------------------------------
# 10. Enable services (manual symlinks, offline-deterministic)
# ------------------------------------------------------------------
RUN <<EOF_RUN
mkdir -p /etc/systemd/system/multi-user.target.wants \
         /etc/systemd/system/sockets.target.wants
for service in NetworkManager.service systemd-udevd.service sshd.service \
               docker.service docker-android-net.service ds-firstboot.service; do
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
# 11. Final cleanup
# ------------------------------------------------------------------
RUN dnf clean all && \
    rm -rf /var/cache/libdnf5* /var/cache/dnf /var/log/* /tmp/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Fedora CoreOS 44 - Server" \
      droidspaces.distro="Fedora CoreOS" \
      droidspaces.description="Fedora CoreOS rootfs with Docker CE + compose, key-only SSH, tuned for Android/Droidspaces (GKI)." \
      droidspaces.author="chandr1000"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
