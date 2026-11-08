#!/usr/bin/env python3
"""Host-side checks for the console client. No board and no GTK."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pmodpirate.protocol import (  # noqa: E402
    Console,
    ConsoleTimeout,
    PirateError,
    describe_rate,
    format_hex,
    format_hz,
    normalize_hex,
    parse_hz,
    parse_words,
)


class ScriptedPort:
    def __init__(self, replies):
        self.replies = list(replies)
        self.written = []
        self.timeout = 3.0
        self.closed = False

    def write(self, data):
        self.written.append(data)

    def flush(self):
        pass

    def readline(self):
        if not self.replies:
            return b""
        return self.replies.pop(0)

    def reset_input_buffer(self):
        pass

    def close(self):
        self.closed = True


def expect(name, got, want):
    if got != want:
        raise SystemExit(f"FAIL {name}: got {got!r} want {want!r}")


def test_hex():
    expect("compact", normalize_hex("A5 3C", 256), "a53c")
    expect("prefix", normalize_hex("0xA5, 0x01", 256), "a501")
    try:
        normalize_hex("abc", 256)
        raise SystemExit("FAIL odd hex was accepted")
    except ValueError:
        pass
    try:
        normalize_hex("", 256)
        raise SystemExit("FAIL empty hex was accepted")
    except ValueError:
        pass
    expect("groups", format_hex("a53c"), "a5 3c")
    expect("leave prose", format_hex("pmodpirate"), "pmodpirate")


def test_words_and_rate():
    expect("words", parse_words("0x01010014 20"), [0x01010014, 20])
    try:
        parse_words(" ")
        raise SystemExit("FAIL empty words were accepted")
    except ValueError:
        pass
    expect("50mhz", describe_rate(50_000_000, "spi"), "2 ticks per half-period (10 ns)")
    expect("100mhz", describe_rate(100_000_000, "spi"), "1 tick per half-period (5 ns)")
    expect("uart", describe_rate(115200, "uart"), "1736 ticks per bit (8680 ns)")
    expect("hz commas", parse_hz("1,000,000"), 1_000_000)
    expect("hz underscores", parse_hz("100_000"), 100_000)
    expect("hz hex", parse_hz("0x10"), 16)
    expect("hz format", format_hz(115200), "115,200")
    try:
        parse_hz("1,000 Hz")
        raise SystemExit("FAIL a rate with a unit was accepted")
    except ValueError:
        pass


def test_session():
    port = ScriptedPort([b"OK pmodpirate\r\n", b"OK 3c\r\n", b"ERR mode\r\n", b""])
    console = Console("COM3")
    console._ser = port
    reply = console.transact("id")
    expect("id payload", reply.payload, "pmodpirate")
    expect("id written", port.written[-1], b"id\n")
    reply = console.transact("spi xfer a5")
    expect("spi payload", reply.payload, "3c")
    try:
        console.transact("spi xfer ff")
        raise SystemExit("FAIL ERR was not raised")
    except PirateError as exc:
        expect("reason", exc.reason, "mode")
    try:
        console.transact("in")
        raise SystemExit("FAIL timeout was not raised")
    except ConsoleTimeout:
        pass

    help_port = ScriptedPort(
        [
            b"OK commands:\r\n",
            b"  id\r\n",
            b"  mode gpio|spi|i2c|uart\r\n",
            b"",
        ]
    )
    console._ser = help_port
    reply = console.transact("help")
    expect("help starts", reply.raw.splitlines()[0], "OK commands:")
    expect("help keeps indent", "  id" in reply.raw, True)


def main():
    test_hex()
    test_words_and_rate()
    test_session()
    print("test_protocol: PASS")


if __name__ == "__main__":
    main()
