#!/usr/bin/env bash
# test-esxi.sh — Upload an OVA bundle to ESXi and verify cloud-init works.
#
# Reusable test harness for any OVA produced by build-ova.sh:
#   1. Verifies the local .ovf/.vmdk/.mf bundle against its manifest.
#   2. Imports the OVF to ESXi via govc.
#   3. Injects cloud-init guestinfo.metadata (hostname + DHCP network).
#   4. Powers on the VM and waits for open-vm-tools to report a guest IP.
#   5. Confirms cloud-init applied the hostname (proves VMware datasource works).
#   6. Cleans up unless KEEP_VM=1.
#
# Required env:
#   ESXI_HOST        — ESXi hostname or IP (no scheme), e.g. 192.168.1.55
#   ESXI_USER        — username (typically 'root')
#   ESXI_PASSWORD    — password
#
# Optional env:
#   OVA_DIR          — directory holding .ovf + .vmdk + .mf  (default: ./_out, then current dir)
#   OVA_NAME         — basename of the .ovf (default: auto-detect single .ovf in OVA_DIR)
#   ESXI_DATASTORE   — target datastore name, or 'auto' to pick the first one
#                      with at least MIN_FREE_GIB free space (default: auto)
#   MIN_FREE_GIB     — free-space threshold for ESXI_DATASTORE=auto (default: 10)
#   ESXI_NETWORK     — port-group name, or 'auto' to prefer 'VM Network' then
#                      first non-Management network (default: auto)
#   TEST_VM_NAME     — VM name on ESXi (default: alpine-ova-test-<pid>)
#   TEST_HOSTNAME    — hostname cloud-init should set; used as success signal (default: alpine-ovatest)
#   WAIT_SECONDS     — how long to wait for guest tools + cloud-init (default: 120)
#   KEEP_VM          — set to 1 to skip cleanup (default: unset → cleanup on exit)
#   GOVC_INSECURE    — passed through to govc (default: 1, for self-signed certs)
#
# Exit: 0 = all checks passed, non-zero = something failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
: "${ESXI_HOST:?ESXI_HOST must be set}"
: "${ESXI_USER:?ESXI_USER must be set}"
: "${ESXI_PASSWORD:?ESXI_PASSWORD must be set}"

: "${ESXI_DATASTORE:=auto}"   # name, or 'auto' to pick first with MIN_FREE_GIB
: "${ESXI_NETWORK:=auto}"     # portgroup name, or 'auto' to prefer 'VM Network'
: "${TEST_VM_NAME:=alpine-ova-test-$$}"
: "${TEST_HOSTNAME:=alpine-ovatest}"
: "${WAIT_SECONDS:=120}"
: "${MIN_FREE_GIB:=10}"        # threshold for 'auto' datastore pick
: "${GOVC_INSECURE:=1}"

