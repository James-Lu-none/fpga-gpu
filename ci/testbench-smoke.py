#!/usr/bin/env python3
"""Arduino O/K/S power control and bounded DUT SSH readiness check."""
import argparse
import array
import fcntl
import os
from pathlib import Path
import select
import subprocess
import termios
import time


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
    key = Path(os.environ.get('DUT_SSH_KEY', '~/.ssh/pve-core.key')).expanduser()
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--power-action', choices=['check', 'on', 'off'], default='on',
                        help='on: power on if needed; off: forced shutdown; check: no power command')
    args = parser.parse_args()
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


if __name__ == '__main__':
    main()
