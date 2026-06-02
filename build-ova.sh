#!/usr/bin/env bash
# build-ova.sh — Generic Alpine Linux OVA builder (ESXi 6.7+ compatible).
#
# Produces: <OUTPUT_DIR>/<NAME>.ovf
#           <OUTPUT_DIR>/<NAME>-disk1.vmdk   (streamOptimized, thin)
#           <OUTPUT_DIR>/<NAME>.mf           (SHA-256 manifest)
#           <OUTPUT_DIR>/SHA256SUMS          (transport checksums of all three)
#
# Pipeline:
#   1. Download pinned alpine-make-vm-image, verify sha1.
#   2. Build qcow2 of Alpine (branch + packages + customize hook).
#   3. qemu-img convert qcow2 -> streamOptimized VMDK.
#   4. Render OVF template with disk size / vmdk size / sizing.
#   5. Write .mf and SHA256SUMS.
#
# Build host needs: bash, curl, qemu-img, qemu-nbd, sudo (for nbd mount),
#                   sha1sum, sha256sum, sfdisk, rsync, e2fsprogs.
# Works on any Linux distro; alpine-make-vm-image self-bootstraps apk.
#
# Usage:
#   ./build-ova.sh [-h]
#
# All inputs come from environment variables; see DEFAULTS block below.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — every value is overridable via env.
# ---------------------------------------------------------------------------
: "${OUTPUT_NAME:=alpine-esxi}"
: "${OUTPUT_DIR:=$(pwd)/_out}"

# Source image
: "${ALPINE_BRANCH:=v3.23}"                          # tracks latest 3.23.x
: "${ARCH:=x86_64}"                                  # x86_64 | aarch64
: "${KERNEL_FLAVOR:=virt}"                           # virt | lts
: "${BOOT_MODE:=BIOS}"                               # BIOS | UEFI

# Sizing
: "${DISK_SIZE_GB:=20}"
: "${CPUS:=1}"
: "${MEMORY_MB:=1024}"

# Hardware / OVF
: "${HW_VERSION:=vmx-14}"                            # vmx-14 = ESXi 6.7 floor
: "${OS_TYPE:=other5xLinux64Guest}"                  # vmw:osType in OVF
: "${OS_ID:=36}"                                     # CIM OS type id
: "${OS_DESCRIPTION:=Other Linux (64-bit, 5.x kernel)}"
: "${NETWORK_NAME:=VM Network}"
: "${PRODUCT_NAME:=Alpine Linux}"
: "${VENDOR:=Alpine Linux Development Team}"
: "${PRODUCT_VERSION:=3.23}"
: "${PRODUCT_FULL_VERSION:=Alpine Linux ${PRODUCT_VERSION}}"

# Packages baked in. Caller can append via EXTRA_PACKAGES.
: "${INSTALL_CLOUD_INIT:=1}"
: "${INSTALL_OPEN_VM_TOOLS:=1}"
: "${INSTALL_NTP:=1}"                                # chronyd
: "${EXTRA_PACKAGES:=}"

# Kernel cmdline — Spec §5 requires net.ifnames=0 biosdevname=0 so first NIC is eth0.
: "${KERNEL_CMDLINE_EXTRA:=net.ifnames=0 biosdevname=0}"

# Optional user customize hook. Runs inside chroot AFTER base install but BEFORE
# alpine-image-setup.sh (which does cloud-init wiring + cleanup last).
: "${CUSTOMIZE_SCRIPT:=}"

# Pinned alpine-make-vm-image. Bump in lock-step.
: "${AMVI_VERSION:=0.13.4}"
: "${AMVI_SHA1:=33b338dc0d2ce67a8dd4f1701862f051aed565f1}"
: "${AMVI_URL:=https://raw.githubusercontent.com/alpinelinux/alpine-make-vm-image/v${AMVI_VERSION}/alpine-make-vm-image}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVA_DIR="$SCRIPT_DIR/ova"
TEMPLATE="$OVA_DIR/alpine.ovf.tmpl"
DEFAULT_SETUP="$OVA_DIR/alpine-image-setup.sh"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
    exit 0
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }

for cmd in curl qemu-img qemu-nbd sha1sum sha256sum sudo sfdisk rsync awk sed tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd (install qemu-utils + util-linux + rsync + coreutils)"
done

[ -f "$TEMPLATE" ]      || die "OVF template not found: $TEMPLATE"
[ -f "$DEFAULT_SETUP" ] || die "Default setup script not found: $DEFAULT_SETUP"
[ -z "$CUSTOMIZE_SCRIPT" ] || [ -f "$CUSTOMIZE_SCRIPT" ] || die "CUSTOMIZE_SCRIPT not found: $CUSTOMIZE_SCRIPT"

# nbd module is required by qemu-nbd. alpine-make-vm-image will modprobe it but
# fail-fast here gives a better error than a 200-line strace later.
if ! lsmod 2>/dev/null | grep -q '^nbd '; then
    log "Loading nbd kernel module (requires sudo)…"
    sudo modprobe nbd max_part=16 || die "modprobe nbd failed — kernel must have NBD support"
fi

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d -t build-ova.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Fetch alpine-make-vm-image
# ---------------------------------------------------------------------------
AMVI="$WORK/alpine-make-vm-image"
log "Fetching alpine-make-vm-image v${AMVI_VERSION}"
curl -fsSL --connect-timeout 10 --max-time 120 -o "$AMVI" "$AMVI_URL"
actual_sha=$(sha1sum "$AMVI" | awk '{print $1}')
[ "$actual_sha" = "$AMVI_SHA1" ] || die "alpine-make-vm-image SHA1 mismatch: got $actual_sha expected $AMVI_SHA1"
chmod +x "$AMVI"

# ---------------------------------------------------------------------------
# 2. Compose package list and combined chroot script
# ---------------------------------------------------------------------------
PACKAGES="chrony curl"
[ "$INSTALL_CLOUD_INIT" = "1" ]    && PACKAGES="$PACKAGES cloud-init cloud-init-vmware-guestinfo"
[ "$INSTALL_OPEN_VM_TOOLS" = "1" ] && PACKAGES="$PACKAGES open-vm-tools"
[ "$INSTALL_NTP" = "1" ]           || PACKAGES="${PACKAGES//chrony/}"
[ -n "$EXTRA_PACKAGES" ]           && PACKAGES="$PACKAGES $EXTRA_PACKAGES"

# Combine user's customize hook + our default setup into one chroot script.
# User hook runs first; our setup (cleanup) runs last.
CHROOT_SCRIPT="$WORK/chroot-driver.sh"
{
    echo '#!/bin/sh'
    echo 'set -eu'
    if [ -n "$CUSTOMIZE_SCRIPT" ]; then
        echo "# === User customize hook: $(basename "$CUSTOMIZE_SCRIPT") ==="
        cat "$CUSTOMIZE_SCRIPT"
        echo
    fi
    echo "# === Default alpine-image-setup.sh (cloud-init + hygiene) ==="
    cat "$DEFAULT_SETUP"
} > "$CHROOT_SCRIPT"
chmod +x "$CHROOT_SCRIPT"

# ---------------------------------------------------------------------------
# 3. Build the qcow2
# ---------------------------------------------------------------------------
QCOW2="$WORK/${OUTPUT_NAME}.qcow2"
log "Building qcow2: $QCOW2 (${DISK_SIZE_GB}G, branch $ALPINE_BRANCH, arch $ARCH)"
sudo env \
    CLOUD_INIT="$INSTALL_CLOUD_INIT" \
    OPEN_VM_TOOLS="$INSTALL_OPEN_VM_TOOLS" \
    ENABLE_NTP="$INSTALL_NTP" \
    KERNEL_CMDLINE="$KERNEL_CMDLINE_EXTRA" \
    "$AMVI" \
        --arch "$ARCH" \
        --branch "$ALPINE_BRANCH" \
        --boot-mode "$BOOT_MODE" \
        --image-format qcow2 \
        --image-size "${DISK_SIZE_GB}G" \
        --kernel-flavor "$KERNEL_FLAVOR" \
        --packages "$PACKAGES" \
        --repositories-file /dev/stdin \
        --serial-console \
        --script-chroot \
        "$QCOW2" "$CHROOT_SCRIPT" <<EOF
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community
EOF