# OVA_DIR: prefer ./_out (where build-ova.sh writes), else current dir.
if [ -z "${OVA_DIR:-}" ]; then
    if [ -d ./_out ] && ls ./_out/*.ovf >/dev/null 2>&1; then OVA_DIR=./_out; else OVA_DIR=.; fi
fi

# OVA_NAME: auto-detect the single .ovf in OVA_DIR.
if [ -z "${OVA_NAME:-}" ]; then
    ovfs=$(find "$OVA_DIR" -maxdepth 1 -name '*.ovf' -printf '%f\n')
    count=$(printf '%s\n' "$ovfs" | grep -c . || true)
    [ "$count" = 1 ] || { echo "ERROR: expected exactly 1 .ovf in $OVA_DIR, found $count: $ovfs" >&2; exit 1; }
    OVA_NAME="${ovfs%.ovf}"
fi

OVF_FILE="$OVA_DIR/${OVA_NAME}.ovf"
MF_FILE="$OVA_DIR/${OVA_NAME}.mf"

export GOVC_URL="https://${ESXI_USER}:${ESXI_PASSWORD}@${ESXI_HOST}"
export GOVC_INSECURE
# GOVC_DATASTORE is set later, after auto-pick if requested.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    rc=$?
    if [ "${KEEP_VM:-0}" = "1" ]; then
        log "KEEP_VM=1 — leaving VM '$TEST_VM_NAME' on $ESXI_HOST for inspection."
        return
    fi
    log "Cleaning up VM '$TEST_VM_NAME'…"
    govc vm.power -off -force "$TEST_VM_NAME" >/dev/null 2>&1 || true
    govc vm.destroy "$TEST_VM_NAME" >/dev/null 2>&1 || true
    # Datastore staging dir (set later if we get past the SSH section)
    if [ -n "${STAGE_REMOTE_DIR:-}" ]; then
        ssh_esxi "rm -rf '$STAGE_REMOTE_DIR'" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
command -v govc >/dev/null 2>&1 || fail "govc not on PATH (install: https://github.com/vmware/govmomi/releases)"
command -v jq   >/dev/null 2>&1 || fail "jq not on PATH (apt install jq / brew install jq)"
command -v base64 >/dev/null 2>&1 || fail "base64 not on PATH"
command -v ssh  >/dev/null 2>&1 || fail "ssh not on PATH"
command -v sshpass >/dev/null 2>&1 || fail "sshpass not on PATH (apt install sshpass / brew install hudochenkov/sshpass/sshpass)"

# Local ovftool: ESXi may already have a cached copy at
# /vmfs/volumes/<ds>/vmware-ovftool/ — we'll check there first and only
# need a local source if ESXi doesn't have one. Resolution order:
#   1. $OVFTOOL_DIR (explicit override)
#   2. ./ovftool/   (project-local bundled copy)
#   3. dirname of the binary on PATH (system install root)
# OVFTOOL_LOCAL_DIR remains empty if none is found; we'll re-check ESXi
# before complaining.
OVFTOOL_LOCAL_DIR=""
if [ -n "${OVFTOOL_DIR:-}" ] && [ -x "$OVFTOOL_DIR/ovftool" ]; then
    OVFTOOL_LOCAL_DIR="$OVFTOOL_DIR"
elif [ -x "./ovftool/ovftool" ]; then
    OVFTOOL_LOCAL_DIR="$(cd ./ovftool && pwd)"
elif command -v ovftool >/dev/null 2>&1; then
    OVFTOOL_LOCAL_DIR="$(dirname "$(readlink -f "$(command -v ovftool)")")"
fi

[ -f "$OVF_FILE" ] || fail "OVF not found: $OVF_FILE"
[ -f "$MF_FILE" ]  || fail "Manifest not found: $MF_FILE"

log "Bundle: $OVA_DIR/${OVA_NAME}.{ovf,vmdk,mf}"
log "Target: $ESXI_HOST (network=$ESXI_NETWORK, datastore=$ESXI_DATASTORE)"
log "VM:     $TEST_VM_NAME (hostname=$TEST_HOSTNAME)"

# ---------------------------------------------------------------------------
# 2. Verify local manifest before upload
# ---------------------------------------------------------------------------
log "Verifying local manifest…"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    fname="${line#SHA256(}"; fname="${fname%)=*}"
    want="${line##* }"
    [ -f "$OVA_DIR/$fname" ] || fail "manifest references missing file: $fname"
    got=$(sha256sum "$OVA_DIR/$fname" | awk '{print $1}')
    [ "$want" = "$got" ] || fail "manifest mismatch for $fname: want=$want got=$got"
done < "$MF_FILE"
pass "manifest verified"

# ---------------------------------------------------------------------------
# 3. Connectivity probe + idempotent cleanup
# ---------------------------------------------------------------------------
log "Probing ESXi connectivity…"
govc about >/dev/null || fail "govc cannot connect to $ESXI_HOST (check ESXI_HOST/USER/PASSWORD, network reachability, GOVC_INSECURE)"
pass "connected to $ESXI_HOST"

# ---------------------------------------------------------------------------
# 3b. Datastore: explicit name, or auto-pick first with enough free space.
# ---------------------------------------------------------------------------
if [ "$ESXI_DATASTORE" = "auto" ]; then
    log "Auto-selecting datastore with ≥${MIN_FREE_GIB} GiB free…"
    min_bytes=$((MIN_FREE_GIB * 1024 * 1024 * 1024))
    # govc ls -t Datastore returns paths like '/ha-datacenter/datastore/datastore1'.
    # For each, govc datastore.info -json returns .Datastores[0].Info.FreeSpace (bytes).
    picked=""; picked_free=""
    # govc datastore.info -json (no args) returns ALL datastores in one shot
    # under .datastores[]; each has .info.name and .info.freeSpace (bytes).
    # Lowercase keys — case matters in jq.
    while IFS=$'\t' read -r ds_name free; do
        [ -z "$ds_name" ] && continue
        if [ "$free" -ge "$min_bytes" ] 2>/dev/null; then
            picked="$ds_name"; picked_free="$free"
            break
        fi
    done < <(govc datastore.info -json 2>/dev/null \
        | jq -r '.datastores[] | "\(.info.name)\t\(.info.freeSpace)"')
    if [ -z "$picked" ]; then
        log "No datastore had ≥${MIN_FREE_GIB} GiB free. Available:"
        govc datastore.info 2>&1 | grep -E 'Name:|Free:' | sed 's/^/  /' >&2
        fail "Set ESXI_DATASTORE=<name> explicitly, or lower MIN_FREE_GIB."
    fi
    ESXI_DATASTORE="$picked"
    pass "picked datastore '$ESXI_DATASTORE' ($((picked_free / 1024 / 1024 / 1024)) GiB free)"
fi
export GOVC_DATASTORE="$ESXI_DATASTORE"

# ---------------------------------------------------------------------------
# 3c. Network: explicit name, or auto-pick (prefer 'VM Network', else first
#     non-Management portgroup, else first available).
# ---------------------------------------------------------------------------
if [ "$ESXI_NETWORK" = "auto" ]; then
    log "Auto-selecting VM network…"
    # `govc ls -t Network` needs an explicit path; `govc find -type n` does not.
    # Returns paths like '/ha-datacenter/network/VM Network'.
    networks=$(govc find -type n 2>/dev/null | sed 's|.*/||' || true)
    [ -n "$networks" ] || fail "no networks visible to govc — check ESXi permissions"
    picked_net=""
    # Preference 1: literal 'VM Network'.
    if printf '%s\n' "$networks" | grep -Fxq 'VM Network'; then
        picked_net='VM Network'
    else
        # Preference 2: first that doesn't look like a Management/vmkernel portgroup.
        picked_net=$(printf '%s\n' "$networks" | grep -viE 'management|vmkernel|vmotion' | head -1)
        # Preference 3: fall back to whatever's first.
        [ -n "$picked_net" ] || picked_net=$(printf '%s\n' "$networks" | head -1)
    fi
    ESXI_NETWORK="$picked_net"
    pass "picked network '$ESXI_NETWORK'"
