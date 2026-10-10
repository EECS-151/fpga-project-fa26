#!/usr/bin/env python3

import os
import serial
import time
import argparse

DEFAULT_BAUD = 115200
# Many USB–UART / PMOD paths only tolerate small bursts before drops; 8 B/chunk has
# been reliable here. Try larger N (16, 32, …) on your setup if stable; raise baud for speed.
DEFAULT_CHUNK_SIZE = 8
# Sleep multiplier on ideal 8N1 wire time per chunk (see _pace_sleep). >1 gives headroom
# for bridges that lag behind the kernel tty queue.
DEFAULT_PACE_MARGIN = 1.04


def _pace_sleep_seconds(n, baud, pace_margin):
    """Time for n bytes on the wire at 8N1 (10 bit times per byte), scaled by pace_margin."""
    return (n * 10.0 / float(baud)) * pace_margin


def hex_to_serial(
    hex_file, addr, port, com, baud=DEFAULT_BAUD, chunk_size=DEFAULT_CHUNK_SIZE, pace_margin=DEFAULT_PACE_MARGIN
):
    # Windows
    if os.name == "nt":
        ser = serial.Serial()
        ser.baudrate = baud
        ser.port = com
        ser.open()
    else:
        ser = serial.Serial(port, baudrate=baud)

    with open(hex_file, "r") as f:
        program = f.readlines()
    if program and ("@" in program[0]):
        program = program[1:]  # remove first line '@0'
    program = [inst.rstrip() for inst in program if inst.strip()]
    # Each line is a hex word (MSB first: leftmost hex digit is the MSB of the word).
    # Memory is little-endian: emit raw bytes LSB first per 32-bit word.
    payload = bytearray()
    for inst in program:
        hex_digits = "".join(inst.split())
        if not hex_digits:
            continue
        word = int(hex_digits, 16)
        payload.extend(word.to_bytes(4, byteorder="little"))
    size = len(payload)

    # write a newline to clear any input tokens before entering the command
    ser.write(b"\r")
    time.sleep(0.01)

    command = "opt_file {:08x} {:d} ".format(addr, size)
    print("Sending command: {}".format(command))
    ser.write(command.encode("ascii"))
    ser.flush()
    time.sleep(0.01)

    # So that we don't overwhelm PC's UART, split into chunks and pace
    if chunk_size and chunk_size < len(data):
        sent = 0
        while sent < len(data):
            n = min(chunk_size, len(data) - sent)
            ser.write(data[sent : sent + n])
            sent += n
            time.sleep(_pace_sleep_seconds(n, baud, pace_margin))
            print("Sent {:d}/{:d} bytes".format(sent, size), end="\r")
        print()
        ser.flush()
    else:
        ser.write(data)
        time.sleep(_pace_sleep_seconds(size, baud, pace_margin))
        ser.flush()
        print("Sent {:d}/{:d} bytes".format(size, size))

    print("Done")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Load hex file to FPGA via serial UART (line-rate pacing, bounded chunks)"
    )
    parser.add_argument("hex_file", action="store", type=str)
    parser.add_argument("--port_name", action="store", type=str, default="/dev/ttyU-PMOD0")
    parser.add_argument("--com_name", action="store", type=str, default="COM11")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help="UART baud (default 115200)")
    parser.add_argument(
        "--chunk_size",
        type=int,
        default=DEFAULT_CHUNK_SIZE,
        metavar="N",
        help=(
            "Bytes per write before pacing sleep (default: %(default)s). "
            "Some bridges only work with very small N; if yours is stable with 16 or 32, use that for fewer loop iterations. "
            "0 = one write for whole payload (risky unless tiny). Throughput: higher UART --baud helps more than huge chunks."
        ),
    )
    parser.add_argument(
        "--pace_margin",
        type=float,
        default=DEFAULT_PACE_MARGIN,
        metavar="F",
        help=(
            "After each chunk write, sleep F×(chunk wire time at 8N1). "
            "Default %(default)s. Increase (e.g. 1.08) if transmission is corrupted."
        ),
    )
    args = parser.parse_args()
    hex_to_serial(
        args.hex_file,
        int("0x30000000", 16),
        args.port_name,
        args.com_name,
        baud=args.baud,
        chunk_size=args.chunk_size,
        pace_margin=args.pace_margin,
    )
