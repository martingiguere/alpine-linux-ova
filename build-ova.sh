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
: "${INSTALL_OPENSSH:=1}"
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

# ---------------------------------------------------------------------------
# Platform + prerequisite detection
# ---------------------------------------------------------------------------
# Required commands. Mapped to per-package-manager package names below.
REQUIRED_CMDS="curl qemu-img qemu-nbd sha1sum sha256sum sudo sfdisk rsync awk sed tar"

detect_platform() {
    case "$(uname -s)" in
        Darwin) PLATFORM=macos; PKG_MGR=brew; return ;;
        Linux)  PLATFORM=linux ;;
        *)      PLATFORM=unknown; PKG_MGR=unknown; return ;;
    esac
    PKG_MGR=unknown
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case " ${ID_LIKE:-} ${ID:-} " in
            *" debian "*|*" ubuntu "*) PKG_MGR=apt ;;
            *" rhel "*|*" fedora "*|*" centos "*) PKG_MGR=dnf ;;
        esac
    fi
    # Fall back to whichever installer is on PATH.
    if [ "$PKG_MGR" = unknown ]; then
        if command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
        elif command -v dnf   >/dev/null 2>&1; then PKG_MGR=dnf
        fi
    fi
}

# Map a missing command to its package name for the active package manager.
pkg_for_cmd() {
    case "$PKG_MGR:$1" in
        apt:qemu-img|apt:qemu-nbd)         echo qemu-utils ;;
        apt:sfdisk)                        echo util-linux ;;
        apt:sha1sum|apt:sha256sum)         echo coreutils ;;
        dnf:qemu-img|dnf:qemu-nbd)         echo qemu-img ;;
        dnf:sfdisk)                        echo util-linux ;;
        dnf:sha1sum|dnf:sha256sum)         echo coreutils ;;
        brew:qemu-img|brew:qemu-nbd)       echo qemu ;;
        brew:sha1sum|brew:sha256sum)       echo coreutils ;;
        *:*)                               echo "$1" ;;
    esac
}

check_prereqs() {
    detect_platform

    # macOS — fail fast. qemu-nbd needs Linux kernel NBD; no amount of brew helps.
    if [ "$PLATFORM" = macos ]; then
        cat >&2 <<'EOF'
ERROR: macOS is not supported as a build host.

build-ova.sh uses qemu-nbd, which depends on the Linux kernel's NBD driver.
Even with `brew install qemu` providing qemu-img/qemu-nbd binaries, the kernel
driver is unavailable on Darwin, so the build cannot complete.

Workarounds (pick one):

  1. GitHub Actions (recommended):
       Push to GitHub, run on an ubuntu-latest runner. See .github/workflows/.

  2. Docker (Docker Desktop or colima with a privileged Linux container):
       docker run --rm -it --privileged -v "$PWD:/build" -w /build ubuntu:24.04 \
         bash -c 'apt-get update && apt-get install -y qemu-utils sudo rsync \
                   curl sfdisk e2fsprogs && ./build-ova.sh'

  3. A Linux VM (UTM, Multipass, Lima) with qemu-utils installed.
EOF
        exit 1
    fi

    # Linux — collect missing commands.
    missing=""
    for cmd in $REQUIRED_CMDS; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done

    # Cross-arch (path C): host arch != target ARCH → need qemu-user-static + binfmt.
    host_arch="$(uname -m)"
    cross_pkg=""
    if [ "$host_arch" != "$ARCH" ]; then
        if [ ! -e "/proc/sys/fs/binfmt_misc/qemu-${ARCH}" ]; then
            case "$PKG_MGR" in
                apt) cross_pkg="qemu-user-static binfmt-support" ;;
                dnf) cross_pkg="qemu-user-static" ;;
                *)   cross_pkg="qemu-user-static (and binfmt registration)" ;;
            esac
        fi
    fi

    if [ -n "$missing" ] || [ -n "$cross_pkg" ]; then
        # Dedupe pkg names.
        pkgs=""
        for cmd in $missing; do
            p="$(pkg_for_cmd "$cmd")"
            case " $pkgs " in *" $p "*) ;; *) pkgs="$pkgs $p" ;; esac
        done
        [ -n "$cross_pkg" ] && pkgs="$pkgs $cross_pkg"
        pkgs="$(echo "$pkgs" | tr -s ' ' | sed 's/^ *//')"

        case "$PKG_MGR" in
            apt) install_cmd="sudo apt-get update && sudo apt-get install -y $pkgs" ;;
            dnf) install_cmd="sudo dnf install -y $pkgs" ;;
            *)   install_cmd="# install these packages with your package manager: $pkgs" ;;
        esac

        {
            printf 'ERROR: build host is not ready.\n\n'
            [ -n "$missing" ]   && printf '  Missing commands:%s\n' "$missing"
            [ -n "$cross_pkg" ] && printf '  Cross-build required: host=%s target=%s — need binfmt for qemu-%s\n' "$host_arch" "$ARCH" "$ARCH"
            printf '\nInstall with (%s):\n  %s\n\n' "${PKG_MGR:-unknown package manager}" "$install_cmd"
            [ "$PKG_MGR" = unknown ] && printf 'Note: no supported package manager detected (looked for apt-get, dnf).\n      Adapt the package names to your distro.\n\n'
            [ -n "$cross_pkg" ] && [ "$PKG_MGR" = apt ] && \
                printf 'After install, register binfmt handlers if not auto-registered:\n  sudo systemctl restart systemd-binfmt   # or: sudo update-binfmts --enable\n\n'
        } >&2
        exit 1
    fi

    # NBD device nodes must be present. Containers without --privileged or
    # without /dev/nbd* passed through cannot run qemu-nbd.
    if [ ! -e /dev/nbd0 ]; then
        if command -v modprobe >/dev/null 2>&1; then
            log "Loading nbd kernel module (requires sudo)…"
            sudo modprobe nbd max_part=16 || die "modprobe nbd failed — kernel must have NBD support compiled in"
        else
            die "/dev/nbd0 missing and modprobe unavailable. If this is a container, re-run with --privileged and ensure the host has 'nbd' kernel module loaded."
        fi
    fi
}

