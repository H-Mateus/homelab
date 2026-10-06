# Paperless-ngx

Document archive for scanned paper. Phone scans go in, get OCR'd, and
become searchable. Tailnet-only, at `https://paperless.<tailnet>.ts.net`.

## Datasets

```
apps/paperless            encryption root (key), lz4, recordsize 128K
├── pgdata                child dataset, recordsize 16K   → postgres
├── data/                 dir, 568:568   → search index, classifier, logs
├── media/                dir, 568:568   → originals + archived PDF/A
├── consume/              dir, 568:568   → drop folder (auto-ingested)
└── export/               dir, 568:568   → document_exporter output
```

Why it's all on `apps` (NVMe) and none of it on `tank`:

- **Size.** Scanned documents are small. Even 10k documents with
  their archive copies come to tens of GB, and `apps` has hundreds of GiB
  free.
- **Consistency.** DB and media share one dataset tree, so one recursive
  snapshot captures both at the same instant. The DB never points at
  files the snapshot doesn't contain.
- **Backup coverage.** The `apps` snapshot task is already recursive, so
  the new datasets are picked up automatically. The `tank` snapshot task
  is not recursive and would need the dataset added by hand.

Why it's **encrypted**: ZFS encryption can only be set when a dataset is
created (see `docs/at-rest-encryption.md`). This is the most sensitive
data on the box and it starts out empty, so encrypting now costs nothing.
Doing it later means a migration. It also serves as the pilot for the
zero-knowledge off-site plan.

### Create them (TrueNAS UI)

1. **Datasets → `apps` → Add Dataset**
   - Name: `paperless`, Dataset Preset: **Generic**
   - **Encryption**: untick *Inherit*, tick *Encryption*,
     Type **Key**, *Generate Key*, Cipher **AES-256-GCM**
   - Advanced: Compression **LZ4** (inherit), Record Size **128K**
     (inherit), Atime **Off**
2. **Export the key immediately**: `apps/paperless` → ZFS Encryption card →
   **Export Key**. Store it in the password manager and in the offline
   envelope. The key auto-unlocks at boot from the TrueNAS config DB, so
   services start unattended. That also means the config backup needs
   *Export Password Secret Seed* ticked.
3. **Datasets → `apps/paperless` → Add Dataset**
   - Name: `pgdata`, Preset **Generic**, encryption **inherited**
   - Advanced: Record Size **16K**. Postgres writes 8K pages, and 16K
     cuts read-modify-write overhead while staying compressible.
4. Create the plain directories (TrueNAS shell):
   ```sh
   mkdir -p /mnt/apps/paperless/{data,media,consume,export}
   chown -R 568:568 /mnt/apps/paperless/{data,media,consume,export}
   ```
   Leave `pgdata` owned by root. The postgres entrypoint chowns it to
   its own uid on first init.

### Off-site replication (raw, zero-knowledge)

OpenZFS refuses to send an encrypted dataset **with properties** unless
the send is **raw**, and one replication task can't mix raw and non-raw.
So Paperless has its own task:

- The main "Regular remote backup" PULL task (on Quack01, non-raw into the
  key-holding `HDDs/backups/local`) has `apps/paperless` in **Exclude
  Child Datasets**.
- A separate PULL task replicates `apps/paperless` (recursive, same
  `-daily`/`-weekly`/`-mothly` naming schemas, **Encryption unchecked** →
  raw send) to `HDDs/backups/paperless`. That dataset must NOT be
  pre-created: the first raw receive creates it as an encrypted copy.
  It stays **locked** on Quack01, which never holds the key.

No dedicated snapshot task: the recursive `apps` snapshot task covers
`apps/paperless` and `pgdata`.

Restore = replicate back to the primary (or anywhere with the key) and
unlock with the exported key.

## Deploy (Dockhand)

1. Tailscale admin: add `tag:paperless` to the ACL. Grant only your own
   devices; don't share it with family the way `tag:immich` is shared.
   Create a pre-approved, non-ephemeral auth key with that tag.
2. Dockhand: create the stack from git path `truenas/docker-compose/paperless`.
   Fill in `.env` from `.env.example`, including `PAPERLESS_URL` with your
   tailnet name.
3. Deploy, open `https://paperless.<tailnet>.ts.net`, and log in with the
   admin user. Then blank `PAPERLESS_ADMIN_*` in Dockhand.

## Getting documents in

- **Phone:** scan with a document scanner (Google Drive scan, Microsoft
  Lens) rather than the camera, so you get de-skew and contrast. Then share
  the PDF to a Paperless mobile app, or upload through the web UI over
  Tailscale.
- **Drop folder:** anything written to `consume/` is ingested and then
  deleted. It can become an SMB share later, but if so, make `consume` its
  own child dataset first so the share's ACLs don't touch the rest.

## Logical backup

Snapshots + replication cover the raw files. On top of that, a nightly
export gives you a DB-independent copy you can import into a fresh
install. Add it in **System → Advanced → Cron Jobs** (user `root`):

```sh
docker exec paperless document_exporter ../export --delete --no-progress-bar
```

Schedule it **before** the daily `apps` snapshot, so each snapshot
contains a fresh export.

## Tuning

Capped for the shared NAS: 1 task worker × 2 OCR threads, plus a
`mem_limit` on every container (~2.8 GB in total). Tika + Gotenberg are
commented out in the compose file. Enable them only if you need Office
documents or `.eml` ingestion.
