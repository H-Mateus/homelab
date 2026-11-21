#!/usr/bin/env bash
# Import games from a downloaded ROM set into RomM's library, verified
# against the DATs in games/dats and sorted into roms/<platform>/ by igir.
# One release per game (1G1R) unless --all. See README.md ("Importing a
# set torrent").
#
# Usage (as root, in the TrueNAS shell):
#   ./import-romset.sh [--dats REGEX] [--list FILE] [--all] [--dry-run] <source> [system ...]
#   ./import-romset.sh --no-dat PLATFORM [--dry-run] <source> [folder ...]
#
#   <source>  the set's download folder, under /mnt/tank/media
#   system    an entry in <source> to import, without extension, e.g.
#             "Nintendo - Game Boy". Either a folder of per-game files
#             (hardlinked, so the torrent keeps seeding) or a whole-system
#             .rar/.7z/.zip of per-game zips (unpacked to staging first,
#             since igir can't read archives inside archives). Omit to
#             import <source> itself as one folder of per-game files.
#   --dats    only use DATs whose name matches REGEX (igir --dat-name-regex,
#             e.g. "Nintendo DS"). Much faster: otherwise every DAT in
#             games/dats is checked in turn, even for one system's games
#   --list    only games whose names match a line of FILE (igir
#             --filter-regex: one regex per line, e.g. ^Golden Sun)
#   --all     keep every region/revision, betas and demos too
#   --dry-run write only a report (games/igir-reports), import nothing
#   --no-dat  skip igir: hardlink every file/folder in <source> (or the
#             named folders) into roms/PLATFORM as it is, for sets no DAT
#             matches (another dump format, PS3/Wii U folders). PLATFORM
#             is RomM's folder name: nds, ps2, ps3, wiiu, xbox360, ...
#             Existing names are skipped; --dry-run lists what it would do
#
# Example:
#   ./import-romset.sh '/mnt/tank/media/downloads/games/No-Intro 20190501' \
#     'Nintendo - Game Boy' 'Sega - Mega Drive - Genesis'
set -euo pipefail

MEDIA=${MEDIA_PATH:-/mnt/tank/media}
IGIR_VERSION=5.8.1
APPS_UID=568

die() { echo "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage/,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

dats='' list='' all='' dry='' nodat=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --dats) dats=${2:?--dats needs a regex}; shift 2 ;;
    --list) list=$(realpath "${2:?--list needs a file}"); shift 2 ;;
    --all) all=1; shift ;;
    --dry-run) dry=1; shift ;;
    --no-dat) nodat=${2:?--no-dat needs a platform}; shift 2 ;;
    -h|--help) usage ;;
    -*) die "Unknown option $1 (see --help)" ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage 1
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."

src=$(realpath "$1"); shift
[[ -d $src ]] || die "No such folder: $src"

