"""Board console session.

The wire protocol is ASCII lines at 115200 8N1. A command ends with a
newline. The board answers one line, ``OK``, ``OK <payload>``, or
``ERR <reason>``, except ``help``, which keeps writing lines after
``OK commands:``.
"""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass


BAUD = 115200
PLAY_HZ = 200_000_000


class PirateError(Exception):
    """The board rejected a command."""

    def __init__(self, reason: str, raw: str):
        super().__init__(reason)
        self.reason = reason
        self.raw = raw


class ConsoleTimeout(TimeoutError):
    """The board did not answer before the read timed out."""


@dataclass
class Reply:
    raw: str
    payload: str


def normalize_port(port: str) -> str:
    """Trim a device path. Windows accepts ``COMn`` only in uppercase."""
    port = port.strip()
    if os.name == "nt" and re.fullmatch(r"(?i)com\d+", port):
        return port.upper()
    return port


def _import_serial():
    try:
        import serial
    except ImportError as exc:
        raise ImportError(
            "pyserial is not installed. "
            "Linux: apt install python3-serial. "
            "Windows, from the UCRT64 shell: python -m pip install pyserial"
        ) from exc
    return serial


def list_ports() -> list[tuple[str, str]]:
    """Return ``(device, label)`` for every serial port the OS reports."""
    _import_serial()
    from serial.tools import list_ports as port_list

    found = []
    for port in port_list.comports():
        description = (port.description or "").strip()
        if description and description.lower() not in ("n/a", "unknown"):
            label = f"{port.device} — {description}"
        else:
            label = port.device
        found.append((port.device, label))
    found.sort(key=lambda item: item[0])
    return found


def normalize_hex(text: str, max_bytes: int) -> str:
    """Compact even-length hex with spaces, commas, and ``0x`` removed."""
    cleaned = re.sub(r"0x", "", text, flags=re.IGNORECASE)
    cleaned = re.sub(r"[\s,]+", "", cleaned)
    if not cleaned:
        raise ValueError("enter at least one byte")
    if len(cleaned) % 2:
        raise ValueError("hex needs an even number of digits")
    if not re.fullmatch(r"[0-9a-fA-F]+", cleaned):
        raise ValueError("hex contains a non-hex digit")
    count = len(cleaned) // 2
    if count > max_bytes:
        raise ValueError(f"at most {max_bytes} bytes")
    return cleaned.lower()


def format_hex(payload: str) -> str:
    """Group a compact hex payload into bytes for display."""
    compact = re.sub(r"\s+", "", payload)
    if not compact or len(compact) % 2 or not re.fullmatch(r"[0-9a-fA-F]+", compact):
        return payload
    return " ".join(compact[i : i + 2] for i in range(0, len(compact), 2))


def parse_words(text: str) -> list[int]:
    """Parse raw player words the same way the firmware does (base 0)."""
    tokens = text.split()
    if not tokens:
        raise ValueError("enter at least one word")
    if len(tokens) > 64:
        raise ValueError("at most 64 words")
    words = []
    for token in tokens:
        try:
            value = int(token, 0)
        except ValueError as exc:
            raise ValueError(f"not an integer: {token}") from exc
        if value < 0 or value > 0xFFFFFFFF:
            raise ValueError(f"word out of range: {token}")
        words.append(value)
    return words


def parse_hz(text: str) -> int:
    """Read a rate. Commas and underscores are thousands separators."""
    cleaned = text.strip().replace(",", "").replace("_", "").replace(" ", "")
    if not cleaned:
        raise ValueError("enter a rate")
    return int(cleaned, 0)


def format_hz(hz: int) -> str:
    return f"{hz:,}"


def describe_rate(hz: int, kind: str) -> str:
    """Say how the firmware will quantize ``hz`` onto the 200 MHz timebase."""
    if hz < 1 or hz > 100_000_000:
        return "Rate must be from 1 to 100,000,000"
    if kind == "uart":
        ticks = PLAY_HZ // hz
        unit = "tick" if ticks == 1 else "ticks"
        return f"{ticks} {unit} per bit ({ticks * 5} ns)"
    half = PLAY_HZ // (2 * hz)
    if half < 1:
        return "Faster than one tick. The board will answer ERR rate"
    unit = "tick" if half == 1 else "ticks"
    return f"{half} {unit} per half-period ({half * 5} ns)"


class Console:
    """One open serial port. Methods are safe to call from a worker thread."""

    def __init__(self, port: str, timeout: float = 3.0):
        self.port = port
        self.timeout = timeout
        self._ser = None
        self._lock = threading.Lock()

    def open(self) -> None:
        serial = _import_serial()
        self.port = normalize_port(self.port)
        kwargs = {
            "timeout": self.timeout,
            "write_timeout": self.timeout,
        }
        # Windows rejects exclusive=True. On Linux it stops a second
        # program from opening the same UART.
        if os.name == "posix":
            kwargs["exclusive"] = True
        self._ser = serial.Serial(self.port, BAUD, **kwargs)
        self._ser.reset_input_buffer()

    def close(self) -> None:
        with self._lock:
            if self._ser is not None:
                self._ser.close()
                self._ser = None

    def transact(self, command: str) -> Reply:
        """Send one command and return the board's reply."""
        line = command.strip()
        if not line:
            raise ValueError("empty command")
        with self._lock:
            if self._ser is None:
                raise PirateError("not connected", "")
            self._ser.write((line + "\n").encode("ascii"))
            self._ser.flush()
            text = self._read_line()
            while text == "":
                text = self._read_line()
            if text.startswith("ERR"):
                reason = text[3:].strip() or "error"
                raise PirateError(reason, text)
            if text.startswith("OK commands:"):
                return Reply(self._read_help(text), "")
            if text.startswith("OK"):
                payload = text[2:].strip()
                return Reply(text, payload)
            raise PirateError(f"unexpected reply: {text}", text)

    def _read_line(self) -> str:
        assert self._ser is not None
        raw = self._ser.readline()
        if not raw:
            raise ConsoleTimeout(f"no reply from {self.port}")
        return raw.decode("ascii", "replace").rstrip("\r\n")

    def _read_help(self, first: str) -> str:
        """``help`` has no terminator. Read until the UART goes quiet."""
        assert self._ser is not None
        lines = [first]
        previous = self._ser.timeout
        self._ser.timeout = 0.2
        try:
            while True:
                raw = self._ser.readline()
                if not raw:
                    break
                lines.append(raw.decode("ascii", "replace").rstrip("\r\n"))
        finally:
            self._ser.timeout = previous
        return "\n".join(lines)
