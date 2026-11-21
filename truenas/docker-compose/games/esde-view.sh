#!/usr/bin/env bash
# Build games/library/esde/: one symlink per RomM platform folder, named as
# ES-DE expects (ngc -> gc, 3ds -> n3ds, ...), so ES-DE on a PC can use the
# read-only SMB share of games/library directly. Safe to re-run; run it
# again when a new platform folder appears. See README.md ("Playing on a PC").
#
# Usage (as root, in the TrueNAS shell): ./esde-view.sh
set -euo pipefail

MEDIA=${MEDIA_PATH:-/mnt/tank/media}
APPS_UID=568
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)." >&2; exit 1; }

# RomM folder -> ES-DE folder, where they differ (from igir's console token
# table). Anything not listed has the same name in both.
MAP='
ngc gc
3ds n3ds
sms mastersystem
dc dreamcast
sega32 sega32x
neo-geo-pocket ngp
neo-geo-pocket-color ngpc
neogeomvs neogeo
neo-geo-cd neogeocd
turbografx-cd tg-cd
pc-fx pcfx
sfam sfc
g-and-w gameandwatch
64dd n64dd
pokemon-mini pokemini
lynx atarilynx
jaguar atarijaguar
atari-jaguar-cd atarijaguarcd
atari8bit atari800
atari-st atarist
wonderswan-color wonderswancolor
appleii apple2
apple-iigs apple2gs
acpc amstradcpc
amiga-cd32 amigacd32
c-plus-4 plus4
vic-20 vic20
zxs zxspectrum
odyssey-2 odyssey2
philips-cd-i cdimono1
sharp-x68000 x68000
pc-8800-series pc88
pc-9800-series pc98
fairchild-channel-f channelf
sg1000 sg-1000
'

# As the apps user, like everything else under games/. Links are relative
# (../roms/<folder>) so they resolve inside the share.
docker run --rm --user "$APPS_UID:$APPS_UID" -v "$MEDIA":/media -e MAP="$MAP" alpine sh -c '
  cd /media/games/library && mkdir -p esde && cd esde || exit 1
  find . -maxdepth 1 -type l -delete
  for d in ../roms/*/; do
    romm=${d#../roms/}; romm=${romm%/}
    es=$(echo "$MAP" | awk -v r="$romm" "\$1 == r { print \$2 }")
    ln -s "../roms/$romm" "${es:-$romm}"
    echo "  ${es:-$romm} -> roms/$romm"
  done'
echo "Done: $MEDIA/games/library/esde. In ES-DE, set the ROM directory to <share>/esde."
