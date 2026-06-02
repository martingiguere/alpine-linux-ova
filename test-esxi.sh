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
#   ESXI_DATASTORE   — target datastore name (default: datastore1)
#   ESXI_NETWORK     — port-group name for VM NIC (default: 'VM Network')
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

: "${ESXI_DATASTORE:=datastore1}"
: "${ESXI_NETWORK:=VM Network}"
: "${TEST_VM_NAME:=alpine-ova-test-$$}"
: "${TEST_HOSTNAME:=alpine-ovatest}"
: "${WAIT_SECONDS:=120}"
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
export GOVC_DATASTORE="$ESXI_DATASTORE"

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
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
command -v govc >/dev/null 2>&1 || fail "govc not on PATH (install: https://github.com/vmware/govmomi/releases)"
command -v base64 >/dev/null 2>&1 || fail "base64 not on PATH"

[ -f "$OVF_FILE" ] || fail "OVF not found: $OVF_FILE"
[ -f "$MF_FILE" ]  || fail "Manifest not found: $MF_FILE"

log "Bundle: $OVA_DIR/${OVA_NAME}.{ovf,vmdk,mf}"
log "Target: $ESXI_HOST (datastore=$ESXI_DATASTORE network=$ESXI_NETWORK)"
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

if govc vm.info "$TEST_VM_NAME" 2>/dev/null | grep -q '^Name:'; then
    log "Removing pre-existing VM '$TEST_VM_NAME'…"
    govc vm.power -off -force "$TEST_VM_NAME" >/dev/null 2>&1 || true
    govc vm.destroy "$TEST_VM_NAME"
fi

# ---------------------------------------------------------------------------
# 4. Import OVF
# ---------------------------------------------------------------------------
log "Importing OVF (this can take a minute on slower datastores)…"
# Build the network map override on the fly: every Network in the OVF -> ESXI_NETWORK.
# Without -options the import would prompt for network mapping.
spec=$(govc import.spec "$OVF_FILE" \
    | jq --arg net "$ESXI_NETWORK" --arg name "$TEST_VM_NAME" \
        '.Name = $name | .DiskProvisioning = "thin" | .NetworkMapping[].Network = $net')
echo "$spec" | govc import.ovf -options=- -name="$TEST_VM_NAME" "$OVF_FILE" >/dev/null
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
