# Network Configuration

Network settings for the TrueNAS server.

## Interfaces

| Interface | Type | IP Address | Notes |
|-----------|------|------------|-------|
| `eno1` | Physical | `192.168.1.x/24` | Primary LAN |

> Replace `192.168.1.x` with your actual static IP. A static IP (or a DHCP reservation at the router) is strongly recommended for a NAS so that shares and services always resolve at the same address.

## Static IP Configuration

Configure a static IP in the TrueNAS web UI:

1. Go to **Network → Interfaces**.
2. Select the network interface.
3. Disable **DHCP**.
4. Add the desired static IP and subnet mask.
5. Set the gateway under **Network → Global Configuration**.
6. Set DNS servers under **Network → Global Configuration** (e.g. `1.1.1.1` and `8.8.8.8`).

## DNS

| Role | Address |
|------|---------|
| Primary DNS | `1.1.1.1` (Cloudflare) |
| Secondary DNS | `8.8.8.8` (Google) |

A local DNS resolver (e.g. **AdGuard Home** or **Pi-hole**) can be used to provide local hostname resolution so that services are accessible by name rather than IP.

## Hostname

The server hostname is set under **Network → Global Configuration**. Example:

```
Hostname: truenas
Domain:   local
FQDN:     truenas.local
```

## Ports Used by Services

The following ports are exposed on the TrueNAS host. Inbound traffic from the internet is handled by **Traefik** (see [networking stack](../../docker/networking/docker-compose.yml)); only ports 80 and 443 need to be forwarded at the router for external access.

| Port | Protocol | Service | External? |
|------|----------|---------|-----------|
| 80 | TCP | Traefik HTTP (redirects to HTTPS) | Yes (router forward) |
| 443 | TCP | Traefik HTTPS | Yes (router forward) |
| 8096 | TCP | Jellyfin (internal) | No |
| 8080 | TCP | qBittorrent WebUI (internal) | No |
| 3000 | TCP | Grafana (internal) | No |
| 9000 | TCP | Portainer (internal) | No |
| 445 | TCP | SMB shares | LAN only |
| 2049 | TCP/UDP | NFS shares | LAN only |
| 22 | TCP | SSH | LAN only (or VPN) |

## Firewall / Access Control

- The TrueNAS web UI (port 80/443) should be restricted to the LAN. Do **not** expose the TrueNAS admin interface directly to the internet.
- SSH should only be accessible from trusted IPs or via a VPN.
- All external-facing services should go through Traefik with valid TLS certificates.

## VPN

A site-to-site or road-warrior VPN (e.g. WireGuard) is recommended for remote admin access. WireGuard can be set up via the TrueNAS **Apps** catalogue or as a Docker container.
