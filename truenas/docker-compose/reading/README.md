# Reading

Books and manga, fetched automatically and read in one place. Tailnet-only;
no LAN ports.

| Service   | Tailnet URL                          | What it does |
|-----------|--------------------------------------|--------------|
| Bookshelf | `https://bookshelf.<tailnet>.ts.net` | Readarr revival. Follows authors, searches indexers through Prowlarr, sends grabs to qBittorrent, and files finished ebooks under `books/`. Admin only. |
| Suwayomi  | `https://suwayomi.<tailnet>.ts.net`  | Tachiyomi/Mihon-compatible server. Follows manga series and downloads new chapters as CBZ into `manga/`. Admin only. |
| Kavita    | `https://kavita.<tailnet>.ts.net`    | Reader for ebooks, manga and comics in the browser or OPDS apps, with per-user progress. This is the one family members use. |

Prowlarr and qBittorrent live in the `arr-stack` project and are reused here.

```
Prowlarr ──indexers──▶ Bookshelf ──grab──▶ qBittorrent (VPN)
                           │                    │ downloads/books/
                           └──hardlink──▶ books/ ◀┘
Suwayomi ──CBZ──▶ manga/mangas/<source>/<series>/
                    books/  manga/  comics/ ──read-only──▶ Kavita
```

## Storage

Everything goes in the arr-stack's media dataset (`MEDIA_PATH`, e.g.
`/mnt/tank/media`):

```
tank/media                  MEDIA_PATH
├── downloads/books/        qBittorrent category `books` (save path /media/downloads/books)
├── books/                  Bookshelf root folder (/media/books); Kavita /books
├── manga/                  Suwayomi downloads; Kavita /manga
│   └── mangas/<source>/<series>/<chapter>.cbz
└── comics/                 drop comics in by hand; Kavita /comics
```

**`books/` must be a plain directory, not a child dataset.** Hardlinks
can't cross datasets (see the arr-stack README, "The hardlink rule"). With
a child dataset every import becomes a full copy. That still works, but
it doubles the disk used. `music/` is a child dataset on purpose; don't
copy that here. `manga/` and `comics/` could be child datasets because
nothing hardlinks into them, but there's no reason to make them one.

Bookshelf mounts the whole of `MEDIA_PATH` at `/media`, the same as
qBittorrent. So a path qBittorrent reports (`/media/downloads/books/...`)
exists unchanged inside Bookshelf, and no Remote Path Mapping is needed.

App state (Bookshelf DB, Kavita DB and covers, Suwayomi DB and extensions,
Tailscale node keys) lives in `CONFIG_PATH` (`apps/reading`), covered by the
recursive `apps` snapshot task.

## Setup order

1. **Tailscale**: Bookshelf and Suwayomi are admin-only, so their keys use
   the existing `tag:ts-apps`. Kavita is family-facing and gets its own
   `tag:family-reading` (see "Family access" for the ACL lines). Make three
   single-use, pre-approved, non-ephemeral auth keys accordingly.
   Deploy arr-stack first: this stack joins its network.
2. **Datasets and directories** (TrueNAS shell):
   ```sh
   # apps/reading: create in the UI with the Apps preset, then
   mkdir -p /mnt/apps/reading/{bookshelf,kavita,suwayomi}
   chown -R 568:568 /mnt/apps/reading
   # Library directories (plain mkdir: NOT datasets)
   mkdir -p /mnt/tank/media/{books,manga,comics,downloads/books}
   chown 568:568 /mnt/tank/media/{books,manga,comics,downloads/books}
   ```
   Create the directories before the first deploy. Otherwise Docker creates
   missing bind-mount sources owned by root, and Suwayomi (uid 568) can't
   write to `manga/`.
3. **Dockhand**: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy.
4. **Bookshelf**: follow "Wiring Bookshelf" below.
5. **Suwayomi**: add an extension repo, then manga (below).
6. **Kavita**: create the admin account and libraries (below), then invite
   family.

## Wiring Bookshelf to Prowlarr and qBittorrent

`bookshelf-ts` joins arr-stack's network (`arr-stack_default`), so the three
apps reach each other by name: Bookshelf → `prowlarr:9696` and
`qbittorrent:8080`, Prowlarr → `bookshelf-ts:8787` (Bookshelf listens inside
its sidecar's namespace, so the sidecar's name is its address). That's also
how qBittorrent's VPN killswitch lets it through: it answers its own Compose
network, which a request to the host's published port wouldn't come from.

### Bookshelf (first login at `https://bookshelf.<tailnet>.ts.net`)

1. Create the login when prompted (Forms auth).
2. **Settings → Media Management** (*Show Advanced*):
   - Root folder: `/media/books`.
   - **Use Hardlinks instead of Copy: on**. Completed torrents are then
     hardlinked into `books/` and keep seeding from `downloads/books/`.
     Bookshelf never moves a torrent that is still seeding, but this keeps
     the "copy" from costing disk.
3. **Settings → Download Clients → + → qBittorrent**:
   - Host `qbittorrent`, port `8080`, plus the qBittorrent WebUI login (or
     API key on qBittorrent 5.2+).
   - Category `books`. In qBittorrent, set the `books` category's save
     path to `/media/downloads/books`, next to the other categories.
   - **Remove Completed: off.** TorrentLeech is a ratio tracker. Let
     qBittorrent's own share limits decide when a torrent stops, not
     Bookshelf.
4. **Settings → General**: note the **API key** for Prowlarr. It goes in
   the password manager with the others (`BOOKSHELF_API_KEY`).

