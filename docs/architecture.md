# Architecture

This document describes how the homelab is structured, how data and
requests flow through it, and the reasoning behind key design choices.

## Overview

The homelab currently consists of a single TrueNAS Scale server hosted
**off-site at a family member's house**. All services run as Docker
Compose stacks managed by Dockge/Dockhand. Remote access is via
Tailscale; no services are exposed publicly currently.
reverse proxy.

This off-site arrangement is unusual but deliberate: it provides
geographic redundancy for storage, low-friction backups for family
members on the same network, and isolates noisy/power-hungry hardware
from my flat. It also creates interesting operational constraints -
notably, no physical access for recovery - which have shaped several
design decisions (see ADRs).

## Physical and network topology

```mermaid
flowchart TB
    subgraph Remote[Remote site - family member's house]
        Router1[Router]
        TrueNAS[TrueNAS Scale server]
        JetKVM[JetKVM<br/>out-of-band management]
        Router1 --- TrueNAS
        Router1 --- JetKVM
        JetKVM -.BIOS/IPMI.-> TrueNAS
    end

    subgraph Local[Local site - my flat]
        Devices[Laptop, phone, etc.]
    end

    subgraph Cloud[External services]
        Tailscale[Tailscale<br/>coordination]
        CF[Cloudflare DNS]
        LE[Let's Encrypt]
        CS[CrowdSec Central API]
    end

    Internet((Internet))

    Router1 <--> Internet
    Devices <--> Internet
    Internet <--> Cloud

    Devices <-.Tailscale mesh.-> TrueNAS
    Devices <-.Tailscale mesh.-> JetKVM
```

## Service access patterns

All services are accessed via nice domain names (e.g.
`immich.tail.mateusharrington.com`) regardless of access path. There are
three ways a request can reach a service:

1. **Public** — no services currently exposed; SWAG + CrowdSec is in
   place for when this changes.
2. **Tailscale (personal devices)** — my own devices on the tailnet
   resolve domains via MagicDNS to the TrueNAS host's tailnet IP and
   hit SWAG.
3. **Tailscale (shared, restricted)** — family members access Immich
   via Tailscale node sharing rather than user invites, with ACLs
   restricting them to the Immich port only. This works around the
   3-user limit of the Tailscale free plan and limits blast radius if
   one of their devices is compromised.
4. **LAN** — devices on the remote LAN resolve to the static LAN IP
   and hit SWAG directly.

```mermaid
flowchart LR
    Client[Client device]

    Client -->|*.mateusharrington.com| DNS{DNS resolution}
    DNS -->|Tailscale| TSIP[Tailnet IP]
    DNS -->|LAN| LANIP[LAN IP]
    DNS -->|Public| PubIP[Public IP via Cloudflare]

    TSIP --> SWAG
    LANIP --> SWAG
    PubIP --> Router --> SWAG

    SWAG -->|check| CrowdSec
    SWAG -->|proxy| Service[Target service]
```

The wildcard certificate (`*.mateusharrington.com`,
`*.tail.mateusharrington.com`, `*.local.mateusharrington.com`) is
issued via Let's Encrypt DNS-01 challenge through Cloudflare, so SWAG
never needs to be publicly reachable for cert renewal.

## Storage layout

- **Pool: `HDDs`** — main storage, mirrored vdevs
  - `HDDs/Media` — Plex/arr media library
  - `HDDs/appdata` — Docker volumes and compose configs
  - `HDDs/backups` — local backup target
- **Snapshots**:
  - daily with 2 weekly retention

## Trust boundaries

| Zone | Examples | Access control |
|------|----------|----------------|
| Public internet | n/a currently | Would be SWAG + CrowdSec |
| Tailnet | All services via `*.mateusharrington.com` | Tailscale ACLs |
| Remote LAN | TrueNAS UI, services | Physical/network access at remote site |
| Out-of-band | TrueNAS BIOS, boot | JetKVM over Tailscale |

The JetKVM is critical given the off-site location: it provides BIOS
access, power control, and console output for recovery scenarios where
the OS is unreachable. Without it, any failure requiring BIOS
intervention would mean a trip to the remote site.

## External dependencies

