#!/usr/bin/env python3
"""DUT B primitives: PCIe preparation/discovery and UART capture."""
import argparse
import fcntl
import os
from pathlib import Path
import select
import subprocess
import sys
import termios
import time


def endpoints():
    return [p for p in Path('/sys/bus/pci/devices').iterdir() 
        if (p / 'vendor').read_text().strip() == '0x10ee' and (p / 'device').read_text().strip() == '0x7021']


def verify_endpoint(p):
    if (p / 'driver').exists():
        raise RuntimeError(f'{p.name} has a bound driver; refusing automatic recovery')
    try:
        with (p / 'config').open('rb') as config:
            identity = config.read(4)
    except OSError as exc:
        print(f'PCIe config-space read failed: {exc}', flush=True)
        return False
    if identity != bytes.fromhex('ee102170'):
        print(f'PCIe config-space identity unavailable: {identity.hex()}', flush=True)
        return False
    bars = (p / 'resource').read_text().splitlines()
    for index, minimum in [(0, 0x30000), (1, 0x10000)]:
        start, end, flags = (int(value, 16) for value in bars[index].split())
        if start == 0 or end - start + 1 < minimum or not flags & 0x200:
            print(f'PCIe BAR{index} not assigned correctly: {bars[index]}', flush=True)
            return False
        print(f'BAR{index}: 0x{start:x}-0x{end:x}', flush=True)
    print(f'PASS: FPGA PCIe endpoint {p.name}; config ID=10ee:7021, BAR0/BAR1 assigned, driver unbound', flush=True)
    return True


def pci_diagnostics():
    # Read-only evidence before any power-cycle recovery destroys link state.
    for command in [['lspci', '-Dtv'], ['dmesg', '--color=never']]:
        try:
            output = subprocess.run(command, capture_output=True, text=True, timeout=5)
            print(f'DIAGNOSTIC: {" ".join(command)} (exit={output.returncode})', flush=True)
            print('\n'.join((output.stdout + output.stderr).splitlines()[-60:]), flush=True)
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f'DIAGNOSTIC unavailable: {exc}', flush=True)


def pci_main(action):
    if action == 'prepare':
        devices = endpoints()
        if len(devices) > 1:
            raise RuntimeError('Multiple FPGA PCIe endpoints found; refusing ambiguous target')
        for p in devices:
            if (p / 'driver').exists():
                raise RuntimeError(f'{p.name} has a bound driver; stop clients and unload it before programming')
        for p in devices:
            (p / 'remove').write_text('1\n')
            print(f'Removed PCIe endpoint {p.name}', flush=True)
        if not devices:
            print('No existing FPGA endpoint; continuing with JTAG programming', flush=True)
    elif action == 'rescan':
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            Path('/sys/bus/pci/rescan').write_text('1\n')
            devices = endpoints()
            if len(devices) == 1:
                if verify_endpoint(devices[0]):
                    return
            if len(devices) > 1:
                raise RuntimeError('Multiple FPGA PCIe endpoints after rescan')
            time.sleep(2)
        pci_diagnostics()
        print('FAIL: FPGA PCIe endpoint did not become ready within 30 seconds', flush=True)
        raise SystemExit(75)  # Explicit recoverable readiness failure, not any script error.


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
        deadline = time.monotonic() + 3600
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
        raise TimeoutError('UART capture exceeded 3600 seconds')
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare', help='Remove the unbound FPGA PCIe endpoint')
    commands.add_parser('rescan', help='Rescan PCIe and require one FPGA endpoint')
    uart = commands.add_parser('uart', help='Capture 115200-baud UART until stdin closes')
    uart.add_argument('--device', default='/dev/ttyUSB0')
    commands.add_parser('device', help='Require one unbound FPGA and print its resource0 path')
    args = parser.parse_args()
    if args.command == 'uart':
        uart_main(args)
    elif args.command == 'device':
        devices = endpoints()
        if len(devices) != 1 or (devices[0] / 'driver').exists():
            raise RuntimeError('Require exactly one unbound FPGA endpoint')
        # Keep stdout a path for hardware-test.sh; readiness was checked earlier.
        print(devices[0] / 'resource0')
    else:
        pci_main(args.command)


if __name__ == '__main__':
    main()
