#!/usr/bin/env python3
"""Linux TAP helper for okrun web-switch access ports.

Stdout/stdin carry length-prefixed raw Ethernet frames:
  uint32_be length + frame bytes

All logs/control messages go to stderr so stdout remains binary-safe.
"""

import argparse
import errno
import fcntl
import json
import ipaddress
import random
import time
import os
import select
import signal
import struct
import subprocess
import sys

TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000
MAX_IFACE_BYTES = 15

running = True


def handle_signal(_signum, _frame):
    global running
    running = False


def log(message):
    print(message, file=sys.stderr, flush=True)


def run_ip(args):
    subprocess.run(['ip', *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def create_tap(interface, mtu, ip_cidr, mac=None, probe=False):
    encoded_name = interface.encode('utf-8')
    if len(encoded_name) > MAX_IFACE_BYTES:
        raise ValueError(f'interface name {interface!r} is longer than {MAX_IFACE_BYTES} bytes')

    if os.path.exists('/sys/class/net/' + interface):
        raise ValueError('Refusing to attach to an existing interface')
    fd = os.open('/dev/net/tun', os.O_RDWR | os.O_NONBLOCK)
    ifr = struct.pack('16sH', encoded_name, IFF_TAP | IFF_NO_PI)
    result = fcntl.ioctl(fd, TUNSETIFF, ifr)
    actual = result[:16].split(b'\0', 1)[0].decode('utf-8')

    if mac:
        run_ip(['link', 'set', 'dev', actual, 'address', mac])
    if probe:
        # Only this new TAP: never accept router advertisements/default routes.
        with open('/proc/sys/net/ipv6/conf/' + actual + '/disable_ipv6', 'w', encoding='ascii') as setting:
            setting.write('1')
    if mtu:
        run_ip(['link', 'set', 'dev', actual, 'mtu', str(mtu)])
    if ip_cidr and not probe:
        run_ip(['addr', 'replace', ip_cidr, 'dev', actual])
    run_ip(['link', 'set', 'dev', actual, 'up'])
    return fd, actual


def write_all(fd, payload):
    view = memoryview(payload)
    while view:
        try:
            written = os.write(fd, view)
            view = view[written:]
        except BlockingIOError:
            select.select([], [fd], [])
        except BrokenPipeError:
            return False
    return True


def emit_frame(frame):
    header = struct.pack('!I', len(frame))
    return write_all(1, header + frame)


def handle_stdin_buffer(buffer, tap_fd, max_frame_size, probe=None):
    offset = 0
    total = len(buffer)
    while total - offset >= 4:
        frame_length = struct.unpack('!I', buffer[offset:offset + 4])[0]
        if frame_length > max_frame_size:
            raise ValueError(f'input frame length {frame_length} exceeds {max_frame_size}')
        if total - offset < 4 + frame_length:
            break
        frame = buffer[offset + 4:offset + 4 + frame_length]
        if probe:
            probe.inspect(frame)
        try:
            write_all(tap_fd, frame)
        except OSError as error:
            log(f'OKRUN_SWITCH_TAP_DROP write failed: {error}')
        offset += 4 + frame_length
    return buffer[offset:]


class AddressConflict(Exception):
    pass


class AddressProbe:
    """RFC 5227-style probing on the tunnel, without CAP_NET_RAW or a DHCP server.

    Both transports carry these ARPs. Continue watching after assignment and
    relinquish on conflict; the supervisor will choose another host address.
    """
    def __init__(self, interface, cidr, mac, mtu):
        self.interface, self.cidr, self.mtu = interface, cidr, mtu
        self.ip = ipaddress.IPv4Interface(cidr).ip.packed
        self.mac = bytes.fromhex(mac.replace(':', ''))
        self.probes = 0
        self.assigned = False
        self.announcements = 0
        self.next_action = time.monotonic() + random.uniform(0, 1)

    def packet(self, announce=False):
        return (b'\xff' * 6 + self.mac + b'\x08\x06' +
                struct.pack('!HHBBH', 1, 0x0800, 6, 4, 1) + self.mac +
                (self.ip if announce else b'\x00' * 4) + b'\x00' * 6 + self.ip)

    def inspect(self, frame):
        if len(frame) < 42 or frame[12:20] != bytes.fromhex('0806000108000604'):
            return
        if struct.unpack('!H', frame[20:22])[0] not in (1, 2) or frame[22:28] == self.mac:
            return
        sender, target = frame[28:32], frame[38:42]
        if sender == self.ip or (not self.assigned and sender == b'\x00' * 4 and target == self.ip):
            raise AddressConflict()

    def tick(self):
        now = time.monotonic()
        if now < self.next_action:
            return
        if self.probes < 3:
            emit_frame(self.packet())
            self.probes += 1
            self.next_action = now + (2 if self.probes == 3 else random.uniform(1, 2))
        elif not self.assigned:
            run_ip(['addr', 'add', self.cidr, 'dev', self.interface])
            self.assigned = True
            log('OKRUN_SWITCH_TAP_READY ' + json.dumps({
                'interface': self.interface, 'ip': self.cidr, 'mtu': self.mtu,
            }, separators=(',', ':')))
            emit_frame(self.packet(announce=True))
            self.announcements = 1
            self.next_action = now + 2
        elif self.announcements < 2:
            emit_frame(self.packet(announce=True))
            self.announcements += 1
            self.next_action = float('inf')


def bridge_loop(tap_fd, max_frame_size, probe=None):
    stdin_buffer = b''
    while running:
        if probe:
            probe.tick()
        readable, _, _ = select.select([tap_fd, 0], [], [], 0.1)
        for fd in readable:
            if fd == tap_fd:
                try:
                    frame = os.read(tap_fd, max_frame_size)
                except BlockingIOError:
                    continue
                if not frame:
                    return
                if not emit_frame(frame):
                    return
            elif fd == 0:
                chunk = os.read(0, 65536)
                if not chunk:
                    return
                stdin_buffer += chunk
                stdin_buffer = handle_stdin_buffer(stdin_buffer, tap_fd, max_frame_size, probe)


def main():
    parser = argparse.ArgumentParser(description='OkRun web-switch Linux TAP helper')
    parser.add_argument('--interface', required=True)
    parser.add_argument('--ip', default=None, help='CIDR address to assign, e.g. 10.77.0.1/24')
    parser.add_argument('--mac', default=None)
    parser.add_argument('--probe-address', action='store_true')
    parser.add_argument('--mtu', type=int, default=1500)
    parser.add_argument('--max-frame-size', type=int, default=70000)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    tap_fd = None
    try:
      if args.probe_address and (not args.ip or not args.mac):
          raise ValueError('--probe-address requires --ip and --mac')
      tap_fd, actual = create_tap(args.interface, args.mtu, args.ip, args.mac, args.probe_address)
      probe = AddressProbe(actual, args.ip, args.mac, args.mtu) if args.probe_address else None
      if not probe:
          log('OKRUN_SWITCH_TAP_READY ' + json.dumps({
              'interface': actual, 'ip': args.ip, 'mtu': args.mtu,
          }, separators=(',', ':')))
      bridge_loop(tap_fd, args.max_frame_size, probe)
    except AddressConflict:
      log('OKRUN_SWITCH_ADDRESS_CONFLICT')
      return 2
    except subprocess.CalledProcessError as error:
      stderr = error.stderr.decode('utf-8', errors='replace').strip() if error.stderr else ''
      log(f'OKRUN_SWITCH_TAP_ERROR ip command failed: {stderr or error}')
      return 1
    except OSError as error:
      if error.errno == errno.EPERM:
          log('OKRUN_SWITCH_TAP_ERROR permission denied; run as root or grant CAP_NET_ADMIN')
      else:
          log(f'OKRUN_SWITCH_TAP_ERROR {error}')
      return 1
    except Exception as error:  # pylint: disable=broad-except
      log(f'OKRUN_SWITCH_TAP_ERROR {error}')
      return 1
    finally:
      if tap_fd is not None:
          os.close(tap_fd)
    return 0


if __name__ == '__main__':
    sys.exit(main())
