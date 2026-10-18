"""Local HTTPS proxy that splits the TLS ClientHello into small TCP segments so
SNI-based ISP filtering doesn't match it. Listens on 127.0.0.1 only.

Hostnames are resolved via 1.1.1.1 directly, skipping the hosts file and ISP DNS.

Usage: python steam_proxy.py [port]   (default 8881)
"""
import asyncio, random, socket, struct, sys

LISTEN = ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8881)
DNS_SERVER = ("1.1.1.1", 53)
_dns_cache = {}

# Served at /proxy.pac: only Steam web hosts go through this proxy, everything else is direct.
# Game downloads (steamcontent / CDN) stay direct.
PAC = f"""function FindProxyForURL(url, host) {{
  if (dnsDomainIs(host, "steampowered.com") || dnsDomainIs(host, "steamcommunity.com") ||
      dnsDomainIs(host, "steamstatic.com") || dnsDomainIs(host, "steamusercontent.com") ||
      host == "steamcdn-a.akamaihd.net")
    return "PROXY {LISTEN[0]}:{LISTEN[1]}; DIRECT";
  return "DIRECT";
}}
"""


def resolve(host):
    """Minimal A-record lookup against DNS_SERVER."""
    if host in _dns_cache:
        return _dns_cache[host]
    qid = random.randint(0, 0xFFFF)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in host.split(".")) + b"\0"
    q += struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(q, DNS_SERVER)
        resp = s.recv(4096)
    finally:
        s.close()
    ancount = struct.unpack(">H", resp[6:8])[0]
    pos = len(q)
    for _ in range(ancount):
        # name is usually a compression pointer
        if resp[pos] & 0xC0 == 0xC0:
            pos += 2
        else:
            while resp[pos]:
                pos += resp[pos] + 1
            pos += 1
        rtype, _, _, rdlen = struct.unpack(">HHIH", resp[pos:pos + 10])
        pos += 10
        if rtype == 1 and rdlen == 4:
            ip = socket.inet_ntoa(resp[pos:pos + 4])
            _dns_cache[host] = ip
            return ip
        pos += rdlen
    raise OSError(f"no A record for {host}")


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def handle(c_reader, c_writer):
    try:
        head = await c_reader.readuntil(b"\r\n\r\n")
        method, target, _ = head.split(b"\r\n", 1)[0].decode().split(" ", 2)
        if method == "GET" and target == "/proxy.pac":
            body = PAC.encode()
            c_writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                           b"Content-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            await c_writer.drain()
            c_writer.close()
            return
        if method != "CONNECT":
            c_writer.write(b"HTTP/1.1 405 Only CONNECT supported\r\n\r\n")
            await c_writer.drain()
            c_writer.close()
            return
        host, port = target.rsplit(":", 1)
        ip = await asyncio.get_running_loop().run_in_executor(None, resolve, host)
        s_reader, s_writer = await asyncio.open_connection(ip, int(port))
        s_writer.get_extra_info("socket").setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        c_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await c_writer.drain()

        # split the first client packet (the ClientHello) into small segments
        first = await c_reader.read(65536)
        for i in range(0, len(first), 8):
            s_writer.write(first[i:i + 8])
            await s_writer.drain()
            await asyncio.sleep(0.002)

        await asyncio.gather(pipe(c_reader, s_writer), pipe(s_reader, c_writer))
    except Exception as e:
        print(f"error: {e}", flush=True)
        c_writer.close()


async def main():
    server = await asyncio.start_server(handle, *LISTEN)
    print(f"proxy listening on {LISTEN[0]}:{LISTEN[1]}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