check_prereqs

[ -f "$TEMPLATE" ]      || die "OVF template not found: $TEMPLATE"
[ -f "$DEFAULT_SETUP" ] || die "Default setup script not found: $DEFAULT_SETUP"
[ -z "$CUSTOMIZE_SCRIPT" ] || [ -f "$CUSTOMIZE_SCRIPT" ] || die "CUSTOMIZE_SCRIPT not found: $CUSTOMIZE_SCRIPT"

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
# Build the package list. Alpine splits OpenRC service files into *-openrc
# subpackages — if we forget one, the service doesn't exist and our
# `rc-update add` calls in alpine-image-setup.sh silently no-op.
PACKAGES="curl"
[ "$INSTALL_NTP" = "1" ]           && PACKAGES="$PACKAGES chrony chrony-openrc"
[ "$INSTALL_CLOUD_INIT" = "1" ]    && PACKAGES="$PACKAGES cloud-init cloud-init-openrc cloud-init-datasource-vmware cloud-init-datasource-nocloud"
[ "$INSTALL_OPEN_VM_TOOLS" = "1" ] && PACKAGES="$PACKAGES open-vm-tools open-vm-tools-openrc open-vm-tools-guestinfo open-vm-tools-vix"
[ "$INSTALL_OPENSSH" = "1" ]      && PACKAGES="$PACKAGES openssh openssh-server openssh-server-common-openrc"
[ -n "$EXTRA_PACKAGES" ]           && PACKAGES="$PACKAGES $EXTRA_PACKAGES"
EXPECTED_PACKAGES="$PACKAGES"   # captured for post-install verification

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
# Write repos to a real file (NOT /dev/stdin — heredoc pipes don't survive
# `sudo env`; alpine-make-vm-image's `install -m644` on the missing pipe
# silently produces an empty image with no apk repos configured).
REPOS_FILE="$WORK/repositories"
cat > "$REPOS_FILE" <<EOF
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main
https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community
EOF

QCOW2="$WORK/${OUTPUT_NAME}.qcow2"
log "Building qcow2: $QCOW2 (${DISK_SIZE_GB}G, branch $ALPINE_BRANCH, arch $ARCH)"
sudo env \
    EXPECTED_PACKAGES="$EXPECTED_PACKAGES" \
    CLOUD_INIT="$INSTALL_CLOUD_INIT" \
    OPEN_VM_TOOLS="$INSTALL_OPEN_VM_TOOLS" \
    OPENSSH="$INSTALL_OPENSSH" \
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
        --repositories-file "$REPOS_FILE" \
        --serial-console \
        --script-chroot \
        "$QCOW2" "$CHROOT_SCRIPT"

sudo chown "$(id -u):$(id -g)" "$QCOW2"

# Sanity: a base + cloud-init + open-vm-tools image is ≥250 MB uncompressed,
# ≥100 MB qcow2 actual-size. A 2-3 MB image means the install silently failed.
QCOW_BYTES=$(qemu-img info --output=json "$QCOW2" | awk -F'[ ,:]+' '/"actual-size"/{print $3; exit}')
MIN_BYTES=$((100 * 1024 * 1024))
if [ "${QCOW_BYTES:-0}" -lt "$MIN_BYTES" ]; then
    die "qcow2 actual-size is $QCOW_BYTES bytes (< 100 MB threshold) — install likely failed silently. Check alpine-make-vm-image output above."
fi

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