| Service | Purpose | Failure impact |
|---------|---------|----------------|
| Cloudflare DNS | Authoritative DNS, DNS-01 cert challenge | Cert renewal fails after ~60 days |
| Let's Encrypt | TLS certificates | Existing certs valid for ~90 days |
| Tailscale | Remote access mesh | Lose remote access; LAN unaffected |
| CrowdSec Central API | Threat intel updates | Local bouncing still works on cached rules |

## Backup strategy

### Current state

- ZFS snapshots on the remote TrueNAS (local to that machine only)
- No off-site backup beyond the remote location itself

This is insufficient: snapshots protect against accidental deletion
but not against site loss (fire, theft, hardware failure of the whole
pool). It's also not 3-2-1 compliant.

### Planned: 3-2-1 with cloud backup

```
ZFS snapshots (remote TrueNAS)  →  ZFS replication (future local TrueNAS)  →  encrypted cloud backup (Backblaze B2)
        copy 1                              copy 2                                       copy 3
```

- **Tool**: `restic` for cloud backups — client-side AES-256 encryption,
  deduplication, snapshot semantics
- **Target**: Backblaze B2 (S3-compatible, ~$6/TB/month, no egress
  fees within reason)
- **Scope**: irreplaceable data only (photos via Immich, documents,
  service configs). Re-downloadable media is excluded.
- **Schedule**: nightly, with monthly integrity checks (`restic check`)
- **Key management**: restic repo password stored in password manager +
  printed offline copy in a sealed envelope (the "you got hit by a bus"
  recovery path)

### Cryptographic considerations

`restic` uses AES-256 for data encryption and `scrypt` for
password-based key derivation. Both are considered resistant to known
quantum attacks: Grover's algorithm halves effective symmetric key
strength, leaving AES-256 with ~128-bit post-quantum security, which
remains adequate. Post-quantum concerns primarily affect asymmetric
cryptography (TLS key exchange, SSH keys), not symmetric encryption of
backup data at rest.

## Planned evolution

The medium-term plan is a **two-site replication topology**:

```mermaid
flowchart LR
    subgraph Local[Local site - planned]
        NewTrueNAS[New TrueNAS<br/>primary]
    end
    subgraph Remote[Remote site - current]
        OldTrueNAS[Existing TrueNAS<br/>replication target]
    end
    NewTrueNAS -->|ZFS send/receive| OldTrueNAS
```

Once built, the local server becomes the primary and the existing
remote server becomes a ZFS replication target — providing geographic
redundancy for snapshots without the latency of running services
remotely. This has been delayed by the recent spike in hard drive
prices.

Other planned changes:

- An encrypted cloud backup is also planned.
- Migrate Immich from a TrueNAS app to a Docker Compose stack, for
  consistency with the rest of the stack and to bring it under the
  same git-managed config.
- A separate Proxmox host (HP ProDesk 400 G5 Mini) is also planned for
  running Home Assistant and experimenting with k3s.

---

## Kubernetes cluster (Talos + Flux)

A Talos Linux Kubernetes cluster runs on Proxmox VMs alongside the
TrueNAS server. Talos is an immutable, API-driven OS designed
specifically for Kubernetes — there is no SSH, no package manager, and
no shell; all configuration is applied declaratively via `talosctl`.

### Cluster topology

```
Proxmox host (HP ProDesk 400 G5 Mini)
└── Talos VMs
    ├── controlplane (1x)
    └── workers (n x, TBD)
```

Machine configs live in `proxmox/` (untracked — contains PKI material
and secrets, must never be committed).

### Flux GitOps flow

Flux CD v2 is the GitOps controller. It continuously reconciles the
cluster state with this repository:

```
git push (main branch)
  │
  ▼
Flux GitRepository (polls every 1 min)
  │
  ▼
flux-system Kustomization  →  kubernetes/clusters/talos/
  │                           (all *.yaml files here are raw manifests)
  ├──▶ sources Kustomization (10-min interval)
  │      └── kubernetes/infrastructure/sources/
  │              └── HelmRepositories (tailscale, ...)
  │
  └──▶ apps Kustomization (10-min interval, prune: true)
         dependsOn: sources  ← waits for HelmRepositories to be Ready
         └── kubernetes/apps/
                 ├── tailscale/      ← Tailscale Operator (HelmRelease)
                 └── <future apps>/
```

