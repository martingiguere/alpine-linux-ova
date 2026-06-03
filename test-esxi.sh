#!/usr/bin/env bash
# test-esxi.sh — Upload an OVA bundle to ESXi/vCenter and verify cloud-init works.
#
# Reusable test harness for any OVA produced by build-ova.sh. Supports both
# licensed and free-license ESXi hosts via two deploy paths picked at runtime:
#
#   DEPLOY_MODE=govc   Licensed ESXi / vCenter: ovftool from this workstation
#                      targeting the remote host, govc for vm.change/power/destroy.
#                      Fast.
#   DEPLOY_MODE=ssh    Free / unlicensed ESXi (SOAP write API gated by the
#                      license): scp ovftool to the host once (cached on the
#                      datastore), run via SSH targeting localhost, use vim-cmd
#                      for power/destroy. Slower (requires SCP of ovftool the
#                      first time, ~30 MB).
#   DEPLOY_MODE=auto   (default) Probe a no-op SOAP write call; license error
#                      → ssh, anything else → govc.
#
# Pipeline (identical for both modes):
#   1. Verify the local .ovf/.vmdk/.mf bundle against its manifest.
#   2. Auto-pick datastore + network (override with env).
#   3. Deploy via ovftool with cloud-init metadata baked in as
#      --prop:guestinfo.metadata=<base64>. This avoids a separate vm.change
#      call (also gated on free).
#   4. Power on.
#   5. Wait for open-vm-tools to report a guest IP.
#   6. Confirm cloud-init applied the test hostname (proves the VMware
#      datasource consumed guestinfo).
#   7. Clean up unless KEEP_VM=1.
#
# Required env:
#   ESXI_HOST        — hostname or IP (no scheme), e.g. 192.168.1.55
#   ESXI_USER        — username (typically 'root')
#   ESXI_PASSWORD    — password
#
# Optional env (with defaults):
#   DEPLOY_MODE      — auto | govc | ssh                                (auto)
#   OVA_DIR          — dir holding .ovf + .vmdk + .mf                   (./_out, then ./)
#   OVA_NAME         — basename of the .ovf                             (auto-detect)
#   ESXI_DATASTORE   — datastore name, or 'auto'                        (auto)
#   MIN_FREE_GIB     — threshold for ESXI_DATASTORE=auto                (10)
#   ESXI_NETWORK     — portgroup name, or 'auto'                        (auto)
#   TEST_VM_NAME     — VM name on ESXi                                  (alpine-ova-test-<pid>)
#   TEST_HOSTNAME    — hostname cloud-init should set                   (alpine-ovatest)
#   WAIT_SECONDS     — timeout for guest tools + DHCP                   (120)
#   KEEP_VM          — set to 1 to skip cleanup                         (unset)
#   GOVC_INSECURE    — passed to govc                                   (1)
#   OVFTOOL_DIR      — override location of local ovftool install dir   (unset)
#
# Exit: 0 = pass, non-zero = fail.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
: "${ESXI_HOST:?ESXI_HOST must be set}"
: "${ESXI_USER:?ESXI_USER must be set}"
: "${ESXI_PASSWORD:?ESXI_PASSWORD must be set}"

: "${ESXI_DATASTORE:=auto}"
: "${ESXI_NETWORK:=auto}"
: "${TEST_VM_NAME:=alpine-ova-test-$$}"
: "${TEST_HOSTNAME:=alpine-ovatest}"
: "${WAIT_SECONDS:=120}"
: "${MIN_FREE_GIB:=10}"
: "${GOVC_INSECURE:=1}"
: "${DEPLOY_MODE:=auto}"

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

ssh_esxi() {
    SSHPASS="$ESXI_PASSWORD" sshpass -e ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${ESXI_USER}@${ESXI_HOST}" "$@"
}

scp_to_esxi() {
    SSHPASS="$ESXI_PASSWORD" sshpass -e scp \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$@"
}

# Look up a VM's vmid via vim-cmd (ssh mode only).
get_vmid() {
    ssh_esxi "vim-cmd vmsvc/getallvms 2>/dev/null | awk '/[[:space:]]$1[[:space:]]/ {print \$1; exit}'"
}

# Mode-dispatching cleanup. Both branches are idempotent and safe to call
# on a half-failed deploy.
DEPLOY_MODE_RESOLVED=""
STAGE_REMOTE_DIR=""

