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

## Later / production TODO

- Switch `ffmpeg.inputs` to the **go2rtc restream** (`preset-rtsp-restream`) so
  each camera is opened once. This is also the path for **two-way audio** — the
  Reolink doorbell/cameras expose an ONVIF audio backchannel that go2rtc
  negotiates for a talk button in the Frigate/HA live view.
- **Audio in recordings** needs the main stream to be **AAC** (Reolink usually
  is — confirm in VLC). If a camera is PCM/G711, transcode it via go2rtc.
- Add the official **Reolink HA integration** alongside Frigate for the doorbell
  *button-press* event + two-way audio in the HA dashboard (Frigate stays the
  NVR/detection layer).
- Bind `./media` to the **NFS `cctv` pool** on TrueNAS; keep the DB local.
- Record **on motion** (not 24/7) and/or size storage up — 4 cameras incl. the
  16MP floodlight is ~230 GB/day continuous.
- Add the **Coral USB** device to `docker-compose.yml` if OpenVINO gets tight.
- Set `mqtt.enabled: true` and wire into Home Assistant.
