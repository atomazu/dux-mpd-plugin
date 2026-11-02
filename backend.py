#!/usr/bin/env python3
"""One-shot MPD protocol adapter. Secrets never cross the QML/process boundary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket


MAX_ART_BYTES = 5 * 1024 * 1024
MAX_CACHED_ART = 32


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

    def _resolve_art(self, sock, reader, uri):
        if not uri:
            return ''
        digest = hashlib.sha256(uri.encode('utf-8')).hexdigest()[:24]
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(self.cache_dir, 0o700)
            for ext in ('.jpg', '.png', '.webp', '.gif', '.none'):
                cached = self.cache_dir / (digest + ext)
                if cached.is_file():
                    return '' if ext == '.none' else cached.resolve().as_uri()
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
                    art_url = self._resolve_art(sock, reader, song_file)
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
                'playlistLength': int(status_pairs.get('playlistlength', '0') or 0),
                'songPosition': int(status_pairs['song']) + 1 if 'song' in status_pairs else 0,
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
            elif action in ('next', 'previous', 'clearerror'):
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
        if args.action != 'snapshot':
            client.action(args.action, args.target)
            result = {'ok': True, 'action': args.action}
        else:
            result = client.snapshot(fetch_art=not args.no_art)
    except IntegrationError as exc:
        result = {'ok': False, 'error': str(exc)}
    except OSError:
        result = {'ok': False, 'error': 'Cannot read the password file. Check its path and permissions.'}
    except Exception:
        result = {'ok': False, 'error': 'Unexpected MPD response. Check server compatibility.'}
    print(json.dumps(result))


if __name__ == '__main__':
    main()
