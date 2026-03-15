#!/usr/bin/env python3
"""Receive marquee commands over TCP/UDP and forward them to the local dmarquees FIFO."""

import argparse
import errno
import os
import signal
import socket
import stat
import sys
from typing import Iterable

running = True


def handle_signal(_signum, _frame):
    global running
    running = False


def ensure_fifo(path: str) -> None:
    if os.path.exists(path):
        mode = os.stat(path).st_mode
        if not stat.S_ISFIFO(mode):
            raise RuntimeError(f"Path exists and is not a FIFO: {path}")
    else:
        os.mkfifo(path, 0o666)
    os.chmod(path, 0o666)


def write_fifo_nonblocking(path: str, command: str, verbose: bool) -> bool:
    payload = (command.rstrip("\n") + "\n").encode("utf-8", errors="replace")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        if exc.errno == errno.ENXIO:
            if verbose:
                print(f"[netbridge] no FIFO reader yet, dropping: {command}", file=sys.stderr)
            return False
        raise

    try:
        os.write(fd, payload)
    finally:
        os.close(fd)

    if verbose:
        print(f"[netbridge] forwarded: {command}")
    return True


def iter_lines_from_bytes(chunks: Iterable[bytes], carry: str = ""):
    buf = carry
    for chunk in chunks:
        if not chunk:
            continue
        buf += chunk.decode("utf-8", errors="replace")
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if line:
                yield line
    if buf.strip():
        yield buf.strip()


def serve_udp(host: str, port: int, fifo_path: str, verbose: bool) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    sock.settimeout(1.0)

    print(f"[netbridge] UDP listening on {host}:{port}, fifo={fifo_path}")
    while running:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue

        for line in iter_lines_from_bytes([data]):
            if verbose:
                print(f"[netbridge] recv {addr[0]}:{addr[1]} -> {line}")
            write_fifo_nonblocking(fifo_path, line, verbose)


def serve_tcp(host: str, port: int, fifo_path: str, verbose: bool) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(8)
    server.settimeout(1.0)

    print(f"[netbridge] TCP listening on {host}:{port}, fifo={fifo_path}")
    while running:
        try:
            conn, addr = server.accept()
        except socket.timeout:
            continue

        with conn:
            conn.settimeout(1.0)
            chunks = []
            while running:
                try:
                    chunk = conn.recv(2048)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                chunks.append(chunk)

            for line in iter_lines_from_bytes(chunks):
                if verbose:
                    print(f"[netbridge] recv {addr[0]}:{addr[1]} -> {line}")
                write_fifo_nonblocking(fifo_path, line, verbose)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="dmarquees network to FIFO bridge")
    parser.add_argument("--protocol", choices=["tcp", "udp"], default="tcp")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", type=int, default=5533)
    parser.add_argument("--fifo", default="/tmp/dmarquees_cmd")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.port < 1 or args.port > 65535:
        print(f"Invalid port: {args.port}", file=sys.stderr)
        return 2

    ensure_fifo(args.fifo)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    if args.protocol == "udp":
        serve_udp(args.host, args.port, args.fifo, args.verbose)
    else:
        serve_tcp(args.host, args.port, args.fifo, args.verbose)

    print("[netbridge] exiting")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