sudo chown "$(id -u):$(id -g)" "$QCOW2"

# ---------------------------------------------------------------------------
# 4. Convert qcow2 -> streamOptimized VMDK
# ---------------------------------------------------------------------------
VMDK_NAME="${OUTPUT_NAME}-disk1.vmdk"
VMDK_PATH="$OUTPUT_DIR/$VMDK_NAME"
log "Converting qcow2 -> streamOptimized VMDK: $VMDK_PATH"
qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized "$QCOW2" "$VMDK_PATH"

# Populated size = actual data in the disk (NOT file size on host). qemu-img info
# 'disk size' is what got written; for OVF we report bytes.
VMDK_FILE_SIZE=$(stat -c '%s' "$VMDK_PATH")
DISK_POPULATED_BYTES=$(qemu-img info --output=json "$VMDK_PATH" \
    | awk -F'[ ,:]+' '/"actual-size"/{print $3; exit}')
[ -n "${DISK_POPULATED_BYTES:-}" ] || DISK_POPULATED_BYTES="$VMDK_FILE_SIZE"

# ---------------------------------------------------------------------------
# 5. Render OVF and manifest
# ---------------------------------------------------------------------------
case "$BOOT_MODE" in BIOS) FIRMWARE=bios ;; UEFI) FIRMWARE=efi ;; *) die "bad BOOT_MODE: $BOOT_MODE" ;; esac

OVF_PATH="$OUTPUT_DIR/${OUTPUT_NAME}.ovf"
log "Rendering OVF: $OVF_PATH"
sed \
    -e "s|@@VMDK_FILENAME@@|${VMDK_NAME}|g" \
    -e "s|@@VMDK_FILE_SIZE@@|${VMDK_FILE_SIZE}|g" \
    -e "s|@@DISK_CAPACITY_GB@@|${DISK_SIZE_GB}|g" \
    -e "s|@@DISK_POPULATED_BYTES@@|${DISK_POPULATED_BYTES}|g" \
    -e "s|@@NETWORK_NAME@@|${NETWORK_NAME}|g" \
    -e "s|@@VM_NAME@@|${OUTPUT_NAME}|g" \
    -e "s|@@OS_ID@@|${OS_ID}|g" \
    -e "s|@@OS_TYPE@@|${OS_TYPE}|g" \
    -e "s|@@OS_DESCRIPTION@@|${OS_DESCRIPTION}|g" \
    -e "s|@@PRODUCT_NAME@@|${PRODUCT_NAME}|g" \
    -e "s|@@VENDOR@@|${VENDOR}|g" \
    -e "s|@@VERSION@@|${PRODUCT_VERSION}|g" \
    -e "s|@@FULL_VERSION@@|${PRODUCT_FULL_VERSION}|g" \
    -e "s|@@HW_VERSION@@|${HW_VERSION}|g" \
    -e "s|@@CPUS@@|${CPUS}|g" \
    -e "s|@@MEMORY_MB@@|${MEMORY_MB}|g" \
    -e "s|@@FIRMWARE@@|${FIRMWARE}|g" \
    "$TEMPLATE" > "$OVF_PATH"

MF_PATH="$OUTPUT_DIR/${OUTPUT_NAME}.mf"
log "Writing OVF manifest: $MF_PATH"
(
    cd "$OUTPUT_DIR"
    {
        printf 'SHA256(%s)= %s\n' "$(basename "$OVF_PATH")"  "$(sha256sum "$(basename "$OVF_PATH")"  | awk '{print $1}')"
        printf 'SHA256(%s)= %s\n' "$VMDK_NAME"               "$(sha256sum "$VMDK_NAME"               | awk '{print $1}')"
    } > "$MF_PATH"

    sha256sum "$(basename "$OVF_PATH")" "$VMDK_NAME" "$(basename "$MF_PATH")" > SHA256SUMS
)

log "Done. Artifacts in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR/${OUTPUT_NAME}".* "$OUTPUT_DIR/SHA256SUMS" >&2
