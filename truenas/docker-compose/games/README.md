# Games

A ROM library you can browse and play in the browser, plus an *arr that
fills it. Tailnet-only:

| Service | URL | What it does |
|---|---|---|
| **RomM** | `https://romm.<tailnet>.ts.net` | Scans the library, pulls metadata and artwork (IGDB, ScreenScraper, RetroAchievements, SteamGridDB, Hasheous), and plays games in the browser (EmulatorJS, Ruffle, js-dos). Keeps saves and states per user. |
| **MariaDB** (`romm-db`) | internal | RomM's database. |
| **ROMarr** | `https://romarr.<tailnet>.ts.net` | The *arr for ROMs. You add a game to Wanted. It searches your Prowlarr indexers, sends the best release to qBittorrent, checks the finished files against No-Intro/Redump DATs, files them into RomM's folders, and asks RomM to rescan that platform. |

Prowlarr and qBittorrent are not in this stack. ROMarr uses the ones in
`arr-stack`. igir (for auditing the collection you already have) runs as a
one-off command, not a service.

```
              Prowlarr (arr-stack, :9696)
                 ▲  search / grab (TorrentLeech via Privoxy → VPN)
                 │
  you ──► ROMarr ┼──► qBittorrent (arr-stack, :8080, VPN killswitch)
                 │        │ downloads to /media/downloads/games/
                 │        ▼
                 ├── DAT check (verified / bad dump / unknown)
                 │        │ hardlink (or copy) — never move
                 │        ▼
                 └──► /media/games/library/roms/<platform>/  ──► RomM rescan
```

## Storage layout

Everything sits in the arr-stack media dataset (`MEDIA_PATH`, e.g.
`/mnt/tank/media`), next to qBittorrent's `downloads/`:

```
tank/media                         ← MEDIA_PATH. ROMarr and qBit both see it as /media
├── downloads/
│   └── games/                     qBit category `romarr` save path
└── games/                         ← a DIRECTORY, not a dataset. RomM sees it as /romm
    ├── library/
    │   ├── roms/<platform>/       RomM Structure A. ROMarr files into here
    │   └── bios/<platform>/       firmware (PS1, Saturn, GBA BIOS, …)
    ├── resources/                 RomM covers/screenshots (rebuildable)
    ├── assets/                    RomM saves, states, screenshots (NOT rebuildable)
    ├── config/                    RomM config.yml (optional)
    └── dats/                      No-Intro + Redump DATs (ROMarr and igir)
apps/games                         ← CONFIG_PATH (SSD)
├── mariadb/                       RomM database
├── romm/redis-data/               RomM's internal Valkey snapshot
└── romarr/                        romarr.json: settings, API key, history
```

**Why `games/` must not be a dataset.** The arr-stack README's hardlink rule
applies here too. A hardlink can't cross datasets, and Docker can't link
across two separate bind mounts even on the same dataset. So ROMarr gets the
same single `${MEDIA_PATH}:/media` mount as qBittorrent. Downloads and the
library are then one filesystem on one mount, and qBit's reported paths
(`/media/downloads/games/…`) mean the same thing inside ROMarr. No remote
path mapping is needed.

Platform folders use RomM's slugs (`gba`, `snes`, `psx`, `genesis`, …, see
RomM's *Supported Platforms* page). ROMarr and igir's `{romm}` token both
produce these names.

## Reaching Prowlarr and qBittorrent

Both are in the arr-stack Compose project. `romarr-ts` joins that project's
network (`arr-stack_default`, declared `external`), so ROMarr reaches them by
service name, `http://prowlarr:9696` and `http://qbittorrent:8080`, the same
way Sonarr does. Those URLs are fixed in `docker-compose.yml`.

Why not the host's LAN ports: qBittorrent's killswitch
(`VPN_LAN_LEAK_ENABLED=false`) answers only `VPN_LAN_NETWORK` and its own
Compose network. A request from another Docker bridge to the host's published
`:8080` arrives with a bridge source address and gets dropped. Prowlarr's
tailnet name isn't usable either: the sidecars run in userspace mode, so the
app can't route to other tailnet devices.

Trade-off: deploy arr-stack first; this stack won't start without its network.

## Deploy

1. **Tailscale**: both are admin-only UIs, so they use the existing
   `tag:ts-apps` (no ACL change; `group:admin` already reaches everything).
   Create one single-use, pre-approved, **non-ephemeral** auth key per
   sidecar, tagged `tag:ts-apps`.

