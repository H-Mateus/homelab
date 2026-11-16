# Radicale

Self-hosted CalDAV for the shared house calendar. Each of us has our own
login and private calendars, plus one **House** calendar that both of us
can read and write. Phones use their built-in calendar apps, so event
reminders come from the phone itself. Tailnet-only, at
`https://radicale.<tailnet>.ts.net`.

Below, `<you>` and `<partner>` are the two login names (lowercase, no
spaces). `homeassistant` is a third, read-only login for Home Assistant.

## How sharing works

Radicale's default rule (`owner_only`) lets each login see only its own
`/<user>/` folder. The House calendar lives in `<you>`'s folder and is
*mapped* into the others' folders with Radicale's sharing API (3.7+):

```
/<you>/house/       owner: read + write
/<partner>/house/   map → /<you>/house/, read + write
/homeassistant/house/   map → /<you>/house/, read only
```

Calendar apps discover a mapped calendar like one of their own. Nobody can
map a calendar they don't own, and private calendars stay private.

## Deploy

1. **Tailscale ACL** (admin console): add the tag and let both of us (and,
   optionally, Home Assistant) reach it on 443.
   ```jsonc
   "tagOwners": { "tag:radicale": ["autogroup:admin"] },
   "grants": [
     { "src": ["autogroup:member"], "dst": ["tag:radicale"], "ip": ["tcp:443"] }
   ]
   ```
   If `<partner>` isn't a tailnet member, share the `radicale` device with
   them instead (like Immich, via `autogroup:shared`). Then create a
   single-use, pre-approved, non-ephemeral auth key tagged `tag:radicale`.
2. **Dataset**: create `apps/radicale` (Generic preset, defaults), then:
   ```sh
   chown 568:568 /mnt/apps/radicale
   ```
3. **Logins**: make one bcrypt line per login. On the Mac (`htpasswd` ships
   with macOS) it prompts for each password:
   ```sh
   for u in <you> <partner> homeassistant; do htpasswd -nB "$u"; done
   ```
   Paste the three `name:$2y$…` lines into `/mnt/apps/radicale/users` on
   TrueNAS, then:
   ```sh
   chown 568:568 /mnt/apps/radicale/users && chmod 600 /mnt/apps/radicale/users
   ```
   Keep the passwords in the password manager. No restart is needed when
   this file changes.
4. **Dockhand**: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy. `docker logs radicale` should show only the
   "creating storage" warnings on first start.
5. **Calendars**: open `https://radicale.<tailnet>.ts.net` and log in as
   `<you>`. Use *Create a new addressbook or calendar*, with href `house`,
   type calendar and title "House". Create any private ones the same way.
   `<partner>` can log in and make their own.
6. **Share House**: the web UI's *Share* button on the House calendar does
   this. Below are the equivalent API calls, run from any tailnet machine.
   Each map is created by the owner and then accepted by the recipient, so
   nothing appears unannounced.
   ```sh
   R=https://radicale.<tailnet>.ts.net
   # <partner>: read + write
   curl -u <you> -d PathOrToken=/<partner>/house/ -d PathMapped=/<you>/house/ \
        -d User=<partner> -d Permissions=rw -d Enabled=True -d Hidden=False \
        $R/.sharing/v1/map/create
   curl -u <partner> -d PathOrToken=/<partner>/house/ -d Enabled=True -d Hidden=False \
        $R/.sharing/v1/map/update
   # Home Assistant: read only
   curl -u <you> -d PathOrToken=/homeassistant/house/ -d PathMapped=/<you>/house/ \
        -d User=homeassistant -d Permissions=r -d Enabled=True -d Hidden=False \
        $R/.sharing/v1/map/create
   curl -u homeassistant -d PathOrToken=/homeassistant/house/ -d Enabled=True -d Hidden=False \
        $R/.sharing/v1/map/update
   ```
   Each call answers `Status='success'`.
7. **Phones** (Tailscale must be connected to sync; on iOS turn on
   *VPN On Demand* in the Tailscale app so it connects by itself):
   - **iPhone**: Settings → Apps → Calendar → Calendar Accounts → Add
     Account → Other → *Add CalDAV Account*. Server
     `radicale.<tailnet>.ts.net`, your login. House and your own calendars
     appear in the Calendar app. Set a default alert under Settings →
     Calendar → Default Alert Times.
   - **Android**: install **DAVx⁵** (Play Store or F-Droid) → *Login with
     URL and user name* → `https://radicale.<tailnet>.ts.net/`. Tick the
     calendars to sync. They then show in Samsung Calendar / Google
     Calendar like any other account. Allow DAVx⁵ to run unrestricted in
     battery settings or sync stalls.

## Home Assistant (optional)

Lets automations react to House events (e.g. "bins tomorrow" the evening
before, from a recurring event).

**Blocker first:** the HA Tailscale app runs with *Userspace networking*
on. In that mode tailnet devices can reach HA but HA can't reach them, so
it can't talk to Radicale. Turning it off creates a real `tailscale0`
interface on the HA host. That box is also the subnet router for
`192.168.1.0/24`, so at the same time turn *Accept routes* off (it doesn't
need routes from other nodes, and accepting its own subnet can hijack LAN
traffic). Then restart the app and check the LAN and the cameras still
work. HA's device is tagged `tag:homeassistant` (applied in the admin
console, so the app's *Advertise tags* option stays empty). Grant it only
what it needs:
```jsonc
{ "src": ["tag:homeassistant"], "dst": ["tag:radicale"], "ip": ["tcp:443"] }
```

Then: Settings → Devices & services → Add integration → **CalDAV**. URL
`https://radicale.<tailnet>.ts.net/`, user `homeassistant`. You get
`calendar.house`, which works with the `calendar` trigger (with an
`offset:` for "the evening before").

## Day to day

- **Change a password**: replace that user's line in `users` with a new
  `htpasswd -nB <user>` line. It applies immediately.
- **Backups**: everything is plain files on the dataset; snapshots of
  `apps` cover it. Export a single calendar with
  `curl -u <you> $R/<you>/house/ > house.ics`.
- **List or remove shares**: `curl -u <you> -d '' $R/.sharing/v1/map/list`;
  remove one with `curl -u <you> -d PathOrToken=/<partner>/house/ $R/.sharing/v1/map/delete`.
- **Upgrades**: Renovate opens a PR bumping the tag in `docker-compose.yml`. Read the
  [changelog](https://github.com/Kozea/Radicale/blob/master/CHANGELOG.md)
  first, because sharing is a new feature and its API may still move.
