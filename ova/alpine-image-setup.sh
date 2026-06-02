#!/bin/sh
# Default in-chroot setup script invoked by build-ova.sh.
#
# Runs AFTER alpine-make-vm-image has installed the base system + packages and
# AFTER the user's optional customization hook (CUSTOMIZE_SCRIPT, if any) has run.
# This script handles ESXi/cloud-init wiring and image hygiene that every OVA needs.
#
# Environment passed in by build-ova.sh:
#   EXPECTED_PACKAGES: space-separated apk packages that MUST be installed
#                     (fails the build hard if any are missing — catches
#                     alpine-make-vm-image's silent-on-missing-package mode)
#   CLOUD_INIT       : "1" if cloud-init was installed (enables service + drop-in)
#   OPEN_VM_TOOLS    : "1" if open-vm-tools was installed (enables service)
#   KERNEL_CMDLINE   : extra args to append to extlinux default_kernel_opts
#   ENABLE_NTP       : "1" to enable chronyd
set -eu

# 0. Verify every expected package made it in. apk silently skipping a missing
#    package would leave us with a base-only image that imports OK but never
#    runs cloud-init or open-vm-tools.
if [ -n "${EXPECTED_PACKAGES:-}" ]; then
    missing=""
    for pkg in $EXPECTED_PACKAGES; do
        apk info -e "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        echo "ERROR: expected packages not installed:$missing" >&2
        echo "Check the 'Installing additional packages' output above." >&2
        exit 1
    fi
fi

# 1. Kernel command line (eth0 predictability, plus any caller extras).
#    update-extlinux is the Alpine-native way to regenerate /boot/extlinux.conf.
if [ -f /etc/update-extlinux.conf ]; then
    cur=$(awk -F'=' '/^default_kernel_opts=/{print $2}' /etc/update-extlinux.conf | tr -d '"')
    new="${cur} ${KERNEL_CMDLINE:-}"
    new=$(echo "$new" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    sed -i "s|^default_kernel_opts=.*|default_kernel_opts=\"${new}\"|" /etc/update-extlinux.conf
    update-extlinux
fi

# 2. Cloud-init: prefer VMware datasource (reads guestinfo via vmware-rpctool),
#    fall back to NoCloud. Ship a drop-in instead of editing /etc/cloud/cloud.cfg.
if [ "${CLOUD_INIT:-0}" = "1" ]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-vmware-guestinfo.cfg <<'EOF'
# Set by build-ova.sh: pin cloud-init datasource lookup order.
# VMware reads guestinfo.{metadata,userdata}{,.encoding} via vmware-rpctool.
datasource_list: [ VMware, NoCloud, None ]
EOF
    # cloud-init in Alpine uses OpenRC services: cloud-init-local, cloud-init,
    # cloud-config, cloud-final. Enable all four.
    for svc in cloud-init-local cloud-init cloud-config cloud-final; do
        rc-update add "$svc" default 2>/dev/null || true
    done
fi

# 3. open-vm-tools — required for the VMware datasource AND for vSphere to see
#    guest IP / do graceful shutdown.
if [ "${OPEN_VM_TOOLS:-0}" = "1" ]; then
    rc-update add open-vm-tools default 2>/dev/null || true
fi

# 4. NTP (chrony). K8s is sensitive to clock skew.
if [ "${ENABLE_NTP:-0}" = "1" ]; then
    rc-update add chronyd default 2>/dev/null || true
fi

# 5. Network is brought up by ifupdown via /etc/network/interfaces.
#    cloud-init will rewrite this on first boot from guestinfo.metadata.
#    Provide a DHCP fallback so the VM is reachable if cloud-init has nothing.
mkdir -p /etc/network
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
rc-update add networking default 2>/dev/null || true
rc-update add hostname default 2>/dev/null || true

# 6. SSH explicitly NOT enabled by default. If sshd is installed, leave it off;
#    operators add their own access. Spec §7 anti-requirement.

# 7. Hygiene — clear build-time state so each clone gets fresh identity.
#    Cloud-init regenerates SSH host keys, machine-id, and consumes its own state.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id 2>/dev/null || true
rm -rf /var/lib/cloud/* 2>/dev/null || true
rm -rf /var/cache/apk/* /tmp/* /var/tmp/* 2>/dev/null || true
find /var/log -type f -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
rm -f /root/.ash_history /root/.bash_history /root/.lesshst 2>/dev/null || true

# Lock root password — image must not ship with a known password.
passwd -l root 2>/dev/null || true
