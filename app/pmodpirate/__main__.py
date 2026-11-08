"""python -m pmodpirate"""

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio

from pmodpirate.window import PirateWindow


class PirateApp(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id="com.pmodpirate.Console",
            flags=Gio.ApplicationFlags.NON_UNIQUE,
        )

    def do_startup(self):
        Adw.Application.do_startup(self)
        self.set_accels_for_action("win.quit", ["<primary>q"])

    def do_activate(self, *_args):
        win = self.props.active_window
        if win is None:
            win = PirateWindow(self)
        win.present()


def main():
    app = PirateApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
