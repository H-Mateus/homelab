# MinIO

S3-compatible object storage on TrueNAS, exposed only over Tailscale. The
sole consumer is OpenTofu remote state (see `opentofu/`).

## Why MinIO and not <X>

- We already manage Compose stacks on TrueNAS; one more is cheap.
- MinIO speaks the S3 protocol Tofu's `s3` backend wants natively.
- Recent Tofu/Terraform support `use_lockfile = true`, an S3-native
  conditional-write lock — so we don't need a DynamoDB-compatible side
  service.
- Free hosted backends (HCP Terraform, Scalr) work but leak homelab
  topology to a third party.

## Architecture

```
your laptop  ──tailnet──▶  minio.<tailnet>.ts.net:443 (Tailscale serve)
                                       │ HTTPS termination
                                       ▼
                          minio-ts container (userspace TS)
                                       │ http://minio:9000
                                       ▼
                                 minio container
                                       │
                                       ▼
                          /mnt/HDDs/minio/data
```

No host ports are bound. Access requires being on the tailnet *and* having
a Tailscale ACL that permits your device to reach `tag:minio`.

## Bootstrap

### 1. Create the dataset (TrueNAS GUI)

Storage units in TrueNAS are *datasets*, not directories. We want one
dedicated to MinIO so snapshots, quotas, and replication can be tuned
independently of the rest of the pool — same pattern as the `immich`
dataset already in use.

In the TrueNAS Scale UI:

1. **Datasets → Add Dataset**, parent = `HDDs` (or whichever data pool
   you use).
2. Name: `minio`. Preset: **Generic** (POSIX permissions; we don't need
   SMB ACLs).
3. After creation, select the new dataset → **Edit Permissions**:
   - Owner: `apps` (UID 568)
   - Group: `apps` (GID 568)
   - Mode: `770` (`rwxrwx---`) — owner + group only, no world access.
   - Apply recursively.
4. Optionally set ZFS properties on the dataset (Edit → Advanced):
   - Compression: `lz4` (default; fine for mixed object content).
   - Record size: `1M` (MinIO writes whole objects; bigger records help).
   - atime: `off` (object stores don't need it).

The mount path will be `/mnt/HDDs/minio` (or `/mnt/<your-pool>/minio`).

### 2. Create the subdirectories the Compose mounts expect

Two subdirs inside the dataset — one for object data, one for the
Tailscale sidecar's persistent state. The TS state dir is small and
fully reproducible from a fresh authkey, so it doesn't warrant its
own dataset; subdir is fine.

```bash
# On the TrueNAS host:
sudo mkdir -p /mnt/HDDs/minio/{data,ts-state}
sudo chown -R 568:568 /mnt/HDDs/minio
```

### 3. Confirm snapshot coverage

If a pool-recursive periodic snapshot task already exists (the usual
homelab default), the new `HDDs/minio` dataset is automatically
covered — no extra task needed. ZFS snapshots aren't directory-aware,
so a recursive task at the pool snapshots every child dataset with
the same policy.

Only add a dedicated `HDDs/minio` task if you want a **different**
policy here than the pool default — e.g. more frequent snapshots
because the tofu-state bucket is small and important, or different
retention. For most setups the pool-level policy is fine.

State protection is layered:

1. **Object versioning** on the `tofu-state` bucket — fine-grained
   per-object rollback (enabled with `mc version enable` in step 5).
2. **ZFS snapshots** of `HDDs/minio` from the pool-recursive task —
   covers the bucket plus MinIO's metadata for whole-dataset rollback.

### 4. Bring the stack up

```bash
cd /path/to/truenas/docker-compose/minio
cp .env.example .env
$EDITOR .env       # fill in MINIO_ROOT_*, TS_TAILNET, TS_AUTHKEY

docker compose up -d
docker logs minio-ts    # watch for "Success. ... use this URL: ..."
```

### 5. Create the bucket + scoped user

See the next section.

## Create the tofu-state bucket and a scoped user (step 5)

From any Tailnet client (after a few seconds for MagicDNS to propagate):

```bash
mc alias set homelab https://minio.<tailnet>.ts.net \
  "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

mc mb homelab/tofu-state
mc version enable homelab/tofu-state     # versioning lets you roll back bad applies

mc admin user add homelab tofu "$(openssl rand -hex 24)"
mc admin policy attach homelab readwrite --user tofu
```

Hand the `tofu` user's keys to OpenTofu via environment:

```bash
export AWS_ACCESS_KEY_ID=tofu
export AWS_SECRET_ACCESS_KEY=...
cd opentofu/live/homelab
tofu init                # picks up creds from env, talks to MinIO over TS
```

## Backup

See bootstrap step 3. Object versioning on the bucket handles per-object
rollback; the pool-recursive ZFS snapshot task handles whole-dataset
rollback. No MinIO-specific snapshot task is required unless you want a
different retention policy than the pool default.

## Outage planning

If MinIO is unreachable, `tofu plan` / `tofu apply` can't acquire the
lock or read state. For homelab use that's fine. If MinIO won't come
back (data loss), see the recovery section in `opentofu/README.md` —
the short version is: state can be recreated from the running cluster
plus the Tofu code, just slowly and carefully.
