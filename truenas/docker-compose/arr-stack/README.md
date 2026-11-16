# *arr stack

Media automation stack: Prowlarr-driven indexer management, Sonarr/Radarr
for TV/movies, Bazarr for subtitles, Jellyfin for playback, Seerr for
requests, Suggestarr for watch-history-based suggestions, and qBittorrent
(routed through Proton VPN with WireGuard) for downloads.

Music is not part of this stack: it lives in the separate
[`music`](../music/) stack (slskd / beets / explo / navidrome), which replaced
Lidarr.

## Services

| Service        | Port  | Purpose                                              |
|----------------|-------|------------------------------------------------------|
| Prowlarr       | 9696  | Indexer aggregator; pushes indexers to other *arrs   |
| Sonarr         | 8989  | TV series automation                                 |
| Radarr         | 7878  | Film automation                                      |
| Bazarr         | 6767  | Subtitle automation for Sonarr/Radarr                |
| Jellyfin       | 8096  | Media server / playback                              |
| Seerr          | 5055  | User-facing request frontend for Jellyfin            |
| Profilarr      | 6868  | Syncs custom formats + quality profiles into *arrs   |
| Suggestarr     | —     | Requests titles similar to Jellyfin watch history (tailnet only) |
| FlareSolverr   | 8191  | Cloudflare challenge solver for protected indexers   |
| qBittorrent    | 8080  | Torrent client (VPN-bound)                           |
| Privoxy        | 8118  | HTTP proxy exposing the VPN tunnel to LAN clients    |

Each user-facing service is reached over Tailscale via its own
`tailscale/tailscale` sidecar — its own Tailnet device + MagicDNS hostname
(e.g. `sonarr.<tailnet>.ts.net`), terminating HTTPS with `tailscale serve`
(see the header comment in `docker-compose.yml`). The `ports:` mappings are
retained transitionally for direct-LAN access and can be dropped now that SWAG
is retired. qBittorrent deliberately has no sidecar (its VPN killswitch drops
traffic to the Compose network) and stays reachable on its LAN port `8080`.

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

TorrentLeech is a private tracker, so ratio matters: it is configured in
Prowlarr (synced to Sonarr/Radarr like any other indexer), and anything that
feeds requests in automatically — Suggestarr especially — should go through
an approval step rather than straight to download (see "Suggestarr" below).

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

### Suggestarr

