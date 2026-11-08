# PModPirate console

A GTK application for the board's USB-UART. It speaks the command set in `doc/user_protocol.md` at 115200 8N1. The same sources run on Linux and Windows. Serial ports are `COMn` or `/dev/ttyUSB*`; nothing in the app assumes a Linux device path.

## Linux

```sh
sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1 python3-serial
cd app
python3 -m pmodpirate
```

## Windows

Install [MSYS2](https://www.msys2.org/), open the **UCRT64** shell, and install GTK plus PyGObject:

```sh
pacman -S mingw-w64-ucrt-x86_64-gtk4 mingw-w64-ucrt-x86_64-libadwaita mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-python-gobject mingw-w64-ucrt-x86_64-python-pip
python -m pip install pyserial
cd /c/path/to/PModPirate/app
python -m pmodpirate
```

Run it from that UCRT64 shell so Python can see the GTK libraries. The board shows up as a COM port. Pick it in the port field and press Connect. The app asks the board for `id` and expects `OK pmodpirate`.

The last port, window size, and pin settings are stored in the user config directory (`%APPDATA%/pmodpirate` on Windows, `~/.config/pmodpirate` on Linux).
