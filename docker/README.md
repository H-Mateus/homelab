# Docker Compose Stacks

This directory contains Docker Compose files for all services running on the TrueNAS server.

## Prerequisites

- Docker and Docker Compose v2 installed (available by default on TrueNAS SCALE).
- A `.env` file placed alongside each `docker-compose.yml` (copy the provided `.env.example` and fill in your values).

## Stack Overview

| Stack | Directory | Services |
|-------|-----------|---------|
| Media | [`media/`](media/) | Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent |
| Networking | [`networking/`](networking/) | Traefik, Cloudflare DDNS |
| Monitoring | [`monitoring/`](monitoring/) | Grafana, Prometheus, node-exporter, cAdvisor |
| Productivity | [`productivity/`](productivity/) | Vaultwarden, Nextcloud |

## Common Patterns

### Bringing a Stack Up

```bash
cd docker/<stack>
cp .env.example .env
# Edit .env with your values
docker compose up -d
```

### Viewing Logs

```bash
docker compose -f docker/<stack>/docker-compose.yml logs -f
```

### Updating Containers

```bash
docker compose -f docker/<stack>/docker-compose.yml pull
docker compose -f docker/<stack>/docker-compose.yml up -d
```

### Stopping a Stack

```bash
docker compose -f docker/<stack>/docker-compose.yml down
```

## Networking

All stacks share a common external Docker network called `proxy` so that Traefik can route traffic to them. Create it once before starting any stack:

```bash
docker network create proxy
```

## Data Volumes

Container data is stored in the `tank/docker/appdata` ZFS dataset (see [Datasets](../docs/truenas/datasets.md)). Each service has its own sub-directory, mapped via the `APPDATA_DIR` variable in the `.env` files.

## Traefik Labels

Services that should be accessible via Traefik use labels like:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<service>.rule=Host(`<service>.example.com`)"
  - "traefik.http.routers.<service>.entrypoints=websecure"
  - "traefik.http.routers.<service>.tls.certresolver=cloudflare"
```