fi

if govc vm.info "$TEST_VM_NAME" 2>/dev/null | grep -q '^Name:'; then
    log "Removing pre-existing VM '$TEST_VM_NAME'…"
    govc vm.power -off -force "$TEST_VM_NAME" >/dev/null 2>&1 || true
    govc vm.destroy "$TEST_VM_NAME"
fi

# ---------------------------------------------------------------------------
# 4. Import OVF via ovftool running ON ESXi (works on free + licensed alike).
# ---------------------------------------------------------------------------
# Helper: run a command on the ESXi shell via sshpass+ssh.
ssh_esxi() {
    SSHPASS="$ESXI_PASSWORD" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${ESXI_USER}@${ESXI_HOST}" "$@"
}

OVFTOOL_REMOTE_DIR="/vmfs/volumes/${ESXI_DATASTORE}/vmware-ovftool"
STAGE_REMOTE_DIR="/vmfs/volumes/${ESXI_DATASTORE}/.ova-stage-${TEST_VM_NAME}"

# 4a. Cache check: does ESXi already have ovftool?
log "Checking for cached ovftool on ESXi at ${OVFTOOL_REMOTE_DIR}/ovftool…"
if ssh_esxi "[ -x ${OVFTOOL_REMOTE_DIR}/ovftool ]" 2>/dev/null; then
    pass "ovftool already present on ESXi (cached)"