### Prowlarr (in arr-stack)

**Settings → Apps → + → Readarr.** Bookshelf keeps Readarr's API, so the
Readarr app type works:

| Field             | Value                              |
|-------------------|------------------------------------|
| Prowlarr Server   | `http://prowlarr:9696` (how Bookshelf reaches Prowlarr) |
| Readarr Server    | `http://bookshelf-ts:8787` (how Prowlarr reaches Bookshelf) |
| API Key           | Bookshelf's API key                |
| Sync Level        | Full Sync                          |

Save, then **Sync App Indexers**. TorrentLeech should appear under
Bookshelf's **Settings → Indexers**, with its seed ratio and time copied
from Prowlarr. Its `vpn` tag and Privoxy proxy stay on Prowlarr's side:
Bookshelf queries Prowlarr's proxied Torznab endpoint, so TorrentLeech
traffic still leaves through the VPN.

## Suwayomi

1. Log in with `SUWAYOMI_USERNAME` / `SUWAYOMI_PASSWORD`.
2. **Extension repo.** Suwayomi ships with no sources at all. Under
   **Settings → Browse → Extension repositories**, add the index URL of a
   Tachiyomi/Mihon-compatible extension repo you've chosen yourself. It
   usually ends in `index.min.json`. This repo deliberately doesn't name one.
   Then install the extensions you want under **Browse → Extensions**.
3. **Downloads** (Settings → Downloads): CBZ is already forced on by the
   compose file (`DOWNLOAD_AS_CBZ`). Leave the download location at its
   default: the container's default downloads folder *is*
   `MEDIA_PATH/manga`. Turn on **auto-download new chapters** here. It's a
   per-user setting in current releases, so it isn't set from compose.
4. **Library updates** (Settings → Library): the global update runs every
   12 h by default. That checks your library for new chapters, and new ones
   are auto-downloaded. Add series to the library from **Browse**.
5. Optional: some sources sit behind Cloudflare. Point **Settings →
   FlareSolverr** at the arr-stack's instance, `http://flaresolverr:8191`.

Settings that compose sets (`BIND_IP`, `DOWNLOAD_AS_CBZ`, `AUTH_*`) are
re-applied on every start, so changing them in the UI doesn't stick. Change
them in compose or `.env` instead.

Files land as `manga/mangas/<Source (lang)>/<Series>/<chapter>.cbz`. Kavita
treats each `<Series>` folder as one series. If you follow the same series
from two sources, Kavita shows it twice.

## Kavita

1. Open `https://kavita.<tailnet>.ts.net` and create the admin account.
2. **Server Settings → Libraries → Add Library**, one per kind, so each uses
   the right parser and family can be given access to just some:

   | Library | Type  | Folder         |
   |---------|-------|----------------|
   | Books   | Book  | `/books`       |
   | Manga   | Manga | `/manga/mangas`|
   | Comics  | Comic | `/comics`      |

   Point Manga at `/manga/mangas`, not `/manga`. Suwayomi also keeps a
   `thumbnails/` folder at the top level, and Kavita shouldn't scan it.
   Kavita's folder watching picks up new chapters and books. The nightly
   scan is a backstop.
3. The library mounts are read-only. Kavita never changes your files;
   covers, progress and its database stay in `CONFIG_PATH/kavita`.

## Family access

Only Kavita is meant for family. Bookshelf and Suwayomi stay admin-only:
neither has a "request" role, so book and manga requests come to you.

1. **Tailscale**: Kavita's sidecar is tagged `tag:family-reading`. In the
   policy file, add it to `tagOwners` and to the household grant, the same
   way as Immich and Jellyfin:
   ```jsonc
   "tag:family-reading": ["group:admin"],
   // in the group:household grant's dst list:
   "dst": ["tag:immich", "tag:family-jellyfin", "tag:immichframe", "tag:family-reading"],
   ```
   For someone outside the tailnet, share just the `kavita` device from the
   admin console (*Share…*) and add a grant
   `{"src": ["autogroup:shared"], "dst": ["tag:family-reading"], "ip": ["tcp:443"]}`,
   as with Immich.
2. **Kavita account**: **Server Settings → Users → Invite**, untick the
   admin role and pick which libraries they can see. Without email set up,
   Kavita shows an invite link to send them yourself.
3. **Reading**: in the browser at `https://kavita.<tailnet>.ts.net` (it
   installs as an app on phones), or in any OPDS reader (KOReader, Panels,
   Moon+ Reader, …). The OPDS URL is under each user's **Settings → 3rd
   Party Clients**. Tailscale must be connected on the device.

## Day to day

- **Upgrades**: Renovate opens PRs bumping the tags in `docker-compose.yml`. Bookshelf has no release
  notes; tags are `hardcover-v<readarr version>.<build>`, and the commit
  log on GitHub is the changelog. Keep the `hardcover-` prefix.
- **Backups**: snapshots of `apps/reading` cover all app state. Bookshelf
  also makes weekly internal backups (System → Backup). Suwayomi makes daily
  ones into `CONFIG_PATH/suwayomi/backups`. The library itself is in
  `tank/media`.
- **Check hardlinks**: after the first book import, run
  `ls -li /mnt/tank/media/downloads/books/<file> /mnt/tank/media/books/<Author>/<Book>/<file>`.
  The same inode number means hardlinked.

## Files

```
reading/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
└── ts-config/{bookshelf,kavita,suwayomi}/serve.json
```
