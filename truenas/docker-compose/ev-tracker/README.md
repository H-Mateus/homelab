# EV tracker

Checks AutoTrader once a day for used EVs near Cardiff, scores each one
(value vs market, range, 360 camera, insurance group, …), sends Telegram
alerts for standout deals plus a twice-weekly digest, and serves a ranking
page at `https://ev.<tailnet>.ts.net`. Source and image (private):
[H-Mateus/ev-price-tracker](https://github.com/H-Mateus/ev-price-tracker).

The page is a static file regenerated after every run: sortable ranking,
per-car pros/cons, price history and "similar cars" price comparison, plus
`latest.md` (a briefing to hand to a person or an AI) and `latest.json`.

## Deploy

1. **Image**: pushed to GHCR by the (private) repo's `image` workflow on
   every push to `main`, so the package is private too. Create a **classic**
   PAT with only the `read:packages` scope (GHCR doesn't take fine-grained
   tokens), then either add `ghcr.io` with it as a registry in Dockhand, or
   log the TrueNAS Docker in once:
   ```sh
   echo <PAT> | docker login ghcr.io -u H-Mateus --password-stdin
   ```
2. **Tailscale ACL** (admin console): add the tag and let it reach Kuma for
   the heartbeat.
   ```jsonc
   "tagOwners": { "tag:ev-tracker": ["autogroup:admin"] },
   "grants": [
     { "src": ["tag:ev-tracker"], "dst": ["tag:uptime-kuma"], "ip": ["tcp:443"] }
   ]
   ```
   Then a single-use, pre-approved, non-ephemeral auth key tagged
   `tag:ev-tracker`.
3. **Dataset**: create `apps/ev-tracker` (Generic preset, defaults), then:
   ```sh
   chown 568:568 /mnt/apps/ev-tracker
   ```
   It holds the SQLite file and the generated `site/`. Optional: copy an
   existing `evtracker.db` from the laptop into it to keep the history.
4. **Telegram**: message @BotFather → `/newbot` → token. Send the new bot any
   message, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and
   copy `message.chat.id`.
5. **Uptime Kuma**: add a monitor of type *Push*, heartbeat interval
   `90000` s (25 h), and put its URL in `EVTRACKER_PUSH_URL`
   (`https://uptime.<tailnet>.ts.net/api/push/<token>`). Goes down if a run
   fails, AutoTrader blocks it, or the search returns nothing.
6. **Dockhand**: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy.
7. **Check**:
   ```sh
   docker exec ev-tracker evtracker test-notify       # Telegram arrives
   docker exec ev-tracker evtracker run --digest      # first run now
   docker logs ev-tracker                             # "serving …", "next run …"
   ```
   Then open `https://ev.<tailnet>.ts.net`.

## Day to day

- Criteria, weights and the buyer notes in `latest.md`: edit
  `config/config.toml`, commit; picked up at the next run.
- `docker exec ev-tracker evtracker top` prints the current ranking;
  `… evtracker export` regenerates the page now.
- AutoTrader has no public API; if they change their site the run fails and
  Kuma alerts. Fix in the source repo, then pull the new image.