cleanup() {
    rc=$?
    if [ "${KEEP_VM:-0}" = "1" ]; then
        log "KEEP_VM=1 — leaving VM '$TEST_VM_NAME' on $ESXI_HOST for inspection."
        return
    fi
    log "Cleaning up VM '$TEST_VM_NAME'…"
    case "$DEPLOY_MODE_RESOLVED" in
        govc)
            govc vm.power -off -force "$TEST_VM_NAME" >/dev/null 2>&1 || true
            govc vm.destroy "$TEST_VM_NAME" >/dev/null 2>&1 || true
            ;;
        ssh)
            vmid=$(get_vmid "$TEST_VM_NAME" 2>/dev/null || true)
            if [ -n "$vmid" ]; then
                ssh_esxi "vim-cmd vmsvc/power.off $vmid 2>/dev/null; \
                          vim-cmd vmsvc/unregister $vmid 2>/dev/null" >/dev/null || true
            fi
            ssh_esxi "rm -rf /vmfs/volumes/${ESXI_DATASTORE}/${TEST_VM_NAME}" 2>/dev/null || true
            if [ -n "$STAGE_REMOTE_DIR" ]; then
                ssh_esxi "rm -rf '$STAGE_REMOTE_DIR'" 2>/dev/null || true
            fi
            ;;
    esac
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Pre-flight tool check
# ---------------------------------------------------------------------------
command -v govc    >/dev/null 2>&1 || fail "govc not on PATH (install: https://github.com/vmware/govmomi/releases)"
command -v jq      >/dev/null 2>&1 || fail "jq not on PATH (apt install jq / brew install jq)"
command -v base64  >/dev/null 2>&1 || fail "base64 not on PATH"
command -v ovftool >/dev/null 2>&1 || \
    [ -n "${OVFTOOL_DIR:-}" ] && [ -x "$OVFTOOL_DIR/ovftool" ] || \
    [ -x "./ovftool/ovftool" ] || \
    fail "ovftool not found (PATH, OVFTOOL_DIR, or ./ovftool/). See README for install instructions."
# ssh+sshpass only required if we end up in ssh mode; check after detection.

[ -f "$OVF_FILE" ] || fail "OVF not found: $OVF_FILE"
[ -f "$MF_FILE" ]  || fail "Manifest not found: $MF_FILE"

log "Bundle: $OVA_DIR/${OVA_NAME}.{ovf,vmdk,mf}"
log "Target: $ESXI_HOST (network=$ESXI_NETWORK, datastore=$ESXI_DATASTORE, mode=$DEPLOY_MODE)"
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
# 3. Connect + auto-pick datastore / network (works for both modes)
# ---------------------------------------------------------------------------
log "Probing ESXi connectivity…"
govc about >/dev/null || fail "govc cannot connect to $ESXI_HOST"
pass "connected to $ESXI_HOST"

if [ "$ESXI_DATASTORE" = "auto" ]; then
    log "Auto-selecting datastore with ≥${MIN_FREE_GIB} GiB free…"
    min_bytes=$((MIN_FREE_GIB * 1024 * 1024 * 1024))
    picked=""; picked_free=""
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

if [ "$ESXI_NETWORK" = "auto" ]; then
    log "Auto-selecting VM network…"
    networks=$(govc find -type n 2>/dev/null | sed 's|.*/||' || true)
    [ -n "$networks" ] || fail "no networks visible to govc"
    if printf '%s\n' "$networks" | grep -Fxq 'VM Network'; then
        ESXI_NETWORK='VM Network'
    else
        ESXI_NETWORK=$(printf '%s\n' "$networks" | grep -viE 'management|vmkernel|vmotion' | head -1)
        [ -n "$ESXI_NETWORK" ] || ESXI_NETWORK=$(printf '%s\n' "$networks" | head -1)
    fi
    pass "picked network '$ESXI_NETWORK'"
fi

# ---------------------------------------------------------------------------
# 4. Deploy mode detection
# ---------------------------------------------------------------------------
if [ "$DEPLOY_MODE" = "auto" ]; then
    log "Probing SOAP write capability to choose deploy mode…"
    # datastore.rm on a nonexistent path hits the license gate BEFORE the
    # existence check on free ESXi (file ops are write-API methods). On
    # licensed hosts, it returns 'file not found' or similar. This is the
    # most reliable probe; vm.power and vm.destroy short-circuit on
    # 'vm not found' before reaching the license check.
    probe_err=$(govc datastore.rm "__esxi_mode_probe_nonexistent__" 2>&1 || true)
    case "$probe_err" in
        *license*|*License*)
            DEPLOY_MODE_RESOLVED=ssh
            pass "probe: license-gated host detected → DEPLOY_MODE=ssh"
            ;;
        *)
            DEPLOY_MODE_RESOLVED=govc
            pass "probe: SOAP writes allowed → DEPLOY_MODE=govc"
            ;;
    esac
