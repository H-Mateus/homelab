# Homelab

Self-hosted infrastructure running on a TrueNAS Scale server,
providing media services, network-wide ad blocking, and secure
remote access. This repository is the source of truth for all
configuration.

## Architecture

![Architecture diagram](docs/diagrams/architecture.png)

<!-- TODO: replace with real diagram. For now, a text overview: -->

- **TrueNAS Scale** runs on an old desktop PC I build — handles storage (ZFS)
  and hosts Docker containers managed via Dockhand
- **SWAG** provides reverse proxy and TLS termination for all
  web-facing services
- **Tailscale** provides secure remote access without exposing
  ports to the internet
- **CrowdSec** provides collaborative intrusion prevention
- **AdGuard Home** runs as the network DNS, blocking ads and
  trackers for all devices on the LAN

## Services

| Service | Purpose | Access |
|---------|---------|--------|
| AdGuard Home | Network-wide DNS / ad blocking | LAN + Tailscale |
| SWAG | Reverse proxy + Let's Encrypt | Public (443) |
| CrowdSec | Intrusion prevention | Internal |
| *arr stack | Media automation | Tailscale only |
| [etc.] | | |

## Key design decisions

Full ADRs in [docs/decisions/](docs/decisions/).

- **Tailscale over port forwarding** — only ports 80/443 are exposed;
  everything else is accessed via Tailscale mesh VPN
- **SWAG over Traefik / NPM** — [your reasoning]
- **CrowdSec and fail2ban** — community threat intelligence, modern
  architecture, better integration with reverse proxies
- **Dockge/Dockhand for management** — file-based compose stacks
  remain the source of truth, manageable via git

## Repository structure

\`\`\`
.
├── truenas/
│   └── docker-compose/     # One directory per stack
│       ├── adguardhome/
│       ├── swag/
│       ├── arr-stack/
│       └── ...
├── docs/
│   ├── diagrams/
│   ├── decisions/          # Architecture Decision Records
│   └── runbooks/           # Operational procedures
└── scripts/                # Backup and maintenance scripts
\`\`\`

## Deployment workflow

1. Changes are made locally and committed to this repo
2. On the TrueNAS host, `git pull` updates the stack directories
3. Dochand is used to redeploy affected stacks
4. Dockhand handles routine image updates

## Secrets management

No secrets are committed to this repository. Each stack that requires
secrets includes a `.env.example` file documenting required variables.
Actual `.env` files live only on the host. The repository is scanned
with [gitleaks](https://github.com/gitleaks/gitleaks) on every push.

## Planned work

- [ ] Migrate from Docker Compose to k3s on a separate Proxmox host
- [ ] Add Prometheus + Grafana monitoring
- [ ] Implement GitOps deployment with ArgoCD
- [ ] Add Home Assistant stack on Proxmox Mini PC
- [ ] Off-site backup automation with Restic

## Hardware

- **TrueNAS server**: Intel i7-4770K, 16GB custom build desktop
- **Upcoming**: HP ProDesk 400 G5 Mini for Proxmox / Home Assistant

## License

MIT
