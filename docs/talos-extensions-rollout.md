# Talos system extensions rollout

> **Status (2026-06-15): legacy / pre-cutover reference.**
>
> This runbook was written for the original hand-built 1-control-plane
> + 2-worker Talos cluster whose machine configs lived in `proxmox/`.
> That cluster has been replaced by a 3-CP + 2-worker cluster
> provisioned by OpenTofu (see [`opentofu/README.md`](../opentofu/README.md)).
>
> On the OpenTofu cluster, extension changes are made by editing the
> `talos_extensions` variable in `opentofu/live/homelab/main.tf` and
> running `tofu apply` — the `talos-image` module re-derives the Image
> Factory schematic ID and the `talos-cluster` module rolls nodes one
> at a time via `staged_if_needing_reboot`. There is no need for the
> manual `talosctl patch` + `talosctl upgrade` choreography below.
>
> The text below is retained because (1) it documents the
> step-by-step reasoning for what each phase of an extension rollout
> actually does, which remains educational, and (2) the `proxmox/`
> cluster is kept powered off as a quick rollback option until the
> new cluster has been stable for long enough.
>
> Paths in `proxmox/` referenced below no longer exist in the
> OpenTofu world; their equivalents live under
> `opentofu/modules/talos-cluster/patches/`.

This runbook covers installing or updating Talos Linux system extensions
on the existing cluster — specifically the first rollout of
`siderolabs/tailscale` (joining each node to the tailnet so kubelet can
mount NFS from off-site TrueNAS), but the procedure is the same for any
future extension change.

It is written for the legacy cluster topology: **one control plane node
and two workers**. With a single control plane, the API server is
unavailable during the few minutes the control plane reboots. This is
acceptable for a homelab but worth being aware of — `kubectl` and Flux
will both fail until the control plane is back, then catch up
automatically.

## Why a runbook

Extension changes happen rarely, and the steps are easy to get subtly
wrong. Capturing the order
of operations and the reasoning for each step makes future rollouts
repeatable rather than improvised.

## Prerequisites

A shell with these variables set (the values below are the current
cluster — update as needed):

```bash
export CONTROL_PLANE_IP=192.168.1.31
export WORKER_IPS=("192.168.1.32" "192.168.1.33")
export SCHEMATIC=077514df2c1b6436460bc60faabc976687b16193b8a1290fda4366c69024fec2
export TALOSCONFIG=proxmox/talosconfig
```

`SCHEMATIC` is the Image Factory ID for the bundle of extensions defined
in `proxmox/schematic.yaml`. If that file changes, regenerate the ID:

```bash
curl -X POST --data-binary @proxmox/schematic.yaml \
  https://factory.talos.dev/schematics
# {"id":"<new-id>"}
```

Schematic IDs are deterministic — the same `schematic.yaml` always
produces the same ID — so this is safe to re-run.

You also need an out-of-band recovery path in case the control plane
fails to come back. For this cluster that's Proxmox console access to
the Talos VMs (Talos exposes a recovery TUI on the VM console). For the
TrueNAS host that NFS lives on, the equivalent is JetKVM.

## Step 1 — Pre-flight checks

Confirm what's actually running on each node, not just what the machine
config claims:

```bash
talosctl version --nodes "$CONTROL_PLANE_IP"
for n in $WORKER_IPS; do talosctl version --nodes "$n"; done
```

Note the **server** Talos version for each node. The upgrade target
should match this version unless you're intentionally bumping Talos —
mixing an extension rollout with a Talos version bump doubles the blast
radius if something goes wrong, so do them as separate rollouts.

Check cluster health:

```bash
talosctl --nodes $CONTROL_PLANE_IP health
```

This must report healthy before continuing. If it doesn't, fix the
underlying issue first — upgrading an unhealthy cluster is asking for
trouble.

Confirm Flux is in a clean state:

```bash
flux get all -A
```

If any Kustomization or HelmRelease is reconciling or failing, let it
settle (or suspend it) before the upgrade. Mid-reconciliation +
API-server outage during the CP reboot can leave Flux state confused.

## Step 2 — Snapshot etcd

With a single control plane, etcd has no replicas to recover from. Take
a snapshot before touching it:

```bash
talosctl etcd snapshot etcd-backup-$(date +%Y%m%d-%H%M%S).db \
  --endpoints "$CONTROL_PLANE_IP" \
  --nodes "$CONTROL_PLANE_IP"
```