else
    DEPLOY_MODE_RESOLVED="$DEPLOY_MODE"
    log "DEPLOY_MODE=$DEPLOY_MODE_RESOLVED (explicit)"
fi

if [ "$DEPLOY_MODE_RESOLVED" = "ssh" ]; then
    command -v ssh     >/dev/null 2>&1 || fail "ssh not on PATH (required for DEPLOY_MODE=ssh)"
    command -v sshpass >/dev/null 2>&1 || fail "sshpass not on PATH (apt install sshpass / brew install hudochenkov/sshpass/sshpass)"
fi

# Resolve local ovftool install dir (for both modes; in ssh mode we may not
# need it if ESXi already has a cached copy).
OVFTOOL_LOCAL_DIR=""
if [ -n "${OVFTOOL_DIR:-}" ] && [ -x "$OVFTOOL_DIR/ovftool" ]; then
    OVFTOOL_LOCAL_DIR="$OVFTOOL_DIR"
elif [ -x "./ovftool/ovftool" ]; then
    OVFTOOL_LOCAL_DIR="$(cd ./ovftool && pwd)"
elif command -v ovftool >/dev/null 2>&1; then
    OVFTOOL_LOCAL_DIR="$(dirname "$(readlink -f "$(command -v ovftool)")")"
fi

# ---------------------------------------------------------------------------
# 5. Build cloud-init metadata payload (same for both modes)
# ---------------------------------------------------------------------------
metadata=$(printf '%s\n' \
    "instance-id: ${TEST_VM_NAME}" \
    "local-hostname: ${TEST_HOSTNAME}" \
    "network:" \
    "  version: 2" \
    "  ethernets:" \
    "    eth0:" \
    "      dhcp4: true")
METADATA_B64=$(printf '%s' "$metadata" | base64 -w0 2>/dev/null || printf '%s' "$metadata" | base64)
PW_ENC=$(printf '%s' "$ESXI_PASSWORD" | jq -sRr @uri)

# ---------------------------------------------------------------------------
# 6. Idempotent cleanup of stale VM
# ---------------------------------------------------------------------------
case "$DEPLOY_MODE_RESOLVED" in
    govc)
        if govc vm.info "$TEST_VM_NAME" 2>/dev/null | grep -q '^Name:'; then
            log "Removing pre-existing VM '$TEST_VM_NAME'…"
            govc vm.power -off -force "$TEST_VM_NAME" >/dev/null 2>&1 || true
            govc vm.destroy "$TEST_VM_NAME"
        fi
        ;;
    ssh)
        stale=$(get_vmid "$TEST_VM_NAME" 2>/dev/null || true)
        if [ -n "$stale" ]; then
            log "Removing pre-existing VM '$TEST_VM_NAME' (vmid=$stale)…"
            ssh_esxi "vim-cmd vmsvc/power.off $stale 2>/dev/null; \
                      vim-cmd vmsvc/unregister $stale" >/dev/null
            ssh_esxi "rm -rf /vmfs/volumes/${ESXI_DATASTORE}/${TEST_VM_NAME}"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# 7. Deploy via ovftool — mode-dispatched
# ---------------------------------------------------------------------------
OVFTOOL_REMOTE_DIR="/vmfs/volumes/${ESXI_DATASTORE}/vmware-ovftool"

# ovftool flags. NOTE: we don't pass --prop:guestinfo.* here — those would
# land in the OVF environment, not in VM extraConfig. Cloud-init's VMware
# datasource reads extraConfig via vmware-rpctool, so we must set
# guestinfo.metadata as a true extraConfig key:
#   govc mode: govc vm.change -e guestinfo.metadata=...
#   ssh mode:  append to .vmx + vim-cmd reload
OVFTOOL_FLAGS=(
    "--datastore=${ESXI_DATASTORE}"
    "--diskMode=thin"
    "--name=${TEST_VM_NAME}"
    "--network=${ESXI_NETWORK}"
    "--noSSLVerify"
    "--acceptAllEulas"
    "--skipManifestCheck"
)

