#!/usr/bin/env python3
"""DUT B operations: PCIe, UART capture and real-hardware driver tests."""
import argparse
import fcntl
import os
from pathlib import Path
import select
import shutil
import subprocess
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


def test_main(args):
    """Build for the running kernel, then exercise the real PCIe device."""
    root = args.workspace.resolve()
    driver = root / 'fpga-gpu-driver'
    firmware = root / 'fpga-gpu-firmware'
    compiler = root / 'fpga-gpu-compiler'
    logs = root / 'results'
    logs.mkdir(exist_ok=True)
    jobs = str(len(os.sched_getaffinity(0)))
    kernel = os.uname().release
    headers = Path('/lib/modules') / kernel / 'build'
    llvm = Path('/usr/lib/llvm-18/lib/cmake/llvm')
    for tool in ('make', 'gcc', 'g++', 'cmake', 'clang-18', 'riscv64-unknown-elf-gcc',
                 'riscv64-unknown-elf-objcopy', 'riscv64-unknown-elf-objdump',
                 'insmod', 'rmmod', 'dmesg'):
        if not shutil.which(tool):
            raise RuntimeError(f'Missing DUT build dependency: {tool}')
    if not headers.is_dir() or not llvm.is_dir():
        raise RuntimeError(f'Require running-kernel headers at {headers} and LLVM 18 at {llvm}')
    devices = endpoints()
    if len(devices) != 1 or (devices[0] / 'driver').exists():
        raise RuntimeError('Require exactly one unbound FPGA endpoint before testing')
    if Path('/sys/module/fpgagpu_driver').exists():
        raise RuntimeError('fpgagpu_driver is already loaded; refusing to replace it')
    env = dict(os.environ, FPGAGPU_COMPILER_DIR=str(compiler),
               LD_LIBRARY_PATH=str(driver / 'umd'))

    def run(name, command, cwd=root, timeout=300):
        print(f'RUN: {name}: {command}', flush=True)
        with (logs / f'{name}.log').open('w') as output:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        print(f'{"PASS" if result.returncode == 0 else "FAIL"}: {name}', flush=True)
        if result.returncode:
            print((logs / f'{name}.log').read_text(errors='replace')[-8192:], flush=True)
            result.check_returncode()

    loaded = False
    try:
        run('dmesg-before', ['dmesg', '--color=never'])
        run('compiler-configure', ['cmake', '-S', str(compiler), '-B', str(compiler / 'build'),
                                  '-DCMAKE_BUILD_TYPE=Release', f'-DLLVM_DIR={llvm}', '-DBUILD_TESTING=OFF'])
        run('compiler-build', ['cmake', '--build', str(compiler / 'build'), '--parallel', jobs], timeout=600)
        run('firmware-build', ['make', '-j' + jobs], cwd=firmware)
        run('driver-build', ['make', '-j' + jobs, 'KDIR=' + str(headers)], cwd=driver)
        run('firmware-load', ['./load_fw', str(devices[0] / 'resource0')], cwd=firmware, timeout=90)
        run('module-load', ['insmod', str(driver / 'driver/fpgagpu_driver.ko'), 'queue_mode=0'])
        loaded = True
        deadline = time.monotonic() + 10
        while not Path('/dev/fpgagpu0').exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not Path('/dev/fpgagpu0').exists() or not (devices[0] / 'driver').exists():
            raise RuntimeError('Driver did not bind/create /dev/fpgagpu0')
        tests = ('test_dma', 'test_opencl_buffer_copy', 'test_opencl_vector_add',
                 'test_opencl_matmul', 'test_opencl_matmul_occupancy', 'test_opencl_branch_divergence')
        for test in tests:
            run(test, ['./' + test], cwd=driver / 'tests', timeout=120)
        print(f'PASS: {len(tests)} hardware tests completed', flush=True)
    finally:
        # Collect diagnostics before unloading, even when a test fails.
        for pattern in ('*_cpu.bin', '*_gpu.bin'):
            for path in (driver / 'tests').glob(pattern):
                shutil.copy2(path, logs / path.name)
        try:
            run('dmesg-after', ['dmesg', '--color=never'])
        finally:
            if loaded:
                run('module-unload', ['rmmod', 'fpgagpu_driver'], timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare', help='Remove the unbound FPGA PCIe endpoint')
    commands.add_parser('rescan', help='Rescan PCIe and require one FPGA endpoint')
    uart = commands.add_parser('uart', help='Capture 115200-baud UART until stdin closes')
    uart.add_argument('--device', default='/dev/ttyUSB0')
    test = commands.add_parser('test', help='Build/load driver and run FPGA hardware tests')
    test.add_argument('--workspace', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'uart':
        uart_main(args)
    elif args.command == 'test':
        test_main(args)
    else:
        pci_main(args.command)


if __name__ == '__main__':
    main()
