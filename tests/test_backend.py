import importlib.util
import json
from pathlib import Path
import socketserver
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location('backend', Path(__file__).resolve().parents[1] / 'backend.py')
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


JPEG_SAMPLE = b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9'


class MockMPDHandler(socketserver.StreamRequestHandler):
    calls = []
    state = 'play'
    repeat = '0'
    random = '1'
    single = 'oneshot'
    consume = '0'
    volume = '75'
    require_password = ''
    art_payload = JPEG_SAMPLE
    fail_readpicture = False

    def handle(self):
        self.wfile.write(b'OK MPD 0.23.5\n')
        self.wfile.flush()
        authed = not self.require_password
        while True:
            raw = self.rfile.readline()
            if not raw:
                break
            cmd = raw.decode('utf-8').rstrip('\r\n')
            self.calls.append(cmd)
            if cmd.startswith('password '):
                expected = f'password "{self.require_password}"'
                if cmd == expected:
                    authed = True
                    self.wfile.write(b'OK\n')
                else:
                    self.wfile.write(b'ACK [3@0] {password} incorrect password\n')
                self.wfile.flush()
                continue
            if not authed:
                self.wfile.write(b'ACK [4@0] {' + cmd.split()[0].encode() + b'} you don\'t have permission\n')
                self.wfile.flush()
                continue
            if cmd == 'status':
                lines = [
                    f'volume: {self.volume}',
                    f'repeat: {self.repeat}',
                    f'random: {self.random}',
                    f'single: {self.single}',
                    f'consume: {self.consume}',
                    f'state: {self.state}',
                    'playlist: 14',
                    'song: 2',
                    'songid: 102',
                    'playlistlength: 8',
                    'elapsed: 42.5',
                    'duration: 180.0',
                    'bitrate: 320',
                    'audio: 44100:16:2',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(lines).encode('utf-8'))
            elif cmd == 'currentsong':
                lines = [
                    'file: Jazz/Blue Train.flac',
                    'Title: Blue Train',
                    'Artist: John Coltrane',
                    'Album: Blue Train',
                    'Date: 1957',
                    'Id: 102',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(lines).encode('utf-8'))
            elif cmd.startswith('playlistinfo'):
                parts = cmd.split(' ', 1)
                start, end = 0, 8
                if len(parts) > 1 and ':' in parts[1]:
                    s_str, e_str = parts[1].split(':', 1)
                    start, end = int(s_str), int(e_str)
                out = []
                for pos in range(start, min(8, end)):
                    out.extend([
                        f'file: Track_{pos}.flac',
                        f'Title: Song {pos}',
                        f'Artist: Artist {pos % 2}',
                        'Album: Test Album',
                        'duration: 120.5',
                        f'Pos: {pos}',
                        f'Id: {100 + pos}'
                    ])
                out.append('OK\n')
                self.wfile.write('\n'.join(out).encode('utf-8'))
            elif cmd.startswith('playlistid '):
                song_id = int(cmd.split(' ', 1)[1])
                pos = max(0, song_id - 100)
                lines = [
                    f'file: Track_{pos}.flac',
                    f'Pos: {pos}',
                    f'Id: {song_id}',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(lines).encode('utf-8'))
            elif cmd == 'list Genre':
                lines = [
                    'Genre: Electronic',
                    'Genre: Jazz',
                    'Genre: Rock',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(lines).encode('utf-8'))
            elif cmd.startswith('search ') or cmd == 'listallinfo':
                out = [
                    'file: Electronic/Eclipse/01_Monolith.flac',
                    'Title: Monolith',
                    'Artist: meganeko',
                    'AlbumArtist: meganeko',
                    'Album: Eclipse',
                    'Genre: Electronic',
                    'Date: 2023',
                    'duration: 308.0',
                    'file: Electronic/Eclipse/02_Feral.flac',
                    'Title: Feral',
                    'Artist: meganeko',
                    'AlbumArtist: meganeko',
                    'Album: Eclipse',
                    'Genre: Electronic',
                    'Date: 2023',
                    'duration: 267.0',
                    'file: Jazz/Blue_Train.flac',
                    'Title: Blue Train',
                    'Artist: John Coltrane',
                    'AlbumArtist: John Coltrane',
                    'Album: Blue Train',
                    'Genre: Jazz',
                    'Date: 1957',
                    'duration: 642.0',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(out).encode('utf-8'))
            elif cmd.startswith('addid '):
                self.wfile.write(b'Id: 501\nOK\n')
            elif cmd.startswith('readpicture '):
                if self.fail_readpicture or not self.art_payload:
                    self.wfile.write(b'ACK [50@0] {readpicture} No picture\n')
                else:
                    header = f'size: {len(self.art_payload)}\nbinary: {len(self.art_payload)}\n'.encode('utf-8')
                    self.wfile.write(header + self.art_payload + b'\nOK\n')
            elif cmd.startswith('albumart '):
                if not self.art_payload:
                    self.wfile.write(b'ACK [50@0] {albumart} No file exists\n')
                else:
                    header = f'size: {len(self.art_payload)}\nbinary: {len(self.art_payload)}\n'.encode('utf-8')
                    self.wfile.write(header + self.art_payload + b'\nOK\n')
            else:
                self.wfile.write(b'OK\n')
            self.wfile.flush()


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True


class BackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadedTCPServer(('127.0.0.1', 0), MockMPDHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.address = f'127.0.0.1:{cls.server.server_address[1]}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        MockMPDHandler.calls.clear()
        MockMPDHandler.state = 'play'
        MockMPDHandler.repeat = '0'
        MockMPDHandler.random = '1'
        MockMPDHandler.single = 'oneshot'
        MockMPDHandler.consume = '0'
        MockMPDHandler.volume = '75'
        MockMPDHandler.require_password = ''
        MockMPDHandler.art_payload = JPEG_SAMPLE
        MockMPDHandler.fail_readpicture = False

    def test_snapshot_and_art_caching(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = backend.Client(self.address, cache_dir=tmp)
            snap = client.snapshot()
            self.assertTrue(snap['ok'])
            self.assertEqual(snap['state'], 'play')
            self.assertEqual(snap['volume'], 75)
            self.assertFalse(snap['repeat'])
            self.assertTrue(snap['random'])
            self.assertEqual(snap['single'], 'oneshot')
            self.assertEqual(snap['song']['title'], 'Blue Train')
            self.assertEqual(snap['song']['artist'], 'John Coltrane')
            self.assertEqual(snap['songPosition'], 3)
            self.assertEqual(snap['songId'], 102)
            self.assertEqual(snap['playlistVersion'], 14)
            self.assertEqual(snap['playlistLength'], 8)
            self.assertTrue(snap['artUrl'].startswith('file://'))
            self.assertTrue(any(c.startswith('readpicture ') for c in MockMPDHandler.calls))
            # Second snapshot uses cached art without querying readpicture again.
            MockMPDHandler.calls.clear()
            snap2 = client.snapshot()
            self.assertEqual(snap2['artUrl'], snap['artUrl'])
            self.assertFalse(any(c.startswith('readpicture ') for c in MockMPDHandler.calls))

    def test_albumart_fallback_when_readpicture_fails(self):
        MockMPDHandler.fail_readpicture = True
        with tempfile.TemporaryDirectory() as tmp:
            client = backend.Client(self.address, cache_dir=tmp)
            snap = client.snapshot()
            self.assertTrue(snap['artUrl'].startswith('file://'))
            self.assertTrue(any(c.startswith('albumart ') for c in MockMPDHandler.calls))

    def test_toggle_states_and_transport(self):
        client = backend.Client(self.address)
        client.action('toggle')
        self.assertEqual(MockMPDHandler.calls[-1], 'pause 1')
        MockMPDHandler.state = 'pause'
        client.action('toggle')
        self.assertEqual(MockMPDHandler.calls[-1], 'pause 0')
        MockMPDHandler.state = 'stop'
        client.action('toggle')
        self.assertEqual(MockMPDHandler.calls[-1], 'play')
        client.action('seek', '95.4')
        self.assertEqual(MockMPDHandler.calls[-1], 'seekcur 95.40')
        client.action('volume', '40')
        self.assertEqual(MockMPDHandler.calls[-1], 'setvol 40')

    def test_queue_windowing_and_search(self):
        client = backend.Client(self.address)
        q = client.queue('2:3:replace:')
        self.assertTrue(q['ok'])
        self.assertEqual(q['total'], 8)
        self.assertEqual(q['matched'], 8)
        self.assertEqual(q['offset'], 2)
        self.assertEqual(len(q['items']), 3)
        self.assertEqual(q['items'][0]['id'], 102)
        self.assertIn('playlistinfo 2:5', MockMPDHandler.calls)

        # Filtered query
        qf = client.queue('0:10:replace:Artist 1')
        self.assertEqual(qf['matched'], 4)
        self.assertTrue(all(item['artist'] == 'Artist 1' for item in qf['items']))

    def test_queue_mutations(self):
        client = backend.Client(self.address)
        client.action('play-id', '104')
        self.assertEqual(MockMPDHandler.calls[-1], 'playid 104')
        client.action('delete-id', '105')
        self.assertEqual(MockMPDHandler.calls[-1], 'deleteid 105')
        client.action('move-id', '106:1')
        self.assertEqual(MockMPDHandler.calls[-1], 'moveid 106 1')
        # Move track after current song (song is at pos 2; moving id 106 from pos 6 -> pos 3)
        client.action('move-next', '106')
        self.assertEqual(MockMPDHandler.calls[-1], 'moveid 106 3')
        # Moving id 100 from pos 0 (before pos 2) -> pos 2 so it lands right after current song
        client.action('move-next', '100')
        self.assertEqual(MockMPDHandler.calls[-1], 'moveid 100 2')
        client.action('shuffle-queue')
        self.assertEqual(MockMPDHandler.calls[-1], 'shuffle')
        client.action('clear-queue')
        self.assertEqual(MockMPDHandler.calls[-1], 'clear')

    def test_mode_cycling(self):
        client = backend.Client(self.address)
        MockMPDHandler.single = '0'
        client.action('single')
        self.assertEqual(MockMPDHandler.calls[-1], 'single 1')
        MockMPDHandler.single = '1'
        client.action('single')
        self.assertEqual(MockMPDHandler.calls[-1], 'single oneshot')
        MockMPDHandler.single = 'oneshot'
        client.action('single')
        self.assertEqual(MockMPDHandler.calls[-1], 'single 0')

    def test_password_auth_and_sanitization(self):
        MockMPDHandler.require_password = 'secret-mpd-password'
        with tempfile.TemporaryDirectory() as tmp:
            pw_file = Path(tmp) / 'pw'
            pw_file.write_text('secret-mpd-password\n')
            pw = backend.load_password(str(pw_file))
            client = backend.Client(self.address, pw, cache_dir=tmp)
            snap = client.snapshot(fetch_art=False)
            self.assertTrue(snap['ok'])
            self.assertNotIn('secret-mpd-password', json.dumps(snap))
        with self.assertRaisesRegex(backend.IntegrationError, 'Authentication failed'):
            backend.Client(self.address, 'wrong-password').snapshot(fetch_art=False)

    def test_remote_password_rejected(self):
        with self.assertRaisesRegex(backend.IntegrationError, 'non-loopback'):
            backend.Client('192.0.2.10:6600', 'secret')

    def test_endpoint_and_input_validation(self):
        self.assertEqual(backend.resolve_endpoint('[::1]:6600'), ('tcp', ('::1', 6600), True))
        self.assertEqual(backend.resolve_endpoint('/run/mpd/socket'), ('unix', '/run/mpd/socket', True))
        for bad in ['http://localhost:6600', 'user@localhost:6600', 'localhost:99999', 'localhost:abc', '::1:6600']:
            with self.assertRaises(backend.IntegrationError):
                backend.resolve_endpoint(bad)
        with self.assertRaises(backend.IntegrationError):
            backend.quote_arg('bad\ninjection')

    def test_library_scopes_and_filters(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = backend.Client(self.address, cache_dir=tmp)
            # 1. Albums scope
            res_albums = client.library(json.dumps({'scope': 'albums', 'offset': 0, 'limit': 50}))
            self.assertTrue(res_albums['ok'])
            self.assertEqual(res_albums['matched'], 2)
            self.assertEqual(res_albums['genres'], ['Electronic', 'Jazz', 'Rock'])
            titles = [item['title'] for item in res_albums['items']]
            self.assertEqual(titles, ['Blue Train', 'Eclipse'])
            eclipse = [item for item in res_albums['items'] if item['title'] == 'Eclipse'][0]
            self.assertEqual(eclipse['trackCount'], 2)
            self.assertEqual(eclipse['artist'], 'meganeko')
            self.assertTrue(eclipse['artUrl'].startswith('file://'))

            # 2. Genres scope
            res_genres = client.library(json.dumps({'scope': 'genres'}))
            self.assertEqual([g['title'] for g in res_genres['items']], ['Electronic', 'Jazz', 'Rock'])

            # 3. Artists scope with inline genre token
            res_artists = client.library(json.dumps({'scope': 'artists', 'query': 'genre:Electronic'}))
            self.assertEqual(res_artists['matched'], 1)
            self.assertEqual(res_artists['items'][0]['title'], 'meganeko')
            self.assertEqual(res_artists['items'][0]['albumCount'], 1)

            # 4. Tracks scope with multi-facet filter + shared album art cache
            MockMPDHandler.calls.clear()
            res_tracks = client.library(json.dumps({
                'scope': 'tracks',
                'genre': 'Electronic',
                'artist': 'meganeko',
                'album': 'Eclipse',
                'query': 'Feral'
            }))
            self.assertEqual(res_tracks['matched'], 1)
            self.assertEqual(res_tracks['items'][0]['title'], 'Feral')
            # Feral shares Eclipse's cached album cover without needing another readpicture call!
            self.assertEqual(res_tracks['items'][0]['artUrl'], eclipse['artUrl'])
            self.assertFalse(any(c.startswith('readpicture ') for c in MockMPDHandler.calls))

    def test_library_queue_actions(self):
        client = backend.Client(self.address)
        client.action('add-uri', 'Electronic/Eclipse/01_Monolith.flac')
        self.assertEqual(MockMPDHandler.calls[-1], 'add "Electronic/Eclipse/01_Monolith.flac"')

        client.action('play-uri', 'Electronic/Eclipse/01_Monolith.flac')
        self.assertIn('addid "Electronic/Eclipse/01_Monolith.flac"', MockMPDHandler.calls)
        self.assertEqual(MockMPDHandler.calls[-1], 'playid 501')

        client.action('insert-uri-next', 'Electronic/Eclipse/02_Feral.flac')
        self.assertEqual(MockMPDHandler.calls[-1], 'addid "Electronic/Eclipse/02_Feral.flac" 3')

        client.action('play-filter', json.dumps({'genre': 'Electronic', 'album': 'Eclipse'}))
        self.assertIn('addid "Electronic/Eclipse/01_Monolith.flac"', MockMPDHandler.calls)
        self.assertIn('add "Electronic/Eclipse/02_Feral.flac"', MockMPDHandler.calls)
        self.assertEqual(MockMPDHandler.calls[-1], 'playid 501')


if __name__ == '__main__':
    unittest.main()
