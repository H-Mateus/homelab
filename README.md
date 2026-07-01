# Homelab

Self-hosted infrastructure running on a TrueNAS Scale server and a
Talos Linux Kubernetes cluster on Proxmox, providing media services,
network-wide ad blocking, and secure remote access. This repository
is the source of truth for all configuration, managed with GitOps.

## Architecture

![](images/260524-202517.avif)

- **TrueNAS Scale** runs on an old desktop PC — handles storage (ZFS)
  and hosts Docker containers managed via Dockhand
- **Proxmox** hosts a Talos Linux Kubernetes cluster, provisioned
  with OpenTofu (IaC) and reconciled with Flux CD v2 (GitOps)
- **SWAG** provided reverse proxy and TLS termination for web-facing
  services (currently **disabled** — being retired in favour of
  per-service Tailscale sidecars as the remote→local TrueNAS migration
  proceeds)
- **Tailscale** provides secure remote access without exposing
  ports to the internet, with the Tailscale Kubernetes Operator
  managing cluster ingress via Flux
- **CrowdSec** provides collaborative intrusion prevention
- **AdGuard Home** runs as the network DNS, blocking ads and
  trackers for all devices on the LAN

## Services

| Service | Platform | Purpose | Access |
|---------|----------|---------|--------|
| AdGuard Home | TrueNAS | Network-wide DNS / ad blocking | LAN + Tailscale |
| SWAG | TrueNAS | Reverse proxy + Let's Encrypt (disabled; being retired for Tailscale sidecars) | LAN + Tailscale |
| CrowdSec | TrueNAS | Intrusion prevention | Internal |
| *arr stack | TrueNAS | Media automation | Tailscale only |
| Immich | TrueNAS | Self-hosted photo library | Tailscale (own device, shared to family) |
| Immich Frame | TrueNAS | Slideshow client for Immich | Tailscale (own device, shared to family) |
| Tailscale Operator | Kubernetes | Cluster ingress via Tailscale | Tailscale |
| democratic-csi | Kubernetes | NFS PV provisioner backed by TrueNAS | Internal |
| kube-prometheus-stack | Kubernetes | Prometheus + Grafana + Alertmanager | Tailscale (Grafana via operator) |

## Key design decisions

Full ADRs in [docs/decisions/](docs/decisions/).

- **Tailscale over port forwarding** — only ports 80/443 are exposed;
  everything else is accessed via Tailscale mesh VPN
- **SWAG over Traefik / NPM** — mature, battle-tested, tight
  integration with CrowdSec and Let's Encrypt DNS-01
- **CrowdSec and fail2ban** — community threat intelligence, modern
  architecture, better integration with reverse proxies
- **Dockge/Dockhand for TrueNAS** — file-based compose stacks remain
  the source of truth, manageable via git
- **Flux CD over ArgoCD** — lighter-weight, Kubernetes-native, strong
  SOPS integration, pull-based model fits a homelab well
