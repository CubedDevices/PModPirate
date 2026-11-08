#!/usr/bin/env python3
"""Scripted console session for a PModPirate board.

With no --port the hardware session is skipped and the process exits 0.
Pass --port /dev/ttyUSB1 (the board UART, not the Vivado console) to run
id, mode, oe/in, and a raw play. --loopback also checks that a driven pin
reads back on a jumpered neighbor.
"""

import argparse
import sys


def session(port, baud, loopback):
    import serial

    ser = serial.Serial(port, baud, timeout=2)
    try:
        banner = ser.readline().decode("ascii", "replace").strip()
        if not banner.startswith("OK"):
            # The banner may already have been printed. Ask for id.
            ser.write(b"id\n")
            banner = ser.readline().decode("ascii", "replace").strip()
        if banner != "OK pmodpirate":
            raise SystemExit(f"unexpected id reply: {banner!r}")

        def cmd(line, expect_prefix="OK"):
            ser.write((line + "\n").encode("ascii"))
            reply = ser.readline().decode("ascii", "replace").strip()
            if not reply.startswith(expect_prefix):
                raise SystemExit(f"{line!r} -> {reply!r}")
            return reply

        cmd("mode gpio")
        cmd("oe 0x00")
        cmd("out 0x00")
        pins = cmd("in")
        if not pins.startswith("OK "):
            raise SystemExit(f"in reply {pins!r}")

        # One word: drive pin 0 high for 20 ticks, then the player returns to idle.
        cmd("buf.words 0x01010014")
        cmd("play")

        if loopback:
            cmd("oe 0x01")
            cmd("out 0x01")
            got = cmd("in")
            if got.split()[-1].lower() not in ("01", "0x01"):
                raise SystemExit(f"loopback expected pin 0 high, got {got!r}")
            cmd("out 0x00")
        print("console_test: PASS")
    finally:
        ser.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="serial device, e.g. /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--loopback",
        action="store_true",
        help="require a jumper that feeds a driven JA pin back to itself",
    )
    args = parser.parse_args()
    if not args.port:
        print("console_test: skipped (no --port)")
        return 0
    session(args.port, args.baud, args.loopback)
    return 0


if __name__ == "__main__":
    sys.exit(main())