else
    log "Not present — need to upload from this workstation."
    if [ -z "$OVFTOOL_LOCAL_DIR" ]; then
        cat >&2 <<'EOF'
ERROR: ESXi has no cached ovftool, and none is available locally to upload.

Set one up locally (any of these works), then re-run this script. The first
run uploads it to the ESXi datastore; subsequent runs reuse the cached copy.

  Get it from Broadcom (free, account registration required):
    https://developer.broadcom.com/tools/open-virtualization-format-ovf-tool/latest
    Look for the bundle matching your OS, e.g.:
        VMware-ovftool-4.6.3-24031167-lin.x86_64.zip       (Linux)
        VMware-ovftool-4.6.3-24031167-mac.x64.zip          (macOS)

  Or pull from the rgl/ovftool-binaries community mirror:
    curl -fsSL -o /tmp/ovftool.zip \
      https://github.com/rgl/ovftool-binaries/raw/main/archive/VMware-ovftool-4.6.3-24031167-lin.x86_64.zip
    unzip /tmp/ovftool.zip -d "$HOME/.local/"
    export PATH="$HOME/.local/ovftool:$PATH"
    ovftool --version

Or point the script at an unpacked tree:
    OVFTOOL_DIR=/path/to/vmware-ovftool ./test-esxi.sh
EOF
        exit 1
    fi
    log "Uploading ovftool from $OVFTOOL_LOCAL_DIR → ${OVFTOOL_REMOTE_DIR}/"
    ssh_esxi "mkdir -p '$OVFTOOL_REMOTE_DIR'"
    # Upload every file in the install dir, preserving relative paths.
    cd "$OVFTOOL_LOCAL_DIR"
    file_count=$(find . -type f | wc -l)
    i=0
    find . -type f | while IFS= read -r f; do
        rel="${f#./}"
        i=$((i + 1))
        printf '\r  [%d/%d] %s' "$i" "$file_count" "$rel" >&2
        govc datastore.upload "$rel" "vmware-ovftool/$rel" >/dev/null
    done
    printf '\n' >&2
    # Mark the wrapper + binary executable; patch shebang from bash to sh
    # (ESXi shell doesn't have bash).
    ssh_esxi "chmod +x '${OVFTOOL_REMOTE_DIR}/ovftool' '${OVFTOOL_REMOTE_DIR}/ovftool.bin' 2>/dev/null; \
              sed -i '1s|^#!/bin/bash|#!/bin/sh|' '${OVFTOOL_REMOTE_DIR}/ovftool' 2>/dev/null; \
              true"
    cd - >/dev/null
    pass "ovftool uploaded and patched (cached for next time)"
fi

# 4b. Upload the OVA bundle to a staging dir on the datastore.
log "Uploading OVA bundle to ESXi staging dir…"
ssh_esxi "mkdir -p '$STAGE_REMOTE_DIR'"
stage_rel=".ova-stage-${TEST_VM_NAME}"
for f in "${OVA_NAME}.ovf" "${OVA_NAME}.mf" "${OVA_NAME}-disk1.vmdk"; do
    govc datastore.upload "$OVA_DIR/$f" "$stage_rel/$f" >/dev/null
done
pass "bundle staged at $STAGE_REMOTE_DIR"

