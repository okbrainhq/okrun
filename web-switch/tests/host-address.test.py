#!/usr/bin/env python3
"""Unprivileged tests for the real TAP helper's address-conflict logic."""
import importlib.util
import pathlib
import struct
import unittest
from unittest.mock import patch

helper = pathlib.Path(__file__).resolve().parents[1] / 'bin/okrun-switch-tap-helper.py'
spec = importlib.util.spec_from_file_location('tap_helper', helper)
tap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tap)


class AddressProbeTest(unittest.TestCase):
    def setUp(self):
        self.probe = tap.AddressProbe('oktest0', '10.77.0.233/24', '02:11:22:33:44:55', 1500)

    def test_probe_does_not_claim_the_ip_before_assignment(self):
        packet = self.probe.packet()
        self.assertEqual(len(packet), 42)
        self.assertEqual(packet[:6], b'\xff' * 6)
        self.assertEqual(packet[28:32], b'\x00' * 4)
        self.assertEqual(packet[38:42], bytes([10, 77, 0, 233]))
        self.assertEqual(self.probe.packet(True)[28:32], packet[38:42])

    def test_owner_and_simultaneous_probe_conflict(self):
        packet = bytearray(self.probe.packet(True))
        packet[22:28] = bytes.fromhex('02aabbccddee')
        with self.assertRaises(tap.AddressConflict):
            self.probe.inspect(packet)
        packet[28:32] = b'\x00' * 4
        with self.assertRaises(tap.AddressConflict):
            self.probe.inspect(packet)
        self.probe.assigned = True
        self.probe.inspect(packet)  # normal DAD request is answered by the kernel
        packet[28:32] = self.probe.ip
        packet[20:22] = struct.pack('!H', 2)
        with self.assertRaises(tap.AddressConflict):
            self.probe.inspect(packet)  # continuous conflict detection

    def test_own_echo_and_unrelated_frames_are_not_conflicts(self):
        self.probe.inspect(self.probe.packet(True))
        self.probe.inspect(b'bad')
        self.probe.inspect(b'\x00' * 100)

    def test_three_probes_precede_address_and_announcements(self):
        with patch.object(tap, 'emit_frame') as emit, patch.object(tap, 'run_ip') as ip, patch.object(tap, 'log'):
            for _ in range(3):
                self.probe.next_action = 0
                self.probe.tick()
                ip.assert_not_called()
            self.assertEqual(emit.call_count, 3)
            self.probe.next_action = 0
            self.probe.tick()
            ip.assert_called_once_with(['addr', 'add', '10.77.0.233/24', 'dev', 'oktest0'])
            self.assertTrue(self.probe.assigned)
            self.probe.next_action = 0
            self.probe.tick()
            self.assertEqual(emit.call_count, 5)


if __name__ == '__main__':
    unittest.main()