[Suggestarr](https://github.com/giuseppe99barchetta/SuggestArr) reads
Jellyfin watch history, finds similar titles via TMDb, and submits them to
Seerr as requests. Both are reached by Compose service name
(`http://jellyfin:8096`, `http://seerr:5055`) — not `localhost`, which would be
the Suggestarr container itself.

Image `ciuse99/suggestarr` (web UI + setup wizard on port `5000`), with its
SQLite DB and config in `${CONFIG_PATH}/suggestarr` (mounted at
`/app/config/config_files`). The image has no PUID/PGID support, so the
compose file pins it to `user: "568:568"` like Seerr. It has no LAN port:
reach it at `https://suggestarr.<tailnet>.ts.net` (auth key tagged
`tag:ts-apps`, like the other admin UIs).

#### Make Seerr require approval for Suggestarr's requests

Without this, every suggestion is an auto-download — and on a ratio tracker
like TorrentLeech that's a lot of unwanted grabs. By default Suggestarr
submits with the Seerr API key, which acts as the Seerr admin, and admin
requests are auto-approved. Instead, give it a dedicated Seerr user whose
requests land in Seerr's pending queue:

1. In Seerr, **Users → Create Local User** (e.g. `suggestarr`) with a password.
2. Edit that user → **Permissions**: grant **Request** (Movies + Series), and
   make sure **Auto-Approve** (and **Manage Requests** / **Admin**) are
   **unticked**. Check **Settings → Users → Default Permissions** doesn't hand
   out auto-approve to new users.
3. In Suggestarr's Seer settings, enable **user selection**, pick the
   `suggestarr` user and enter its password, so requests are made as that
   user rather than as the admin. (Password login only works for local Seerr
   users, hence step 1.) Avoid the "mapped Seer user" mode for this: it
   requests as each watcher's own Seerr account, which may auto-approve.

Suggestions then show up under **Requests → Pending** in Seerr as a review
queue: approve what you want, decline the rest. Optional extras in
Suggestarr: **Pause while Seer requests are pending** on each job (stops it
piling up suggestions while the queue is unreviewed), and auto-decline after
N days under **Approvals** (needs an API key with `MANAGE_REQUESTS`; it's
dry-run by default).

### FlareSolverr

Headless browser used by Prowlarr to bypass Cloudflare anti-bot challenges
on certain indexers. No persistent state, no config needed beyond the
compose entry. Prowlarr is configured to point at it under
**Settings → Indexers → FlareSolverr**.

## Storage layout (datasets)

This stack spans both pools on the local TrueNAS box. Getting the split right
is the single most important setup decision — it determines whether
Radarr/Sonarr can **hardlink** imports or is forced to **copy** them.

### The hardlink rule

Radarr/Sonarr import a finished download into the library by a hardlink or an
atomic (instant) move — but only when the download and the library live on the
**same filesystem**. On TrueNAS every dataset is a separate filesystem, and
hardlinks cannot cross datasets — not even a parent and its own child dataset.

So the download directory and the organized library must be **directories
inside one single dataset**, not separate datasets:

- `tank/media` with a `downloads/` **directory** → hardlinks work ✅
- `tank/media/downloads` as a **child dataset** → hardlinks break; every import
  is a full copy (2× space during import, can't seed while keeping an organized
  copy) ❌

### Recommended layout

**`tank` (HDD, bulk) — one media dataset, mounted `/media` in every container:**

```
tank/media                 ← MEDIA_PATH; mounted /media in all *arr + Jellyfin + qBit
├── downloads/             qBittorrent save path (categories: downloads/{movies,tv})
├── movies/                Radarr root folder  → /media/movies
└── tv/                    Sonarr root folder  → /media/tv
```

(`tank/media/music` is a child dataset owned by the separate `music` stack.)

**`apps` (SSD, fast) — application config/databases:**

Each service's `/config` (Sonarr/Radarr/etc. SQLite databases, Jellyfin
metadata, qBittorrent + WireGuard) plus the Tailscale sidecar node state are
small, latency-sensitive, and painful to rebuild, so they live on the SSD pool.
`CONFIG_PATH` (default `/mnt/apps/arr-stack`) pins them to a **dedicated
dataset** — independent of where Dockhand keeps the stack — so the whole stack's
persistent state sits in one place you can snapshot / roll back / back up on its
own schedule, while `MEDIA_PATH` reaches across to `tank`. Create it with the
TrueNAS "Apps" preset, owned by uid/gid 568.

### Dataset options

Set these **before** copying any data in — `recordsize` only applies to newly
written blocks, so changing it later doesn't rewrite existing files.

| Dataset          | recordsize     | atime | Rationale                                                              |
|------------------|----------------|-------|------------------------------------------------------------------------|
| `tank/media`            | `1M`           | `off` | Large sequential video: more throughput, less metadata; no per-read writes |
| `apps/arr-stack` (`CONFIG_PATH`) | default (128K) | `off` | SQLite does small random IO; default is fine                    |

```bash
zfs set recordsize=1M atime=off tank/media
```

- **Ownership**: everything runs as PUID/PGID `568` (TrueNAS `apps` user). The
  media dataset and the config dataset must be owned by / writable by uid 568,
  or imports and DB writes fail with permission errors.
- **compression**: leave the default `lz4` on — near-free, and a no-op on
  already-compressed media.
- **Snapshots**: snapshot the **config** dataset aggressively (cheap DB
  insurance); `tank/media` snapshots are optional — media is re-acquirable and
  the `downloads/` churn makes them heavier.

### Importing an existing library

When copying old media in (e.g. the loose Jellyfin directories from the remote
box), land it directly under `tank/media/{movies,tv}`, then use
**"Import Existing"** in Radarr/Sonarr so they adopt it. For loose (non-dataset)
directories, rsync over Tailscale:

```bash
zfs set recordsize=1M atime=off tank/media   # tune FIRST, then copy
rsync -avP --info=progress2 user@remote:/mnt/<pool>/jellyfin/movies/ /mnt/tank/media/movies/
```

### Verifying hardlinks actually work

After the first import, compare inode numbers — same inode = one copy on disk:

```bash
ls -li /mnt/tank/media/downloads/<file>  /mnt/tank/media/tv/<imported-file>
# Identical number in column 1 = hardlinked.
```