2. **Directories** (TrueNAS shell). Create `apps/games` with the *Apps*
   preset, then:
   ```sh
   M=/mnt/tank/media
   mkdir -p $M/downloads/games \
            $M/games/library/roms $M/games/library/bios \
            $M/games/resources $M/games/assets $M/games/config $M/games/dats \
            /mnt/apps/games/romm/redis-data /mnt/apps/games/romarr /mnt/apps/games/mariadb
   chown -R 568:568 $M/downloads/games $M/games /mnt/apps/games/romm /mnt/apps/games/romarr
   zfs list -o name,mountpoint | grep games   # must show apps/games only, NOT tank/media/games
   ```
   Leave `mariadb/` alone. The MariaDB image chowns it on first start.

3. **qBittorrent** (arr-stack WebUI): Options → Downloads → enable
   *Automatic Torrent Management* as the default. Then right-click
   Categories → *Add category*: name `romarr`, save path
   `/media/downloads/games`. ROMarr tags every torrent it adds with this
   category.

4. **Dockhand**: add the stack pointed at this directory and fill the
   variables from `.env.example`. Generate `ROMM_AUTH_SECRET_KEY` with
   `openssl rand -hex 32` and the DB passwords with `openssl rand -hex 24`.
   You can't create the RomM account for ROMarr yet (step 6). Pick its
   password now and put it in `ROMM_ROMARR_PASSWORD`, or leave it empty and
   enter it in ROMarr's UI later. ROMarr reads its connection variables
   **once, on first start**. After that, its Settings pages are what counts.
   Deploy.

5. **RomM first**: open `https://romm.<tailnet>.ts.net`. The setup wizard
   creates your admin account.
   - **Metadata**: set at least one provider before the first scan.
     ScreenScraper (artwork, best for retro) and RetroAchievements (hash
     matching, achievements) are the most useful. IGDB needs a Twitch
     developer app (client ID + secret). SteamGridDB is covers only. Keys are
     Dockhand variables (see `.env.example`); RomM's Metadata sources page
     only shows their status. Hasheous, PlayMatch, LaunchBox and
     HowLongToBeat need no key and are on. Redeploy after adding keys.
   - Put any BIOS files in `games/library/bios/<platform>/`.

