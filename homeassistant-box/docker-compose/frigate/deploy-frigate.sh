#!/usr/bin/env bash
# GitOps deploy for this stack, run by frigate-deploy.timer (see README
# "Updating"). The TrueNAS stacks are redeployed by Dockhand when main
# changes; this LXC isn't Dockhand-managed, so this script does the same job:
# fast-forward this checkout to origin/main and, if the stack changed (a merged
# Renovate PR, a config.yml edit) or the running image doesn't match the pin:
#   - new Frigate image: tars ./config (incl. frigate.db) into backups/, pulls,
#     recreates, waits for /api/version to report the pinned tag, and on
#     failure restores the backup and puts the previous image back;
#   - config/ only: restarts Frigate so it rereads config.yml.
# A commit that failed is remembered in .deploy-failed and not retried; the
# next commit on main (a fix, or a revert) is.
#
#   ./deploy-frigate.sh            # normal run (what the timer does)
#   ./deploy-frigate.sh --dry-run  # report what it would do, change nothing
#
# Optional .env setting:
#   FRIGATE_NOTIFY_URL=...  # POSTed a one-line message (ntfy topic or an HA
#                           # webhook automation both work)
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
exec 9>.deploy-frigate.lock
flock -n 9 || { echo "another deploy is running"; exit 0; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

NOTIFY_URL="$(sed -n 's/^FRIGATE_NOTIFY_URL=//p' .env | tail -1)"
notify() {
  echo "$1"
  if [[ -n "$NOTIFY_URL" ]] && ! $DRY_RUN; then
    curl -fsS -m 15 -d "$1" "$NOTIFY_URL" >/dev/null || echo "notify failed"
  fi
}
# the frigate image pinned in docker-compose.yml at a given commit
pinned_image() {
  git show "$1:./docker-compose.yml" |
    sed -n 's/^ *image: *\(ghcr\.io\/blakeblackshear\/frigate:[^ ]*\).*/\1/p'
}

git fetch -q origin main
old="$(git rev-parse HEAD)"
new="$(git rev-parse origin/main)"
if [[ -f .deploy-failed ]] && [[ "$(cat .deploy-failed)" == "$new" ]]; then
  echo "main@${new:0:7} failed to deploy earlier; waiting for a new commit"
  exit 0
fi

running="$(docker inspect -f '{{.Config.Image}}' frigate 2>/dev/null || true)"
wanted="$(pinned_image "$new")"
stack_changed=false
if [[ "$old" != "$new" ]] && ! git diff --quiet "$old" "$new" -- .; then
  stack_changed=true
fi

if ! $stack_changed && [[ "$running" == "$wanted" ]]; then
  [[ "$old" == "$new" ]] || $DRY_RUN || git merge -q --ff-only origin/main
  echo "up to date: $running (main@${new:0:7})"
  exit 0
fi

if $DRY_RUN; then
  echo "would deploy main@${new:0:7}: frigate ${running:-<not running>} -> $wanted"
  $stack_changed && git diff --stat "$old" "$new" -- .
  exit 0
fi

if ! git merge -q --ff-only origin/main; then
  echo "$new" >.deploy-failed   # notify once per commit, not hourly
  notify "Frigate deploy: can't fast-forward to main@${new:0:7} (local edits in the checkout?). Check: git -C $PWD status"
  exit 1
fi

if [[ "$running" == "$wanted" ]]; then
  docker compose pull -q
  docker compose up -d
  if ! git diff --quiet "$old" "$new" -- config; then
    docker compose restart frigate
  fi
  notify "Frigate stack redeployed at main@${new:0:7} (image unchanged: $wanted)"
  exit 0
fi

echo "deploying main@${new:0:7}: frigate ${running:-<not running>} -> $wanted"
mkdir -p backups
backup="backups/config-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$backup" --exclude=config/model_cache config   # model_cache re-downloads
# shellcheck disable=SC2012  # our own timestamped names, no odd characters
ls -1t backups/config-*.tar.gz | tail -n +6 | xargs -r rm --   # keep 5

healthy() {   # Frigate's internal, unauthenticated API reports the version
  local v
  for _ in $(seq 1 30); do
    v="$(docker exec frigate curl -fsS -m 5 http://127.0.0.1:5000/api/version 2>/dev/null || true)"
    [[ -n "$v" && "$v" == "${1##*:}"* ]] && return 0
    sleep 10
  done
  return 1
}

if docker compose pull -q && docker compose up -d && healthy "$wanted"; then
  rm -f .deploy-failed
  docker image prune -f >/dev/null
  notify "Frigate deployed: ${running:-<not running>} -> $wanted (main@${new:0:7}; config backup: $backup)"
  exit 0
fi

echo "$new" >.deploy-failed
if [[ -z "$running" ]]; then
  notify "Frigate deploy of $wanted FAILED and nothing was running before to roll back to. Check: docker compose logs frigate"
  exit 1
fi
# Back to the image that was running, via a throwaway override; the checkout
# stays on main so the next commit there (fix or revert) deploys normally.
docker compose stop frigate || true
rm -f config/frigate.db config/frigate.db-*   # no stale WAL over the restored DB
tar -xzf "$backup"
printf 'services:\n  frigate:\n    image: %s\n' "$running" >.rollback.yml
docker compose -f docker-compose.yml -f .rollback.yml up -d frigate || true
if healthy "$running"; then
  notify "Frigate deploy of $wanted FAILED; rolled back to $running and restored config/. Check: docker compose logs frigate"
else
  notify "Frigate deploy of $wanted FAILED and the rollback to $running isn't healthy either. Config backup: $backup"
fi
exit 1