if [ "$DEPLOY_MODE_RESOLVED" = "govc" ]; then
    # GOVC mode: run ovftool from workstation, talking to remote ESXi/vCenter.
    [ -n "$OVFTOOL_LOCAL_DIR" ] || fail "ovftool required locally for DEPLOY_MODE=govc"
    log "Deploying via local ovftool → ${ESXI_HOST}…"
    "$OVFTOOL_LOCAL_DIR/ovftool" "${OVFTOOL_FLAGS[@]}" \
        "$OVF_FILE" \
        "vi://${ESXI_USER}:${PW_ENC}@${ESXI_HOST}" >/dev/null
    pass "imported as '$TEST_VM_NAME'"
else
    # SSH mode: ensure ovftool is on the host (cached or freshly uploaded),
    # stage the bundle there, then SSH-exec ovftool with target=localhost.
    STAGE_REMOTE_DIR="/vmfs/volumes/${ESXI_DATASTORE}/.ova-stage-${TEST_VM_NAME}"

    log "Checking for cached ovftool on ESXi at ${OVFTOOL_REMOTE_DIR}/ovftool…"
    if ssh_esxi "[ -x ${OVFTOOL_REMOTE_DIR}/ovftool ]" 2>/dev/null; then
        pass "ovftool already present on ESXi (cached)"
    else
        log "Not present — need to upload from this workstation."
        [ -n "$OVFTOOL_LOCAL_DIR" ] || cat >&2 <<'EOF'
ERROR: ESXi has no cached ovftool, and none is available locally to upload.

Set one up locally (any of these works), then re-run this script. The first
run uploads it to the ESXi datastore; subsequent runs reuse the cached copy.

  Get it from Broadcom (free, account registration required):
    https://developer.broadcom.com/tools/open-virtualization-format-ovf-tool/latest
    Look for the bundle matching your OS, e.g.:
        VMware-ovftool-4.4.3-18663434-lin.x86_64.zip       (Linux, recommended
                                                            for ESXi <= 7.0u3)
        VMware-ovftool-4.6.3-24031167-lin.x86_64.zip       (Linux, latest)
        VMware-ovftool-4.6.3-24031167-mac.x64.zip          (macOS)

  Or pull from the rgl/ovftool-binaries community mirror:
    curl -fsSL -o /tmp/ovftool.zip \
      https://github.com/rgl/ovftool-binaries/raw/main/archive/VMware-ovftool-4.4.3-18663434-lin.x86_64.zip
    unzip /tmp/ovftool.zip -d "$HOME/.local/"
    export PATH="$HOME/.local/ovftool:$PATH"
    ovftool --version

Or point the script at an unpacked tree:
    OVFTOOL_DIR=/path/to/vmware-ovftool ./test-esxi.sh
EOF
        [ -n "$OVFTOOL_LOCAL_DIR" ] || exit 1
        log "Uploading ovftool from $OVFTOOL_LOCAL_DIR → ${OVFTOOL_REMOTE_DIR}/ (scp)"
        ssh_esxi "mkdir -p '$OVFTOOL_REMOTE_DIR'"
        # scp -r preserves filenames byte-for-byte (govc datastore.upload
        # URL-encodes '+' as spaces — fatal for libstdc++.so.6 etc).
        scp_to_esxi -r "$OVFTOOL_LOCAL_DIR/." \
            "${ESXI_USER}@${ESXI_HOST}:${OVFTOOL_REMOTE_DIR}/" >/dev/null
        # Patch shebang (ESXi shell has no bash).
        ssh_esxi "chmod +x '${OVFTOOL_REMOTE_DIR}/ovftool' '${OVFTOOL_REMOTE_DIR}/ovftool.bin' 2>/dev/null; \
                  sed -i '1s|^#!/bin/bash|#!/bin/sh|' '${OVFTOOL_REMOTE_DIR}/ovftool' 2>/dev/null; \
                  true"
        pass "ovftool uploaded and patched (cached for next time)"
    fi

    log "Uploading OVA bundle to ESXi staging dir…"
    ssh_esxi "mkdir -p '$STAGE_REMOTE_DIR'"
    scp_to_esxi \
        "$OVA_DIR/${OVA_NAME}.ovf" \
        "$OVA_DIR/${OVA_NAME}.mf" \
        "$OVA_DIR/${OVA_NAME}-disk1.vmdk" \
        "${ESXI_USER}@${ESXI_HOST}:${STAGE_REMOTE_DIR}/" >/dev/null
    pass "bundle staged at $STAGE_REMOTE_DIR"

    log "Deploying via ovftool on ESXi (target=localhost)…"
    # Compose the remote command. Bash arrays don't cross SSH; expand inline.
    remote_cmd="${OVFTOOL_REMOTE_DIR}/ovftool"
    for flag in "${OVFTOOL_FLAGS[@]}"; do
        remote_cmd="$remote_cmd '$flag'"
    done
    remote_cmd="$remote_cmd '${STAGE_REMOTE_DIR}/${OVA_NAME}.ovf' 'vi://${ESXI_USER}:${PW_ENC}@localhost'"
    ssh_esxi "$remote_cmd" >/dev/null

    ssh_esxi "rm -rf '$STAGE_REMOTE_DIR'" >/dev/null 2>&1 || true
    STAGE_REMOTE_DIR=""
    pass "imported as '$TEST_VM_NAME'"
