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
                    'song: 2',
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
                    'Id: 15',
                    'OK\n'
                ]
                self.wfile.write('\n'.join(lines).encode('utf-8'))
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


if __name__ == '__main__':
    unittest.main()
