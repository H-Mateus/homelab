# Homepage

Start page for the homelab ([gethomepage.dev](https://gethomepage.dev)): a
tile per app with live widgets. Tailnet-only at `https://homepage.<tailnet>.ts.net`.
Complements Uptime Kuma rather than replacing it: Kuma alerts, Homepage is
for getting to things.

## To finish (draft, not deployed)

- [x] Tailscale policy: `tag:homepage` in `tagOwners`, plus a grant to the
      widget targets only (links are opened by the browser, so they need no
      grant): `{"src":["tag:homepage"],"dst":["tag:ts-apps",
      "tag:family-jellyfin","tag:immich","tag:paperless",
      "tag:truenas-primary","tag:uptime-kuma"],"ip":["tcp:443"]}`.
- [ ] Single-use, pre-approved auth key tagged `tag:homepage`.
- [ ] Add the stack in Dockhand pointed at this directory; fill `.env` from
      `.env.example` (keys from Bitwarden).
- [ ] Check `config/` is writable by uid 568 in Dockhand's checkout
      (Homepage writes `config/logs/`).
- [x] Fill out `config/services.yaml`.
- [ ] Create the new widget keys (Immich `server.statistics`, Paperless
      token, read-only TrueNAS key); the arr/Jellyfin/Seerr keys are
      already in Bitwarden.
- [ ] Create and publish a Kuma status page with slug `homelab` (the
      widget is already enabled for it).
- [ ] Optional widgets left as links: Navidrome, Frigate, Proxmox,
      pfSense, Home Assistant (each needs extra creds or TLS handling).
- [ ] Pin `HOMEPAGE_VERSION` to a release.
