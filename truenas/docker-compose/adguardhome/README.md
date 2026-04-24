# AdGuard Home

Network-wide DNS resolver, ad/tracker blocker, and DHCP server for
the remote site.

## Role in the stack

- **DNS for the LAN** — all clients use AdGuard as their resolver,
  giving network-wide ad and tracker blocking
- **DNS rewrites** — resolves `*.mateusharrington.com` to the TrueNAS
  host's LAN IP, so internal clients reach SWAG via nice domain names
  rather than IP addresses
- **DHCP server** — hands out leases at the remote site, ensuring
  clients are configured to use AdGuard for DNS automatically

## Why AdGuard Home (over Pi-hole)

- More polished UI
- Built-in DoH/DoT support upstream
- DHCP server included (Pi-hole's is more limited)
- Better DNS rewrite UX for internal domain handling

## DNS architecture

```
Client device  →  AdGuard Home (DNS)  →  Cloudflare DoH (upstream)
                       ↓
                   Block lists
                       ↓
                   DNS rewrites: *.mateusharrington.com → 192.168.0.172
```

Internal clients querying `immich.mateusharrington.com` get the LAN
IP of the TrueNAS host, hit SWAG, and reach Immich — without any
public DNS exposure.

## DHCP notes

When DHCP was migrated from the router to AdGuard:
- Router DHCP was disabled to avoid conflicts
- Existing clients retained their old leases until renewal (~50% of
  lease time) or rebinding (~87.5%), so the AdGuard dashboard
  populates gradually rather than all at once
- Devices with static IPs (e.g. TrueNAS itself) don't appear in the
  DHCP client list — this is expected

## Configuration committed to this repo

- `docker-compose.yml`
- This README

AdGuard's runtime config (`AdGuardHome.yaml`, query logs,
statistics) lives in the bind-mounted config directory and is not
committed — it's regenerated from the UI on first run, and the
filter list / rewrite config is small enough to recreate manually
or restore from a TrueNAS-level backup.

## Bootstrap on a new host

1. `docker compose up -d`
2. Browse to `http://<host>:3000` for the setup wizard
3. Configure:
   - Upstream DNS: `https://dns10.quad9.net/dns-query`
   - Block lists: AdGuard DNS filter, EasyList, EasyPrivacy
   - DNS rewrites: `*.mateusharrington.com` → TrueNAS LAN IP
   - DHCP: enable on appropriate interface, configure range
4. Disable any other DHCP server on the network (router, etc.)
