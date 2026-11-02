#!/usr/bin/env python3
"""One-shot MPD protocol adapter. Secrets never cross the QML/process boundary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket


MAX_ART_BYTES = 5 * 1024 * 1024
MAX_CACHED_ART = 512
MAX_QUEUE_LIMIT = 250
MAX_LIBRARY_LIMIT = 250
MAX_ALBUM_ART_FETCH_PER_CALL = 24

INLINE_TOKEN_RE = re.compile(r'\b(genre|artist|album|year|date):(?:"([^"]+)"|(\S+))', re.IGNORECASE)


class IntegrationError(Exception):
    pass


def resolve_endpoint(address=''):
    raw = (address or '').strip()
    if not raw or raw == 'auto':
        candidates = []
        runtime = os.getenv('XDG_RUNTIME_DIR', '')
        if runtime:
            candidates.append(Path(runtime) / 'mpd/socket')
        candidates.append(Path('/run/mpd/socket'))
        for candidate in candidates:
            if candidate.exists():
                return ('unix', str(candidate), True)
        return ('tcp', ('127.0.0.1', 6600), True)
    if '://' in raw or '@' in raw or any(ch.isspace() for ch in raw):
        raise IntegrationError('Use a host:port or an absolute Unix socket path.')
    if raw.startswith('/') or raw.startswith('~'):
        expanded = Path(raw).expanduser()
        if not expanded.is_absolute():
            raise IntegrationError('Unix socket path must be absolute.')
        return ('unix', str(expanded), True)
    host, sep, port_str = raw.rpartition(':')
    if sep and host.startswith('[') and host.endswith(']'):
        host = host[1:-1]
    elif sep and ':' in host:
        # Unbracketed IPv6 literal without port is rejected to avoid ambiguity.
        raise IntegrationError('Wrap IPv6 addresses in brackets, e.g. [::1]:6600.')
    elif not sep:
        host, port_str = raw, '6600'
    if not host:
        raise IntegrationError('Use a valid MPD host:port or Unix socket path.')
    try:
        port = int(port_str, 10)
    except ValueError:
        raise IntegrationError('MPD port must be an integer between 1 and 65535.') from None
    if not (1 <= port <= 65535):
        raise IntegrationError('MPD port must be between 1 and 65535.')
    is_local = host.lower() in ('localhost', '127.0.0.1', '::1')
    return ('tcp', (host, port), is_local)


def load_password(password_path=''):
    if not password_path:
        return ''
    text = Path(password_path).expanduser().read_text(encoding='utf-8').strip()
    if not text:
        raise IntegrationError('The password file is empty.')
    if any(ord(ch) < 32 for ch in text):
        raise IntegrationError('The password file must contain a single-line password.')
    return text


def quote_arg(value):
    text = str(value)
    if any(ord(ch) < 32 for ch in text):
        raise IntegrationError('Invalid control character in MPD argument.')
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def parse_inline_query(raw_query=''):
    tokens = {'genre': '', 'artist': '', 'album': '', 'year': ''}
    if not raw_query:
        return '', tokens

    def _replace(match):
        key = match.group(1).lower()
        if key == 'date':
            key = 'year'
        val = (match.group(2) if match.group(2) is not None else match.group(3) or '').strip()
        if val:
            tokens[key] = val
        return ' '

    cleaned = INLINE_TOKEN_RE.sub(_replace, raw_query)
    free_text = ' '.join(cleaned.split())
    return free_text, tokens


def build_legacy_filter_args(genre='', artist='', album='', year='', free_text=''):
    parts = []
    if genre:
        parts.extend(['Genre', quote_arg(genre)])
    if artist:
        parts.extend(['Artist', quote_arg(artist)])
    if album:
        parts.extend(['Album', quote_arg(album)])
    if year:
        parts.extend(['Date', quote_arg(year)])
    if free_text:
        parts.extend(['any', quote_arg(free_text)])
    return ' '.join(parts)


def album_art_cache_key(uri='', album='', album_artist='', artist=''):
    alb = (album or '').strip().lower()
    art = (album_artist or artist or '').strip().lower()
    if alb:
        return f'album:{alb}|artist:{art}'
    if uri:
        parent = str(Path(uri).parent)
        if parent and parent != '.':
            return f'dir:{parent.lower()}'
        return f'file:{uri}'
    return ''


def detect_image_ext(data):
    if data.startswith(b'\xff\xd8\xff'):
        return '.jpg'
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return '.png'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return '.webp'
    if data.startswith((b'GIF87a', b'GIF89a')):
        return '.gif'
    return ''


def parse_tracks(pairs):
    tracks = []
    current = None
    for key, val in pairs:
        if key == 'file':
            if current is not None:
                tracks.append(_normalize_track(current))
            current = {'file': val}
        elif current is not None and key not in current:
            current[key] = val
    if current is not None:
        tracks.append(_normalize_track(current))
    return tracks


def _normalize_track(raw):
    song_file = raw.get('file', '')
    fallback_title = Path(song_file).name or song_file
    duration = float(raw.get('duration', raw.get('Time', 0)) or 0)
    track_id = int(raw.get('Id', 0) or 0)
    date_val = str(raw.get('Date') or '').strip()
    return {
        'id': track_id,
        'trackId': track_id,
        'pos': int(raw.get('Pos', 0) or 0),
        'file': song_file,
        'title': raw.get('Title') or raw.get('Name') or fallback_title,
        'artist': raw.get('Artist') or raw.get('AlbumArtist') or raw.get('Performer') or '',
        'albumArtist': raw.get('AlbumArtist') or raw.get('Artist') or '',
        'album': raw.get('Album') or '',
        'genre': raw.get('Genre') or '',
        'date': date_val[:4] if len(date_val) >= 4 else date_val,
        'track': str(raw.get('Track') or ''),
        'duration': max(0.0, duration)
    }


def _track_matches_filters(track, genre='', artist='', album='', year='', free_text=''):
    if genre and track.get('genre', '').lower() != genre.lower():
        return False
    if artist:
        needle_artist = artist.lower()
        if track.get('artist', '').lower() != needle_artist and track.get('albumArtist', '').lower() != needle_artist and needle_artist not in track.get('artist', '').lower():
            return False
    if album and track.get('album', '').lower() != album.lower():
        return False
    if year and not track.get('date', '').lower().startswith(year.lower()):
        return False
    if free_text:
        haystack = ' '.join([
            track.get('title', ''),
            track.get('artist', ''),
            track.get('albumArtist', ''),
            track.get('album', ''),
            track.get('genre', ''),
            track.get('date', ''),
            track.get('file', '')
        ]).lower()
        for word in free_text.lower().split():
            if word not in haystack:
                return False
    return True


class Client:
    def __init__(self, address='', password='', cache_dir=None):
        self.kind, self.target, self.is_local = resolve_endpoint(address)
        if password and not self.is_local:
            raise IntegrationError('Refusing to send an MPD password over unencrypted non-loopback TCP.')
        self.password = password
        default_cache = Path(os.getenv('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'mpd-control/art'
        self.cache_dir = Path(cache_dir) if cache_dir is not None else default_cache

    def _connect(self):
        sock = None
        reader = None
        try:
            if self.kind == 'unix':
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(3.0)
                sock.connect(self.target)
            else:
                sock = socket.create_connection(self.target, timeout=3.0)
                sock.settimeout(3.0)
            reader = sock.makefile('rb')
            greeting = reader.readline().decode('utf-8', errors='replace')
            if not greeting.startswith('OK MPD '):
                raise IntegrationError('Unexpected server greeting. Is this an MPD port?')
            if self.password:
                self._execute(sock, reader, 'password ' + quote_arg(self.password))
            return sock, reader
        except IntegrationError:
            if reader is not None:
                reader.close()
            if sock is not None:
                sock.close()
            raise
        except (OSError, TimeoutError):
            if reader is not None:
                reader.close()
            if sock is not None:
                sock.close()
            raise IntegrationError('MPD is unreachable or timed out.') from None

    def _execute(self, sock, reader, command):
        try:
            sock.sendall((command + '\n').encode('utf-8'))
            pairs = []
            while True:
                line = reader.readline()
                if not line:
                    raise IntegrationError('MPD closed the connection unexpectedly.')
                decoded = line.decode('utf-8', errors='replace').rstrip('\r\n')
                if decoded == 'OK':
                    return pairs
                if decoded.startswith('ACK '):
                    if 'password' in decoded.lower() or 'permission' in decoded.lower():
                        raise IntegrationError('Authentication failed or permission denied.')
                    msg = decoded.split('} ', 1)[-1] if '} ' in decoded else decoded
                    raise IntegrationError('MPD error: ' + msg)
                if ': ' in decoded:
                    key, val = decoded.split(': ', 1)
                    pairs.append((key, val))
        except IntegrationError:
            raise
        except (OSError, TimeoutError):
            raise IntegrationError('Communication with MPD timed out.') from None

    def _fetch_binary(self, sock, reader, cmd_name, uri):
        offset = 0
        total_size = None
        chunks = []
        while True:
            command = f'{cmd_name} {quote_arg(uri)} {offset}'
            sock.sendall((command + '\n').encode('utf-8'))
            headers = {}
            chunk = b''
            while True:
                line = reader.readline()
                if not line:
                    raise IntegrationError('MPD closed the connection unexpectedly.')
                decoded = line.decode('utf-8', errors='replace').rstrip('\r\n')
                if decoded == 'OK':
                    break
                if decoded.startswith('ACK '):
                    return b''
                if ': ' in decoded:
                    key, val = decoded.split(': ', 1)
                    headers[key] = val
                    if key == 'binary':
                        length = int(val)
                        if length < 0 or offset + length > MAX_ART_BYTES:
                            return b''
                        chunk = reader.read(length)
                        # Consume trailing newline after binary payload.
                        reader.readline()
            if not chunk:
                return b''
            if total_size is None:
                total_size = int(headers.get('size', len(chunk)))
                if total_size <= 0 or total_size > MAX_ART_BYTES:
                    return b''
            chunks.append(chunk)
            offset += len(chunk)
            if offset >= total_size:
                return b''.join(chunks)

    def _cached_art_uri(self, uri='', album='', album_artist='', artist=''):
        cache_key = album_art_cache_key(uri=uri, album=album, album_artist=album_artist, artist=artist)
        if not cache_key:
            return None
        digest = hashlib.sha256(cache_key.encode('utf-8')).hexdigest()[:24]
        try:
            for ext in ('.jpg', '.png', '.webp', '.gif', '.none'):
                cached = self.cache_dir / (digest + ext)
                if cached.is_file():
                    return '' if ext == '.none' else cached.resolve().as_uri()
        except OSError:
            return ''
        return None

    def _resolve_art(self, sock, reader, uri, album='', album_artist='', artist=''):
        if not uri:
            return ''
        cached_uri = self._cached_art_uri(uri=uri, album=album, album_artist=album_artist, artist=artist)
        if cached_uri is not None:
            return cached_uri
        cache_key = album_art_cache_key(uri=uri, album=album, album_artist=album_artist, artist=artist)
        if not cache_key:
            return ''
        digest = hashlib.sha256(cache_key.encode('utf-8')).hexdigest()[:24]
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(self.cache_dir, 0o700)
            raw = self._fetch_binary(sock, reader, 'readpicture', uri)
            if not raw:
                raw = self._fetch_binary(sock, reader, 'albumart', uri)
            ext = detect_image_ext(raw) if raw else ''
            target = self.cache_dir / (digest + (ext or '.none'))
            tmp = self.cache_dir / (digest + '.tmp-' + str(os.getpid()))
            tmp.write_bytes(raw if ext else b'')
            os.replace(tmp, target)
            files = sorted(self.cache_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
            for stale in files[MAX_CACHED_ART:]:
                stale.unlink(missing_ok=True)
            return target.resolve().as_uri() if ext else ''
        except OSError:
            return ''

    def _query_tracks(self, sock, reader, genre='', artist='', album='', year='', free_text=''):
        filter_args = build_legacy_filter_args(genre, artist, album, year, free_text)
        pairs = []
        if filter_args:
            try:
                pairs = self._execute(sock, reader, f'search {filter_args}')
            except IntegrationError:
                pairs = self._execute(sock, reader, 'listallinfo')
        else:
            try:
                pairs = self._execute(sock, reader, 'search any ""')
            except IntegrationError:
                pairs = self._execute(sock, reader, 'listallinfo')
        tracks = parse_tracks(pairs)
        return [
            t for t in tracks
            if _track_matches_filters(t, genre=genre, artist=artist, album=album, year=year, free_text=free_text)
        ]

    def _list_genres(self, sock, reader):
        try:
            pairs = self._execute(sock, reader, 'list Genre')
            genres = sorted({val.strip() for key, val in pairs if key.lower() == 'genre' and val.strip()}, key=lambda s: s.lower())
            return genres
        except IntegrationError:
            return []

    def snapshot(self, fetch_art=True):
        sock, reader = self._connect()
        try:
            status_pairs = dict(self._execute(sock, reader, 'status'))
            song_pairs = dict(self._execute(sock, reader, 'currentsong'))
            state = status_pairs.get('state', 'stop')
            if state not in ('play', 'pause', 'stop'):
                state = 'stop'
            raw_vol = int(status_pairs.get('volume', '-1'))
            volume = raw_vol if 0 <= raw_vol <= 100 else None
            single_raw = status_pairs.get('single', '0')
            single = 'oneshot' if single_raw == 'oneshot' else ('on' if single_raw == '1' else 'off')
            consume_raw = status_pairs.get('consume', '0')
            consume = 'oneshot' if consume_raw == 'oneshot' else ('on' if consume_raw == '1' else 'off')
            elapsed = float(status_pairs.get('elapsed', status_pairs.get('time', '0:0').split(':')[0] or 0))
            duration = float(status_pairs.get('duration', song_pairs.get('duration', song_pairs.get('Time', 0)) or 0))
            bitrate_raw = int(status_pairs.get('bitrate', '0') or 0)
            song_file = song_pairs.get('file', '')
            song = None
            art_url = ''
            if song_file:
                fallback_title = Path(song_file).name or song_file
                song = {
                    'file': song_file,
                    'title': song_pairs.get('Title') or song_pairs.get('Name') or fallback_title,
                    'artist': song_pairs.get('Artist') or song_pairs.get('AlbumArtist') or song_pairs.get('Performer') or '',
                    'album': song_pairs.get('Album') or '',
                    'date': song_pairs.get('Date') or '',
                    'id': song_pairs.get('Id') or ''
                }
                if fetch_art:
                    art_url = self._resolve_art(
                        sock,
                        reader,
                        song_file,
                        album=song.get('album', ''),
                        album_artist=song_pairs.get('AlbumArtist', ''),
                        artist=song.get('artist', '')
                    )
            return {
                'ok': True,
                'state': state,
                'volume': volume,
                'repeat': status_pairs.get('repeat') == '1',
                'random': status_pairs.get('random') == '1',
                'single': single,
                'consume': consume,
                'elapsed': max(0.0, elapsed),
                'duration': max(0.0, duration),
                'playlistVersion': int(status_pairs.get('playlist', '0') or 0),
                'playlistLength': int(status_pairs.get('playlistlength', '0') or 0),
                'songPosition': int(status_pairs['song']) + 1 if 'song' in status_pairs else 0,
                'songId': int(status_pairs['songid']) if 'songid' in status_pairs else -1,
                'bitrate': bitrate_raw if bitrate_raw > 0 else None,
                'audio': status_pairs.get('audio', ''),
                'playbackError': status_pairs.get('error', ''),
                'song': song,
                'artUrl': art_url
            }
        finally:
            try:
                reader.close()
            finally:
                sock.close()

    def queue(self, target=''):
        parts = (target or '').split(':', 3)
        try:
            offset = int(parts[0]) if len(parts) > 0 and parts[0] != '' else -1
            limit = int(parts[1]) if len(parts) > 1 and parts[1] != '' else 100
        except ValueError:
            raise IntegrationError('Queue offset and limit must be integers.') from None
        limit = max(1, min(MAX_QUEUE_LIMIT, limit))
        mode = parts[2] if len(parts) > 2 and parts[2] in ('replace', 'append', 'prepend', 'sync') else 'replace'
        query = (parts[3] if len(parts) > 3 else '').strip()

        sock, reader = self._connect()
        try:
            status = dict(self._execute(sock, reader, 'status'))
            total = int(status.get('playlistlength', '0') or 0)
            version = int(status.get('playlist', '0') or 0)
            cur_pos = int(status.get('song', '0') or 0)
            if total <= 0:
                return {
                    'ok': True,
                    'action': 'queue',
                    'playlistVersion': version,
                    'total': 0,
                    'matched': 0,
                    'offset': 0,
                    'limit': limit,
                    'mode': mode,
                    'query': query,
                    'items': []
                }
            if not query:
                if offset < 0:
                    offset = max(0, min(max(0, total - limit), cur_pos - limit // 4))
                elif mode == 'append':
                    offset = max(0, min(offset, total))
                else:
                    offset = max(0, min(offset, max(0, total - 1)))
                end = min(total, offset + limit)
                pairs = self._execute(sock, reader, f'playlistinfo {offset}:{end}') if offset < end else []
                items = parse_tracks(pairs)
                return {
                    'ok': True,
                    'action': 'queue',
                    'playlistVersion': version,
                    'total': total,
                    'matched': total,
                    'offset': offset,
                    'limit': limit,
                    'mode': mode,
                    'query': '',
                    'items': items
                }
            needle = query.lower()
            all_tracks = parse_tracks(self._execute(sock, reader, 'playlistinfo'))
            matched_tracks = [
                t for t in all_tracks
                if needle in t['title'].lower()
                or needle in t['artist'].lower()
                or needle in t['album'].lower()
                or needle in t['file'].lower()
                or needle == str(t['pos'] + 1)
            ]
            matched_count = len(matched_tracks)
            if offset < 0:
                offset = 0
            elif mode == 'append':
                offset = max(0, min(offset, matched_count))
            else:
                offset = max(0, min(offset, max(0, matched_count - 1)))
            return {
                'ok': True,
                'action': 'queue',
                'playlistVersion': version,
                'total': total,
                'matched': matched_count,
                'offset': offset,
                'limit': limit,
                'mode': mode,
                'query': query,
                'items': matched_tracks[offset:offset + limit]
            }
        finally:
            try:
                reader.close()
            finally:
                sock.close()

    def library(self, target='', fetch_art=True):
        spec = {}
        if target:
            try:
                spec = json.loads(target)
                if not isinstance(spec, dict):
                    spec = {}
            except ValueError:
                raise IntegrationError('Library query target must be valid JSON.') from None

        scope = str(spec.get('scope') or 'albums').lower()
        if scope not in ('albums', 'tracks', 'artists', 'genres'):
            scope = 'albums'
        mode = str(spec.get('mode') or 'replace').lower()
        if mode not in ('replace', 'append', 'prepend', 'sync'):
            mode = 'replace'
        try:
            offset = max(0, int(spec.get('offset', 0) or 0))
            limit = max(1, min(MAX_LIBRARY_LIMIT, int(spec.get('limit', 90) or 90)))
        except ValueError:
            raise IntegrationError('Library offset and limit must be integers.') from None

        raw_query = str(spec.get('query') or '').strip()
        free_text, inline_tokens = parse_inline_query(raw_query)
        genre = str(spec.get('genre') or inline_tokens['genre'] or '').strip()
        artist = str(spec.get('artist') or inline_tokens['artist'] or '').strip()
        album = str(spec.get('album') or inline_tokens['album'] or '').strip()
        year = str(spec.get('year') or inline_tokens['year'] or '').strip()

        sock, reader = self._connect()
        try:
            genres_list = self._list_genres(sock, reader)
            tracks = self._query_tracks(
                sock,
                reader,
                genre=genre,
                artist=artist,
                album=album,
                year=year,
                free_text=free_text
            )
            if not genres_list and tracks:
                genres_list = sorted({t['genre'] for t in tracks if t.get('genre')}, key=lambda s: s.lower())

            if scope == 'genres':
                genre_map = {}
                for t in tracks:
                    g_name = t.get('genre') or 'Unknown Genre'
                    entry = genre_map.get(g_name)
                    if entry is None:
                        entry = {
                            'kind': 'genre',
                            'title': g_name,
                            'subtitle': '',
                            'artist': '',
                            'album': '',
                            'genre': '' if g_name == 'Unknown Genre' else g_name,
                            'date': '',
                            'file': t.get('file', ''),
                            'duration': 0.0,
                            'trackCount': 0,
                            'albumsSet': set(),
                            'artUrl': ''
                        }
                        genre_map[g_name] = entry
                    entry['trackCount'] += 1
                    entry['duration'] += t.get('duration', 0.0)
                    if t.get('album'):
                        entry['albumsSet'].add(t['album'])

                # Include genres from `list Genre` if no artist/album/year filter excluded them
                if not artist and not album and not year:
                    for g_name in genres_list:
                        if genre and g_name.lower() != genre.lower():
                            continue
                        if free_text and not all(w in g_name.lower() for w in free_text.lower().split()):
                            continue
                        if g_name not in genre_map:
                            genre_map[g_name] = {
                                'kind': 'genre',
                                'title': g_name,
                                'subtitle': 'Genre',
                                'artist': '',
                                'album': '',
                                'genre': g_name,
                                'date': '',
                                'file': '',
                                'duration': 0.0,
                                'trackCount': 0,
                                'albumsSet': set(),
                                'artUrl': ''
                            }

                all_items = sorted(genre_map.values(), key=lambda x: (x['title'] == 'Unknown Genre', x['title'].lower()))
                for item in all_items:
                    album_cnt = len(item.pop('albumsSet', set()))
                    parts = []
                    if album_cnt > 0:
                        parts.append(f'{album_cnt} album' + ('s' if album_cnt != 1 else ''))
                    if item['trackCount'] > 0:
                        parts.append(f"{item['trackCount']} track" + ('s' if item['trackCount'] != 1 else ''))
                    item['subtitle'] = ' · '.join(parts) if parts else 'Genre'
                    item['albumCount'] = album_cnt

            elif scope == 'artists':
                artist_map = {}
                for t in tracks:
                    a_name = t.get('albumArtist') or t.get('artist') or 'Unknown Artist'
                    entry = artist_map.get(a_name)
                    if entry is None:
                        entry = {
                            'kind': 'artist',
                            'title': a_name,
                            'subtitle': '',
                            'artist': '' if a_name == 'Unknown Artist' else a_name,
                            'albumArtist': '' if a_name == 'Unknown Artist' else a_name,
                            'album': t.get('album', ''),
                            'genre': t.get('genre', ''),
                            'date': '',
                            'file': t.get('file', ''),
                            'duration': 0.0,
                            'trackCount': 0,
                            'albumsSet': set(),
                            'artUrl': ''
                        }
                        artist_map[a_name] = entry
                    entry['trackCount'] += 1
                    entry['duration'] += t.get('duration', 0.0)
                    if t.get('album'):
                        entry['albumsSet'].add(t['album'])

                all_items = sorted(artist_map.values(), key=lambda x: (x['title'] == 'Unknown Artist', x['title'].lower()))
                for item in all_items:
                    album_cnt = len(item.pop('albumsSet', set()))
                    parts = []
                    if album_cnt > 0:
                        parts.append(f'{album_cnt} album' + ('s' if album_cnt != 1 else ''))
                    if item['trackCount'] > 0:
                        parts.append(f"{item['trackCount']} track" + ('s' if item['trackCount'] != 1 else ''))
                    item['subtitle'] = ' · '.join(parts) if parts else 'Artist'
                    item['albumCount'] = album_cnt

            elif scope == 'albums':
                album_map = {}
                for t in tracks:
                    alb_name = t.get('album') or 'Singles & Unassigned'
                    alb_artist = t.get('albumArtist') or t.get('artist') or 'Unknown Artist'
                    key = (alb_name.lower(), alb_artist.lower())
                    entry = album_map.get(key)
                    if entry is None:
                        entry = {
                            'kind': 'album',
                            'title': alb_name,
                            'subtitle': alb_artist,
                            'artist': '' if alb_artist == 'Unknown Artist' else alb_artist,
                            'albumArtist': '' if alb_artist == 'Unknown Artist' else alb_artist,
                            'album': '' if alb_name == 'Singles & Unassigned' else alb_name,
                            'genre': t.get('genre', ''),
                            'date': t.get('date', ''),
                            'file': t.get('file', ''),
                            'duration': 0.0,
                            'trackCount': 0,
                            'albumCount': 1,
                            'artUrl': ''
                        }
                        album_map[key] = entry
                    entry['trackCount'] += 1
                    entry['duration'] += t.get('duration', 0.0)
                    if not entry['date'] and t.get('date'):
                        entry['date'] = t['date']
                    if not entry['genre'] and t.get('genre'):
                        entry['genre'] = t['genre']
                    if not entry['file'] and t.get('file'):
                        entry['file'] = t['file']

                all_items = sorted(
                    album_map.values(),
                    key=lambda x: (x['title'] == 'Singles & Unassigned', x['title'].lower(), x['subtitle'].lower())
                )

            else:
                # scope == 'tracks'
                all_items = []
                for t in tracks:
                    sub_parts = []
                    if t.get('artist'):
                        sub_parts.append(t['artist'])
                    if t.get('album'):
                        sub_parts.append(t['album'])
                    all_items.append({
                        'kind': 'track',
                        'title': t['title'],
                        'subtitle': ' · '.join(sub_parts) if sub_parts else t['file'],
                        'artist': t.get('artist', ''),
                        'albumArtist': t.get('albumArtist', ''),
                        'album': t.get('album', ''),
                        'genre': t.get('genre', ''),
                        'date': t.get('date', ''),
                        'file': t['file'],
                        'duration': t.get('duration', 0.0),
                        'trackCount': 1,
                        'albumCount': 0,
                        'artUrl': ''
                    })

            matched_count = len(all_items)
            if mode == 'append':
                offset = max(0, min(offset, matched_count))
            else:
                offset = max(0, min(offset, max(0, matched_count - 1))) if matched_count > 0 else 0
            sliced = all_items[offset:offset + limit]

            has_uncached_art = False
            if fetch_art and sliced:
                fetched_network = 0
                album_art_memo = {}
                for item in sliced:
                    sample_uri = item.get('file', '')
                    if not sample_uri:
                        continue
                    item_album = item.get('album', '')
                    item_album_artist = item.get('albumArtist', '') or item.get('artist', '')
                    cache_key = album_art_cache_key(
                        uri=sample_uri,
                        album=item_album,
                        album_artist=item_album_artist,
                        artist=item.get('artist', '')
                    )
                    if cache_key in album_art_memo:
                        item['artUrl'] = album_art_memo[cache_key]
                        continue
                    cached_uri = self._cached_art_uri(
                        uri=sample_uri,
                        album=item_album,
                        album_artist=item_album_artist,
                        artist=item.get('artist', '')
                    )
                    if cached_uri is not None:
                        item['artUrl'] = cached_uri
                        album_art_memo[cache_key] = cached_uri
                    elif scope in ('albums', 'tracks', 'artists'):
                        if fetched_network < MAX_ALBUM_ART_FETCH_PER_CALL:
                            resolved_uri = self._resolve_art(
                                sock,
                                reader,
                                sample_uri,
                                album=item_album,
                                album_artist=item_album_artist,
                                artist=item.get('artist', '')
                            )
                            item['artUrl'] = resolved_uri
                            album_art_memo[cache_key] = resolved_uri
                            fetched_network += 1
                        else:
                            has_uncached_art = True

            return {
                'ok': True,
                'action': 'library',
                'scope': scope,
                'mode': mode,
                'query': raw_query,
                'genre': genre,
                'artist': artist,
                'album': album,
                'year': year,
                'total': matched_count,
                'matched': matched_count,
                'offset': offset,
                'limit': limit,
                'hasUncachedArt': has_uncached_art,
                'genres': genres_list,
                'items': sliced
            }
        finally:
            try:
                reader.close()
            finally:
                sock.close()

    def action(self, action, target=''):
        sock, reader = self._connect()
        try:
            if action == 'toggle':
                status = dict(self._execute(sock, reader, 'status'))
                state = status.get('state', 'stop')
                if state == 'play':
                    self._execute(sock, reader, 'pause 1')
                elif state == 'pause':
                    self._execute(sock, reader, 'pause 0')
                else:
                    self._execute(sock, reader, 'play')
            elif action == 'play':
                self._execute(sock, reader, 'play')
            elif action == 'pause':
                self._execute(sock, reader, 'pause 1')
            elif action == 'resume':
                self._execute(sock, reader, 'pause 0')
            elif action == 'stop':
                self._execute(sock, reader, 'stop')
            elif action in ('next', 'previous', 'clearerror', 'update'):
                self._execute(sock, reader, action)
            elif action == 'seek':
                try:
                    seconds = float(target)
                except ValueError:
                    raise IntegrationError('Seek position must be a number.') from None
                if seconds < 0 or seconds != seconds or seconds == float('inf'):
                    raise IntegrationError('Seek position must be non-negative.')
                self._execute(sock, reader, f'seekcur {seconds:.2f}')
            elif action == 'volume':
                try:
                    vol = int(round(float(target)))
                except ValueError:
                    raise IntegrationError('Volume must be an integer between 0 and 100.') from None
                if not (0 <= vol <= 100):
                    raise IntegrationError('Volume must be between 0 and 100.')
                self._execute(sock, reader, f'setvol {vol}')
            elif action in ('repeat', 'random'):
                if target in ('0', '1'):
                    val = target
                else:
                    status = dict(self._execute(sock, reader, 'status'))
                    val = '0' if status.get(action) == '1' else '1'
                self._execute(sock, reader, f'{action} {val}')
            elif action == 'single':
                if target in ('0', '1', 'oneshot'):
                    val = target
                else:
                    status = dict(self._execute(sock, reader, 'status'))
                    cur = status.get('single', '0')
                    val = '1' if cur == '0' else ('oneshot' if cur == '1' else '0')
                self._execute(sock, reader, f'single {val}')
            elif action == 'consume':
                if target in ('0', '1'):
                    val = target
                else:
                    status = dict(self._execute(sock, reader, 'status'))
                    val = '0' if status.get('consume') in ('1', 'oneshot') else '1'
                self._execute(sock, reader, f'consume {val}')
            elif action in ('play-id', 'delete-id'):
                try:
                    song_id = int(target, 10)
                except ValueError:
                    raise IntegrationError('A valid track ID is required.') from None
                if song_id < 0:
                    raise IntegrationError('Track ID must be non-negative.')
                cmd = 'playid' if action == 'play-id' else 'deleteid'
                self._execute(sock, reader, f'{cmd} {song_id}')
            elif action == 'move-id':
                id_str, sep, pos_str = (target or '').partition(':')
                if not sep:
                    raise IntegrationError('Move target requires id:position.')
                try:
                    song_id = int(id_str, 10)
                    to_pos = int(pos_str, 10)
                except ValueError:
                    raise IntegrationError('Move ID and position must be integers.') from None
                if song_id < 0 or to_pos < 0:
                    raise IntegrationError('Move ID and position must be non-negative.')
                self._execute(sock, reader, f'moveid {song_id} {to_pos}')
            elif action == 'move-next':
                try:
                    song_id = int(target, 10)
                except ValueError:
                    raise IntegrationError('A valid track ID is required.') from None
                if song_id < 0:
                    raise IntegrationError('Track ID must be non-negative.')
                status = dict(self._execute(sock, reader, 'status'))
                total = int(status.get('playlistlength', '0') or 0)
                if total <= 1:
                    return
                cur_pos = int(status.get('song', '0') or 0)
                song_info = dict(self._execute(sock, reader, f'playlistid {song_id}'))
                from_pos = int(song_info.get('Pos', cur_pos))
                if from_pos == cur_pos:
                    return
                to_pos = min(total - 1, cur_pos + 1) if from_pos > cur_pos else max(0, cur_pos)
                if to_pos != from_pos:
                    self._execute(sock, reader, f'moveid {song_id} {to_pos}')
            elif action == 'shuffle-queue':
                self._execute(sock, reader, 'shuffle')
            elif action == 'clear-queue':
                self._execute(sock, reader, 'clear')
            elif action == 'add-uri':
                if not target:
                    raise IntegrationError('Track URI is required.')
                self._execute(sock, reader, f'add {quote_arg(target)}')
            elif action == 'play-uri':
                if not target:
                    raise IntegrationError('Track URI is required.')
                res = dict(self._execute(sock, reader, f'addid {quote_arg(target)}'))
                song_id = res.get('Id')
                if song_id is not None:
                    self._execute(sock, reader, f'playid {int(song_id)}')
                else:
                    self._execute(sock, reader, 'play')
            elif action == 'insert-uri-next':
                if not target:
                    raise IntegrationError('Track URI is required.')
                status = dict(self._execute(sock, reader, 'status'))
                total = int(status.get('playlistlength', '0') or 0)
                if 'song' in status and total > 0:
                    next_pos = min(total, int(status['song']) + 1)
                    self._execute(sock, reader, f'addid {quote_arg(target)} {next_pos}')
                else:
                    self._execute(sock, reader, f'addid {quote_arg(target)}')
            elif action in ('add-filter', 'play-filter'):
                spec = {}
                if target:
                    try:
                        spec = json.loads(target)
                        if not isinstance(spec, dict):
                            spec = {}
                    except ValueError:
                        raise IntegrationError('Filter action target must be valid JSON.') from None
                raw_query = str(spec.get('query') or '').strip()
                free_text, inline_tokens = parse_inline_query(raw_query)
                genre = str(spec.get('genre') or inline_tokens['genre'] or '').strip()
                artist = str(spec.get('artist') or inline_tokens['artist'] or '').strip()
                album = str(spec.get('album') or inline_tokens['album'] or '').strip()
                year = str(spec.get('year') or inline_tokens['year'] or '').strip()
                tracks = self._query_tracks(
                    sock,
                    reader,
                    genre=genre,
                    artist=artist,
                    album=album,
                    year=year,
                    free_text=free_text
                )
                if not tracks:
                    raise IntegrationError('No matching tracks to add.')
                first_id = None
                for idx, t in enumerate(tracks):
                    uri = t.get('file', '')
                    if not uri:
                        continue
                    if idx == 0 and action == 'play-filter':
                        added = dict(self._execute(sock, reader, f'addid {quote_arg(uri)}'))
                        if 'Id' in added:
                            first_id = int(added['Id'])
                    else:
                        self._execute(sock, reader, f'add {quote_arg(uri)}')
                if action == 'play-filter':
                    if first_id is not None:
                        self._execute(sock, reader, f'playid {first_id}')
                    else:
                        self._execute(sock, reader, 'play')
            else:
                raise IntegrationError('Unknown action.')
        finally:
            try:
                reader.close()
            finally:
                sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--address', default='')
    parser.add_argument('--password-file', default='')
    parser.add_argument('--no-art', action='store_true')
    parser.add_argument('--action', default='snapshot')
    parser.add_argument('--target', default='')
    args = parser.parse_args()
    try:
        client = Client(args.address, load_password(args.password_file))
        if args.action == 'snapshot':
            result = client.snapshot(fetch_art=not args.no_art)
        elif args.action == 'queue':
            result = client.queue(args.target)
        elif args.action == 'library':
            result = client.library(args.target, fetch_art=not args.no_art)
        else:
            client.action(args.action, args.target)
            result = {'ok': True, 'action': args.action}
    except IntegrationError as exc:
        result = {'ok': False, 'error': str(exc)}
    except OSError:
        result = {'ok': False, 'error': 'Cannot read the password file. Check its path and permissions.'}
    except Exception:
        result = {'ok': False, 'error': 'Unexpected MPD response. Check server compatibility.'}
    print(json.dumps(result))


if __name__ == '__main__':
    main()
