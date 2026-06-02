# build-ova.sh — generic Alpine OVA builder

Builds a thin, ESXi 6.7+ compatible OVA bundle from upstream Alpine packages.

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

## Testing on a real ESXi host

`test-esxi.sh` uploads an OVA bundle to an ESXi host, injects cloud-init
guestinfo, powers the VM on, and verifies that open-vm-tools reports a guest IP
and that cloud-init applied the requested hostname (proves the VMware
datasource is wired correctly end-to-end). Cleans up after itself.

Requires `govc` and `jq` on PATH.

```sh
export ESXI_HOST=esxi.lan          # or IP
export ESXI_USER=root
export ESXI_PASSWORD=…
# Optional:
export ESXI_DATASTORE=auto         # default — picks first datastore with ≥10 GiB free
export MIN_FREE_GIB=10             # threshold for ESXI_DATASTORE=auto
export ESXI_NETWORK=auto           # default — prefers 'VM Network', else first non-mgmt portgroup
export KEEP_VM=1                   # skip cleanup if you want to inspect

# Point at the .ovf bundle (auto-detects in ./_out/ or current dir)
./test-esxi.sh
```

Pass criteria:
1. Local manifest hashes match the actual files.
2. govc can authenticate.
3. OVF imports without error.
4. VM powers on and reports a guest IP within `WAIT_SECONDS` (120s default).
5. Guest hostname (via VMware tools) matches `TEST_HOSTNAME` — confirms the
   VMware cloud-init datasource read guestinfo and cloud-init applied it.
