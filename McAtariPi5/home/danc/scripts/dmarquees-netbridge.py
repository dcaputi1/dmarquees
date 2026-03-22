#!/usr/bin/env python3
"""Receive marquee commands over TCP/UDP and forward them to the local dmarquees FIFO."""

import argparse
import errno
import os
import signal
import socket
import stat
import subprocess
import sys
import time
from typing import Iterable

running = True
TTY_CONSOLE_TOKEN = "console=tty1"
FIFO_WRITE_RETRIES = 12
FIFO_RETRY_DELAY_SEC = 0.05


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
    for attempt in range(FIFO_WRITE_RETRIES):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno == errno.ENXIO:
                if attempt < FIFO_WRITE_RETRIES - 1:
                    time.sleep(FIFO_RETRY_DELAY_SEC)
                    continue
                if verbose:
                    print(f"[netbridge] no FIFO reader after retries, dropping: {command}", file=sys.stderr)
                return False
            raise

        try:
            os.write(fd, payload)
        finally:
            os.close(fd)

        if verbose:
            print(f"[netbridge] forwarded: {command}")
        return True

    return False


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


def mount_is_active(path: str) -> bool:
    """Return True when path currently has a mounted filesystem."""
    try:
        rc = subprocess.run(["mountpoint", "-q", path], check=False).returncode
        return rc == 0
    except Exception:
        return os.path.ismount(path)


def swap_art(marquees_zip: str, cpanel_zip: str, mnt: str, state_file: str, fifo: str, verbose: bool) -> None:
    """Toggle the FUSE-mounted art zip between marquees and cpanel, then REFRESH the daemon."""
    try:
        with open(state_file) as f:
            current = f.read().strip()
    except FileNotFoundError:
        current = "marquees"

    if current == "marquees":
        next_zip, next_state = cpanel_zip, "cpanel"
    else:
        next_zip, next_state = marquees_zip, "marquees"

    if verbose:
        print(f"[netbridge] SWAPART: {current} -> {next_state}")

    # Unmount current zip only when something is actually mounted.
    # Fresh boot/state can legitimately have no mount yet.
    if mount_is_active(mnt):
        try:
            subprocess.run(["fusermount", "-u", mnt], check=True, capture_output=True)
        except subprocess.CalledProcessError as exc:
            err = exc.stderr.decode().strip()
            print(f"[netbridge] fusermount failed: {err}", file=sys.stderr)
            try:
                subprocess.run(["umount", "-f", mnt], check=True, capture_output=True)
            except subprocess.CalledProcessError:
                # Last resort for stale/busy mount states.
                try:
                    subprocess.run(["umount", "-l", mnt], check=True, capture_output=True)
                except subprocess.CalledProcessError:
                    # If nothing is mounted anymore, continue to mount target zip.
                    if mount_is_active(mnt):
                        print("[netbridge] force/lazy umount failed; aborting SWAPART", file=sys.stderr)
                        return
                    if verbose:
                        print(f"[netbridge] {mnt} no longer mounted after unmount attempts; continuing")
    elif verbose:
        print(f"[netbridge] SWAPART: {mnt} not mounted; proceeding to mount target zip")

    time.sleep(0.5)

    # Mount the new zip
    try:
        subprocess.run(
            ["fuse-zip", "-r", "-o", "allow_other", next_zip, mnt],
            check=True, capture_output=True,
        )
    except subprocess.CalledProcessError as exc:
        print(f"[netbridge] fuse-zip mount failed: {exc.stderr.decode().strip()}", file=sys.stderr)
        # Try to restore the previous zip so the display isn't left unmounted
        restore_zip = marquees_zip if next_state == "cpanel" else cpanel_zip
        try:
            subprocess.run(["fuse-zip", "-r", "-o", "allow_other", restore_zip, mnt], capture_output=True)
        except Exception:
            pass
        return

    # Persist mount state
    try:
        with open(state_file, "w") as f:
            f.write(next_state + "\n")
    except OSError as exc:
        print(f"[netbridge] failed to write state file: {exc}", file=sys.stderr)

    # Tell the daemon to re-render whatever it's currently showing
    write_fifo_nonblocking(fifo, "REFRESH", verbose)

    if verbose:
        print(f"[netbridge] SWAPART complete: now showing {next_state}")


def get_boot_cmdline_path() -> str | None:
    for path in ("/boot/firmware/cmdline.txt", "/boot/cmdline.txt"):
        if os.path.isfile(path):
            return path
    return None


def tty_console_boot_enabled(cmdline_path: str) -> bool:
    try:
        with open(cmdline_path, "r", encoding="utf-8", errors="replace") as f:
            tokens = f.read().strip().split()
    except OSError:
        return False
    return TTY_CONSOLE_TOKEN in tokens


