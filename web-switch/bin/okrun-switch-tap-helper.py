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


def create_tap(interface, mtu, ip_cidr):
    encoded_name = interface.encode('utf-8')
    if len(encoded_name) > MAX_IFACE_BYTES:
        raise ValueError(f'interface name {interface!r} is longer than {MAX_IFACE_BYTES} bytes')

    fd = os.open('/dev/net/tun', os.O_RDWR | os.O_NONBLOCK)
    ifr = struct.pack('16sH', encoded_name, IFF_TAP | IFF_NO_PI)
    result = fcntl.ioctl(fd, TUNSETIFF, ifr)
    actual = result[:16].split(b'\0', 1)[0].decode('utf-8')

    if mtu:
        run_ip(['link', 'set', 'dev', actual, 'mtu', str(mtu)])
    if ip_cidr:
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


def handle_stdin_buffer(buffer, tap_fd, max_frame_size):
    offset = 0
    total = len(buffer)
    while total - offset >= 4:
        frame_length = struct.unpack('!I', buffer[offset:offset + 4])[0]
        if frame_length > max_frame_size:
            raise ValueError(f'input frame length {frame_length} exceeds {max_frame_size}')
        if total - offset < 4 + frame_length:
            break
        frame = buffer[offset + 4:offset + 4 + frame_length]
        try:
            write_all(tap_fd, frame)
        except OSError as error:
            log(f'OKRUN_SWITCH_TAP_DROP write failed: {error}')
        offset += 4 + frame_length
    return buffer[offset:]


def bridge_loop(tap_fd, max_frame_size):
    stdin_buffer = b''
    while running:
        readable, _, _ = select.select([tap_fd, 0], [], [], 0.5)
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
                stdin_buffer = handle_stdin_buffer(stdin_buffer, tap_fd, max_frame_size)


def main():
    parser = argparse.ArgumentParser(description='OkRun web-switch Linux TAP helper')
    parser.add_argument('--interface', required=True)
    parser.add_argument('--ip', default=None, help='CIDR address to assign, e.g. 10.77.0.1/24')
    parser.add_argument('--mtu', type=int, default=1500)
    parser.add_argument('--max-frame-size', type=int, default=70000)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    tap_fd = None
    try:
      tap_fd, actual = create_tap(args.interface, args.mtu, args.ip)
      log('OKRUN_SWITCH_TAP_READY ' + json.dumps({
          'interface': actual,
          'ip': args.ip,
          'mtu': args.mtu,
      }, separators=(',', ':')))
      bridge_loop(tap_fd, args.max_frame_size)
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