## Setup

### Prerequisites

- **Config dataset `apps/arr-stack` on the SSD pool** (TrueNAS "Apps" preset,
  owned by uid 568) — set `CONFIG_PATH` to it; holds every `/config` + the
  sidecar node state (see "Storage layout")
- **Single media dataset on `tank` (HDD)** (e.g. `/mnt/tank/media`) with
  `recordsize=1M`, `atime=off`, owned by uid 568 — set `MEDIA_PATH` to it
- Proton VPN account with WireGuard config generated (see above)
- PUID/PGID `568` (TrueNAS `apps` user) owns the config and media datasets

### First run

```bash
cp .env.example .env
# Edit .env: set MEDIA_PATH, CONFIG_PATH, LAN_IP_RANGE, and the TS_AUTHKEY_* keys
# Put the Proton WireGuard config where qBittorrent reads it (in CONFIG_PATH):
mkdir -p "$CONFIG_PATH/qbit/wireguard"
cp configs/qbit/wireguard/wg0.conf.example "$CONFIG_PATH/qbit/wireguard/wg0.conf"
# Paste the real Proton WireGuard config into $CONFIG_PATH/qbit/wireguard/wg0.conf
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
2. **Sonarr/Radarr**: configure
   - Root folders pointing into `/media/...`
   - qBittorrent as the download client (host: `qbittorrent`, port `8080`)
   - Quality profiles, custom formats, naming schemes
3. **Bazarr**: link to Sonarr and Radarr via their API keys.
4. **Jellyfin**: add `/media` libraries. Hardware transcoding is currently
   disabled (Nvidia runtime commented out in compose); enable when needed.
5. **Seerr**: link to Jellyfin and to Sonarr/Radarr.
6. **Suggestarr** (after Seerr): before first start,
   `mkdir -p "$CONFIG_PATH/suggestarr" && chown 568:568 "$CONFIG_PATH/suggestarr"`.
   Open `https://suggestarr.<tailnet>.ts.net`, create the admin account, then
   run the wizard:
   - TMDb API key (required — free from themoviedb.org account settings)
   - Jellyfin: URL `http://jellyfin:8096` + an API key from **Jellyfin
     Dashboard → API Keys**; pick the users/libraries whose history counts
   - Seer: URL `http://seerr:5055` + the Seerr API key (**Settings →
     General**), and the dedicated non-auto-approve user — see
     "Make Seerr require approval for Suggestarr's requests" above
   - Set the job schedule (cron) and filters in the UI.

## Backup & recovery

### What's backed up

- **Application-level backups**: Sonarr, Radarr, Prowlarr each run
  weekly internal backups (zipped DB + config.xml) into their own
  `Backups/` folder under `<service>/` in the `CONFIG_PATH` dataset. Configured
  per-app in **Settings → General → Backup**.
- **Filesystem snapshots**: weekly ZFS snapshots of the `CONFIG_PATH` dataset
  capture the entire config + sidecar state at a consistent point.
- **Off-site**: not yet — eventual replication target is the
  remote TrueNAS at parents' house, once local hardware is migrated.

### What's NOT in git

Application state lives in the `CONFIG_PATH` dataset (`/mnt/apps/arr-stack`),
outside git and the repo working tree. It contains:

- `config.xml` files with API keys
- SQLite databases with indexer credentials, download client passwords,
  notification webhooks, and full history
- The real `wg0.conf` with the Proton private key
- Tailscale sidecar node state (device keys) under `ts-state/`

Recovery does **not** depend on git — git carries only the compose file, env
template, README, and the sanitised `wg0.conf.example`. State recovery is via
ZFS snapshot rollback of the `CONFIG_PATH` dataset.

### Recovery procedure

From a clean TrueNAS install:

1. Restore the `CONFIG_PATH` dataset (`apps/arr-stack`) from the most recent
   ZFS snapshot (or from a replicated off-site copy).
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
arr-stack/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
├── ts-config/<svc>/serve.json     # tailscale serve config per sidecar
└── configs/
    └── qbit/
        └── wireguard/
            └── wg0.conf.example   # template only
```

Runtime state (each service's `/config` plus `ts-state/`) lives in the
`CONFIG_PATH` dataset, not the repo — recovered from ZFS snapshot rather than
git.
