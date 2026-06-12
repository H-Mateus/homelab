# OpenTofu: Talos cluster on Proxmox

Infrastructure-as-code for the homelab Talos Linux cluster. Provisions five
VMs on a single Proxmox host, generates Talos machine configuration,
applies it, bootstraps etcd, and waits for the cluster to become healthy
— all from one `tofu apply`.

The pre-existing hand-built cluster (`proxmox/` directory) is the starting
point this replaces.

```
opentofu/
├── modules/
│   ├── talos-image/      # Image Factory schematic + ISO download to Proxmox
│   ├── proxmox-vm/       # One Talos-friendly VM (no cloud-init)
│   └── talos-cluster/    # Secrets, machine configs, apply, bootstrap, health
└── live/
    └── homelab/          # The one environment, composing the modules
```

## Design notes

A few choices worth flagging because they matter for both correctness and
portfolio-readability.

**HA control plane via Talos native VIP.** The 3 control planes share a
single floating IP (`var.cluster_vip`, default `192.168.1.55`). Talos
implements this with a built-in keepalived-style election — no external
load balancer, no metallb-for-the-API chicken-and-egg. The Kubernetes API
endpoint is `https://192.168.1.55:6443`. If the holder dies, another CP
takes over within a few seconds.

**Schematic ID is in code.** The previous `proxmox/schematic.yaml` was
hand-curl'd against factory.talos.dev. Here, `talos_image_factory_schematic`
turns the list of extensions into a stable schematic ID, and that ID
embeds into the ISO download URL and installer image. Bumping Talos or
extensions means changing one variable, not chasing a hash by hand.

**Tailscale auth key out of plaintext.** The previous extension config
had the key in `proxmox/tailscale-extension.yaml` (gitignored, but still
plaintext on disk). It now lives in `secrets.enc.yaml`, SOPS-encrypted
with the repo's existing age recipient, decrypted at apply time and
templated into the extension config.

**Provider separation.** `proxmox-vm` doesn't know about Talos.
`talos-cluster` doesn't know about Proxmox. They're glued together in
`live/homelab/main.tf`. The modules are small enough to read in one sitting.

**Static IPs in Talos, not Proxmox.** The VM has no cloud-init disk and
no DHCP dependence. Talos's `machine.network.interfaces` is the source
of truth for node addressing, with `deviceSelector: { driver: virtio_net }`
matching the NIC robustly across kernel name shuffles.

**Boot from disk first, ISO as fallback.** On first power-on the disk is
empty and BIOS falls through to the ISO. Talos installs itself to the
disk and reboots. Subsequent boots skip the ISO entirely. Leaving the ISO
attached costs nothing and means re-imaging is just `tofu taint` + apply.

## Prerequisites

1. **Proxmox host** reachable on the LAN with the bpg/proxmox provider's
   requirements satisfied (see the API token recipe below).
2. **Garage on TrueNAS** for remote state. See
   `truenas/docker-compose/garage/`. Stand this up first.
3. **OpenTofu ≥ 1.9** locally. `.terraform-version` pins to 1.10.3.
4. **SOPS + age** locally, with the age key at the repo's expected location.
   The repo's `.sops.yaml` already configures the recipient.

## Proxmox API token

Don't use root. Create a dedicated `tofu@pve` user with the smallest role
that works for VM lifecycle + ISO downloads.

On the Proxmox host (one-time):

