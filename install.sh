#!/usr/bin/env bash
set -euo pipefail
source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
destination="${XDG_CONFIG_HOME:-$HOME/.config}/dms/plugins/mpdControl"
command -v python3 >/dev/null || { printf 'Python 3 is required.\n' >&2; exit 1; }
if [[ -e "$destination" ]]; then
    backup="${XDG_STATE_HOME:-$HOME/.local/state}/mpd-control/backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p -- "$(dirname -- "$backup")"
    mv -- "$destination" "$backup"
    printf 'Previous plugin backed up to %s\n' "$backup"
fi
mkdir -p -- "$(dirname -- "$destination")"
cp -R -- "$source_dir" "$destination"
rm -rf -- "$destination/.git"
printf 'Installed to %s\nIn Dux: Settings → Plugins → Scan for Plugins → enable MPD Control.\nThen add mpdControl to your bar layout.\n' "$destination"
