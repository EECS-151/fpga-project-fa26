#!/usr/bin/env python3
"""Load Zephyr with hex_to_serial, enter it via ``jal 10000000``, run CoreMark, extract results."""

import argparse
import json
import os
import re
import serial
import time
from pathlib import Path

from hex_to_serial import hex_to_serial

ZEPHYR_LOAD_ADDR = 0x30000000
JAL_CMD = "jal 10000000\r"
COREMARK_CMD = "coremark\r"


def _open_serial(port, com):
    if os.name == "nt":
        ser = serial.Serial()
        ser.baudrate = 115200
        ser.port = com
        ser.open()
    else:
        ser = serial.Serial(port)
        ser.baudrate = 115200
    return ser


def _send_slow(ser, command, delay=0.01):
    for char in command:
        ser.write(bytearray([ord(char)]))
        time.sleep(delay)


def _wait_for_shell(ser, timeout_s=120):
    """Read UART until Zephyr shell prompt appears (discard data, no printing)."""
    deadline = time.time() + timeout_s
    ser.timeout = 0.5
    while time.time() < deadline:
        line = ser.readline()
        if not line:
            continue
        text = line.decode("utf-8", errors="replace")
        if "uart:" in text and "$" in text:
            return True
    return False


def _extract_coremark_block(full_text):
    """Return the substring from ``Starting CoreMark`` through the validation line."""
    lines = full_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if "Starting CoreMark" in line:
            start = i
            break
    if start is None:
        return None
    out = []
    for line in lines[start:]:
        out.append(line)
        if "Correct operation validated" in line:
            return "\n".join(out) + "\n"
    return None


def _parse_ticks_and_iterations(block):
    """Parse Total ticks and Iterations into integers; return None if missing."""
    ticks = None
    iters = None
    for line in block.splitlines():
        m = re.match(r"^\s*Total ticks\s*:\s*(\d+)", line.rstrip())
        if m:
            ticks = int(m.group(1))
        m = re.match(r"^\s*Iterations\s*:\s*(\d+)", line.rstrip())
        if m:
            iters = int(m.group(1))
    if ticks is None or iters is None:
        return None
    return {"total_ticks": ticks, "iterations": iters}


def run_zephyr_coremark(hex_file, port, com):
    """
    Load Zephyr, jump to 0x10000000, run CoreMark.

    Returns:
        On success: {"total_ticks": int, "iterations": int}
        On failure (including ``ERROR`` in UART output, timeout, or bad parse):
        {"error": True}
    """
    hex_to_serial(hex_file, ZEPHYR_LOAD_ADDR, port, com)
    time.sleep(0.2)

    ser = _open_serial(port, com)
    try:
        if hasattr(ser, "reset_input_buffer"):
            ser.reset_input_buffer()

        _send_slow(ser, JAL_CMD)
        ser.readline()

        if not _wait_for_shell(ser):
            return {"error": True}

        _send_slow(ser, COREMARK_CMD)

        ser.timeout = None

        captured = []
        while True:
            line = ser.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace")
            captured.append(text)
            if "Correct operation validated" in text:
                break

        full = "".join(captured)
        if "ERROR" in full:
            return {"error": True}

        block = _extract_coremark_block(full)
        if block is None:
            return {"error": True}

        parsed = _parse_ticks_and_iterations(block)
        if parsed is None:
            return {"error": True}
        return parsed
    finally:
        ser.close()


def main():
    default_hex = Path(__file__).resolve().parent.parent.parent / "zephyr/zephyr/build/zephyr/zephyr.hex"
    parser = argparse.ArgumentParser(
        description="Load Zephyr, jal to 0x10000000, run CoreMark, extract results."
    )
    parser.add_argument(
        "hex_file",
        nargs="?",
        default=str(default_hex),
        help="Zephyr .hex image (default: %(default)s)",
    )
    parser.add_argument("--port_name", default="/dev/ttyUSB0", help="Serial device (Linux)")
    parser.add_argument("--com_name", default="COM11", help="Serial port (Windows)")
    parser.add_argument(
        "-o",
        "--output",
        metavar="FILE",
        help="Write JSON result (dict) to this file.",
    )
    args = parser.parse_args()

    result = run_zephyr_coremark(args.hex_file, args.port_name, args.com_name)
    print(json.dumps(result))

    if args.output:
        Path(args.output).write_text(json.dumps(result) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
