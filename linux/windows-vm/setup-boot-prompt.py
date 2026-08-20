#!/usr/bin/env python3
"""Acknowledge the Windows media "Press any key to boot from CD" prompt.

Microsoft install media waits a few seconds for a key before booting WinPE.
The prompt's timing varies with firmware boot enumeration, and a fixed burst
of three presses demonstrably misses the window (observed on real hardware:
BdsDxe starts the DVD entry, times out untouched, and the whole unattended
install stalls in a boot-manager loop). Press repeatedly across the whole
prompt window instead; extra presses after WinPE hands over to the answer
file are ignored by setup.
"""
import argparse
import json
import socket
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("socket", help="QMP unix socket path")
    parser.add_argument("--presses", type=int, default=30,
                        help="number of key presses (default 30)")
    parser.add_argument("--delay", type=float, default=0.7,
                        help="seconds between presses (default 0.7)")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(args.socket)
    sock.recv(65536)
    sock.sendall(b'{"execute":"qmp_capabilities"}\n')
    sock.recv(65536)
    command = {
        "execute": "human-monitor-command",
        "arguments": {"command-line": "sendkey spc"},
    }
    for _ in range(args.presses):
        time.sleep(args.delay)
        sock.sendall((json.dumps(command) + "\n").encode())
        sock.recv(65536)
    sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
