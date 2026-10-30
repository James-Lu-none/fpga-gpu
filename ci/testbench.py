#!/usr/bin/env python3
"""Testbench CLI: Arduino/SSH connectivity, bundle validation and Vivado Lab loading."""
import argparse
import array
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import subprocess
import sys
import termios
import time

HERE = Path(__file__).resolve().parent


def log(message):
    print(f'[{time.strftime("%Y-%m-%dT%H:%M:%S%z")}] {message}', flush=True)


class Arduino:
    def __init__(self, device):
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.pending = b''
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            attrs = termios.tcgetattr(self.fd)
            attrs[0] = attrs[1] = attrs[3] = 0
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[4] = attrs[5] = termios.B9600
            attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
            # Match the known-working on_off_test.py DTR sequence, including
            # QEMU USB/serial forwarding. Disable hardware flow control above.
            dtr = array.array('i', [termios.TIOCM_DTR])
            fcntl.ioctl(self.fd, termios.TIOCMBIC, dtr)
            time.sleep(1)
            fcntl.ioctl(self.fd, termios.TIOCMBIS, dtr)
            time.sleep(5)
            termios.tcflush(self.fd, termios.TCIFLUSH)
            log(f'Arduino ready: {device}, 9600 baud')
        except BaseException:
            self.close()
            raise

    def close(self):
        os.close(self.fd)

    def request(self, command, expected, timeout=30):
        log(f'TX: {command}; expecting {sorted(expected)}')
        os.write(self.fd, command.encode('ascii'))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b'\n' not in self.pending:
                remaining = max(0, deadline - time.monotonic())
                if not select.select([self.fd], [], [], remaining)[0]:
                    break
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    raise RuntimeError('Arduino serial connection closed')
                self.pending += chunk
                continue
            line, self.pending = self.pending.split(b'\n', 1)
            line = line.rstrip(b'\r').decode('ascii', errors='replace')
            if not line:
                continue
            log(f'RX: {line}')
            if line in expected:
                return line
            if line.startswith('TRY:'):
                continue
            raise RuntimeError(f'Unexpected Arduino response: {line}')
        raise TimeoutError(f'Timed out waiting for response to {command}')


def set_power(controller, action):
    state = controller.request('S', {'STATUS:ON', 'STATUS:OFF'})
    if action == 'on' and state == 'STATUS:OFF':
        controller.request('O', {'REPORT:SUCCESS_ON', 'REPORT:ALREADY_ON'})
    elif action == 'off' and state == 'STATUS:ON':
        controller.request('K', {'REPORT:SUCCESS_OFF', 'REPORT:ALREADY_OFF'})
    wanted = 'STATUS:OFF' if action == 'off' else 'STATUS:ON'
    controller.request('S', {wanted})


def ssh_command():
    key = Path(os.environ.get('DUT_SSH_KEY', '/home/github-runner/.ssh/pve-core')).expanduser()
    if not key.is_file():
        raise RuntimeError(f'SSH key not found: {key}')
    return [
        'ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        os.environ.get('DUT_SSH_TARGET', 'user@10.0.0.7'),
        'hostname; uname -r; id',
    ]


def wait_ssh(command, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=min(15, remaining))
            if result.returncode == 0:
                log(result.stdout.strip())
                log('PASS: Arduino power feedback and DUT SSH connection')
                return
            log(f'SSH not ready: {result.stderr.strip()}')
        except subprocess.TimeoutExpired:
            log('SSH attempt timed out')
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    raise TimeoutError('DUT SSH did not become ready within the boot deadline')


def smoke_main(args):
    # Validate SSH configuration before changing power.
    command = ssh_command() if args.power_action != 'off' else None
    controller = Arduino(os.environ.get('ARDUINO_DEVICE', '/dev/ttyACM0'))
    try:
        set_power(controller, args.power_action)
        if args.power_action == 'off':
            log('PASS: DUT power is OFF')
        else:
            wait_ssh(command)
    finally:
        controller.close()
    # No automatic power-off or recovery after failure; preserve DUT for debug.


def verify(directory, expected_sha):
    if not re.fullmatch(r'[0-9a-fA-F]{40}', expected_sha):
        raise ValueError('Expected source SHA must be a full Git commit SHA')
    source = (directory / 'source-sha.txt').read_text().strip()
    if source.lower() != expected_sha.lower():
        raise ValueError(f'Source SHA mismatch: {source}')
    entries = {}
    for line in (directory / 'bitstream.sha256').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](top\.(?:bit|bin))', line)
        if not match or match[2] in entries:
            raise ValueError('Invalid or duplicate bitstream checksum entry')
        entries[match[2]] = match[1].lower()
    if set(entries) != {'top.bit', 'top.bin'}:
        raise ValueError('Bundle must contain checksums for top.bit and top.bin')
    for name, expected in entries.items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing, empty or symlinked output: {name}')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f'Checksum mismatch: {name}')
    print(f'PASS: bitstream checksums and source commit {source}')


def verify_binary(directory, expected_sha, expected_digest):
    """Validate bin-only transfer against same-run producer job outputs."""
    if not re.fullmatch(r'[0-9a-fA-F]{40}', expected_sha):
        raise ValueError('Expected source SHA must be a full Git commit SHA')
    if not re.fullmatch(r'[0-9a-fA-F]{64}', expected_digest):
        raise ValueError('Missing or invalid producer binary checksum')
    path = directory / 'top.bin'
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ValueError('Missing, empty or symlinked top.bin')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest.lower():
        raise ValueError('Checksum mismatch: top.bin')
    print(f'PASS: top.bin matches producer checksum for CI source {expected_sha}')


