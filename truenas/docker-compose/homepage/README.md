# Homepage

Start page for the homelab ([gethomepage.dev](https://gethomepage.dev)): a
tile per app with live widgets. Tailnet-only at `https://homepage.<tailnet>.ts.net`.
Complements Uptime Kuma rather than replacing it: Kuma alerts, Homepage is
for getting to things.

## Status (deployed 2026-11-02)

- [x] Tailscale policy: `tag:homepage` in `tagOwners`, plus a grant to the
      widget targets only (links are opened by the browser, so they need no
      grant): `{"src":["tag:homepage"],"dst":["tag:ts-apps",
      "tag:family-jellyfin","tag:immich","tag:paperless",
      "tag:truenas-primary","tag:uptime-kuma","tag:homeassistant",
      "tag:k8s"],"ip":["tcp:443"]}` (last two for the HA and Grafana
      status dots).
- [x] Single-use, pre-approved auth key tagged `tag:homepage`.
- [x] Add the stack in Dockhand pointed at this directory; fill `.env` from
      `.env.example`. Paste the secret *values*, not the Bitwarden secret
      IDs (36-char UUIDs), or every widget fails auth.
- [x] Check `config/` is writable by uid 568 in Dockhand's checkout
      (Homepage writes `config/logs/`).
- [x] Fill out `config/services.yaml`.
- [x] Widget keys: Immich (admin account, `server.statistics` only),
      Paperless (dedicated view-only `homepage` user; it must be **active**,
      or the token gets "User inactive or deleted"), read-only TrueNAS key.
- [x] Kuma status pages: `homelab` (primary), `offsite-box` (off-site).
- [ ] Optional widgets left as links: Navidrome, Frigate, Proxmox,
      pfSense, Home Assistant (each needs extra creds or TLS handling).
- [ ] Pin `HOMEPAGE_VERSION` to a release.
