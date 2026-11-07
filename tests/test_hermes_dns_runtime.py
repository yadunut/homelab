"""Optional real-CoreDNS split-forward test using local DNS fixtures only.

Set COREDNS_BINARY to the binary extracted from the pinned image. This does not
exercise Tailscale, cluster DNS64, or Kubernetes; upstream replies are fixtures.
"""
import ipaddress
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def unused_port():
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
        sock.bind(("::1", 0))
        return sock.getsockname()[1]


def question(name):
    wire = b"".join(bytes([len(part)]) + part.encode() for part in name.split(".")) + b"\0"
    return struct.pack("!6H", 1234, 0x100, 1, 0, 0, 0) + wire + struct.pack("!2H", 28, 1)


def reply(server, data):
    end = 12
    labels = []
    while data[end]:
        size = data[end]
        labels.append(data[end + 1:end + 1 + size].decode())
        end += size + 1
    name = ".".join(labels)
    server.seen.append(name)
    end += 5
    rcode = 3 if name.startswith("missing.") else 2 if name.startswith("broken.") else 0
    answer = b""
    if not rcode:
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, 0, 16) + server.address.packed
    return data[:2] + struct.pack("!5H", 0x8180 | rcode, 1, bool(answer), 0, 0) + data[12:end] + answer


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(reply(self.server, data), self.client_address)


class UDPServer(socketserver.ThreadingUDPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


class TCPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        size = struct.unpack("!H", self.rfile.read(2))[0]
        data = reply(self.server, self.rfile.read(size))
        self.wfile.write(struct.pack("!H", len(data)) + data)


class TCPServer(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


@unittest.skipUnless(os.environ.get("COREDNS_BINARY"), "set COREDNS_BINARY for real resolver test")
class HermesDNSRuntimeTest(unittest.TestCase):
    def test_split_forward_preserves_answers_and_does_not_fail_open(self):
        servers = []
        seen = [[], []]
        ports = [unused_port(), unused_port()]
        addresses = [ipaddress.ip_address("fd7a:115c:a1e0::1234"),
                     ipaddress.ip_address("64:ff9b::c000:201")]
        try:
            for i in range(2):
                for cls, handler in [(UDPServer, UDPHandler), (TCPServer, TCPHandler)]:
                    server = cls(("::1", ports[i]), handler)
                    server.seen, server.address = seen[i], addresses[i]
                    servers.append(server)
                    threading.Thread(target=server.serve_forever, daemon=True).start()
            port = unused_port()
            config = (ROOT / "cluster/apps/hermes/tailnet.Corefile").read_text()
            config = config.replace(":53 {", f":{port} {{")
            config = config.replace("[fd7a:115c:a1e0::53]", f"[::1]:{ports[0]}")
            config = config.replace("[fd00:10:97::a]", f"[::1]:{ports[1]}")
            config = config.replace(":18180", f":{unused_port()}").replace(":18181", f":{unused_port()}")
            with tempfile.TemporaryDirectory(prefix="hermes-dns-") as directory:
                path = Path(directory) / "Corefile"
                path.write_text(config)
                with open(Path(directory) / "log", "w+") as log:
                    process = subprocess.Popen([os.environ["COREDNS_BINARY"], "-conf", str(path)], stdout=log, stderr=log)
                    try:
                        for _ in range(50):
                            try:
                                with socket.create_connection(("::1", port), timeout=0.1):
                                    break
                            except OSError:
                                if process.poll() is not None:
                                    log.seek(0)
                                    self.fail(log.read())
                                time.sleep(0.1)
                        else:
                            self.fail("CoreDNS did not listen")
                        for transport in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
                            for name, expected, rcode in [
                                ("bb.tail8dce03.ts.net", 0, 0),
                                ("litellm.litellm.svc.k8s.internal", 1, 0),
                                ("ipv4-only.example", 1, 0),
                                ("not-tail8dce03.ts.net", 1, 0),
                                ("missing.tail8dce03.ts.net", 0, 3),
                                ("broken.tail8dce03.ts.net", 0, 2),
                            ]:
                                with self.subTest(name=name, transport=transport):
                                    with socket.socket(socket.AF_INET6, transport) as sock:
                                        sock.settimeout(4)
                                        sock.connect(("::1", port))
                                        data = question(name)
                                        if transport == socket.SOCK_STREAM:
                                            sock.sendall(struct.pack("!H", len(data)) + data)
                                            stream = sock.makefile("rb")
                                            size = struct.unpack("!H", stream.read(2))[0]
                                            result = stream.read(size)
                                            stream.close()
                                        else:
                                            sock.send(data)
                                            result = sock.recv(4096)
                                    self.assertEqual(result[3] & 15, rcode)
                                    if not rcode:
                                        self.assertEqual(result[-16:], addresses[expected].packed)
                                    self.assertIn(name, seen[expected])
                                    self.assertNotIn(name, seen[1 - expected])
                    finally:
                        process.terminate()
                        process.wait(timeout=10)
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
