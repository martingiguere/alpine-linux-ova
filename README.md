# alpine-linux-ova — generic Alpine OVA builder for ESXi / vCenter

Builds a thin, ESXi 6.7+ compatible OVA bundle from upstream Alpine packages
(`build-ova.sh`), and ships a test harness that deploys + validates it against
real ESXi or vCenter (`test-esxi.sh`).

## Prebuilt downloads (releases)

Each `v*` tag publishes a built, verified OVA bundle as a
[GitHub Release](https://github.com/martingiguere/alpine-linux-ova/releases)
asset (built reproducibly from the tagged source by `.github/workflows/release.yml`).

```sh
# Download the latest release bundle with the GitHub CLI:
gh release download --repo martingiguere/alpine-linux-ova --pattern '*'

# Verify integrity:
sha256sum -c SHA256SUMS
```

Each release attaches `alpine-esxi-<tag>.ovf`, `alpine-esxi-<tag>-disk1.vmdk`
(streamOptimized), `alpine-esxi-<tag>.mf`, and `SHA256SUMS`. Cut a new release
by tagging: `git tag v0.1.0 && git push --tags`.

## Output

Three files in `$OUTPUT_DIR`, plus a transport checksum file:

| File | What it is |
|---|---|
| `<name>.ovf` | OVF 1.0 descriptor (BIOS, pvscsi, vmxnet3, HW vmx-14 default) |
| `<name>-disk1.vmdk` | streamOptimized VMDK — thin, compressed, OVA-canonical |
| `<name>.mf` | SHA-256 manifest (validated by `ovftool` and `govc` on import) |
| `SHA256SUMS` | Transport checksums for all three files |

These can be imported directly with `govc import.ovf` or `VBoxManage import`, or
re-bundled as a `.ova` tarball (`tar cf out.ova <name>.ovf <name>.mf <name>-disk1.vmdk` — OVF first).

## Build-host prerequisites

```
bash curl qemu-img qemu-nbd sudo sfdisk rsync sha1sum sha256sum tar awk sed
```

On Debian/Ubuntu: `qemu-utils util-linux rsync curl coreutils`.
The Linux kernel must have NBD support; `modprobe nbd` is auto-loaded if missing.

## Usage

```sh
# Minimal: defaults produce a generic Alpine 3.23 OVA with cloud-init + open-vm-tools.
./build-ova.sh

# Custom: bigger disk, name, and a customization hook
OUTPUT_NAME=my-alpine \
DISK_SIZE_GB=40 \
EXTRA_PACKAGES="bash htop" \
CUSTOMIZE_SCRIPT=/path/to/my-setup.sh \
./build-ova.sh
```

See `./build-ova.sh -h` for the full env-var list.

## What gets installed by default

| Component | Purpose |
|---|---|
| `cloud-init` + `cloud-init-vmware-guestinfo` | Reads `guestinfo.{metadata,userdata}` at first boot via the VMware datasource |
| `open-vm-tools` | Required by the VMware datasource (`vmware-rpctool`/`vmtoolsd`); also gives vSphere guest IP / graceful shutdown |
| `open-vm-tools-vix` | VIX plugin — enables vSphere Guest Operations API (`govc guest.run`, `guest.start`, file transfer) without ssh. Without this plugin loaded, vCenter reports "guest operations agent is out of date" even though `vmtoolsd` reports `guestToolsRunning`. |
| `chrony` | NTP — K8s and TLS hate clock skew |
| `curl` | Useful for inside-VM debugging |

Disable any of these with `INSTALL_CLOUD_INIT=0`, `INSTALL_OPEN_VM_TOOLS=0`, `INSTALL_NTP=0`.

## What gets removed at the end of the build

`ova/alpine-image-setup.sh` clears every artifact that would leak build identity into clones:

- SSH host keys (`/etc/ssh/ssh_host_*`)
- `/etc/machine-id` and `/var/lib/dbus/machine-id`
- `/var/lib/cloud/*` (cloud-init state)
- `/var/cache/apk/*`, `/tmp/*`, `/var/tmp/*`
- All log file contents
- Root shell history
- Root password is locked (`passwd -l root`)

SSH is **not** enabled by default. Operators add their own access via cloud-init userdata.

## Customization hook

Set `CUSTOMIZE_SCRIPT=/path/to/script.sh` to inject your own steps. The script runs
**inside the image chroot** after Alpine is installed but before cleanup. Example —
install a binary to `/usr/local/bin` and drop an OpenRC service:

```sh
#!/bin/sh
set -eu
curl -fsSL -o /usr/local/bin/myapp https://example.com/myapp
chmod +x /usr/local/bin/myapp
cat > /etc/init.d/myapp <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/myapp"
command_background=yes
pidfile="/run/myapp.pid"
EOF
chmod +x /etc/init.d/myapp
rc-update add myapp default
```

## ESXi version targeting

Default `HW_VERSION=vmx-14` targets ESXi 6.7 GA. Bump if you need newer features:

| `HW_VERSION` | Minimum ESXi |
|---|---|
| `vmx-14` | 6.7 GA |
| `vmx-15` | 6.7 U2 |
| `vmx-17` | 7.0 |
| `vmx-19` | 7.0 U2 |

## Cloud-init wiring

The image ships `/etc/cloud/cloud.cfg.d/99-vmware-guestinfo.cfg`:

```yaml
datasource_list: [ VMware, NoCloud, None ]
```

cloud-init reads `guestinfo.metadata` and `guestinfo.userdata` from the VM's
extraConfig (set on vSphere via the OVF properties or `extra_config = {}` in
terraform's `vsphere_virtual_machine`). Both base64 and gzip+base64 encodings
are honored via the corresponding `.encoding` keys, which are declared as
`ovf:userConfigurable="true"` properties in the OVF.

## Testing on a real ESXi host or vCenter

`test-esxi.sh` deploys an OVA bundle, injects cloud-init guestinfo, powers the
VM on, and verifies that open-vm-tools reports a guest IP and that cloud-init
applied the requested hostname (proves the VMware datasource is wired correctly
end-to-end). Cleans up after itself.

It auto-detects the target and picks a deploy path:

| Target | `DEPLOY_MODE` | How it deploys |
|---|---|---|
| **vCenter** | `govc` (forced) | `govc import.ovf` (native, placed via the detected datacenter/cluster/resource pool); `govc` for power/guestinfo/destroy |
| **Licensed standalone ESXi** | `govc` | `govc import.ovf`; `govc` for the rest |
| **Free / unlicensed ESXi** | `ssh` | ovftool uploaded to the datastore and run *on the host* (`vi://…@localhost`, the William Lam workaround — the SOAP write API is gated on free); `vim-cmd` for power/destroy. **The only path that uses ovftool.** |

`DEPLOY_MODE=auto` (default) probes the target. vCenter → `govc`. Standalone
ESXi → a no-op write probe: license error → `ssh`, else → `govc`. Override with
`DEPLOY_MODE=govc|ssh`.

**Auto-detected** (override any via env):
- target type (standalone ESXi vs vCenter)
- on vCenter: datacenter, cluster, resource pool, ovftool inventory locator
- datastore: prefers **shared** storage (mounted by >1 host) with the most free
  space, so a clustered VM isn't pinned to a single host's local disk
- network: prefers `VM Network`, else the first non-management portgroup

**Workstation prerequisites** (all on PATH): `govc`, `jq`, `base64`. The `govc`
path (vCenter / licensed ESXi) needs nothing else — `govc import.ovf` does the
deploy natively, so it runs on any architecture.

The `ssh` path (free ESXi) additionally needs `ssh` + `sshpass`, and ovftool to
upload to the host on first use — provide it via one of:
- `ovftool` on PATH (Broadcom bundle or the rgl/ovftool-binaries mirror), or
- `OVFTOOL_DIR` pointing at an unpacked ovftool tree, or
- a `./ovftool/` directory next to the script.

(Once ESXi has the cached copy from a prior `ssh`-mode run, no local ovftool is
needed.)

```sh
export ESXI_HOST=vcenter.lan       # ESXi host OR vCenter
export ESXI_USER=administrator@vsphere.local   # 'root' for standalone ESXi
export ESXI_PASSWORD=…
# Optional:
export DEPLOY_MODE=auto            # auto | govc | ssh
export ESXI_DATASTORE=auto         # or a name; auto prefers shared, most-free
export MIN_FREE_GIB=10
export ESXI_NETWORK=auto           # or a portgroup name
export GOVC_DATACENTER=…           # vCenter only; auto-detected if unset
export KEEP_VM=1                   # skip cleanup if you want to inspect

# Point at the .ovf bundle (auto-detects in ./_out/ or current dir)
./test-esxi.sh
```

Pass criteria:
1. Local manifest hashes match the actual files.
2. govc can authenticate; target type + inventory resolved.
3. OVF deploys without error.
4. VM powers on and open-vm-tools reports `guestToolsRunning` within
   `WAIT_SECONDS` (120s default).
5. **Guest hostname (via VMware tools) matches `TEST_HOSTNAME`** — the pass
   criterion. Confirms the VMware cloud-init datasource read guestinfo (over
   the hypervisor backdoor, not the network) and cloud-init applied it.

The guest **IP is informational, not a pass requirement**. `hostName` and
`toolsRunningStatus` are reported by open-vm-tools independently of networking,
and the VMware datasource reads guestinfo via `vmware-rpctool` (backdoor), so
the test passes even on a portgroup with no DHCP server. If no IPv4 appears
within the window the script logs a note and continues — it does not fail.

> **Note for vCenter targets:** the script deploys a real VM into the cluster
> (unique `alpine-ova-test-<pid>` name) and destroys it on exit. On a shared/
> production vCenter, run deliberately — set `KEEP_VM=1` to inspect, or
> `TEST_VM_NAME=…` to control naming.
