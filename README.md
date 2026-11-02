# MPD Control — Dux Shell 2.0

Version 0.2.0. A composite QML plugin with one shared backend, a horizontal/vertical bar widget, a popout, and an optional Control Center tile.

## Features

- Track metadata (Title, Artist, Album, queue position, audio format/bitrate) and playback state (`Playing`, `Paused`, `Stopped`, `Queue empty`).
- Embedded and folder cover art fetched via MPD's `readpicture` and `albumart` commands, cached locally with a fallback icon.
- Compact bar widget displaying the current song's cover art and an inline Play/Pause button, with `Artist • Album • Title` hover tooltip and mouse-wheel/touchpad volume scrolling.
- Virtualized **Queue** tab engineered for thousands of entries: server-side windowed loading (`playlistinfo START:END`), progressive infinite scroll (up and down), instant 100-track range paging, jump-to-current-track, server-side search filtering, live drag-and-drop / step / play-next reordering (`moveid`), and optimistic track removal (`deleteid`).
- **Search & Library** tab with **Grid** and **List** views, global search (`genre:…`, `artist:…`, `album:…`, `year:…` inline tokens + free-text), interactive scope pills (`Albums`, `Tracks`, `Artists`, `Genres`), removable filter breadcrumb chips, drill-down navigation, cached album art, and one-click **Play Now**, **Play Next**, **Add to Queue**, and **Save to Quick Actions** buttons.
- **Quick Actions** section on the **Track** page for one-click queue replacement (`replace-filter`: clears the queue, adds all matching tracks, and starts playback), configurable via plugin settings or saved directly from the Search tab.
- Everyday MPRIS-equivalent transport controls: Play/Pause, Stop, Previous, Next, and seek scrubbing with smooth 1-second local elapsed progression while playing and diffed daemon updates.
- Playback mode controls: Repeat, Random, Single (`Off` / `On` / `Oneshot`), and Consume.
- Volume slider when MPD's hardware or software mixer is active; explicit indicator when mixer control is disabled.
- Playback error display with one-click dismissal (`clearerror`), plus stale-state preservation when MPD becomes unreachable.
- Native Dux Material widgets (`DButton`, `DIconButton`, `DSlider`) with ripple effects, focus rings, tooltips, and grouped cards.

## Screenshots

| Main View | Queue |
| :---: | :---: |
| <img width="380" alt="Main playback view" src="https://github.com/user-attachments/assets/f72b77b1-2a01-46f1-91fa-170adcb20b0c" /> | <img width="380" alt="Queue view" src="https://github.com/user-attachments/assets/2567a1f8-bff7-432e-9c02-a9b1f23947b0" /> |
| **Library and Search** | **In Control Panel** |
| <img width="380" alt="Playback modes" src="https://github.com/user-attachments/assets/1b2c5a76-a887-472e-9a5e-73bcc16167a8" /> | <img width="380" alt="Error state" src="https://github.com/user-attachments/assets/2ec08e73-fb62-4608-b68f-1117179b9532" /> |

## Requirements

Dux Shell >= 2.0.0, Python >= 3.9 (standard library only), and a running Music Player Daemon (MPD) instance. No external CLI tools (`mpc`) or third-party Python packages are required.

## Install

Run from the parent directory:

```sh
bash mpd-control/install.sh
```

The installer copies the plugin into `${XDG_CONFIG_HOME:-$HOME/.config}/dms/plugins/mpdControl`. When updating, the installer moves any previous installation into a dated backup under `${XDG_STATE_HOME:-$HOME/.local/state}/mpd-control/backups/`. Dux plugin settings are kept separately and preserved. After installing or updating, open **Settings → Plugins**, scan for plugins, enable **MPD Control**, then add `mpdControl` to your bar or Control Center.

## Connect

By default, when **MPD address or socket path** is left empty, the backend checks:

1. `$XDG_RUNTIME_DIR/mpd/socket`
2. `/run/mpd/socket`
3. `127.0.0.1:6600`

You can configure a custom `host:port` (e.g. `127.0.0.1:6600` or `[::1]:6600`) or an absolute Unix socket path (e.g. `~/.config/mpd/socket`).

If your MPD server requires a password, create a private file (`0600`) containing only the password and set its path in **Password file path**. The password stays inside the Python process and is never stored in Dux settings or passed on the command line. Because MPD's TCP protocol is unencrypted, password authentication is only permitted over Unix domain sockets or loopback TCP (`localhost`, `127.0.0.1`, `::1`).

## Validation

Run included tests:

```sh
python3 -m unittest discover -s mpd-control/tests -v
node mpd-control/tests/test_format.cjs
```

## TODO / Roadmap

- [ ] **Playlists**: Browse, load, save, and manage stored MPD playlists.
- [ ] **Dynamic Playlists**: Saved filter/query rules (similar to Quick Actions) that dynamically populate or top up the queue.
- [ ] **MPD Stickers**: Support song stickers (`sticker`, e.g., ratings, play counts, favorites, or custom tags) and sticker-based filtering.
- [ ] **Expanded Quick Actions**: Allow Quick Actions to also set playback modes (`consume`, `random`, `repeat`, `single`) or load and play a specific stored playlist.