def run_logged(command, timeout, *, input_text=None):
    log(f'RUN: {command[0]}')
    # Stream output to workflow/tee even if the external process times out.
    subprocess.run(command, input=input_text, text=True, check=True, timeout=timeout)


def find_vivado_lab():
    explicit = os.environ.get('VIVADO_LAB')
    candidates = [explicit] if explicit else [
        shutil.which('vivado_lab'),
        '/opt/Xilinx/2026.1/Vivado_Lab/bin/vivado_lab',
        '/opt/Xilinx/Vivado_Lab/2026.1/bin/vivado_lab',
    ]
    for path in candidates:
        if path and Path(path).is_file() and os.access(path, os.X_OK):
            return str(Path(path).resolve())
    raise RuntimeError('Vivado Lab not found; set VIVADO_LAB to the vivado_lab executable')


def program_command(lab, action, bundle, logs, mode):
    return [lab, '-mode', 'batch', '-notrace', '-source', str(HERE.parent / 'fpga-gpu-hardware' / 'program_fpga.tcl'),
            '-log', str(logs / f'lab-{action}.log'),
            '-journal', str(logs / f'lab-{action}.jou'),
            '-tclargs', action, str(bundle / 'top.bin'), mode]


def uart_main(args):
    """Run on DUT B; SSH stdin EOF stops capture, with a hard lifetime limit."""
    fd = os.open(args.device, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        print('UART capture ready: 115200 baud, 8N1', flush=True)
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd, sys.stdin.buffer], [], [], 1)
            if sys.stdin.buffer in ready and not os.read(0, 1):
                return
            if fd in ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    raise RuntimeError('FPGA UART disconnected')
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        raise TimeoutError('UART capture exceeded 900 seconds')
    finally:
        os.close(fd)


@contextmanager
def capture_uart(ssh, logs):
    # Send the existing CLI as code; no extra script installation on DUT B.
    source = "__file__ = 'testbench.py'\n" + Path(__file__).read_text()
    remote = 'python3 -u -c ' + shlex.quote(source) + ' uart'
    with (logs / 'uart.log').open('wb') as output:
        process = subprocess.Popen(ssh + [remote], stdin=subprocess.PIPE,
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while b'UART capture ready:' not in (logs / 'uart.log').read_bytes():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('DUT UART capture failed to start; inspect uart.log')
                time.sleep(0.1)
            log('Capturing DUT B /dev/ttyUSB0 at 115200 baud to uart.log')
            yield
            if process.poll() is not None:
                raise RuntimeError('DUT UART capture stopped unexpectedly; inspect uart.log')
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def load_main(args):
    bundle = args.bundle.resolve()
    verify_binary(bundle, args.source_sha, args.bin_sha256)
    lab = find_vivado_lab()
    logs = Path('artifacts/testbench').resolve()
    logs.mkdir(parents=True, exist_ok=True)
    ssh = ssh_command()[:-1]
    pci_helper = (HERE / 'dut-pci.py').read_text()
    # Workflow concurrency also serializes the connectivity test. Keep Arduino
    # connection/lock open throughout loading; no forced shutdown on failure.
    controller = Arduino(os.environ.get('ARDUINO_DEVICE', '/dev/ttyACM0'))
    try:
        set_power(controller, 'on')
        wait_ssh(ssh_command())
        run_logged(program_command(lab, 'detect', bundle, logs, args.program_mode), 90)
        run_logged(ssh + ['sudo -n python3 - prepare'], 30, input_text=pci_helper)
        with capture_uart(ssh, logs):
            run_logged(program_command(lab, 'program', bundle, logs, args.program_mode),
                       600 if args.program_mode == 'flash' else 180)
            time.sleep(3)
            run_logged(ssh + ['sudo -n python3 - rescan'], 45, input_text=pci_helper)
        log(f'PASS: {args.program_mode} programming and FPGA PCIe enumeration')
    finally:
        controller.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    smoke = commands.add_parser('smoke', help='Check power and SSH readiness')
    smoke.add_argument('--power-action', choices=['check', 'on', 'off'], default='on')
    uart = commands.add_parser('uart', help='Capture UART on DUT B until stdin closes')
    uart.add_argument('--device', default='/dev/ttyUSB0')
    bundle = commands.add_parser('verify-bundle', help='Verify local producer bundle')
    bundle.add_argument('directory', type=Path)
    bundle.add_argument('--source-sha', required=True)
    load = commands.add_parser('load', help='Program FPGA using Vivado Lab')
    load.add_argument('bundle', type=Path)
    load.add_argument('--source-sha', required=True)
    load.add_argument('--bin-sha256', required=True)
    load.add_argument('--program-mode', choices=['sram', 'flash'], default='sram',
                      help='flash erases/programs/verifies configuration memory and boots from it')
    args = parser.parse_args()
    if args.command == 'smoke':
        smoke_main(args)
    elif args.command == 'uart':
        uart_main(args)
    elif args.command == 'verify-bundle':
        verify(args.directory, args.source_sha)
    else:
        load_main(args)


if __name__ == '__main__':
    main()
