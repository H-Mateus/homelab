# *arr stack

Media automation stack: Prowlarr-driven indexer management, Sonarr/Radarr/Lidarr
for TV/movies/music, Bazarr for subtitles, Jellyfin for playback, Seerr for
requests, and qBittorrent (routed through Proton VPN with WireGuard) for
downloads.

## Services

| Service        | Port  | Purpose                                              |
|----------------|-------|------------------------------------------------------|
| Prowlarr       | 9696  | Indexer aggregator; pushes indexers to other *arrs   |
| Sonarr         | 8989  | TV series automation                                 |
| Radarr         | 7878  | Film automation                                      |
| Lidarr         | 8686  | Music automation                                     |
| Bazarr         | 6767  | Subtitle automation for Sonarr/Radarr                |
| Jellyfin       | 1337  | Media server / playback                              |
| Seerr          | 5055  | User-facing request frontend for Jellyfin            |
| FlareSolverr   | 8191  | Cloudflare challenge solver for protected indexers   |
| qBittorrent    | 8080  | Torrent client (VPN-bound)                           |
| Privoxy        | 8118  | HTTP proxy exposing the VPN tunnel to LAN clients    |

All services are reached via the SWAG reverse proxy on Tailscale; direct port
access is LAN-only.

## Architecture notes

### qBittorrent + Proton VPN

qBittorrent runs in a `hotio/qbittorrent` container with WireGuard built in.
The container:

- Establishes a WireGuard tunnel to Proton on startup
- Kills all non-VPN traffic if the tunnel drops (`VPN_LAN_LEAK_ENABLED=false`)
- Allows LAN access from `${VPN_LAN_NETWORK}` so the WebUI remains reachable
- Uses Proton's NAT-PMP to auto-acquire a forwarded port
  (`VPN_AUTO_PORT_FORWARD=true`)

The WireGuard config lives at `configs/qbit/wireguard/wg0.conf`. A sanitised
template is committed as `wg0.conf.example`. To regenerate:

1. Log into the Proton VPN account dashboard.
2. **Account → WireGuard → Create config**.
3. Enable **NAT-PMP (Port Forwarding)** — required for inbound peers.
4. Choose a P2P-friendly server (look for the arrow icon).
5. Download the `.conf`, drop it in `configs/qbit/wireguard/wg0.conf`.
6. Restart the qbittorrent container.

### Routing specific indexers through the VPN (Privoxy)

Privoxy runs alongside qBittorrent inside the same network namespace, so its
traffic also exits via the VPN tunnel. It exposes port `8118` on the LAN as
an HTTP proxy.

This is used to selectively route specific Prowlarr indexers through the VPN
— for indexers that block residential or datacentre IPs but allow known VPN
ranges. TorrentLeech is the indexer that prompted this setup.

**Configuration in Prowlarr:**

1. **Settings → Indexers → Proxies → Add → HTTP**
   - Name: `proton-vpn`
   - Host: `qbittorrent`
   - Port: `8118`
   - Tags: `vpn`
2. Edit any indexer that needs the VPN, add the `vpn` tag.

Indexers without the tag use the normal connection. This keeps latency low
where it doesn't matter and tunnels only what's necessary.

Toggle via `PRIVOXY_ENABLED=true` on the qbittorrent service.

### FlareSolverr

Headless browser used by Prowlarr to bypass Cloudflare anti-bot challenges
on certain indexers. No persistent state, no config needed beyond the
compose entry. Prowlarr is configured to point at it under
**Settings → Indexers → FlareSolverr**.

## Setup

### Prerequisites

- TrueNAS dataset for the stack (e.g. `/mnt/HDDs/stacks/prowlarr`)
- Media dataset reachable from the host (e.g. `/mnt/HDDs/media`)
- Proton VPN account with WireGuard config generated (see above)
- PUID/PGID `568` (TrueNAS `apps` user) owns the config and media datasets

### First run

```bash
cp .env.example .env
# Edit .env: set MEDIA_PATH and VPN_LAN_NETWORK
mkdir -p configs/qbit/wireguard
cp configs/qbit/wireguard/wg0.conf.example configs/qbit/wireguard/wg0.conf
# Paste real Proton WireGuard config into wg0.conf
docker compose up -d
```

Verify the VPN is up before doing anything else:

```bash
docker exec qbittorrent curl -s ifconfig.me
# Should return a Proton VPN exit IP, NOT your home IP.
```

If it returns your home IP, **stop the container immediately** and check the
WireGuard config.

### Wiring the *arrs together

1. **Prowlarr** first: add indexers, then **Settings → Apps → Add** for each
   *arr. Use the API key from each *arr's `Settings → General`.
2. **Sonarr/Radarr/Lidarr**: configure
   - Root folders pointing into `/media/...`
   - qBittorrent as the download client (host: `qbittorrent`, port `8080`)
   - Quality profiles, custom formats, naming schemes
3. **Bazarr**: link to Sonarr and Radarr via their API keys.
4. **Jellyfin**: add `/media` libraries. Hardware transcoding is currently
   disabled (Nvidia runtime commented out in compose); enable when needed.
5. **Seerr**: link to Jellyfin and to Sonarr/Radarr.

## Backup & recovery

### What's backed up

- **Application-level backups**: Sonarr, Radarr, Prowlarr, Lidarr each run
  weekly internal backups (zipped DB + config.xml) into their own
  `Backups/` folder under `configs/<service>/`. Configured per-app in
  **Settings → General → Backup**.
- **Filesystem snapshots**: weekly ZFS snapshots of the pool capture the
  entire `configs/` tree at a consistent point.
- **Off-site**: not yet — eventual replication target is the
  remote TrueNAS at parents' house, once local hardware is migrated.

### What's NOT in git

The entire `configs/` directory is gitignored. It contains:

- `config.xml` files with API keys
- SQLite databases with indexer credentials, download client passwords,
  notification webhooks, and full history
- The real `wg0.conf` with the Proton private key

Recovery does **not** depend on git — git only carries the compose file,
env template, and documentation. State recovery is via snapshot rollback.

### Recovery procedure

From a clean TrueNAS install:

1. Restore the `configs/` dataset from the most recent ZFS snapshot (or
   from replicated off-site copy).
2. Clone this repo into the stack directory.
3. Recreate `.env` from `.env.example`.
4. Verify `wg0.conf` is present and has a valid Proton key (regenerate if
   the key was rotated).
5. `docker compose up -d`.
6. Spot-check each *arr's UI loads and shows expected indexers / profiles.

If the snapshot is unavailable but the *arr internal backups exist:

1. Bring up the stack with empty configs.
2. In each *arr: **System → Backups → Restore** and upload the latest zip.
3. Re-enter any secrets the backup doesn't carry (download client password,
   notification tokens — varies by app).

## Maintenance

- **Image updates**: handled by Dockhands's auto-update on a schedule.
- **Proton key rotation**: regenerate the WireGuard config from the Proton
  dashboard, replace `wg0.conf`, restart qbittorrent.
- **Watch for**: qBittorrent container failing to start usually means the
  WireGuard tunnel can't establish — check Proton server status, regenerate
  config if needed.

## Files

```
prowlarr/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
└── configs/
    ├── .gitkeep
    └── qbit/
        └── wireguard/
            └── wg0.conf.example
```

Everything else under `configs/` is runtime state, gitignored, and recovered
from snapshot rather than git.