```bash
# Create the user. Use --password or skip (token-only).
pveum user add tofu@pve --comment "OpenTofu — homelab cluster IaC"

# Role with the privileges the bpg provider actually exercises.
# Notes:
# - `VM.Monitor` existed in older Proxmox versions but was removed; its
#   functionality is covered by VM.Console + VM.PowerMgmt. Don't add it
#   back; recent `pveum` rejects the role creation outright.
# - `SDN.Use` is required on Proxmox 8+ to attach a NIC to a bridge,
#   even the plain `vmbr0` Linux bridge — it sits in the SDN's default
#   "localnetwork" zone now, and the permission check happens at VM
#   create. `SDN.Audit` is for read operations against SDN config.
# - `VM.GuestAgent.Audit` lets the provider query the QEMU guest agent
#   to discover VM-reported network interfaces (post-boot IP detection).
#   Without it apply emits a warning ("error retrieving VM network
#   interfaces from agent") but doesn't fail.
pveum role add OpenTofu -privs "\
VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit \
VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
VM.Config.Options VM.Console VM.Migrate VM.PowerMgmt \
VM.Audit VM.GuestAgent.Audit Datastore.Allocate Datastore.AllocateSpace \
Datastore.AllocateTemplate Datastore.Audit Sys.Audit Sys.Modify \
Pool.Allocate Pool.Audit SDN.Use SDN.Audit"

# Already created the role with a smaller set? Update it in place:
#   pveum role modify OpenTofu -privs "<full priv list above>"

# Grant role at the root scope.
pveum aclmod / -user tofu@pve -role OpenTofu

# Mint a token. The `=` value is what goes in secrets.enc.yaml.
pveum user token add tofu@pve opentofu --privsep 0
# Output: ┌──────────────┬──────────────────────────────────────┐
#         │ key          │ value                                │
#         ├──────────────┼──────────────────────────────────────┤
#         │ full-tokenid │ tofu@pve!opentofu                    │
#         │ value        │ xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx │
#         └──────────────┴──────────────────────────────────────┘
```

The combined form for `secrets.enc.yaml` is
`tofu@pve!opentofu=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.

## Tailscale auth key

Each node joins the tailnet at boot via the `siderolabs/tailscale`
extension, advertising `tag:k8s-node` (see
`modules/talos-cluster/patches/tailscale-extension.yaml.tftpl`).

Generate the key at <https://login.tailscale.com/admin/settings/keys>
with:

- **Reusable** — all 5 nodes share one key.
- **Ephemeral** — dead nodes drop off the tailnet automatically instead
  of accumulating after re-image cycles.
- **Pre-approved** — nodes show up without a manual approve click. If
  device approval isn't enabled on your tailnet, this is a no-op.
- **Tag**: `tag:k8s-node`.

`tag:k8s-node` is already defined in this tailnet's `tagOwners` (from
the previous hand-built Talos cluster — see `docs/architecture.md`),
and the kubelet→TrueNAS NFS grant already references it, so no ACL
change is needed for the rebuild.

Paste the key into `tailscale_authkey:` in `secrets.enc.yaml`.

## Secrets workflow

```bash
cd opentofu/live/homelab
cp secrets.enc.yaml.example secrets.enc.yaml
$EDITOR secrets.enc.yaml          # paste real values

# Encrypt in place. The repo's .sops.yaml maps secrets.enc.* to the
# age recipient automatically.
sops -e -i secrets.enc.yaml

# To edit later (decrypts → editor → re-encrypts):
sops secrets.enc.yaml
```

At apply time the `sops_file` data source decrypts in-memory. Decrypted
content lives only in state — protect the state backend.

## Bootstrap order (first time, end-to-end)

```bash
# 0. Stand up Garage on TrueNAS (one-time). Deploy via Dockhand from
#    truenas/docker-compose/garage/ — its README has the layout-assign
#    + bucket-create steps.

# 1. Configure backend credentials (the Garage key pair from
#    `garage key create tofu`).
export AWS_ACCESS_KEY_ID=GK<...>
export AWS_SECRET_ACCESS_KEY=<long-base64>

# 2. Tofu working directory.
cd opentofu/live/homelab

# 3. Edit backend.tf to put your actual tailnet name in the s3 endpoint.
#    (Search for <TAILNET> and replace.)

# 4. Fill in tfvars + secrets.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
# (secrets.enc.yaml already created above.)

# 5. Init + plan + apply.
tofu init
tofu plan -out plan.bin
tofu apply plan.bin

