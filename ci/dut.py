#!/usr/bin/env python3
"""DUT B operations: FPGA PCIe preparation/rescan and UART capture."""
import argparse
import fcntl
import os
from pathlib import Path
import select
import sys
import termios
import time


def endpoints():
    return [p for p in Path('/sys/bus/pci/devices').iterdir() 
        if (p / 'vendor').read_text().strip() == '0x10ee' and (p / 'device').read_text().strip() == '0x7021']


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
                p = devices[0]
                print(f'PASS: FPGA PCIe endpoint {p.name} (10ee:7021)', flush=True)
                return
            if len(devices) > 1:
                raise RuntimeError('Multiple FPGA PCIe endpoints after rescan')
            time.sleep(2)
        raise TimeoutError('FPGA PCIe endpoint did not enumerate after programming')


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare', help='Remove the unbound FPGA PCIe endpoint')
    commands.add_parser('rescan', help='Rescan PCIe and require one FPGA endpoint')
    uart = commands.add_parser('uart', help='Capture 115200-baud UART until stdin closes')
    uart.add_argument('--device', default='/dev/ttyUSB0')
    args = parser.parse_args()
    if args.command == 'uart':
        uart_main(args)
    else:
        pci_main(args.command)


if __name__ == '__main__':
    main()