Store the snapshot somewhere off the control plane node — at minimum
copy it to your laptop or workstation. If the upgrade destroys etcd and
you only have the snapshot on the same VM, you have nothing.

## Step 3 — Compose the installer image URL

```bash
# Match this to the server version observed in Step 1
export TALOS_VERSION=v1.13.2
export INSTALLER="factory.talos.dev/installer/${SCHEMATIC}:${TALOS_VERSION}"
echo "$INSTALLER"
```

Sanity check by pulling the image manifest (optional but cheap):

```bash
docker manifest inspect "$INSTALLER"
```

## Step 4 — Apply the ExtensionServiceConfig patch

Before upgrading to an image that contains a new extension, push the
extension's runtime configuration to each node. For `siderolabs/tailscale`
this is `proxmox/tailscale-extension.yaml`, which sets `TS_AUTHKEY` and
`TS_EXTRA_ARGS`. The patch is harmless to apply ahead of the upgrade —
Talos will only act on it once the extension is actually present on the
node.

```bash
talosctl patch machineconfig \
  --nodes "$CONTROL_PLANE_IP" \
  --patch @proxmox/tailscale-extension.yaml

for ip in "${WORKER_IPS[@]}"; do
    talosctl patch machineconfig \
      --nodes "$ip" \
      --patch @proxmox/tailscale-extension.yaml
done
```

## Step 5 — Upgrade the workers, then the control plane

Workers first, one at a time, so the cluster only ever has one node
draining. Save the control plane for last — with a single CP this is the
API-server outage window, and you want to know workers are happy before
you take it.

```bash
for ip in "${WORKER_IPS[@]}"; do
    talosctl upgrade --nodes "$ip" --image "$INSTALLER"
    # Wait for the node to come back Ready before moving on
    talosctl health --nodes "$ip"
done

talosctl upgrade --nodes "$CONTROL_PLANE_IP" --image "$INSTALLER"
```

## Step 6 — Verify the extension is loaded

```bash
talosctl get extensions --nodes "$CONTROL_PLANE_IP"
for n in "${WORKER_IPS[@]}"; do talosctl get extensions --nodes "$n"; done
```

Each node should list `siderolabs/tailscale` along with the other
extensions defined in `proxmox/schematic.yaml` (currently `iscsi-tools`,
`qemu-guest-agent`, `util-linux-tools`).

## Step 6a — kubelet nodeIP patch (one-time, only on first rollout)

The first time the `tailscale` extension comes up on a node, kubelet may
pick the new `tailscale0` interface IP (100.x.y.z) as its `nodeIP`,
because Talos by default uses the first non-loopback IPv4. This breaks
Flux and anything else that talks to the kubelet over the LAN, because
node-to-node traffic now tries to route via DERP.

The fix is to pin kubelet's `nodeIP` to the LAN subnet via
`proxmox/patch-node-ip.yaml`:

```yaml
machine:
  kubelet:
    nodeIP:
      validSubnets:
        - 192.168.1.0/24
```

Apply it and reboot all nodes:

```bash
talosctl patch machineconfig -p @proxmox/patch-node-ip.yaml \
  --nodes "$CONTROL_PLANE_IP" --endpoints "$CONTROL_PLANE_IP"
for ip in "${WORKER_IPS[@]}"; do
    talosctl patch machineconfig -p @proxmox/patch-node-ip.yaml \
      --nodes "$ip" --endpoints "$CONTROL_PLANE_IP"
done

talosctl reboot \
  --nodes "$CONTROL_PLANE_IP,${WORKER_IPS[0]},${WORKER_IPS[1]}" \
  --endpoints "$CONTROL_PLANE_IP"
```

This patch is now part of the baseline machine config, so it only needs
re-applying if you add new nodes or wipe an existing one.

## Step 7 — Verify

Per-node service status:

```bash
talosctl service ext-tailscale --nodes "$CONTROL_PLANE_IP"
for n in $WORKER_IPS; do talosctl service ext-tailscale --nodes "$n"; done
```

State should be `Running` and health `OK`. If health is unhealthy, pull
logs:

```bash
talosctl logs ext-tailscale --nodes "$CONTROL_PLANE_IP"
```

Common reasons it fails:

- Auth key is wrong, expired, or not tagged with `tag:k8s-node`.
- Auth key not marked **Pre-approved** and your tailnet requires manual
  device approval.