def set_tty_console_boot(enable: bool, verbose: bool) -> None:
    cmdline_path = get_boot_cmdline_path()
    if not cmdline_path:
        raise RuntimeError("Could not find cmdline.txt under /boot/firmware or /boot")

    with open(cmdline_path, "r", encoding="utf-8", errors="replace") as f:
        tokens = f.read().strip().split()

    tokens = [t for t in tokens if t != TTY_CONSOLE_TOKEN]
    if enable:
        tokens.append(TTY_CONSOLE_TOKEN)

    with open(cmdline_path, "w", encoding="utf-8") as f:
        f.write(" ".join(tokens) + "\n")

    if verbose:
        state = "ENABLED" if enable else "DISABLED"
        print(f"[netbridge] PI3_TTY_TOGGLE applied: cmdline console=tty1 {state} ({cmdline_path})")


def run_systemctl(args: list[str], verbose: bool) -> None:
    cmd = ["systemctl", *args]
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        detail = stderr or stdout or f"exit code {proc.returncode}"
        raise RuntimeError(f"{' '.join(cmd)} failed: {detail}")
    if verbose:
        print(f"[netbridge] ran: {' '.join(cmd)}")


def set_tty_getty(enable: bool, verbose: bool) -> None:
    service = "getty@tty1.service"
    if enable:
        run_systemctl(["unmask", service], verbose)
        run_systemctl(["enable", service], verbose)
    else:
        # Stop first so the login prompt clears right away on the current boot.
        run_systemctl(["disable", "--now", service], verbose)
        run_systemctl(["mask", service], verbose)


def toggle_tty_console_boot(verbose: bool) -> None:
    cmdline_path = get_boot_cmdline_path()
    if not cmdline_path:
        print("[netbridge] PI3_TTY_TOGGLE failed: cmdline.txt not found", file=sys.stderr)
        return

    current = tty_console_boot_enabled(cmdline_path)
    try:
        set_tty_console_boot(not current, verbose)
        set_tty_getty(not current, verbose)
        if verbose:
            state = "ENABLED" if not current else "DISABLED"
            print(f"[netbridge] PI3_TTY_TOGGLE complete: tty console boot {state}")
    except Exception as exc:
        print(f"[netbridge] PI3_TTY_TOGGLE failed: {exc}", file=sys.stderr)


def handle_command(line: str, fifo: str, swap_cfg: dict, verbose: bool) -> None:
    """Dispatch a single received command: intercept SWAPART, forward everything else."""
    cmd = line.strip().upper()
    if cmd == "SWAPART":
        swap_art(
            swap_cfg["marquees_zip"],
            swap_cfg["cpanel_zip"],
            swap_cfg["mnt"],
            swap_cfg["state_file"],
            fifo,
            verbose,
        )
    elif cmd == "PI3_TTY_TOGGLE":
        toggle_tty_console_boot(verbose)
    else:
        write_fifo_nonblocking(fifo, line, verbose)


def serve_udp(host: str, port: int, fifo_path: str, swap_cfg: dict, verbose: bool) -> None:
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
            handle_command(line, fifo_path, swap_cfg, verbose)


def serve_tcp(host: str, port: int, fifo_path: str, swap_cfg: dict, verbose: bool) -> None:
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
                handle_command(line, fifo_path, swap_cfg, verbose)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="dmarquees network to FIFO bridge")
    parser.add_argument("--protocol", choices=["tcp", "udp"], default="tcp")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", type=int, default=5533)
    parser.add_argument("--fifo", default="/tmp/dmarquees_cmd")
    parser.add_argument(
        "--marquees-zip",
        default=os.environ.get("DMARQUEES_MARQUEES_ZIP", "/home/danc/MAME_0.256_EXTRAs/marquees.zip"),
        help="Path to marquees.zip on this machine",
    )
    parser.add_argument(
        "--cpanel-zip",
        default=os.environ.get("DMARQUEES_CPANEL_ZIP", "/home/danc/MAME_0.256_EXTRAs/cpanel.zip"),
        help="Path to cpanel.zip on this machine",
    )
    parser.add_argument(
        "--marquees-mnt",
        default=os.environ.get("DMARQUEES_MARQUEES_MNT", "/home/danc/mnt/marquees"),
        help="FUSE mount point used by dmarquees on this machine",
    )
    parser.add_argument(
        "--mount-state-file",
        default=os.environ.get("DMARQUEES_MOUNT_STATE", "/tmp/dmarquees_mount_state"),
        help="File that tracks which zip is currently mounted (marquees or cpanel)",
    )
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

    swap_cfg = {
        "marquees_zip": args.marquees_zip,
        "cpanel_zip": args.cpanel_zip,
        "mnt": args.marquees_mnt,
        "state_file": args.mount_state_file,
    }

    if args.protocol == "udp":
        serve_udp(args.host, args.port, args.fifo, swap_cfg, args.verbose)
    else:
        serve_tcp(args.host, args.port, args.fifo, swap_cfg, args.verbose)

    print("[netbridge] exiting")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
