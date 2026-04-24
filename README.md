# Homelab

A repository documenting my homelab configuration, including a TrueNAS server and the various services deployed on it via Docker Compose.

## Overview

The homelab is centred around a **TrueNAS SCALE** server which handles storage and runs containerised services through Docker Compose stacks.

## Hardware

| Component | Details |
|-----------|---------|
| OS | TrueNAS SCALE |
| Role | NAS + Docker host |

## Repository Structure

```
homelab/
├── docs/
│   └── truenas/          # TrueNAS server documentation
│       ├── README.md     # Overview
│       ├── setup.md      # Initial setup notes
│       ├── datasets.md   # Storage pools and datasets layout
│       └── network.md    # Network configuration
└── docker/               # Docker Compose stacks
    ├── README.md         # Stacks overview
    ├── media/            # Media stack (Jellyfin, *arr, qBittorrent)
    ├── networking/       # Networking stack (Traefik, Cloudflare DDNS)
    ├── monitoring/       # Monitoring stack (Grafana, Prometheus)
    └── productivity/     # Productivity stack (Vaultwarden, Nextcloud)
```

## Quick Links

- [TrueNAS Documentation](docs/truenas/README.md)
- [Docker Stacks](docker/README.md)

## Services

| Service | Stack | Description |
|---------|-------|-------------|
| [Jellyfin](https://jellyfin.org) | media | Open-source media server |
| [Sonarr](https://sonarr.tv) | media | TV series management |
| [Radarr](https://radarr.video) | media | Movie management |
| [Prowlarr](https://prowlarr.com) | media | Indexer manager |
| [Bazarr](https://www.bazarr.media) | media | Subtitle management |
| [qBittorrent](https://www.qbittorrent.org) | media | Torrent client (via VPN) |
| [Traefik](https://traefik.io) | networking | Reverse proxy |
| [Cloudflare DDNS](https://github.com/timothyjmiller/cloudflare-ddns) | networking | Dynamic DNS updater |
| [Grafana](https://grafana.com) | monitoring | Metrics dashboards |
| [Prometheus](https://prometheus.io) | monitoring | Metrics collection |
| [node-exporter](https://github.com/prometheus/node_exporter) | monitoring | Host metrics exporter |
| [cAdvisor](https://github.com/google/cadvisor) | monitoring | Container metrics exporter |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | productivity | Self-hosted Bitwarden |
| [Nextcloud](https://nextcloud.com) | productivity | Self-hosted file storage |