# 6. Use the cluster.
export KUBECONFIG="$PWD/_generated/kubeconfig"
export TALOSCONFIG="$PWD/_generated/talosconfig"
kubectl get nodes
talosctl health
```

A clean apply on this hardware takes ~15 min: most of it is each VM
booting from ISO, installing Talos, rebooting, joining the cluster.

## Cutover from the existing 1+2 cluster

The Proxmox host has 16 GiB RAM and the new cluster wants 14 GiB — too
tight to run old + new in parallel. The runbook is therefore
**destroy old, then apply new**, with a brief workload outage.

```bash
# --- pre-cutover, while the old cluster is still up ---

# Capture an etcd backup from the old CP. Belt-and-braces; the
# workloads themselves are reproduced from git by Flux.
talosctl --talosconfig proxmox/talosconfig --nodes <old-cp-ip> \
  etcd snapshot proxmox/etcd-backup-pre-cutover.db

# Snapshot any PVC data that doesn't live on TrueNAS NFS/iSCSI (most of
# yours does — democratic-csi PVs survive cluster destruction because
# they're backed by ZFS datasets on TrueNAS).

# --- cutover ---

# Power off old VMs in Proxmox UI (or destroy via Proxmox, but keep the
# disks if you want a quick rollback option).
# Then:
cd opentofu/live/homelab
tofu apply

# --- post-cutover ---

# Flux: install in the new cluster, pointing at the same repo.
kubectl --kubeconfig _generated/kubeconfig apply -k \
  ../../../kubernetes/clusters/talos/flux-system

# Or use `flux bootstrap github` per the repo's existing flow. Flux will
# reconcile everything else from git on the new cluster.

# Verify democratic-csi finds the existing volumes by their pv handles
# (they do — the iSCSI/NFS exports are stable across cluster rebuilds).

# Once happy, delete the old VMs in Proxmox to reclaim disk.
```

If something goes sideways and you need to roll back quickly, power the
old VMs back on; nothing in the new flow has touched the TrueNAS-backed
storage. Workloads come back where they were.

## Day-2 operations

| Task | How |
|------|-----|
| Bump Talos version | Change `talos_version` (and `talos_version_contract` if crossing minor). `apply` rolls nodes one at a time via `staged_if_needing_reboot`. |
| Add a system extension | Append to `talos_extensions`. New schematic ID, new ISO, new installer. Apply reimages nodes on next reboot. |
| Resize a node | Bump `*_memory_mb` / `*_cpu` / `*_disk_gb`. Memory + CPU are hot-pluggable on the bpg provider; disk grows online too. |
| Add a worker | Append to `var.workers`. Apply creates the VM and joins it. |
| Replace a node | `tofu taint module.worker_vm[\"talos-w-02\"].proxmox_virtual_environment_vm.this` then apply. |
| Rotate Tailscale authkey | Edit `secrets.enc.yaml` with sops, apply. Existing nodes keep their existing TS device until they reboot or are reapplied. |

## State recovery

Garage does not implement bucket object versioning, so per-object
rollback isn't available. The recovery story is therefore:

1. **ZFS snapshots** on `HDDs/garage` (from the pool-recursive task)
   — roll back the whole dataset to a known-good point. Affects every
   bucket but for this single-tenant deployment that's only ours.
2. **Worst case**: state can be reconstructed by `tofu import`-ing each
   VM (`proxmox_virtual_environment_vm` import syntax: `node/vmid`)
   and re-deriving Talos secrets from the running cluster.

This is a *deliberate* trade vs MinIO — see
`truenas/docker-compose/garage/README.md` for the rationale.

## What's not in here (deliberately)

- Cloudflare DNS, Tailscale ACLs, and the Flux bootstrap itself are not
  managed here. The cluster comes up; Flux takes over the inside of it;
  Tailscale ACLs and DNS are edited out-of-band. Lifting any of those
  into Tofu is straightforward (add providers, manage resources) but
  out of scope for v1.
- The existing `proxmox/` directory is left in place as a frozen
  reference. Delete it after the cutover is verified.
