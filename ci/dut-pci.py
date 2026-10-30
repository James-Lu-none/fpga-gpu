#!/usr/bin/env python3
"""Run on the DUT via sudo: prepare or rescan the FPGA endpoint only."""
from pathlib import Path
import sys
import time


def endpoints():
    return [p for p in Path('/sys/bus/pci/devices').iterdir() 
        if (p / 'vendor').read_text().strip() == '0x10ee' and (p / 'device').read_text().strip() == '0x7021']


def main():
    action = sys.argv[1]
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
    else:
        raise ValueError('Expected prepare or rescan')


if __name__ == '__main__':
    main()