- ACL doesn't grant `tag:k8s-node` ownership to anything (check
  `tagOwners` in the ACL).

In the Tailscale admin console → **Machines**, each node should appear
with its hostname (Talos node name) and `tag:k8s-node`. This is the
authoritative "did it work" check — Talos doesn't ship the `tailscale`
CLI on the node (no shell, no userland), so admin console + ACL tests
are the verification surface.

Tailnet-side reachability is verified from *another* tailnet device
(your laptop):

```bash
# Find the node's tailnet IP in the admin console, then:
tailscale ping <node-tailnet-ip>
ssh into the node is not possible — this is just a reachability test
```

`tailscale ping` will indicate whether the connection is `direct` or
via a `relay` (DERP). Either is functional, but `direct` is preferable
for NFS throughput. If everything resolves over DERP, check that UDP
41641 is reachable inbound to your nodes on the Proxmox host firewall.

## Step 8 — Update the ACL (if not done already)

This is covered in `docs/architecture.md` and the Tailscale section of
the repo, but for completeness: with nodes now tagged `tag:k8s-node`,
the grant they rely on is

```jsonc
{
  "src": ["tag:k8s-node"],
  "dst": ["tag:truenas"],
  "ip":  ["tcp:2049"]
}
```

The end-to-end test is to apply a small NFS PV/PVC in the cluster and
confirm a test pod mounts it successfully. That belongs in the
democratic-csi rollout runbook rather than this one, but as a quick
smoke test you can deploy a throwaway pod with an `nfs` volume pointing
at the TrueNAS tailnet IP. If the pod reaches `Running`, the kubelet on
its host successfully completed the NFS mount over Tailscale.

## Rollback

If something goes wrong at any step, the rollback path is:

- **Before Step 4 (CP upgrade):** nothing to roll back, just stop.
- **During or after Step 4, CP unhealthy:** restore etcd from the
  snapshot taken in Step 2. The Talos recovery procedure is:

  1. Reset the control plane node, wiping STATE and EPHEMERAL:
     `talosctl reset --graceful=false --reboot --system-labels-to-wipe STATE,EPHEMERAL --nodes "$CONTROL_PLANE_IP"`
  2. Re-apply the machine config (back to the previous stock installer
     image, e.g. `ghcr.io/siderolabs/installer:v1.13.0` — no schematic):
     `talosctl apply-config --insecure --nodes "$CONTROL_PLANE_IP" --file proxmox/controlplane.yaml`
  3. Bootstrap from the snapshot:
     `talosctl bootstrap --recover-from etcd-backup-<timestamp>.db --nodes "$CONTROL_PLANE_IP"`

  Full recovery details are in the Talos docs under "Disaster Recovery";
  the procedure has subtle version-specific differences so cross-check
  before running it under pressure.
- **After Step 5, worker unhealthy:** workers can be wiped and rejoined
  via `talosctl reset --graceful=false --reboot` followed by re-applying
  the worker machine config. The cluster tolerates a worker being out
  for the duration.
- **After Step 6, Tailscale service crashlooping:** the extension being
  unhealthy does not affect Kubernetes — the node continues to function
  for everything that doesn't need the tailnet. Fix the auth key or ACL
  and re-apply Step 6. There's no need to roll back the upgrade.

The worst-case scenario — control plane unrecoverable, etcd snapshot
corrupt — is a full cluster rebuild. The Flux GitOps repo means
workloads come back automatically once a new cluster is bootstrapped
and pointed at the same Git repo. Volume state (NFS) is unaffected
because it lives on TrueNAS.

## Notes for future runs

- This runbook can be re-used unchanged when `schematic.yaml` is
  amended to add or remove an extension. Just regenerate the schematic
  ID in Step 1 and re-run.
- It can also be re-used for Talos minor version upgrades — change
  `TALOS_VERSION` in Step 3. Do not combine an extension change and a
  Talos version bump in the same rollout if it can be avoided.
- The `ExtensionServiceConfig` in Step 6 only needs to be re-applied
  when its content changes (new auth key, new TS_EXTRA_ARGS). It is
  idempotent — re-applying the same config is a no-op.
- The current single-CP topology is a deliberate homelab compromise. If
  the cluster ever grows to three control plane nodes, the rolling
  upgrade in Step 4 becomes non-disruptive and `--preserve` can be
  dropped.