6. **A dedicated RomM account for ROMarr.** ROMarr only reads the catalogue
   and starts scans. Starting a scan (`POST /api/tasks/scan`) needs RomM's
   `tasks.run` scope, and in RomM 5.x only the **Admin** role has it. So:
   - Administration → Users → add user `romarr`, role **Admin**, a long
     random password.
   - Preferred: log in as `romarr` and create a **client API token** (its
     profile → API tokens) with only the read scopes plus `tasks.run`. That
     token (`rmm_…`) is all ROMarr gets, so a leak can't edit or delete your
     library. Give it to ROMarr as the library *API Token*
     (`ROMM_API_TOKEN` on a first start, or ROMarr's Libraries page).
   - Or: give ROMarr the `romarr` username and password.

   Without `tasks.run`, imports still work, but RomM only notices them at its
   nightly scan (04:00). ROMarr's docs call this "The rescan was refused".

7. **ROMarr**: open `https://romarr.<tailnet>.ts.net` and set a password
   (unless `ROMARR_PASSWORD` claimed it already). Then check each Settings
   page, because first-start seeding only fills in what `.env` had:
   - **Indexers**: Prowlarr, `http://prowlarr:9696` + Prowlarr's API
     key (Prowlarr → Settings → General). **Test**.
   - **Download Clients**: qBittorrent, `http://qbittorrent:8080`, your
     WebUI login, category `romarr`. **Test**.
   - **Libraries**: RomM, URL `http://romm-ts:8080`, the token or the
     `romarr` login, path `/media/games/library/roms`, layout
     **Structure A**. Run the library test.
   - **Media Management**: these settings protect your ratio:
     - **Prefer hardlinks** → **ON** (it is off by default).
     - **Keep completed downloads for seeding after import** → **ON**
       (default; confirm it).
     - *Use DAT names for verified single-file imports* → on.
     - *Overwrite an existing file* → off.
   - **Profiles**: set preferred regions to **Europe, World, USA, Japan**
     (the default is USA first). Leave betas and ROM hacks off.

8. **First game**: add a small cartridge game to Wanted, let it grab and
   import, then check that it's a hardlink:
   ```sh
   ls -li /mnt/tank/media/downloads/games/<release>/<file> \
          /mnt/tank/media/games/library/roms/<platform>/<file>
   # Same inode number in column 1 = hardlink, no extra space used.
   ```
   The torrent should still be **Seeding** in qBittorrent, and the game
   should appear in RomM within a minute.

## Indexers: TorrentLeech and others

ROMarr doesn't keep its own indexer list. It searches **through Prowlarr's
API**, across every indexer Prowlarr has, using the Newznab categories
**1000 (Console)** and **4050 (PC/Games)**. So you add indexers in Prowlarr,
not in ROMarr. Unlike Sonarr, there's no Prowlarr *App* to sync.

- **TorrentLeech** is already in Prowlarr with the `vpn` proxy tag. Check
  that its category mappings include Console and PC/Games (Prowlarr →
  Indexers → TorrentLeech → Categories). Grabs go through Prowlarr on the
  server, so the passkeyed `.torrent` URL never reaches ROMarr's UI or logs,
  and it still goes out through Privoxy.
- **Others**: add any tracker with game categories to Prowlarr the usual
  way (tag `vpn` if it needs it). ROMarr picks it up on the next search. The
  **Interactive search** page in ROMarr shows which indexer each result came
  from, which helps check that a new one works.
- ROMarr's Settings → Indexers can also take a Torznab/Newznab feed or a
  torrent RSS feed directly. Prowlarr is the better place for private
  trackers, because it handles their auth and the VPN proxy.

ROMarr spaces out its requests (missing-search every 12 h, RSS hourly, and
it backs off when an indexer returns HTTP 429), which is what private
trackers expect.

## How quality works

For ROMs, "quality" means "is this a known-good dump?", not bitrate. The
reference for that is a DAT: a checksum list kept by a preservation group.

- **No-Intro**: cartridge and handheld systems (NES … GBA, DS, 3DS
  decrypted, etc.). Download the daily pack from Dat-o-Matic
  (datomatic.no-intro.org, free account) → *Daily* → *P/C XML*.
- **Redump**: disc systems (PS1, PS2, Saturn, Dreamcast, GameCube, …).
  Download per system from redump.org/downloads.

Unzip or drop the zips into `/mnt/tank/media/games/dats/` (ROMarr reads
loose `.dat`/`.xml` files and No-Intro's zips). Keep only DATs in there.
ROMarr's status page warns if it finds anything else. ROMarr rereads the
directory on restart.

Each import gets one verdict:

| Verdict | Meaning | What ROMarr does |
|---|---|---|
| **Verified** | Every file's checksum matches a DAT entry. | Files it and, with "Use DAT names", renames it to the DAT's canonical name. Search ranks `[!]` / verified releases higher (+50). |
| **Bad dump** | Matches an entry the DAT marks as bad (`[b]`). | Flags it. Search ranks these down, so a good dump is preferred. |
| **Unknown** | No DAT entry matches: missing DAT for the platform, a hack, a translation, a homebrew, a different revision, or a repack. | Files it under its original name. Unknown is not the same as broken. It means nothing here vouches for it. |

**Collections** (in ROMarr) compares a platform folder against its DAT and
shows what's missing. That's a 1G1R wishlist for one system. Region
preference (Profiles) decides which of several releases of the same game
counts.

## Keeping torrents seeding (ratio)

TorrentLeech is private, so a torrent that stops seeding hurts your ratio.
How this setup protects it:

- **Never moved.** ROMarr hardlinks (with *Prefer hardlinks* on) or copies.
  The setting that matters is **Keep completed downloads for seeding after
  import**. In ROMarr 1.10's code, turning it **off** makes ROMarr remove
  the torrent *and its files* from qBit after a successful import. Keep it
  on. With it on, ROMarr removes only torrents that **never finished**
  (stalled past `stalled_timeout_minutes`, 180 by default, without deleting
  files) and paused partial grabs it decided not to use.
- **Copies instead of links in some cases**: archive releases (`.zip`/`.7z`
  ROMs that ROMarr extracts), and ROMs grabbed for a pending *request*. The
  copy uses extra space, and the torrent still seeds from the original.
- **Don't edit library files in place.** A hardlink is one file with two
  names, so patching or re-zipping the library copy also changes the seeding
  copy, and the torrent fails its recheck. Renames and deletes are safe
  (RomM's renames link + unlink, and deleting in RomM removes only the
  library name).
- Seeding time and ratio are set in **qBittorrent** (global or the `romarr`
  category's share limits). Set them to at least TorrentLeech's minimum.
  Don't use *Remove torrent and its files* as the limit action.

## Importing a set torrent

A set torrent (e.g. a No-Intro pack) holds a whole system's catalogue.
`import-romset.sh` (next to this README) verifies it against `games/dats`
with igir and files one release per game into `library/roms/<platform>/`.
Copy it to the NAS once, somewhere only root can write (it runs as root):

```sh
mkdir -p /root/bin && curl -fsSL -o /root/bin/import-romset.sh \
  https://raw.githubusercontent.com/H-Mateus/homelab/main/truenas/docker-compose/games/import-romset.sh
chmod 700 /root/bin/import-romset.sh
```

Then, as root (in `tmux`: big systems take a while):

```sh
/root/bin/import-romset.sh --help
/root/bin/import-romset.sh '/mnt/tank/media/downloads/games/No-Intro 20190501' \
  'Nintendo - Game Boy' 'Sega - Mega Drive - Genesis'
```

- **Name the systems** as they appear in the download folder, without
  extension. A folder of per-game zips is hardlinked (no extra space, keeps
  seeding). A whole-system `.rar`/`.7z` of per-game zips is unpacked to
  `games/staging` first, because igir can't read archives inside archives;
  staging is removed afterwards. The download is mounted read-only.
- **Curate** with `--list FILE`: one regex per line, matched against the
  DAT name (`^Golden Sun`, `/mother 3/i`). Keep lists in `games/lists/`.
- `--dats REGEX` limits igir to the DATs whose name matches (`"Nintendo DS"`,
  `"PlayStation 2"`). Without it every DAT in `games/dats` is checked in
  turn, which is slow with the full No-Intro pack.
- `--dry-run` writes only a report to `games/igir-reports/`; `--all` keeps
  every region, revision, beta and demo.
- Needs a DAT for each system: the No-Intro Daily pack (P/C XML) unzipped
  flat into `games/dats`, plus Redump DATs for disc systems.
- Then RomM → Scan → Quick scan, or wait for the 04:00 rescan.

### Only some games from a huge set (PS1, PS2, ...)

A Redump PS2 set is well over 400 GB. Download just a list of games from
it with `qbit-select.py`, which sets the torrent's file priorities through
qBittorrent's Web API. It needs only Python 3, so run it from this repo on
your Mac:

1. In qBittorrent, add the set's `.torrent` file (not a magnet: the file
   list must be known) with category `romarr`, **unticking "Start
   torrent"**.
2. Preview, then apply. `ps2` is any part of the torrent's name:

   ```sh
   export QBIT_URL=http://truenas-local.<tailnet>.ts.net:8080 QBIT_USER=admin
   ./qbit-select.py ps2 lists/ps2.txt --dry-run
   ./qbit-select.py ps2 lists/ps2.txt
   ```

   For each title it picks one release (all discs, newest revision, no
   demos or betas) in the `--prefer` region order, which defaults to
   `USA,World,Europe,UK,Japan`: many PAL PS1/PS2 releases run at 50 Hz.
   Everything else is set to "do not download" and the torrent starts.
   The dry run lists any line that matched nothing; fix its spelling to
   the set's naming.
3. Lists are cumulative: add a line and re-run to fetch more.
4. When it finishes, import the folder:
   `import-romset.sh --dats "PlayStation 2" /mnt/tank/media/downloads/games/<set folder>`.
   A set split across torrents (PS2 "A-L" and "M-Z") is just two
   torrents: run steps 1-4 on each with the same list. Each dry run
   reports the other half's titles as unmatched, which is expected.

`lists/` has a starting list per platform (acclaimed games, US titles).
Edit them freely. Ratio: TorrentLeech counts only what you download, so
unticked files cost nothing; seed what you took for the tracker's minimum.

## Auditing your existing collection with igir

[igir](https://github.com/emmercm/igir) checks ROMs against the same
No-Intro/Redump DATs, renames them to canonical names, and can sort them
straight into RomM's `roms/<platform>/` layout (`{romm}` token). RomM's docs
describe the same workflow ("igir" under Ecosystem). Run it as a throwaway
container on TrueNAS, which has no Node install. Nothing permanent is
added.

Set up a helper in the TrueNAS shell (`OLD` = wherever the existing
collection lives):

```sh
OLD=/mnt/tank/old-roms            # existing collection — mounted READ-ONLY below
G=/mnt/tank/media/games
mkdir -p $G/igir-reports $G/staging && chown 568:568 $G/igir-reports $G/staging
igir() {
  docker run --rm -it --user 568:568 -e HOME=/tmp \
    -v "$OLD":/old:ro -v "$G":/games \
    node:24-alpine npx -y igir@latest "$@"
}
```

**Step 0: safety net.** If `OLD` is on a dataset, snapshot it first:
`zfs snapshot <pool/dataset>@pre-igir`. The `:ro` mount already stops any
command from changing it.

**Step 1: report only (read-only).** With `report` alone igir writes
nothing except the CSV:

```sh
igir report --dat '/games/dats/*' --input /old \
  --input-checksum-max SHA1 \
  --report-output '/games/igir-reports/audit-%X.csv'
```

Open the CSV and filter the `Status` column:
- `FOUND`: a file matches a DAT entry (verified; `[b]` names are bad dumps).
- `UNUSED`: matched nothing (unknown: hacks, translations, homebrew,
  headered or trimmed files, or a platform with no DAT loaded).
- `DUPLICATE`: a second copy of something already found.
- `MISSING`: in the DAT but not in your collection. This is long for full
  sets and is normal.

**Step 2: trial build into staging.** This copies from the read-only
original, so the original is never touched:

```sh
igir copy extract test playlist report \
  --dat '/games/dats/*' --input /old \
  --output '/games/staging/roms/{romm}' \
  --input-checksum-max SHA1 \
  --report-output '/games/igir-reports/staging-%X.csv'
```

`test` re-verifies every written file. `playlist` writes `.m3u` files for
multi-disc games.

**Optional 1G1R** (one game, one ROM: one release per title, picked by
region). Add to step 2:

```sh
  --single --prefer-language EN --prefer-region UK,EUR,WORLD,USA,JPN \
  --prefer-verified --prefer-good --prefer-retail --prefer-revision newer
```

and `--only-retail` to also drop betas, demos, prototypes and unlicensed
titles. Note that EU releases of older consoles (NES, SNES, Mega Drive,
PS1) are often 50 Hz PAL and run about 17% slower than US versions. For
those, try `--prefer-region USA,WORLD,UK,EUR,JPN` in a separate run per
platform. Change `--dat` to one system's DAT to limit a run.

**Step 3: review**, then promote. Browse `staging/roms/`. Each disc of a
multi-disc Redump game lands in its own folder. Move them into one game
folder next to the `.m3u` so RomM shows one game (see RomM's igir page).
Then move it into the library. A move within the same dataset is instant:

```sh
cd /mnt/tank/media/games
for d in staging/roms/*/; do p=$(basename "$d"); mkdir -p library/roms/$p; \
  mv -n "$d"* library/roms/$p/; done      # -n: never overwrite something ROMarr filed
```

Then RomM → Scan (or wait for 04:00). Files still listed as `UNUSED` in the
report weren't copied. Keep the ones you want (hacks, translations) by
copying them into `library/roms/<platform>/` by hand. RomM's subfolder tags
(`hack`, `translation`) suit them.

Once the new library looks right in RomM, you can delete or archive `OLD`.
Keep the snapshot until you're sure.

## Day to day

- **Want a game**: ROMarr → search → add to Wanted (or grab from interactive
  search). It shows up in RomM after import.
- **Backups**: `apps/games` (DB, ROMarr state) is covered by the apps
  snapshot task. `games/assets/` holds **saves and states**, which can't be
  re-downloaded. `tank/media` snapshots are optional in arr-stack, so either
  snapshot `tank/media` or back up `games/assets/` separately.
- **Upgrades**: Renovate opens a PR bumping the image tags in `docker-compose.yml`; read the release
  notes first (RomM:
  [releases](https://github.com/rommapp/romm/releases), ROMarr:
  [releases](https://github.com/BlizzHacker/romarr/releases)). RomM runs DB
  migrations on start. Back up `/mnt/apps/games/romarr/romarr.json` before
  rolling ROMarr back, because older builds drop unknown keys.
- **Health**: ROMarr's image has a healthcheck (`/api/health`). Docker marks
  it unhealthy but doesn't restart it.
