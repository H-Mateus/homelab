#!/usr/bin/env bash
# Convert disc games to CHD in RomM's library: lossless, smaller, and read
# directly by DuckStation, PCSX2 and PPSSPP (which can't open .7z/.zip).
# See README.md ("Converting disc games to CHD").
#
# Usage (as root, in the TrueNAS shell):
#   ./make-chd.sh [--dry-run] <platform> <game> [game ...]
#
#   platform  RomM folder to write into: psx, ps2, psp, segacd, dc, ...
#   game      a .7z/.zip/.rar of one game, a .cue/.iso, or a folder holding
#             one; anywhere under /mnt/tank/media (a download or a file in
#             the library). Each .cue becomes a CD CHD, each .iso a DVD CHD.
#
# The source is only read, so a seeding download is untouched. Afterwards a
# copy of the same game in roms/<platform> (e.g. the .7z igir hardlinked
# there) is removed if it is a hardlink, since the download still holds the
# data; a library file with no other link is kept for you to delete.
#
# Example (the whole PS2 library, while still seeding):
#   ./make-chd.sh ps2 /mnt/tank/media/games/library/roms/ps2/*.7z
set -euo pipefail

MEDIA=${MEDIA_PATH:-/mnt/tank/media}
APPS_UID=568

die() { echo "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage/,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

dry=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry=1; shift ;;
    -h|--help) usage ;;
    -*) die "Unknown option $1 (see --help)" ;;
    *) break ;;
  esac
done
[[ $# -ge 2 ]] || usage 1
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
platform=$1; shift
[[ $platform =~ ^[a-z0-9_-]+$ ]] || die "'$platform' isn't a RomM platform folder name"

# Host path under $MEDIA -> the same path inside the containers (/media).
in_media() {
  [[ $1 == "$MEDIA"/* ]] || die "$1 is not under $MEDIA"
  echo "/media${1#"$MEDIA"}"
}
games=()
for g in "$@"; do
  g=$(realpath "$g")
  [[ -e $g ]] || die "No such file: $g"
  games+=("$(in_media "$g")")
done

if [[ -n $dry ]]; then
  for g in "${games[@]}"; do echo "  would convert: $MEDIA${g#/media}"; done
  echo "Dry run: into $MEDIA/games/library/roms/$platform/"
  exit 0
fi

# As in import-romset.sh: root never writes under games/ (owned by the apps
# user), so every create, unpack, convert and delete runs as $APPS_UID.
as_apps() {
  docker run --rm --user "$APPS_UID:$APPS_UID" -v "$MEDIA":/media alpine "$@"
}
as_apps mkdir -p /media/games/staging "/media/games/library/roms/$platform"
stg=$(as_apps mktemp -d /media/games/staging/chd-XXXXXX)
cleanup() { as_apps rm -rf "$stg" || true; }
trap cleanup EXIT

# Root only installs the tools; the work runs as the apps user.
docker run --rm -v "$MEDIA":/media -e STG="$stg" -e APPS_UID="$APPS_UID" \
  -e OUT="/media/games/library/roms/$platform" \
  -e DEBIAN_FRONTEND=noninteractive debian:trixie-slim sh -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends unar mame-tools >/dev/null || exit 1
  exec setpriv --reuid="$APPS_UID" --regid="$APPS_UID" --clear-groups sh -c '\''
    ok=0 failed=0
    for g; do
      echo "==> ${g##*/}"
      work=$STG/work; rm -rf "$work"; mkdir -p "$work"
      src=$g   # a .cue/.iso or a folder is read in place (a .cue needs its .bins)
      case $g in
        *.7z|*.zip|*.rar) src=$work; unar -q -f -o "$work" "$g" >"$STG/log" 2>&1 ||
            { echo "  unpack failed:"; tail -n 3 "$STG/log" | sed "s/^/    /"; failed=$((failed+1)); continue; } ;;
      esac
      discs=$(find "$src" -type f \( -iname "*.cue" -o -iname "*.gdi" \))
      [ -n "$discs" ] || discs=$(find "$src" -type f -iname "*.iso")
      if [ -z "$discs" ]; then
        echo "  no .cue, .gdi or .iso inside; skipped"; failed=$((failed+1)); continue
      fi
      echo "$discs" | while IFS= read -r d; do
        name=${d##*/}; name=${name%.*}
        if [ -e "$OUT/$name.chd" ]; then echo "  exists: $name.chd"; continue; fi
        case $d in *.iso|*.ISO) mode=createdvd ;; *) mode=createcd ;; esac
        # Into staging first, so a failed run never leaves half a CHD in
        # the library; same filesystem, so the move is instant.
        rm -f "$STG/$name.chd"
        if ! chdman $mode -i "$d" -o "$STG/$name.chd" >"$STG/log" 2>&1; then
          echo "  chdman failed:"; grep -v "% complete" "$STG/log" | tail -n 3 | sed "s/^/    /"
          rm -f "$STG/$name.chd"; exit 1
        fi
        mv "$STG/$name.chd" "$OUT/$name.chd" && echo "  -> roms/${OUT##*/}/$name.chd" || exit 1
      done || { failed=$((failed+1)); continue; }
      ok=$((ok+1))
      # The same game already in the library (e.g. igir hardlinked the
      # .7z): drop it if the download still holds the data.
      base=${g##*/}; base=${base%.*}
      for old in "$OUT/$base.7z" "$OUT/$base.zip" "$OUT/$base.rar"; do
        [ -f "$old" ] || continue
        if [ "$(stat -c %h "$old")" -gt 1 ]; then
          rm -f "$old" && echo "  removed library hardlink ${old##*/} (download keeps seeding)"
        else
          echo "  kept ${old##*/}: it is the only copy; delete it once the CHD plays"
        fi
      done
    done
    rm -rf "$STG/work"
    echo; echo "$ok converted, $failed failed"
    [ "$failed" -eq 0 ]
  '\'' sh "$@"' sh "${games[@]}"

echo "Done. RomM: Scan -> Quick scan."
