# EV tracker

Checks AutoTrader once a day for used EVs near Cardiff, scores each one
(value vs market, range, 360 camera, insurance group, …) and sends Telegram
alerts for standout deals plus a twice-weekly digest. Source and image:
[H-Mateus/ev-price-tracker](https://github.com/H-Mateus/ev-price-tracker).

No UI and nothing listening; outbound requests only. Uptime Kuma gets a
heartbeat after every run (see Networking in `docker-compose.yml`).

## Deploy

1. **Image**: pushed to GHCR by the (private) repo's `image` workflow on
   every push to `main`, so the package is private too. Create a **classic**
   PAT with only the `read:packages` scope (GHCR doesn't take fine-grained
   tokens), then either add `ghcr.io` with it as a registry in Dockhand, or
   log the TrueNAS Docker in once:
   ```sh
   echo <PAT> | docker login ghcr.io -u H-Mateus --password-stdin
   ```
2. **Dataset**: create `apps/ev-tracker` (Generic preset, defaults), then:
   ```sh
   chown 568:568 /mnt/apps/ev-tracker
   ```
   It holds one small SQLite file. Optional: copy an existing
   `evtracker.db` from the laptop into it to keep the price history.
3. **Telegram**: message @BotFather → `/newbot` → token. Send the new bot any
   message, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and
   copy `message.chat.id`.
4. **Uptime Kuma**: add a monitor of type *Push*, heartbeat interval
   `90000` s (25 h), and copy its token into
   `EVTRACKER_PUSH_URL=http://uptime-kuma-ts:3001/api/push/<token>`.
   Goes down if a run fails, AutoTrader blocks it, or the search returns
   nothing.
5. **Dockhand**: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy. Requires the `uptime-kuma` stack to be running
   (its network is joined as external).
6. **Check**:
   ```sh
   docker exec ev-tracker evtracker test-notify   # Telegram arrives
   docker exec ev-tracker evtracker probe         # search still works
   docker logs ev-tracker                         # "next run …"
   ```

## Day to day

- Criteria and weights: edit `config/config.toml`, commit; picked up at the
  next run.
- `docker exec ev-tracker evtracker top` prints the current ranking.
- `docker exec ev-tracker evtracker run --digest` runs immediately.
- AutoTrader has no public API; if they change their site the run fails and
  Kuma alerts. Fix in the source repo, then pull the new image.
