#!/usr/bin/env python3
"""Runs inside the verifier's isolated peer network namespace (no LAN/default route)."""
import socket
import struct
import sys
import time

source, name, expected, port, token = sys.argv[1:]
name = name.lower().rstrip('.')
query = struct.pack('!6H', 0x4f4b, 0, 1, 0, 0, 0)
query += b''.join(bytes([len(part)]) + part.encode('ascii') for part in name.split('.')) + b'\0' + struct.pack('!HH', 1, 1)


def dns_name(data, offset):
    labels, end, visited = [], None, set()
    while True:
        if offset in visited or offset >= len(data):
            raise ValueError('Invalid DNS name')
        visited.add(offset)
        size = data[offset]
        if size & 0xc0 == 0xc0:
            pointer = struct.unpack_from('!H', data, offset)[0] & 0x3fff
            if end is None:
                end = offset + 2
            offset = pointer
        elif size == 0:
            return '.'.join(labels).lower(), end if end is not None else offset + 1
        elif size <= 63 and offset + 1 + size <= len(data):
            labels.append(data[offset + 1:offset + 1 + size].decode('ascii'))
            offset += size + 1
        else:
            raise ValueError('Invalid DNS label')


def answers(data):
    if len(data) < 12:
        return []
    _, flags, questions, count, authority, additional = struct.unpack_from('!6H', data)
    if not flags & 0x8000 or questions + count + authority + additional > 512:
        return []
    offset, result = 12, []
    for _ in range(questions):
        _, offset = dns_name(data, offset)
        offset += 4
    for _ in range(count + authority + additional):
        record, offset = dns_name(data, offset)
        kind, cls, ttl, size = struct.unpack_from('!HHIH', data, offset)
        offset += 10
        if record == name and kind == 1 and cls & 0x7fff == 1 and ttl > 0 and size == 4:
            result.append(socket.inet_ntoa(data[offset:offset + size]))
        offset += size
    return result


with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind((source, 0))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(source))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.settimeout(1)
    deadline = time.monotonic() + 12
    found = False
    while time.monotonic() < deadline:
        sock.sendto(query, ('224.0.0.251', 5353))
        try:
            data, _ = sock.recvfrom(65535)
            if expected in answers(data):
                found = True
                break
        except (socket.timeout, ValueError, struct.error, UnicodeError):
            pass
    if not found:
        raise RuntimeError(f'{name} did not resolve to {expected} over the virtual network')

with socket.create_connection((expected, int(port)), timeout=10) as sock:
    sock.sendall(f'GET / HTTP/1.0\r\nHost: {name}\r\n\r\n'.encode('ascii'))
    response = b''
    while len(response) < 65536:
        data = sock.recv(4096)
        if not data:
            break
        response += data
    if response.split(b'\r\n\r\n', 1)[-1].decode('ascii') != token:
        raise RuntimeError('Host HTTP response did not match the verification token')
print(f'{name} -> {expected}; TCP/HTTP reached the physical host via the switch')