# Host path under $MEDIA -> the same path inside the containers (/media).
in_media() {
  [[ $1 == "$MEDIA"/* ]] || die "$1 is not under $MEDIA"
  echo "/media${1#"$MEDIA"}"
}
in_media "$src" >/dev/null

link_inputs=() archives=()
if [[ $# -eq 0 ]]; then
  link_inputs+=("$src")
fi
for s in "$@"; do
  if [[ -d $src/$s ]]; then
    link_inputs+=("$src/$s")
  else
    found=
    for ext in rar 7z zip; do
      [[ -f $src/$s.$ext ]] && { archives+=("$s.$ext"); found=1; break; }
    done
    [[ -n $found ]] || die "Nothing called '$s' in $src. Entries:
$(ls -1 "$src" | sed 's/^/  /')"
  fi
done

if [[ -n $nodat ]]; then
  [[ $nodat =~ ^[a-z0-9_-]+$ ]] || die "--no-dat: '$nodat' isn't a RomM platform folder name"
  [[ ${#archives[@]} -eq 0 ]] || die "--no-dat links folders only, not archives"
  dest=/media/games/library/roms/$nodat
  echo "==> Hardlinking into $MEDIA${dest#/media} (no DAT check)"
  mapped=()
  for p in "${link_inputs[@]}"; do mapped+=("$(in_media "$p")"); done
  # As the apps user, like everything else under games/. Hidden files and
  # qBittorrent's .!qB partials are skipped.
  docker run --rm --user "$APPS_UID:$APPS_UID" -v "$MEDIA":/media alpine sh -c '
    dest=$1 dry=$2; shift 2
    [ -n "$dry" ] || mkdir -p "$dest" || exit 1
    n=0
    for d; do
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        case $f in *.!qB) continue ;; esac
        name=${f##*/}
        if [ -e "$dest/$name" ]; then echo "  exists, skipped: $name"; continue; fi
        # Already converted by make-chd.sh: do not add the archive back.
        if [ -e "$dest/${name%.*}.chd" ]; then echo "  has a CHD, skipped: $name"; continue; fi
        echo "  $name"
        [ -n "$dry" ] || cp -a -l "$f" "$dest/" || exit 1
        n=$((n + 1))
      done
    done
    echo "$n new"' sh "$dest" "$dry" "${mapped[@]}"
  echo
  [[ -n $dry ]] && echo "Dry run: nothing linked." ||
    echo "Done. RomM: Scan -> Quick scan (or wait for the 04:00 rescan)."
  exit 0
fi

ls "$MEDIA"/games/dats/*.dat >/dev/null 2>&1 || die "No DATs in $MEDIA/games/dats"
# games/ belongs to the apps user, so anything running as it could swap a
# path for a symlink. Root never writes there: every create, unpack and
# delete runs in a container as $APPS_UID, so a planted link only reaches
# what that user could reach anyway.
as_apps() {
  docker run --rm --user "$APPS_UID:$APPS_UID" -v "$MEDIA":/media alpine "$@"
}
as_apps mkdir -p /media/games/igir-reports /media/games/igir-tmp /media/games/staging

stg=   # container path
cleanup() {
  as_apps sh -c '[ -n "$1" ] && rm -rf "$1"; find /media/games/igir-tmp -mindepth 1 -delete 2>/dev/null' \
    sh "$stg" || true
}
trap cleanup EXIT

if [[ ${#archives[@]} -gt 0 ]]; then
  stg=$(as_apps mktemp -d /media/games/staging/import-XXXXXX)
  echo "==> Unpacking ${#archives[@]} archive(s) to $MEDIA${stg#/media}"
  # The set is mounted read-only: the seeding files can't be touched. Root
  # only installs unar; the unpack itself runs as the apps user.
  docker run --rm -v "$src":/src:ro -v "$MEDIA":/media -e STG="$stg" \
    -e APPS_UID="$APPS_UID" -e DEBIAN_FRONTEND=noninteractive debian:trixie-slim sh -c '
    apt-get update -qq && apt-get install -y -qq --no-install-recommends unar >/dev/null || exit 1
    for a; do
      echo "  $a"
      setpriv --reuid="$APPS_UID" --regid="$APPS_UID" --clear-groups \
        unar -q -f -o "$STG" "/src/$a" || exit 1
    done' sh "${archives[@]}"
fi

tty=(-i); [[ -t 1 ]] && tty=(-it)
igir() {
  docker run --rm "${tty[@]}" --user "$APPS_UID:$APPS_UID" -e HOME=/tmp \
    -e NPM_CONFIG_UPDATE_NOTIFIER=false \
    -v "$MEDIA":/media node:24-alpine npx -y "igir@$IGIR_VERSION" "$@"
}

opts=(--dat '/media/games/dats/*.dat'
      --output '/media/games/library/roms/{romm}'
      --temp-dir /media/games/igir-tmp)
# shellcheck disable=SC2054 # the commas are igir syntax
if [[ -z $all ]]; then
  opts+=(--single --only-retail --prefer-language EN
         --prefer-region UK,EUR,WORLD,USA,JPN
         --prefer-verified --prefer-good --prefer-revision newer)
fi
[[ -n $dats ]] && opts+=(--dat-name-regex "/$dats/i")
if [[ -n $list ]]; then
  in_media "$list" >/dev/null
  opts+=(--filter-regex "$(in_media "$list")")
fi

# $1: link (seeding folders) or move (staging); then container paths.
# --dry-run: report only.
run_igir() {
  local cmd=$1; shift
  local inputs=() p
  # igir uses an --input that exists as a literal path, so set names
  # with ( ) [ ] need no escaping (escaping them makes it find nothing).
  for p in "$@"; do inputs+=(--input "$p"); done
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  if [[ -n $dry ]]; then
    igir report "${opts[@]}" "${inputs[@]}" \
      --report-output "/media/games/igir-reports/dry-run-$stamp.csv"
  else
    igir "$cmd" test report "${opts[@]}" "${inputs[@]}" \
      --report-output "/media/games/igir-reports/import-$cmd-$stamp.csv"
  fi
}

if [[ ${#link_inputs[@]} -gt 0 ]]; then
  echo "==> Linking from the set"
  mapped=()
  for p in "${link_inputs[@]}"; do mapped+=("$(in_media "$p")"); done
  run_igir link "${mapped[@]}"
fi
[[ -n $stg ]] && { echo "==> Moving from staging"; run_igir move "$stg"; }

echo
if [[ -n $dry ]]; then
  echo "Dry run: see the newest CSV in $MEDIA/games/igir-reports (Status FOUND = would import)."
else
  echo "Done. RomM: Scan -> Quick scan (or wait for the 04:00 rescan)."
fi
