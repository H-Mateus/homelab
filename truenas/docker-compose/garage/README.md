# Garage

S3-compatible object storage on TrueNAS, exposed only over Tailscale.
The sole consumer is OpenTofu remote state (see `opentofu/`).

## Why Garage (and not MinIO)

MinIO was archived on GitHub on 25 April 2026; the project told users to
migrate to AIStor, a commercial product line with a freemium "Free" tier.
Neither continuing to run an archived project nor adopting a commercial
track fits a self-hosted homelab.

[Garage](https://garagehq.deuxfleurs.fr/) is the OSS-community consensus
post-MinIO: actively maintained, single binary, designed for small
self-hosted geo-distributed deployments, runs on a Pi 4. For a single-
operator, low-volume tofu-state use case it's a much better fit than
MinIO ever was.

### Trade-offs vs MinIO

| Feature | MinIO | Garage | Mitigation |
|---|---|---|---|
| S3 API parity | ★★★★★ | ★★★★ | Only relevant for advanced clients; tofu's `s3` backend uses basic operations |
| **`If-None-Match` (Tofu `use_lockfile`)** | ✓ | ✗ | Single-operator setup; don't run two `tofu apply` at once. Documented in `opentofu/live/homelab/backend.tf` |
| **Object versioning** | ✓ | ✗ | Pool-recursive ZFS snapshots cover whole-dataset rollback; bucket versioning would be finer-grained but we don't need that for the volume of state changes here |
| Resource footprint | ~256 MB RAM idle | ~50 MB RAM idle | Garage wins on a 16 GB host |
| Operational complexity | API-driven config after start | Single TOML file + one-time `garage layout` | Garage's model fits GitOps better |

## Architecture

```
your laptop  ──tailnet──▶  garage.<tailnet>.ts.net:443 (Tailscale serve)
                                       │ HTTPS termination
                                       ▼
                          garage-ts container (userspace TS)
                                       │ http://garage:3900 (S3 API)
                                       ▼
                                garage container
                                       │
                                       ▼
                         /mnt/HDDs/garage/{meta,data}
```

No host ports are bound. Access requires being on the Tailnet *and*
having a Tailscale ACL that permits your device to reach `tag:garage`.

## Bootstrap

### 0. Tailscale ACL prerequisite

The sidecar advertises `tag:garage`. The tag must exist in your
Tailscale ACL policy *before* you mint the auth key. In the Tailscale
admin UI → **Access controls**, add:

```jsonc
"tagOwners": {
    // ...existing entries...
    "tag:garage": ["group:admin"],
},

"grants": [
    // ...existing rules...
    {
        "src": ["group:admin"],   // who should reach the bucket
        "dst": ["tag:garage"],
        "ip":  ["tcp:443"],       // HTTPS only — all `tailscale serve` exposes
    },
],
```

> If you previously added `tag:minio` from the MinIO version of this
> stack, you can remove that entry — nothing on the Tailnet uses it now.

### 1. Create the dataset (TrueNAS GUI)

In the TrueNAS Scale UI:

1. **Datasets → Add Dataset**, parent = `HDDs` (or your data pool).
2. Name: `garage`. Preset: **Generic** (POSIX permissions).
3. Edit Permissions:
   - Owner: `apps` (UID 568)
   - Group: `apps` (GID 568)
   - Mode: `770` — owner + group only, no world access.
   - Apply recursively.
4. Optionally (Edit → Advanced):
   - Compression: `lz4` (default; fine for mixed object content).
   - Record size: `1M` (Garage writes whole objects; bigger records help).
   - atime: `off`.

Mount path will be `/mnt/HDDs/garage`.

> If you created an `HDDs/minio` dataset earlier, you can destroy it —
> nothing references it now.

### 2. Create the subdirectories + RPC secret file

```bash
# On the TrueNAS host:
sudo mkdir -p /mnt/HDDs/garage/{meta,data,ts-state}

# Generate the inter-node RPC secret (Garage requires this even on a
# single-node deployment; the value isn't reachable outside the
# container with replication_factor = 1).
sudo sh -c 'openssl rand -hex 32 > /mnt/HDDs/garage/rpc_secret'
sudo chmod 600 /mnt/HDDs/garage/rpc_secret

sudo chown -R 568:568 /mnt/HDDs/garage
```

### 3. Snapshot coverage

The pool-recursive periodic snapshot task already covers
`HDDs/garage`. Only add a dedicated `HDDs/garage` task if you want
different retention here (e.g. more frequent snapshots because tofu-
state is small and important).

### 4. Bring the stack up

In Dockhand: add the stack pointing at this directory's git path,
fill in `.env` in the UI (the `*.example` here is the template),
pull, deploy. The container will start but report **unhealthy** until
you do step 5 — that's expected, Garage refuses requests until a
storage layout is assigned.

```bash
# Tail the logs while the stack starts:
docker logs -f garage
docker logs -f garage-ts    # watch for "Success. ... use this URL: ..."
```

### 5. Assign the storage layout (one-time)

Garage's "layout" decides which nodes hold which data partitions. On a
single-node deployment it's a no-op in practice, but Garage requires
you to declare it explicitly.

```bash
# Get this node's auto-generated ID:
docker exec garage /garage status
# Output looks like:
#   ID                Hostname  Address          Tags     Zone  Capacity  Status
#   abc123def456...   garage    127.0.0.1:3901   NO ROLE ASSIGNED

# Assign the role. Capacity is a hint to Garage's allocator;
# 100GB is plenty of headroom for tofu state.
docker exec garage /garage layout assign <node-id> -z dc1 -c 100G -t default

# Stage the layout change:
docker exec garage /garage layout show

# Apply it (the version number is shown in the output above):
docker exec garage /garage layout apply --version 1
```

After `layout apply`, `garage status` will show the node as healthy
and Compose's healthcheck will start passing.

### 6. Create the bucket and access key

```bash
# Bucket for tofu state:
docker exec garage /garage bucket create tofu-state

# Scoped access key (don't reuse a global one):
docker exec garage /garage key create tofu
# Outputs:
#   Key ID:     GK<...>
#   Secret key: <long-base64>
# Save these — the secret won't be shown again.

# Allow the key on the bucket:
docker exec garage /garage bucket allow \
  --read --write --owner tofu-state --key tofu
```

Use the printed Key ID + Secret as `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` for OpenTofu:

```bash
export AWS_ACCESS_KEY_ID=GK<...>
export AWS_SECRET_ACCESS_KEY=<long-base64>
cd opentofu/live/homelab
tofu init
```

## Day-2 ops

| Task | Command |
|---|---|
| Check health | `docker exec garage /garage status` |
| List buckets | `docker exec garage /garage bucket list` |
| List keys | `docker exec garage /garage key list` |
| Rotate the tofu key | `garage key delete tofu` → `garage key create tofu` → update env |
| Inspect via `mc` | `mc alias set garage https://garage.<tailnet>.ts.net <key> <secret>` then `mc ls garage/tofu-state` |

## Outage planning

If Garage is unreachable, `tofu plan` / `tofu apply` can't read state.
For homelab use that's acceptable downtime. If `HDDs/garage` is lost
entirely:

1. Re-deploy the stack on a fresh dataset (`tofu` state lost).
2. State can be reconstructed by `tofu import`-ing each managed
   resource — slow but mechanical. See `opentofu/README.md`.
3. The cluster + workloads themselves keep running; only the IaC
   ability to *change* them is interrupted.

ZFS snapshots of `HDDs/garage` (from the pool-recursive task) protect
against accidental deletion and most data corruption; restore by
rolling back the snapshot before the bad event.
