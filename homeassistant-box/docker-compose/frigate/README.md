# Frigate (Home Assistant box)

Self-hosted NVR + object detection for the Reolink PoE doorbell and cameras.
Runs as a Docker Compose stack **inside a Proxmox LXC** on the Home Assistant
box (Lenovo ThinkCentre M900, i5-6500T). Home Assistant itself runs as a
separate HAOS VM on the same host.

Design rationale and the wider camera project: [`/docs/frigate-camera-project.md`](../../../docs/frigate-camera-project.md).

> **Testing phase.** This is set up by hand for now to bench-test the cameras
> and PoE switch before install day. Once proven, the LXC/VM will be codified in
> `opentofu/`. The camera block is `test_camera` with `CAM_IP` — rename and add
> blocks per install location as cameras go up.

## Host prerequisites (Proxmox LXC)

Create a Debian LXC and, so Docker + the iGPU work inside it:

- **Privileged** container with **nesting=1** (Options → Features → nesting).
- **iGPU passthrough** — add to `/etc/pve/lxc/<id>.conf`:
  ```
  lxc.cgroup2.devices.allow: c 226:* rwm
  lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
  ```
- Install Docker + the Compose plugin inside the LXC.

## First run

```bash
cp .env.example .env      # fill in camera user/password (see note below)
# edit config/config.yml: set CAM_IP, and h264 vs h265 for the main stream
docker compose up -d
docker compose logs -f    # watch for ffmpeg / detector errors
```

Open **`https://<LXC_IP>:8971`** — you should see the live feed with detection
boxes.

## Camera credentials & the special-character gotcha

Credentials are injected from `.env` via `{FRIGATE_RTSP_USER}` /
`{FRIGATE_RTSP_PASSWORD}` substitution in `config/config.yml`.

RTSP URLs break on the delimiter characters `@ : / # ? & +` and spaces. If your
password contains any of them, **URL-encode it in `.env`** (hidden prompt):

```bash
python3 -c "import urllib.parse,getpass; print(urllib.parse.quote(getpass.getpass(), safe=''))"
```

`@`→`%40` `:`→`%3A` `/`→`%2F` `+`→`%2B` `#`→`%23` `?`→`%3F` `&`→`%26` `%`→`%25` space→`%20`.

Alternatively set an **alphanumeric** password on the camera — safe, since the
cameras sit on an isolated CCTV VLAN.

## Reolink stream notes

- **Main stream** → recording (stream-copied, not re-encoded).
  **Substream** → detection (low-res, cheap). This keeps CPU/GPU load low even
  for high-res cameras.
- **Codec:** the Reolink *app* hides it; the *browser* UI at `https://CAM_IP`
  (Settings → Display/Encode) shows and sets it, and often lists the exact RTSP
  URLs. If unsure, try `h264Preview_01_main`; if the sub connects but main
  doesn't, switch to `h265Preview_01_main`.
- **Enable ONVIF** on each camera (off by default; appears once RTSP is on).
  Needed for the Reolink HA integration's instant push events and for go2rtc
  two-way audio. Set an ONVIF password. Safe on the isolated CCTV VLAN.
- **SD card fallback:** fit a **high-endurance** microSDXC (U3/V30, 128–256 GB;
  Samsung PRO Endurance / SanDisk High Endurance / WD Purple SC) so each camera
  keeps recording locally if Frigate or the network is down. Check each model's
  max capacity (most Reolink cap at 256 GB).
- **`detect.width`/`height` must match the substream's real resolution** (check
  the camera UI, or `ffprobe rtsp://.../..._sub`), or detection is misaligned.

## Verify a camera the fast way (no Frigate)

Proves the camera + cabling + PoE + switch port independently — the same check
to run on install day:

```bash
ffprobe "rtsp://USER:ENCODED_PW@CAM_IP:554/h264Preview_01_main"   # or open in VLC
```

## Stream facts (confirmed in VLC)

- Reolink main stream: high-res H.265, ~25fps → recording (stream-copied).
- Reolink substream: 640x360 **H.264**, ~10fps → detection. `detect.fps: 5`
  samples this cleanly (1-in-2); 5fps is plenty for detection.

## Storage (TrueNAS `cctv` pool over NFS)

Recordings go to the single-disk `cctv` pool on the primary TrueNAS; the
Frigate SQLite DB stays on the LXC's local disk. Order matters: mount the
share **before** applying the 7-day retention in `config/config.yml`, or the
24 GB LXC rootfs fills up.

**TrueNAS (UI):**