fi

# ---------------------------------------------------------------------------
# 8. Inject cloud-init guestinfo into VM extraConfig (BEFORE power on)
# ---------------------------------------------------------------------------
log "Injecting guestinfo.metadata into VM extraConfig…"
case "$DEPLOY_MODE_RESOLVED" in
    govc)
        govc vm.change -vm "$TEST_VM_NAME" \
            -e "guestinfo.metadata=${METADATA_B64}" \
            -e "guestinfo.metadata.encoding=base64" >/dev/null
        ;;
    ssh)
        # Append the keys to the .vmx and tell ESXi to re-read it. vim-cmd
        # vmsvc/reload makes the VM pick up the new extraConfig without an
        # unregister/register cycle.
        vmid=$(get_vmid "$TEST_VM_NAME")
        [ -n "$vmid" ] || fail "could not look up vmid after deploy"
        VMX_PATH="/vmfs/volumes/${ESXI_DATASTORE}/${TEST_VM_NAME}/${TEST_VM_NAME}.vmx"
        ssh_esxi "cat >> '$VMX_PATH' <<'VMXEOF'
guestinfo.metadata = \"${METADATA_B64}\"
guestinfo.metadata.encoding = \"base64\"
VMXEOF
                  vim-cmd vmsvc/reload $vmid" >/dev/null
        ;;
esac
pass "guestinfo set"

# ---------------------------------------------------------------------------
# 9. Power on — mode-dispatched
# ---------------------------------------------------------------------------
log "Powering on…"
case "$DEPLOY_MODE_RESOLVED" in
    govc)
        govc vm.power -on "$TEST_VM_NAME" >/dev/null
        ;;
    ssh)
        vmid=$(get_vmid "$TEST_VM_NAME")
        [ -n "$vmid" ] || fail "could not look up vmid after deploy"
        ssh_esxi "vim-cmd vmsvc/power.on $vmid" >/dev/null
        ;;
esac
pass "powered on"

# ---------------------------------------------------------------------------
# 9. Wait for guest IP (read op — works on free + licensed)
# ---------------------------------------------------------------------------
log "Waiting up to ${WAIT_SECONDS}s for open-vm-tools to report guest IP…"
guest_ip=$(govc vm.ip -wait "${WAIT_SECONDS}s" "$TEST_VM_NAME" 2>&1 || true)
if ! [[ "$guest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "no guest IP within ${WAIT_SECONDS}s — open-vm-tools didn't start, or DHCP failed. Got: $guest_ip"
fi
pass "guest IP: $guest_ip (open-vm-tools is running)"

# ---------------------------------------------------------------------------
# 10. Verify cloud-init set hostname (proves VMware datasource consumed guestinfo)
# ---------------------------------------------------------------------------
log "Verifying cloud-init applied hostname…"
deadline=$(( $(date +%s) + 60 ))
got_hostname=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    # Targeted path: .virtualMachines[0].guest.hostName.
    # Both empty and null map to "" via `// ""`.
    got_hostname=$(govc vm.info -json "$TEST_VM_NAME" 2>/dev/null \
        | jq -r '.virtualMachines[0].guest.hostName // ""' 2>/dev/null || true)
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
echo "  Mode:        $DEPLOY_MODE_RESOLVED"
echo "  VM:          $TEST_VM_NAME"
echo "  Guest IP:    $guest_ip"
echo "  Hostname:    $got_hostname"
echo "  Bundle:      $OVA_DIR/${OVA_NAME}.ovf"
echo "  Cleanup:     ${KEEP_VM:+SKIPPED (KEEP_VM=1)}${KEEP_VM:-on exit}"