Key properties of this setup:

- **Prune enabled**: resources removed from git are deleted from the
  cluster on the next reconcile — the repo is always the single source
  of truth.
- **Wait + timeout**: the apps Kustomization waits for all resources to
  become Ready before considering a sync successful, with a 5-minute
  timeout before failing loudly.
- **HelmRelease remediation**: each HelmRelease is configured to retry
  failed installs/upgrades up to 3 times before giving up.

### Adding a new workload

```bash
mkdir -p kubernetes/apps/<namespace>/<app>
# Create: kustomization.yaml, namespace.yaml, and workload manifests
# If the app needs secrets, create an <app>-secret.sops.yaml and encrypt it
git add -A && git commit -m "feat: add <app>"
git push
# Flux picks it up on the next poll cycle
```

---

## Secrets management

### Strategy overview

| Platform | Method | Where secrets live |
|----------|--------|--------------------|
| TrueNAS (Docker) | `.env` files (never committed) | On the host only |
| Kubernetes (Flux) | SOPS + age (encrypted in git) | Cluster only (private key) |

### SOPS + age: how it works

[SOPS](https://github.com/getsops/sops) encrypts individual YAML
values (not the whole file) using a recipient's public key. The
encrypted file is safe to commit; decryption requires the corresponding
private key, which lives only inside the cluster.

[age](https://github.com/FiloSottile/age) provides the key pair:

```
age-keygen -o age.agekey
# Public key:  age1sg49q...   ← stored in .sops.yaml (safe to commit)
# Private key: AGE-SECRET-...  ← stored only in the cluster as a K8s Secret
```

The private key is bootstrapped into the cluster once:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=./age.agekey
```

After that, the local copy is deleted (or stored in a password manager
as a break-glass recovery key). Flux's `decryption` stanza in
`apps.yaml` tells it to use this secret when reconciling:

```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```

### Secret lifecycle

```
1. Author creates secret file:
   kubernetes/apps/<ns>/<app>/<name>-secret.sops.yaml

2. Fill in plaintext values (DO NOT COMMIT at this stage)

3. Encrypt in place:
   sops --encrypt --in-place kubernetes/apps/<ns>/<app>/<name>-secret.sops.yaml

4. Commit the encrypted file — values are AES-256-GCM ciphertext,
   safe to store in a public repository.

5. On git push, Flux fetches the file, decrypts it in-cluster using
   the age private key, and applies the resulting Secret to Kubernetes.

6. To edit later:
   sops kubernetes/apps/<ns>/<app>/<name>-secret.sops.yaml
   # Opens $EDITOR with plaintext; re-encrypts on save.
```

### Defence in depth against accidental plaintext commits

Three independent layers protect against committing unencrypted secrets:

1. **Naming convention** — all Kubernetes secrets use the `.sops.yaml`
   suffix, making them visually distinguishable and easy to
   pattern-match in hooks and gitignore rules.

2. **`check-sops-encrypted` pre-commit hook** — deterministic check:
   any staged `*.sops.yaml` file that lacks the `sops:` block (which
   SOPS adds on encryption) causes the commit to fail with a clear
   error message. This is the primary safety net.

3. **Gitleaks** — catches other accidentally committed secrets using
   entropy analysis and known pattern matching. Complements the SOPS
   hook but is not SOPS-aware; the two hooks cover different failure
   modes.

### Trust boundaries

```
┌──────────────────────────────────────────────────────────────┐
│ Git repository (public)                                       │
│  *.sops.yaml  ← AES-256-GCM ciphertext, safe to store here  │
│  .sops.yaml   ← age PUBLIC key only, safe to store here      │
└──────────────────────────────────────────────────────────────┘
                              │ Flux pulls + decrypts
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Kubernetes cluster (flux-system namespace)                    │
│  Secret/sops-age  ← age PRIVATE key, never leaves cluster    │
│                                                               │
│  Flux decrypts *.sops.yaml in memory; plaintext Secret       │
│  objects are applied to the cluster but never written to git  │
└──────────────────────────────────────────────────────────────┘
```

The age private key is the only secret that cannot be rotated via git.
It should be backed up to a password manager as a break-glass recovery
key in case the cluster is destroyed and needs to be rebuilt from
scratch.