1. Datasets → `cctv` → Add Dataset `frigate` (Record Size **1M**; compression
   can stay lz4, video is incompressible so it is a no-op).
2. Shares → NFS → Add: path `/mnt/cctv/frigate`, Authorized Hosts = the
   Frigate LXC IP only, Maproot User/Group `root`/`root` (Frigate runs as
   root in the container). Enable the NFS service, start on boot.
3. The pool is ZFS-native encrypted with a TrueNAS-managed key, so it unlocks
   itself at boot. Export the key once (Datasets → `cctv` → Export Key) so the
   footage survives a lost TrueNAS config.

**Frigate LXC (mounts the share directly — it is a privileged LXC, so NFS
mounts work inside it; no Proxmox-side bind mount needed):**

```bash
apt install -y nfs-common
mkdir -p /mnt/cctv
chattr +i /mnt/cctv        # empty mountpoint is immutable → nothing can write
                           # to the LXC rootfs if the NFS mount is ever missing
cat >> /etc/fstab <<'FSTAB'
192.168.1.2:/mnt/cctv/frigate /mnt/cctv nfs4 noatime,_netdev,nofail,retry=10,x-systemd.mount-timeout=12min 0 0
FSTAB
# retry/mount-timeout: after a power cut this LXC boots ~90s before TrueNAS
# has even started, and systemd's default 90s mount timeout killed the mount
# (and with it Docker, via the drop-in below). Keep retrying for 10 min, with
# systemd's timeout just above that so it doesn't kill mount.nfs first.
systemctl daemon-reload && mount /mnt/cctv && df -h /mnt/cctv
touch /mnt/cctv/write-test && rm /mnt/cctv/write-test   # proves maproot=root

# Make Docker wait for the share at boot. Deliberately NOT x-systemd.automount:
# Docker bind-mounts the autofs placeholder and the trigger does not propagate
# into the container, so Frigate would see an empty directory.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/mnt/cctv\n' > /etc/systemd/system/docker.service.d/nfs.conf
systemctl daemon-reload
```

The NFS share's Authorized Hosts is therefore the **LXC's** IP (192.168.1.39),
with Maproot User/Group `root`/`root`. `docker-compose.yml` binds `/mnt/cctv`
to `/media/frigate`. Verify with `docker compose exec frigate df -h
/media/frigate` after `docker compose up -d`.

## Two-way talk (doorbell)

Three parts, all required:

1. **Camera:** Reolink app → Server Settings → **HTTP on** (RTSP + ONVIF already
   on). The http-flv stream go2rtc uses rides on HTTP. If go2rtc logs a
   connection error for the flv source, enable **RTMP** as well.
2. **Config:** the `go2rtc:` block + restream inputs in `config/config.yml`
   (already there). After `docker compose restart frigate`, Frigate UI →
   System → go2rtc should list `doorbell` with a 🎤 (backchannel) and
   `doorbell_sub`.
3. **HTTPS:** browsers only allow microphone access on secure pages, and 8971
   is plain HTTP so the HA integration can talk to it. The `frigate-ts`
   Tailscale sidecar in `docker-compose.yml` fronts it with a valid cert (same
   pattern as the immich stacks; see the comments there for the two
   deliberate differences). One-time bring-up:

   ```bash
   # Tailscale admin → Settings → Keys → generate an auth key (reusable, tagged
   # like the other sidecars), put it in .env as TS_AUTHKEY, then:
   docker compose up -d                     # starts frigate-ts alongside frigate
   docker compose logs -f frigate-ts        # wait for "Serve started" / cert issued
   docker compose exec frigate-ts tailscale ip -4   # Tailscale IP of the node
   ```

   Put that IP (`100.x.y.z:8555`) into `go2rtc.webrtc.candidates` in
   `config/config.yml`, commit, pull, `docker compose restart frigate`.

   Then open `https://frigate.<tailnet>.ts.net` → Live → doorbell. The
   microphone button only appears on HTTPS **and** only when the player is
   WebRTC (not MSE) — Frigate picks WebRTC automatically when a candidate is
   reachable. On the LAN the media flows to 192.168.1.39:8555; over Tailscale
   to the Tailscale IP.

For talk from a Home Assistant dashboard, install **Advanced Camera Card**
(HACS; formerly frigate-hass-card) and use its `go2rtc` live provider with the
microphone enabled — it goes through the Frigate integration's proxy.

## Updating