# 4c. Run ovftool ON ESXi targeting localhost.
# URI-encode the password (chars like '!' '@' '/' ':' are reserved in vi:// URLs).
pw_enc=$(printf '%s' "$ESXI_PASSWORD" | jq -sRr @uri)
log "Deploying via ovftool (running on ESXi, target=localhost)…"
ssh_esxi "${OVFTOOL_REMOTE_DIR}/ovftool \
    --datastore='${ESXI_DATASTORE}' \
    --diskMode=thin \
    --name='${TEST_VM_NAME}' \
    --network='${ESXI_NETWORK}' \
    --noSSLVerify \
    --acceptAllEulas \
    --skipManifestCheck \
    '${STAGE_REMOTE_DIR}/${OVA_NAME}.ovf' \
    'vi://${ESXI_USER}:${pw_enc}@localhost'" >/dev/null

# Clean up staging files (datastore.rm is blocked on free ESXi, so use ssh).
ssh_esxi "rm -rf '$STAGE_REMOTE_DIR'" || true

pass "imported as '$TEST_VM_NAME'"

# ---------------------------------------------------------------------------
# 5. Inject cloud-init guestinfo (VMware datasource consumes this)
# ---------------------------------------------------------------------------
log "Injecting cloud-init guestinfo (hostname=$TEST_HOSTNAME, eth0=DHCP)…"
metadata=$(printf '%s\n' \
    "instance-id: ${TEST_VM_NAME}" \
    "local-hostname: ${TEST_HOSTNAME}" \
    "network:" \
    "  version: 2" \
    "  ethernets:" \
    "    eth0:" \
    "      dhcp4: true")
metadata_b64=$(printf '%s' "$metadata" | base64 -w0 2>/dev/null || printf '%s' "$metadata" | base64)

govc vm.change -vm "$TEST_VM_NAME" \
    -e "guestinfo.metadata=${metadata_b64}" \
    -e "guestinfo.metadata.encoding=base64"
pass "guestinfo set"

# ---------------------------------------------------------------------------
# 6. Power on and wait for guest tools
# ---------------------------------------------------------------------------
log "Powering on…"
govc vm.power -on "$TEST_VM_NAME" >/dev/null
pass "powered on"

log "Waiting up to ${WAIT_SECONDS}s for open-vm-tools to report guest IP…"
# govc vm.ip waits for an IP up to the timeout and prints it.
guest_ip=$(govc vm.ip -wait "${WAIT_SECONDS}s" "$TEST_VM_NAME" 2>&1 || true)
if ! [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "no guest IP within ${WAIT_SECONDS}s — open-vm-tools didn't start, or DHCP failed. Got: $guest_ip"
fi
pass "guest IP: $guest_ip (open-vm-tools is running)"

# ---------------------------------------------------------------------------
# 7. Verify cloud-init set hostname (proves VMware datasource consumed guestinfo)
# ---------------------------------------------------------------------------
log "Verifying cloud-init applied hostname…"
# vm.info shows guest.hostName which is reported by open-vm-tools. Cloud-init
# may take 10-30s after IP comes up to finish setting hostname; poll briefly.
deadline=$(( $(date +%s) + 60 ))
got_hostname=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    got_hostname=$(govc vm.info -json "$TEST_VM_NAME" 2>/dev/null \
        | jq -r '..|.HostName?//empty' | head -1)
    [ "$got_hostname" = "$TEST_HOSTNAME" ] && break
    sleep 3
done

if [ "$got_hostname" = "$TEST_HOSTNAME" ]; then
    pass "guest hostname = '$got_hostname' (cloud-init + VMware datasource works)"
else
    fail "guest hostname is '$got_hostname', expected '$TEST_HOSTNAME' — cloud-init didn't apply guestinfo.metadata"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "All checks passed."
echo
echo "  VM:          $TEST_VM_NAME"
echo "  Guest IP:    $guest_ip"
echo "  Hostname:    $got_hostname"
echo "  Bundle:      $OVA_DIR/${OVA_NAME}.ovf"
echo "  Cleanup:     ${KEEP_VM:+SKIPPED (KEEP_VM=1)}${KEEP_VM:-on exit}"
