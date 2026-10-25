#!/usr/bin/env python3
"""Run a native URL smoke program against owned local HTTP/HTTPS fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import struct
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--host', help='Server IPv4 address reachable by the test executable')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    media = (root / 'Bin/fixtures/markers.wav').read_bytes()
    stop = threading.Event()
    requests = []
    lock = threading.Lock()
    big = 100_000_000
    streaming = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', big + 36, b'WAVE', b'fmt ', 16,
                            1, 1, 24000, 48000, 2, 16, b'data', big)
    streaming += b'\xe8\x03\x18\xfc' * 65536

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_GET(self):
            with lock:
                requests.append(self.path)
            try:
                if self.path == '/delayed-headers':
                    stop.wait(6)
                    return
                if self.path.startswith('/redirect-'):
                    target = https_url + '/media' if self.path == '/redirect-tls' else 'file:///C:/Windows/win.ini'
                    self.send_response(302)
                    self.send_header('Location', target)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                if self.path == '/stall':
                    self.send_response(200)
                    self.send_header('Content-Type', 'audio/wav')
                    self.send_header('Content-Length', str(big + 44))
                    self.end_headers()
                    self.wfile.write(streaming)
                    self.wfile.flush()
                    stop.wait(6)
                    return
                if self.path not in ('/media', '/no-range'):
                    self.send_error(404)
                    return
                start = 0
                ranged = self.path == '/media' and 'Range' in self.headers
                if ranged:
                    start = int(self.headers['Range'].split('=')[1].split('-')[0])
                self.send_response(206 if ranged else 200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', str(len(media) - start))
                if self.path == '/media':
                    self.send_header('Accept-Ranges', 'bytes')
                if ranged:
                    self.send_header('Content-Range', f'bytes {start}-{len(media)-1}/{len(media)}')
                self.end_headers()
                self.wfile.write(media[start:])
            except (BrokenPipeError, ConnectionResetError):
                pass

    host = args.host or '127.0.0.1'
    if not args.host and args.executable.suffix.lower() == '.exe':
        # Windows programs launched from WSL reach the server through its local
        # virtual-interface IPv4 address, without public-network dependencies.
        interfaces = json.loads(subprocess.check_output(['ip', '-j', '-4', 'addr', 'show', 'scope', 'global']))
        host = next(address['local'] for interface in interfaces if interface['ifname'] != 'lo'
                    for address in interface['addr_info'] if address.get('family') == 'inet')
    with tempfile.TemporaryDirectory(prefix='tffmpeg-url-') as directory:
        cert = Path(directory) / 'certificate.pem'
        key = Path(directory) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        http = ThreadingHTTPServer(('0.0.0.0', 0), Handler)
        https = ThreadingHTTPServer(('0.0.0.0', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        https.socket = context.wrap_socket(https.socket, server_side=True)
        https_url = f'https://{host}:{https.server_port}'
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (http, https)]
        for thread in threads:
            thread.start()
        try:
            result = subprocess.run([str(args.executable.resolve()), f'http://{host}:{http.server_port}', https_url],
                                    timeout=45, capture_output=True, text=True, errors='replace')
            print(result.stdout, end='')
            print(result.stderr, end='')
            if result.returncode:
                raise SystemExit(result.returncode)
            assert '/file-must-not-contact-server' not in requests, requests
            assert "Protocol 'file' not on whitelist" in result.stderr, result.stderr
            print('PASS: controlled URL fixture server; local-file factory made no HTTP request; redirect file protocol was denied')
        finally:
            stop.set()
            for server in (http, https):
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()


if __name__ == '__main__':
    main()