Like every stack here, the images are pinned to exact releases in
`docker-compose.yml`, and [Renovate](../../../renovate.json) proposes bumps
as PRs once a release is 5 days old. On TrueNAS, Dockhand redeploys a stack
when its PR merges. This LXC isn't managed by Dockhand, so a systemd timer
does the same job: `deploy-frigate.sh` runs hourly, fast-forwards this
checkout to `origin/main`, and redeploys if the stack changed or the running
image doesn't match the pin. **Merging the PR is the deploy.**

For a new Frigate image it:

1. tars `config/` (with `frigate.db`, without `model_cache/`) into
   `backups/`, keeping 5;
2. pulls and recreates the stack;
3. waits for `/api/version` to report the pinned tag. If it doesn't, it
   restores the backup, puts the previously running image back (via a
   throwaway `.rollback.yml` override) and records the commit in
   `.deploy-failed` so it isn't retried. The next commit on `main`, a fix or
   a revert, deploys normally.

A change under `config/` alone (a `config.yml` edit merged to `main`) just
restarts Frigate. Results go to the journal (`journalctl -u frigate-deploy`,
also in Loki via Alloy), plus `FRIGATE_NOTIFY_URL` if it's set: an ntfy
topic, or a Home Assistant automation with a webhook trigger that sends a
phone notification.

**Patch vs minor.** Frigate's versions are `0.<minor>.<patch>`. Patches
(0.18.2 → 0.18.3) are bug fixes, so merge freely. Minor releases
(0.18 → 0.19) rename config keys and migrate the database one way, so
Renovate opens them as a separate PR with a reminder. Before merging one,
read the release notes from your version up to the target at
[github.com/blakeblackshear/frigate/releases](https://github.com/blakeblackshear/frigate/releases),
and put any `config/config.yml` changes in the same PR. Rolling back across a
minor needs `config/` from the backup as well, because the newer
`frigate.db` won't open in the older release; the script does that for you
when the health check fails. If the failed PR also changed `config.yml`, the
restore leaves the checkout's copy modified: once the fix is on `main`, run
`git checkout config/config.yml` so the deploy can fast-forward.

**Local edits.** The checkout must stay clean enough to fast-forward. If you
save `config.yml` from the Frigate UI, commit that change to `main`, or the
next PR that touches the file stops the deploy with a notification. A
blocked or failed commit isn't retried, so after sorting it out locally run
`rm -f .deploy-failed && systemctl start frigate-deploy`.

### Install (once, in the LXC)

The stack has to live in a git checkout of this repo. A sparse clone keeps
it to this directory:

```bash
apt install -y git curl
git clone --filter=blob:none --sparse https://github.com/H-Mateus/homelab /opt/homelab
git -C /opt/homelab sparse-checkout set homeassistant-box/docker-compose/frigate
cd /opt/homelab/homeassistant-box/docker-compose/frigate
```

If the stack currently runs from a plain copy elsewhere, stop it there
(`docker compose down`), move its gitignored state (`.env`, `ts-state/`,
and `config/` apart from `config.yml`) into the checkout. Then:

```bash
./deploy-frigate.sh --dry-run    # e.g. "would deploy main@1a2b3c4: frigate ...:0.18.0 -> ...:0.18.2"
for u in frigate-deploy.service frigate-deploy.timer; do
  sed "s|STACK_DIR|$PWD|" systemd/$u > /etc/systemd/system/$u
done
systemctl daemon-reload && systemctl enable --now frigate-deploy.timer
systemctl start frigate-deploy   # deploy now rather than at the next hour
```

To see what's actually running: the Frigate UI's System page, or
`docker exec frigate curl -s http://127.0.0.1:5000/api/version`.

### By hand

To roll back on purpose, revert the Renovate PR on GitHub; the timer deploys
the revert (restore `config/` from `backups/` yourself if it crosses a
minor). In an emergency you can edit the image tag here and
`docker compose up -d`, but put the same change on `main` afterwards, or the
next fast-forward will fail.

## Later / production TODO

- Switch driveway / side_alley to the **go2rtc restream** too (doorbell done)
  once they are mounted.
- **Audio in recordings** needs the main stream to be **AAC** (Reolink usually
  is — confirm in VLC). If a camera is PCM/G711, transcode it via go2rtc.
- Add the official **Reolink HA integration** alongside Frigate for the doorbell
  *button-press* event + two-way audio in the HA dashboard (Frigate stays the
  NVR/detection layer).
- Add the **Coral USB** device to `docker-compose.yml` if OpenVINO gets tight.
- Set `mqtt.enabled: true` and wire into Home Assistant.
