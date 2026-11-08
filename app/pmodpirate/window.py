"""GTK 4 window for the PModPirate console.

libadwaita 1.2 is the baseline so the same code runs on current Linux
packages and on the MSYS2 UCRT64 GTK stack for Windows.
"""

from __future__ import annotations

import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from pmodpirate.protocol import (
    BAUD,
    Console,
    PirateError,
    describe_rate,
    format_hz,
    format_hex,
    list_ports,
    normalize_hex,
    normalize_port,
    parse_hz,
    parse_words,
)


JA_PINS = ("J2", "H2", "H4", "F3", "H3", "H1", "G1", "F4")

SPI_MODES = (
    "0 — idle low, sample on the rising edge",
    "1 — idle low, sample on the falling edge",
    "2 — idle high, sample on the falling edge",
    "3 — idle high, sample on the rising edge",
)

CSS = """
.pin-bit {
  min-width: 2em;
  padding: 4px 0;
  border-radius: 6px;
  font-weight: 700;
}
.pin-bit.high {
  background-color: alpha(@accent_bg_color, 0.45);
}
.pin-bit.low {
  background-color: alpha(@window_fg_color, 0.08);
}
"""


def _spin(lower, upper, value):
    spin = Gtk.SpinButton.new_with_range(lower, upper, 1)
    spin.set_value(value)
    spin.set_valign(Gtk.Align.CENTER)
    return spin


def _pin_row(title, subtitle, value):
    row = Adw.ActionRow(title=title, subtitle=subtitle)
    spin = _spin(0, 7, value)
    row.add_suffix(spin)
    return row, spin


def _entry_row(title, text):
    row = Adw.EntryRow(title=title)
    row.set_text(text)
    return row


def _rate_row(title, hz):
    """A frequency entry. Commas are shown, and ignored when the value is read."""
    row = _entry_row(title, format_hz(hz))

    def reformat(*_args):
        try:
            value = parse_hz(row.get_text())
        except ValueError:
            return
        shown = format_hz(value)
        if row.get_text() != shown:
            row.set_text(shown)

    focus = Gtk.EventControllerFocus()
    focus.connect("leave", reformat)
    row.add_controller(focus)
    row.connect("apply", reformat)
    return row


class PirateWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="PModPirate")
        self.set_default_size(1040, 700)
        self.console = None
        self._busy = False
        self._ports = []

        self._install_css()
        self._build()
        self._load_state()
        self._refresh_ports()
        self.connect("close-request", self._on_close)

        about = Gio.SimpleAction.new("about", None)
        about.connect("activate", self._on_about)
        self.add_action(about)
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_a: self.close())
        self.add_action(quit_action)

    def _install_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _build(self):
        self.title = Adw.WindowTitle(title="PModPirate", subtitle="Disconnected")
        header = Gtk.HeaderBar()
        header.set_title_widget(self.title)

        self.port_entry = Gtk.Entry()
        self.port_entry.set_placeholder_text("COM3  or  /dev/ttyUSB2")
        self.port_entry.set_width_chars(22)
        self.port_entry.set_tooltip_text(
            f"Board UART at {BAUD} 8N1. Leave the logic analyzer's port alone."
        )
        header.pack_start(self.port_entry)

        self._port_menu = Gtk.MenuButton()
        self._port_menu.set_icon_name("view-list-symbolic")
        self._port_menu.set_tooltip_text("Detected serial ports")
        header.pack_start(self._port_menu)
        pick = Gio.SimpleAction.new("pick-port", GLib.VariantType.new("s"))
        pick.connect("activate", self._on_pick_port)
        self.add_action(pick)

        refresh = Gtk.Button.new_from_icon_name("view-refresh-symbolic")
        refresh.set_tooltip_text("Look for serial ports again")
        refresh.connect("clicked", lambda *_a: self._refresh_ports())
        header.pack_start(refresh)

        self.connect_btn = Gtk.Button(label="Connect")
        self.connect_btn.add_css_class("suggested-action")
        self.connect_btn.connect("clicked", self._on_connect)
        header.pack_end(self._menu_button())
        header.pack_end(self.connect_btn)

        self.stack = Adw.ViewStack()
        self.stack.add_titled_with_icon(self._gpio_page(), "gpio", "GPIO", "view-grid-symbolic")
        self.stack.add_titled_with_icon(
            self._spi_page(), "spi", "SPI", "media-playlist-consecutive-symbolic"
        )
        self.stack.add_titled_with_icon(
            self._i2c_page(), "i2c", "I2C", "emblem-synchronizing-symbolic"
        )
        self.stack.add_titled_with_icon(
            self._uart_page(), "uart", "UART", "utilities-terminal-symbolic"
        )
        self.stack.add_titled_with_icon(
            self._raw_page(), "raw", "Raw", "text-x-generic-symbolic"
        )

        switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        switch_bar = Gtk.CenterBox()
        switch_bar.set_center_widget(switcher)
        switch_bar.add_css_class("toolbar")

        self.log = Gtk.TextView()
        self.log.set_editable(False)
        self.log.set_cursor_visible(False)
        self.log.set_monospace(True)
        self.log.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log.set_left_margin(10)
        self.log.set_right_margin(10)
        self.log.set_top_margin(8)
        self.log.set_bottom_margin(8)
        self._log_buf = self.log.get_buffer()
        self._log_buf.create_tag("err", weight=700)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_child(self.log)
        scroll.set_vexpand(True)
        self._log_scroll = scroll

        command = Gtk.Entry()
        command.set_placeholder_text("Send a console command")
        command.set_hexpand(True)
        command.connect("activate", self._on_manual)
        self._command = command
        send = Gtk.Button(label="Send")
        send.connect("clicked", self._on_manual)
        clear = Gtk.Button.new_from_icon_name("edit-clear-all-symbolic")
        clear.set_tooltip_text("Clear the log")
        clear.connect("clicked", lambda *_a: self._log_buf.set_text(""))
        command_row = Gtk.Box(spacing=6)
        command_row.set_margin_start(8)
        command_row.set_margin_end(8)
        command_row.set_margin_top(6)
        command_row.set_margin_bottom(8)
        command_row.append(command)
        command_row.append(send)
        command_row.append(clear)

        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        log_title = Gtk.Label(label="Session", xalign=0)
        log_title.add_css_class("heading")
        log_title.set_margin_start(12)
        log_title.set_margin_top(12)
        log_title.set_margin_bottom(6)
        log_box.append(log_title)
        log_box.append(scroll)
        log_box.append(command_row)

        form = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        form.append(switch_bar)
        form.append(self.stack)
        self.stack.set_vexpand(True)

        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        paned.set_start_child(form)
        paned.set_end_child(log_box)
        paned.set_resize_start_child(True)
        paned.set_resize_end_child(True)
        paned.set_shrink_start_child(False)
        paned.set_position(620)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.append(header)
        root.append(paned)
        self.toast_overlay = Adw.ToastOverlay()
        self.toast_overlay.set_child(root)
        self.set_content(self.toast_overlay)

    def _menu_button(self):
        menu = Gio.Menu()
        menu.append("About", "win.about")
        menu.append("Quit", "win.quit")
        button = Gtk.MenuButton()
        button.set_icon_name("open-menu-symbolic")
        button.set_menu_model(menu)
        return button

    def _gpio_page(self):
        page = Adw.PreferencesPage()
        idle = Adw.PreferencesGroup(
            title="Idle levels",
            description="Restored after every play. A released pin is pulled high by the board.",
        )
        self._drives = []
        self._levels = []
        for index, package in enumerate(JA_PINS):
            row = Adw.ActionRow(title=f"JA{index}", subtitle=package)
            drive = Gtk.Switch()
            drive.set_valign(Gtk.Align.CENTER)
            drive.set_tooltip_text("Drive this pin while idle")
            level = Gtk.Switch()
            level.set_valign(Gtk.Align.CENTER)
            level.set_tooltip_text("Driven high when on, low when off")
            level.set_sensitive(False)
            drive.connect("notify::active", self._on_drive, level)
            row.add_suffix(Gtk.Label(label="Drive"))
            row.add_suffix(drive)
            row.add_suffix(Gtk.Label(label="High"))
            row.add_suffix(level)
            idle.add(row)
            self._drives.append(drive)
            self._levels.append(level)
        apply = Adw.ActionRow(title="Send idle levels")
        button = Gtk.Button(label="Apply")
        button.set_valign(Gtk.Align.CENTER)
        button.add_css_class("suggested-action")
        button.connect("clicked", lambda *_a: self._apply_gpio())
        apply.add_suffix(button)
        idle.add(apply)
        page.add(idle)

        read = Adw.PreferencesGroup(
            title="Pins now",
            description="One sample through the player. The boxes run JA0 through JA7 from left to right. JA0 is the least significant bit of the hex byte.",
        )
        bits = Gtk.Box(spacing=6)
        bits.set_margin_start(12)
        bits.set_margin_end(12)
        bits.set_margin_bottom(8)
        bits.set_halign(Gtk.Align.START)
        self._bits = []
        for index in range(8):
            label = Gtk.Label(label=str(index))
            label.add_css_class("pin-bit")
            label.add_css_class("low")
            label.set_tooltip_text(f"JA{index} · {JA_PINS[index]}")
            bits.append(label)
            self._bits.append(label)
        read.add(bits)
        read_row = Adw.ActionRow(title="Read JA")
        self._read_hex = Gtk.Label(label="—")
        self._read_hex.set_selectable(True)
        self._read_hex.add_css_class("monospace")
        read_btn = Gtk.Button(label="Read")
        read_btn.set_valign(Gtk.Align.CENTER)
        read_btn.connect("clicked", lambda *_a: self._read_pins())
        read_row.add_suffix(self._read_hex)
        read_row.add_suffix(read_btn)
        read.add(read_row)
        page.add(read)

        pulse = Adw.PreferencesGroup(
            title="Pulse",
            description="Drives the pins marked Drive high, then low, for this many 5 ns ticks. Other pins are released during the pulse.",
        )
        self._pulse_ticks = _entry_row("Ticks", "20")
        pulse.add(self._pulse_ticks)
        pulse_row = Adw.ActionRow(title="Run the pulse")
        pulse_btn = Gtk.Button(label="Pulse")
        pulse_btn.set_valign(Gtk.Align.CENTER)
        pulse_btn.connect("clicked", lambda *_a: self._pulse())
        pulse_row.add_suffix(pulse_btn)
        pulse.add(pulse_row)
        page.add(pulse)
        return page

    def _spi_page(self):
        page = Adw.PreferencesPage()
        clock = Adw.PreferencesGroup(title="Clock")
        self.spi_hz = _rate_row("SCK frequency", 1_000_000)
        self.spi_hz.connect("changed", lambda *_a: self._show_rate(self.spi_note, self.spi_hz, "spi"))
        self.spi_note = Adw.ActionRow(title="On the wire")
        self._show_rate(self.spi_note, self.spi_hz, "spi")
        clock.add(self.spi_hz)
        clock.add(self.spi_note)
        page.add(clock)

        pins = Adw.PreferencesGroup(
            title="Pins",
            description="Pmod order is pin 1 chip select, pin 2 MOSI, pin 3 MISO, pin 4 clock. Each signal has its own JA pin.",
        )
        cs, self.spi_cs = _pin_row("Chip select", "Pmod pin 1", 0)
        sck, self.spi_sck = _pin_row("Clock", "Pmod pin 4", 3)
        mosi, self.spi_mosi = _pin_row("MOSI", "Pmod pin 2", 1)
        miso, self.spi_miso = _pin_row("MISO", "Pmod pin 3", 2)
        for row in (cs, sck, mosi, miso):
            pins.add(row)
        page.add(pins)

        frame = Adw.PreferencesGroup(title="Frame")
        self.spi_mode = Adw.ComboRow(title="Mode")
        self.spi_mode.set_model(Gtk.StringList.new(list(SPI_MODES)))
        self.spi_order = Adw.ComboRow(title="Bit order")
        self.spi_order.set_model(Gtk.StringList.new(["MSB first", "LSB first"]))
        frame.add(self.spi_mode)
        frame.add(self.spi_order)
        page.add(frame)

        data = Adw.PreferencesGroup(
            title="Transfer",
            description="One play. Chip select falls, the bytes are clocked, then select rises.",
        )
        self.spi_hex = _entry_row("MOSI bytes", "a5")
        data.add(self.spi_hex)
        result = Adw.ActionRow(title="MISO")
        self.spi_result = Gtk.Label(label="—", selectable=True, xalign=0)
        self.spi_result.add_css_class("monospace")
        go = Gtk.Button(label="Transfer")
        go.add_css_class("suggested-action")
        go.set_valign(Gtk.Align.CENTER)
        go.connect("clicked", lambda *_a: self._spi_transfer())
        result.add_suffix(self.spi_result)
        result.add_suffix(go)
        data.add(result)
        page.add(data)
        return page

    def _i2c_page(self):
        page = Adw.PreferencesPage()
        clock = Adw.PreferencesGroup(
            title="Bus",
            description="Open drain. A zero is driven, a one is released. Above 100 kHz the board pull-ups are not enough.",
        )
        self.i2c_hz = _rate_row("SCL frequency", 100_000)
        self.i2c_hz.connect("changed", lambda *_a: self._show_rate(self.i2c_note, self.i2c_hz, "i2c"))
        self.i2c_note = Adw.ActionRow(title="On the wire")
        self._show_rate(self.i2c_note, self.i2c_hz, "i2c")
        sda, self.i2c_sda = _pin_row("SDA", "JA index", 0)
        scl, self.i2c_scl = _pin_row("SCL", "JA index", 1)
        self.i2c_hold = Adw.ActionRow(
            title="Hold the bus",
            subtitle="Drive SDA and SCL low between Start, Write, and Read. Stop releases them.",
        )
        hold = Gtk.Switch()
        hold.set_valign(Gtk.Align.CENTER)
        self.i2c_hold.add_suffix(hold)
        self._i2c_hold = hold
        for row in (self.i2c_hz, self.i2c_note, sda, scl, self.i2c_hold):
            clock.add(row)
        page.add(clock)

        txn = Adw.PreferencesGroup(
            title="Transaction",
            description="Each button is its own play. Write does not send START or STOP.",
        )
        self.i2c_hex = _entry_row("Write bytes", "a0")
        self.i2c_count = _entry_row("Bytes to read", "1")
        txn.add(self.i2c_hex)
        txn.add(self.i2c_count)
        actions = Adw.ActionRow(title="Bus actions")
        for label, handler in (
            ("Start", self._i2c_start),
            ("Write", self._i2c_write),
            ("Read", self._i2c_read),
            ("Stop", self._i2c_stop),
        ):
            button = Gtk.Button(label=label)
            button.set_valign(Gtk.Align.CENTER)
            button.connect("clicked", handler)
            actions.add_suffix(button)
        txn.add(actions)
        result = Adw.ActionRow(title="Read data")
        self.i2c_result = Gtk.Label(label="—", selectable=True)
        self.i2c_result.add_css_class("monospace")
        result.add_suffix(self.i2c_result)
        txn.add(result)
        page.add(txn)
        return page

    def _uart_page(self):
        page = Adw.PreferencesPage()
        link = Adw.PreferencesGroup(
            title="Link",
            description="8N1, least significant bit first. Receive is a timed listen that starts immediately. It does not wait for a start bit.",
        )
        self.uart_hz = _rate_row("Baud", 115_200)
        self.uart_hz.connect("changed", lambda *_a: self._show_rate(self.uart_note, self.uart_hz, "uart"))
        self.uart_note = Adw.ActionRow(title="On the wire")
        self._show_rate(self.uart_note, self.uart_hz, "uart")
        tx, self.uart_tx = _pin_row("TX", "Driven", 0)
        rx, self.uart_rx = _pin_row("RX", "Input", 1)
        self.uart_mark = Adw.ActionRow(
            title="Mark when idle",
            subtitle="Drive TX high between transmits.",
        )
        mark = Gtk.Switch()
        mark.set_active(True)
        mark.set_valign(Gtk.Align.CENTER)
        self.uart_mark.add_suffix(mark)
        self._uart_mark = mark
        for row in (self.uart_hz, self.uart_note, tx, rx, self.uart_mark):
            link.add(row)
        page.add(link)

        data = Adw.PreferencesGroup(title="Bytes")
        self.uart_hex = _entry_row("Transmit", "55")
        self.uart_count = _entry_row("Bytes to listen for", "1")
        data.add(self.uart_hex)
        data.add(self.uart_count)
        actions = Adw.ActionRow(title="Exchange")
        send = Gtk.Button(label="Transmit")
        send.add_css_class("suggested-action")
        send.set_valign(Gtk.Align.CENTER)
        send.connect("clicked", lambda *_a: self._uart_tx())
        listen = Gtk.Button(label="Listen")
        listen.set_valign(Gtk.Align.CENTER)
        listen.connect("clicked", lambda *_a: self._uart_rx())
        actions.add_suffix(listen)
        actions.add_suffix(send)
        data.add(actions)
        result = Adw.ActionRow(title="Received")
        self.uart_result = Gtk.Label(label="—", selectable=True)
        self.uart_result.add_css_class("monospace")
        result.add_suffix(self.uart_result)
        data.add(result)
        page.add(data)
        return page

    def _raw_page(self):
        page = Adw.PreferencesPage()
        group = Adw.PreferencesGroup(
            title="Player words",
            description="Each word is enable, data, duration. 0x01010014 drives JA0 high for 20 ticks (100 ns). At most 64 words.",
        )
        self.raw_text = Gtk.TextView()
        self.raw_text.set_monospace(True)
        self.raw_text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.raw_text.set_left_margin(8)
        self.raw_text.set_top_margin(6)
        self.raw_text.get_buffer().set_text("0x01010014 0x01000014")
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(160)
        scroll.set_child(self.raw_text)
        group.add(scroll)
        row = Adw.ActionRow(title="Load the words and play them")
        button = Gtk.Button(label="Play")
        button.add_css_class("suggested-action")
        button.set_valign(Gtk.Align.CENTER)
        button.connect("clicked", lambda *_a: self._raw_play())
        row.add_suffix(button)
        group.add(row)
        page.add(group)
        return page

    def _show_rate(self, row, entry, kind):
        text = entry.get_text().strip()
        try:
            hz = parse_hz(text)
        except ValueError:
            row.set_subtitle("Enter a rate, such as 1,000,000")
            return
        row.set_subtitle(describe_rate(hz, kind))

    def _on_drive(self, drive, _pspec, level):
        level.set_sensitive(drive.get_active())

    def _masks(self):
        oe = 0
        out = 0
        for index, (drive, level) in enumerate(zip(self._drives, self._levels)):
            if drive.get_active():
                oe |= 1 << index
                if level.get_active():
                    out |= 1 << index
        return oe, out

    def _apply_gpio(self):
        oe, out = self._masks()
        self._run(
            ["mode gpio", f"oe 0x{oe:02x}", f"out 0x{out:02x}"],
            None,
        )

    def _read_pins(self):
        def done(results):
            payload = results[-1][1].payload
            self._read_hex.set_text(payload or "—")
            try:
                value = int(payload, 16)
            except ValueError:
                return
            for index, label in enumerate(self._bits):
                high = bool(value & (1 << index))
                label.remove_css_class("high")
                label.remove_css_class("low")
                label.add_css_class("high" if high else "low")

        self._run(["in"], done)

    def _pulse(self):
        oe, _out = self._masks()
        if oe == 0:
            self._toast("Mark at least one pin as Drive")
            return
        try:
            ticks = int(self._pulse_ticks.get_text().strip(), 0)
        except ValueError:
            self._toast("Ticks must be an integer")
            return
        if ticks < 1:
            self._toast("Ticks must be at least 1")
            return
        self._run([f"pulse 0x{oe:02x} {ticks}"], None)

    def _spi_transfer(self):
        try:
            hz = self._hz(self.spi_hz)
            hex_bytes = normalize_hex(self.spi_hex.get_text(), 256)
        except ValueError as exc:
            self._toast(str(exc))
            return
        order = "msb" if self.spi_order.get_selected() == 0 else "lsb"
        mode = self.spi_mode.get_selected()
        cs = self.spi_cs.get_value_as_int()
        sck = self.spi_sck.get_value_as_int()
        mosi = self.spi_mosi.get_value_as_int()
        miso = self.spi_miso.get_value_as_int()
        if len({cs, sck, mosi, miso}) != 4:
            self._toast("Each SPI signal needs its own pin")
            return
        commands = [
            "mode spi",
            f"hz {hz}",
            f"pins spi {cs} {sck} {mosi} {miso}",
            f"spi.mode {mode}",
            f"spi.order {order}",
            f"spi xfer {hex_bytes}",
        ]

        def done(results):
            self.spi_result.set_text(format_hex(results[-1][1].payload))

        self._run(commands, done)

    def _i2c_setup(self, hold):
        commands = [
            "mode i2c",
            f"hz {self._hz(self.i2c_hz)}",
            "pins i2c {sda} {scl}".format(
                sda=self.i2c_sda.get_value_as_int(),
                scl=self.i2c_scl.get_value_as_int(),
            ),
        ]
        if hold and self._i2c_hold.get_active():
            mask = (1 << self.i2c_sda.get_value_as_int()) | (
                1 << self.i2c_scl.get_value_as_int()
            )
            commands.append(f"oe 0x{mask:02x}")
            commands.append("out 0x00")
        return commands

    def _i2c_start(self, *_args):
        try:
            commands = self._i2c_setup(True)
        except ValueError as exc:
            self._toast(str(exc))
            return
        commands.append("i2c start")
        self._run(commands, None)

    def _i2c_write(self, *_args):
        try:
            commands = self._i2c_setup(True)
            hex_bytes = normalize_hex(self.i2c_hex.get_text(), 128)
        except ValueError as exc:
            self._toast(str(exc))
            return
        commands.append(f"i2c write {hex_bytes}")
        self._run(commands, None)

    def _i2c_read(self, *_args):
        try:
            commands = self._i2c_setup(True)
        except ValueError as exc:
            self._toast(str(exc))
            return
        try:
            count = int(self.i2c_count.get_text().strip(), 0)
        except ValueError:
            self._toast("Read count must be an integer")
            return
        if count < 1 or count > 64:
            self._toast("Read 1 to 64 bytes")
            return
        commands.append(f"i2c read {count}")

        def done(results):
            self.i2c_result.set_text(format_hex(results[-1][1].payload))

        self._run(commands, done)

    def _i2c_stop(self, *_args):
        try:
            commands = self._i2c_setup(False)
        except ValueError as exc:
            self._toast(str(exc))
            return
        commands.append("i2c stop")
        if self._i2c_hold.get_active():
            commands.append("oe 0x00")
        self._run(commands, None)

    def _uart_setup(self):
        commands = [
            "mode uart",
            f"hz {self._hz(self.uart_hz)}",
            "pins uart {tx} {rx}".format(
                tx=self.uart_tx.get_value_as_int(),
                rx=self.uart_rx.get_value_as_int(),
            ),
        ]
        if self._uart_mark.get_active():
            mask = 1 << self.uart_tx.get_value_as_int()
            commands.append(f"oe 0x{mask:02x}")
            commands.append(f"out 0x{mask:02x}")
        return commands

    def _uart_tx(self):
        try:
            commands = self._uart_setup()
            hex_bytes = normalize_hex(self.uart_hex.get_text(), 64)
        except ValueError as exc:
            self._toast(str(exc))
            return
        commands.append(f"uart tx {hex_bytes}")
        self._run(commands, None)

    def _uart_rx(self):
        try:
            commands = self._uart_setup()
        except ValueError as exc:
            self._toast(str(exc))
            return
        try:
            count = int(self.uart_count.get_text().strip(), 0)
        except ValueError:
            self._toast("Listen count must be an integer")
            return
        if count < 1 or count > 32:
            self._toast("Listen for 1 to 32 bytes")
            return
        commands.append(f"uart rx {count}")

        def done(results):
            self.uart_result.set_text(format_hex(results[-1][1].payload))

        self._run(commands, done)

    def _raw_play(self):
        buf = self.raw_text.get_buffer()
        text = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
        try:
            words = parse_words(text)
        except ValueError as exc:
            self._toast(str(exc))
            return
        encoded = " ".join(f"0x{word:08x}" for word in words)
        self._run([f"buf.words {encoded}", "play"], None)

    def _on_manual(self, *_args):
        command = self._command.get_text().strip()
        if not command:
            return
        self._command.set_text("")
        self._run([command], None)

    def _hz(self, entry):
        try:
            hz = parse_hz(entry.get_text())
        except ValueError as exc:
            raise ValueError("Rate must be an integer") from exc
        if hz < 1 or hz > 100_000_000:
            raise ValueError("Rate must be from 1 to 100,000,000")
        return hz

    def _run(self, commands, on_success):
        if self.console is None:
            self._toast("Connect to the board first")
            return
        if self._busy:
            self._toast("Wait for the current command to finish")
            return
        self._busy = True
        self.title.set_subtitle("Working…")
        console = self.console

        def work():
            done = []
            failed = None
            error = None
            try:
                for command in commands:
                    failed = command
                    done.append((command, console.transact(command)))
                failed = None
            except Exception as exc:  # shown in the log; the worker must not die quietly
                error = exc
            GLib.idle_add(self._finished, done, failed, error, on_success)

        threading.Thread(target=work, name="pmodpirate-io", daemon=True).start()

    def _finished(self, done, failed, error, on_success):
        for command, reply in done:
            self._append(f"› {command}\n")
            self._append(reply.raw + "\n")
        self._busy = False
        if self.console is not None:
            self.title.set_subtitle(self.console.port)
        else:
            self.title.set_subtitle("Disconnected")
        if error is not None:
            if failed:
                self._append(f"› {failed}\n")
            detail = error.raw if isinstance(error, PirateError) else str(error)
            self._append(detail + "\n", "err")
            self._toast(str(error))
        elif on_success is not None:
            on_success(done)
        self._scroll_log()
        return False

    def _append(self, text, tag=None):
        end = self._log_buf.get_end_iter()
        if tag:
            self._log_buf.insert_with_tags_by_name(end, text, tag)
        else:
            self._log_buf.insert(end, text)

    def _scroll_log(self):
        adj = self._log_scroll.get_vadjustment()
        adj.set_value(adj.get_upper())

    def _toast(self, text):
        self.toast_overlay.add_toast(Adw.Toast.new(text))

    def _refresh_ports(self):
        try:
            self._ports = list_ports()
        except Exception as exc:
            self._ports = []
            self._toast(str(exc))
        menu = Gio.Menu()
        for device, label in self._ports:
            item = Gio.MenuItem.new(label, None)
            item.set_action_and_target_value(
                "win.pick-port", GLib.Variant.new_string(device)
            )
            menu.append_item(item)
        self._port_menu.set_menu_model(menu)

    def _on_pick_port(self, _action, value):
        self.port_entry.set_text(value.get_string())

    def _on_connect(self, *_args):
        if self.console is not None:
            self._disconnect()
            return
        if self._busy:
            return
        port = normalize_port(self.port_entry.get_text())
        if not port:
            self._toast("Enter a serial port")
            return
        self._busy = True
        self.connect_btn.set_sensitive(False)
        self.title.set_subtitle("Connecting…")

        def work():
            console = Console(port)
            try:
                console.open()
                reply = console.transact("id")
                if "pmodpirate" not in reply.raw:
                    raise PirateError(f"unexpected identity: {reply.raw}", reply.raw)
                GLib.idle_add(self._connected, console, reply, None)
            except Exception as exc:
                console.close()
                GLib.idle_add(self._connected, None, None, exc)

        threading.Thread(target=work, name="pmodpirate-connect", daemon=True).start()

    def _connected(self, console, reply, error):
        self._busy = False
        self.connect_btn.set_sensitive(True)
        if error is not None or console is None:
            self.title.set_subtitle("Disconnected")
            self._toast(str(error))
            self._append(f"connect failed: {error}\n", "err")
            return False
        self.console = console
        self.port_entry.set_text(console.port)
        self.port_entry.set_sensitive(False)
        self.connect_btn.set_label("Disconnect")
        self.connect_btn.remove_css_class("suggested-action")
        self.title.set_subtitle(console.port)
        self._append(f"connected {console.port} at {BAUD}\n")
        self._append(reply.raw + "\n")
        self._scroll_log()
        return False

    def _disconnect(self):
        if self.console is not None:
            self.console.close()
            self.console = None
        self.port_entry.set_sensitive(True)
        self.connect_btn.set_label("Connect")
        self.connect_btn.add_css_class("suggested-action")
        self.title.set_subtitle("Disconnected")
        self._append("disconnected\n")
        self._scroll_log()

    def _on_about(self, *_args):
        about = Adw.AboutWindow(
            transient_for=self,
            application_name="PModPirate",
            version="1.0",
            comments="Talks to the Cmod S7 Pmod console at 115200 8N1.",
        )
        about.present()

    def _state_path(self):
        directory = Path(GLib.get_user_config_dir()) / "pmodpirate"
        directory.mkdir(parents=True, exist_ok=True)
        return directory / "state.ini"

    def _load_state(self):
        path = self._state_path()
        if not path.exists():
            return
        key = GLib.KeyFile()
        try:
            key.load_from_file(str(path), GLib.KeyFileFlags.NONE)
        except GLib.Error:
            return
        self._restore(key, "window", "port", self.port_entry.set_text)
        width = self._int(key, "window", "width")
        height = self._int(key, "window", "height")
        if width and height:
            self.set_default_size(width, height)
        page = self._str(key, "window", "page")
        if page:
            self.stack.set_visible_child_name(page)
        self._restore_hz(key, "spi", self.spi_hz)
        self._restore_hz(key, "i2c", self.i2c_hz)
        self._restore_hz(key, "uart", self.uart_hz)
        # pinout 1 was the test order CS, SCK, MOSI, MISO on JA0..JA3.
        # pinout 2 is the Pmod connector order.
        if self._int(key, "spi", "pinout") == 2:
            self._restore_spin(key, "spi", "cs", self.spi_cs)
            self._restore_spin(key, "spi", "sck", self.spi_sck)
            self._restore_spin(key, "spi", "mosi", self.spi_mosi)
            self._restore_spin(key, "spi", "miso", self.spi_miso)
        mode = self._int(key, "spi", "mode")
        if mode is not None:
            self.spi_mode.set_selected(mode)
        order = self._int(key, "spi", "order")
        if order is not None:
            self.spi_order.set_selected(order)
        self._restore_spin(key, "i2c", "sda", self.i2c_sda)
        self._restore_spin(key, "i2c", "scl", self.i2c_scl)
        hold = self._int(key, "i2c", "hold")
        if hold is not None:
            self._i2c_hold.set_active(bool(hold))
        self._restore_spin(key, "uart", "tx", self.uart_tx)
        self._restore_spin(key, "uart", "rx", self.uart_rx)
        mark = self._int(key, "uart", "mark")
        if mark is not None:
            self._uart_mark.set_active(bool(mark))
        oe = self._int(key, "gpio", "oe")
        out = self._int(key, "gpio", "out")
        if oe is not None and out is not None:
            for index, (drive, level) in enumerate(zip(self._drives, self._levels)):
                drive.set_active(bool(oe & (1 << index)))
                level.set_active(bool(out & (1 << index)))

    def _save_state(self):
        key = GLib.KeyFile()
        width = self.get_width() or 1040
        height = self.get_height() or 700
        key.set_string("window", "port", self.port_entry.get_text())
        key.set_integer("window", "width", width)
        key.set_integer("window", "height", height)
        key.set_string("window", "page", self.stack.get_visible_child_name() or "gpio")
        key.set_string("spi", "hz", self.spi_hz.get_text())
        key.set_integer("spi", "pinout", 2)
        key.set_integer("spi", "cs", self.spi_cs.get_value_as_int())
        key.set_integer("spi", "sck", self.spi_sck.get_value_as_int())
        key.set_integer("spi", "mosi", self.spi_mosi.get_value_as_int())
        key.set_integer("spi", "miso", self.spi_miso.get_value_as_int())
        key.set_integer("spi", "mode", self.spi_mode.get_selected())
        key.set_integer("spi", "order", self.spi_order.get_selected())
        key.set_string("i2c", "hz", self.i2c_hz.get_text())
        key.set_integer("i2c", "sda", self.i2c_sda.get_value_as_int())
        key.set_integer("i2c", "scl", self.i2c_scl.get_value_as_int())
        key.set_integer("i2c", "hold", int(self._i2c_hold.get_active()))
        key.set_string("uart", "hz", self.uart_hz.get_text())
        key.set_integer("uart", "tx", self.uart_tx.get_value_as_int())
        key.set_integer("uart", "rx", self.uart_rx.get_value_as_int())
        key.set_integer("uart", "mark", int(self._uart_mark.get_active()))
        oe, out = self._masks()
        key.set_integer("gpio", "oe", oe)
        key.set_integer("gpio", "out", out)
        try:
            key.save_to_file(str(self._state_path()))
        except GLib.Error:
            pass

    def _on_close(self, *_args):
        self._save_state()
        if self.console is not None:
            self.console.close()
            self.console = None
        return False

    @staticmethod
    def _str(key, group, name):
        try:
            return key.get_string(group, name)
        except GLib.Error:
            return ""

    @staticmethod
    def _int(key, group, name):
        try:
            return key.get_integer(group, name)
        except GLib.Error:
            return None

    def _restore(self, key, group, name, setter):
        value = self._str(key, group, name)
        if value:
            setter(value)

    def _restore_hz(self, key, group, entry):
        value = self._str(key, group, "hz")
        if not value:
            return
        try:
            entry.set_text(format_hz(parse_hz(value)))
        except ValueError:
            entry.set_text(value)

    def _restore_spin(self, key, group, name, spin):
        value = self._int(key, group, name)
        if value is not None:
            spin.set_value(value)