- **SOPS + age for Kubernetes secrets** — encrypted secrets committed
  to git; the age private key lives only in the cluster (see
  [Secrets management](#secrets-management))
- **OpenTofu for cluster IaC, not Terraform** — fork stewardship,
  permissive licence, and the bpg/proxmox + siderolabs/talos
  providers are first-class. The full design + cutover runbook lives
  in [opentofu/README.md](opentofu/README.md)

## Repository structure

```
.
├── kubernetes/
│   ├── clusters/talos/          # Flux bootstrap manifests
│   │   ├── flux-system/         # Flux GitRepository + Kustomization
│   │   ├── sources.yaml         # → kubernetes/infrastructure/sources/
│   │   ├── infrastructure.yaml  # → kubernetes/infrastructure/
│   │   └── apps.yaml            # → kubernetes/apps/
│   ├── infrastructure/          # Cluster prerequisites (CSI, snapshots, Helm repos)
│   │   ├── sources/             #   HelmRepository definitions
│   │   ├── snapshot-controller/ #   CSI volume snapshot CRDs
│   │   └── democratic-csi/      #   NFS provisioner → TrueNAS
│   └── apps/                    # Workload manifests (one dir per app)
│       ├── tailscale/           #   Tailscale Kubernetes Operator
│       └── monitoring/          #   kube-prometheus-stack (Grafana et al.)
├── opentofu/                    # IaC for the Talos cluster on Proxmox
│   ├── modules/                 #   talos-image, proxmox-vm, talos-cluster
│   └── live/homelab/            #   The one environment composing the modules
├── truenas/
│   └── docker-compose/          # One directory per stack
│       ├── adguardhome/
│       ├── swag/
│       ├── arr-stack/
│       ├── garage/              #   S3-compatible store backing OpenTofu state
│       ├── immich/              #   With tailscale sidecar — own Tailnet device
│       └── immich-frame/        #   With tailscale sidecar — own Tailnet device
├── proxmox/                     # Legacy hand-built Talos configs (UNTRACKED — PKI)
├── docs/
│   ├── architecture.md          # Network and service architecture
│   ├── talos-extensions-rollout.md  # Runbook: rolling out Talos extensions
└── scripts/
    └── check-sops-encrypted.sh  # Pre-commit helper (SOPS safety net)
```

## Deployment workflows

### Kubernetes (Flux GitOps)

```
git push → Flux polls every 1 min → reconciles kubernetes/clusters/talos/
         → applies kubernetes/apps/ (10-min interval, prune enabled)
```

New workloads go into `kubernetes/apps/<namespace>/<app>/`. The
`apps.yaml` Kustomization picks them up automatically on the next sync.
Encrypted `*.sops.yaml` secrets are decrypted in-cluster by Flux.

### TrueNAS Docker stacks

1. Changes are committed to this repo
2. On the TrueNAS host, `git pull` updates the stack directories
3. Dockhand reloads/redeploys affected stacks

## Secrets management

Secrets are never committed in plaintext. Two strategies are in use:

**TrueNAS (Docker Compose):** Secrets live only in `.env` files on the
host. Each stack includes a `.env.example` template documenting required
variables. Gitleaks runs on every commit and push to catch accidental
exposure.

**Kubernetes (Flux):** Secrets are encrypted with
[SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age) and committed as
`*.sops.yaml` files. Flux decrypts them in-cluster using an age private
key stored as a Kubernetes Secret in `flux-system`. The private key
never enters the repository.

A dedicated pre-commit hook (`check-sops-encrypted`) blocks any
`*.sops.yaml` file that is missing the `sops:` metadata block,
providing a deterministic safety net on top of gitleaks — which catches
known secret patterns but is not SOPS-aware.

See [docs/architecture.md](docs/architecture.md) for the full secret
lifecycle and trust model.

## Pre-commit hooks

```bash
# Run all hooks against staged files
pre-commit run

# Run against all files
pre-commit run --all-files
```

| Hook | Purpose |
|------|---------|
| `gitleaks` | Catch accidentally committed secrets (patterns + entropy) |
| `detect-private-key` | Block PEM private keys |
| `check-yaml` | YAML syntax validation |
| `yamllint` | YAML style linting |
| `check-sops-encrypted` | Block unencrypted `*.sops.yaml` files |

## Hardware

- **TrueNAS server**: Intel i7-4770K, 16 GB — off-site at a family
  member's house; managed remotely via Tailscale + JetKVM
- **Proxmox host**: HP ProDesk 400 G5 Mini — running Talos Linux VMs
  for the Kubernetes cluster

## Planned work

- [x] GitOps for Kubernetes with Flux CD
- [x] Secret management with SOPS + age
- [x] Tailscale Kubernetes Operator managed via Flux
- [x] NFS-backed dynamic PV provisioning (democratic-csi → TrueNAS)
- [x] Prometheus + Grafana + Alertmanager (kube-prometheus-stack)
- [x] Migrate Immich from a TrueNAS app to a Docker Compose stack with
      a Tailscale sidecar (own Tailnet device, shareable to family)
- [x] Rebuild Talos cluster from hand-built configs to OpenTofu IaC
      with remote state on Garage (S3-compatible) over Tailscale
- [ ] Migrate remaining Docker services to Kubernetes
- [ ] Implement Renovate Bot for automated dependency updates
- [ ] Add Home Assistant stack
- [ ] Off-site backup automation with Restic + Backblaze B2
- [ ] Two-site ZFS replication (local TrueNAS → remote as replica)

## License

MIT
