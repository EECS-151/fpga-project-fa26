#!/usr/bin/env python3
"""Load a program through the BIOS, run it, and read the cycle and instruction counts it prints."""

from hex_to_serial import hex_to_serial
import os
import re
import serial
import time
import argparse

FALLBACK_PORT = '/dev/ttyU-PMOD0'
DEFAULT_TIMEOUT_S = 120


def leased_uart():
    """The CPU's UART (the PMOD serial adapter) of the board `make program` leased, or None.
    scripts/fpga_lease.sh records it in its state directory while the lease lasts."""
    if os.name == 'nt':
        return None
    state = os.environ.get('FPGA_LEASE_DIR') or f'/run/user/{os.getuid()}/fpga-lease'
    try:
        with open(os.path.join(state, 'ttys_extra')) as f:
            ports = [l.strip() for l in f if l.strip()]
    except OSError:
        return None
    return ports[0] if ports else None


def default_port():
    return leased_uart() or FALLBACK_PORT


def _count(pattern, line):
    m = re.search(pattern + r':\s*([0-9a-fA-F]+)', line)
    return int(m.group(1), 16) if m else None


def run_fpga(hex_file, port, com, timeout_s=DEFAULT_TIMEOUT_S):
    """Returns (cycle count, instruction count). Raises TimeoutError if the program hasn't printed
    both within timeout_s of being started."""
    hex_to_serial(hex_file, int('0x30000000', 16), port, com)

    # Windows
    if os.name == 'nt':
        ser = serial.Serial()
        ser.baudrate = 115200
        ser.port = com
        ser.open()
    # Linux
    else:
        ser = serial.Serial(port)
        ser.baudrate = 115200
    ser.timeout = 1

    try:
        command = "jal 10000000\r"
        print("Sending command: {}".format(command))
        for char in command:
            ser.write(bytearray([ord(char)]))
            time.sleep(0.01)

        ser.readline()

        cycle_count = None
        inst_count = None
        deadline = time.time() + timeout_s
        while cycle_count is None or inst_count is None:
            if time.time() > deadline:
                raise TimeoutError('Timeout: {} printed no cycle and instruction counts within {} s'.format(
                    os.path.basename(hex_file), timeout_s))
            line = ser.readline().decode('utf-8', errors='replace').strip()
            if not line:
                continue
            print(line)
            if 'Cycle Count' in line:
                cycle_count = _count('Cycle Count', line)
            if 'Instruction Count' in line:
                inst_count = _count('Instruction Count', line)
    finally:
        ser.close()

    print("Done")

    return cycle_count, inst_count

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Load and execute hex file on FPGA')
    parser.add_argument('hex_file', action="store", type=str)
    parser.add_argument('--port_name', action="store", type=str, default=None,
                        help='serial port (default: your leased board\'s PMOD UART, else {})'.format(FALLBACK_PORT))
    parser.add_argument('--com_name', action="store", type=str, default='COM11')
    parser.add_argument('--timeout', action="store", type=float, default=DEFAULT_TIMEOUT_S, help='seconds (default: %(default)s)')
    args = parser.parse_args()
    cycle_count, inst_count = run_fpga(args.hex_file, args.port_name or default_port(), args.com_name, args.timeout)
