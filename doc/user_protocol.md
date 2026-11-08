# PModPirate console protocol

The console is the USB-UART on the Cmod S7-25, 115200 baud, 8 data bits, no parity, one stop bit. The FPGA transmits on package pin L12 and receives on K15. Lines are ASCII. A command ends with a newline or a carriage return. A CR LF pair is one command followed by an empty line, and an empty line is ignored.

Each command produces a reply that ends with `\r\n`:

| Reply | Meaning |
| --- | --- |
| `OK` | The command ran and has nothing else to return. |
| `OK <payload>` | The command ran. The payload is described with that command. |
| `ERR <reason>` | The command was rejected or the player reported a fault. |

After reset the firmware prints one line before it reads anything:

```
OK pmodpirate
```

A terminal opened after boot misses that line. `id` prints it again.

`help` is the exception to the one-reply rule. Its first line is `OK commands:` and the following lines are the command list. Those lines do not start with `OK` or `ERR`. Read them as part of the help text, not as later replies.

A line longer than 239 characters keeps the first 239 and drops the rest. Tokens are separated by spaces or tabs. Integers accept decimal (`1000000`) or `0x` hex (`0x0F`). A leading zero is octal, because the parser uses C `strtoul` with base 0.

## Pins

JA is eight LVCMOS33 pins, index 0 on the left through index 7:

| Index | Package pin |
| --- | --- |
| 0 | J2 |
| 1 | H2 |
| 2 | H4 |
| 3 | F3 |
| 4 | H3 |
| 5 | H1 |
| 6 | G1 |
| 7 | F4 |

Each pin has a weak pull-up. Output enable is per pin. A pin with its enable bit clear is Hi-Z and the pull-up holds it high. A pin with its enable bit set is driven to the data bit.

Reset and the end of every play return the pins to the idle enable and idle data registers. Those registers come up zero, so the port wakes Hi-Z. Set them with `oe` and `out` before a sequence that must hold a level between commands. I2C in particular needs the bus held low across `i2c start`, `i2c write`, and `i2c stop`, because each of those commands is its own play.

I2C waveforms never drive a pin high. A zero is driven. A one releases the pin. Above 100 kHz the on-board pull-ups are not enough. Add external pull-ups.

The status LED is the player busy flag, and a slow blink while the player is idle.

## Rate

`hz` sets one number used by every protocol. The player timebase is 200 MHz, so one tick is 5 ns. The firmware divides that clock with integer arithmetic.

| Protocol | What `hz` means | Tick count |
| --- | --- | --- |
| SPI | SCK frequency | Half-period is `200000000 / (2 * hz)` ticks. |
| I2C | SCL frequency | Each half of SCL is the same half-period. |
| UART | Baud | One bit is `200000000 / hz` ticks. |

The rate must be from 1 to 100000000. Faster than that, a half-period is under one tick and the reply is `ERR rate`. The default is 1000000. A level longer than 65535 ticks is sent as several words. The longest single word is 327.675 µs.

## Defaults

| Setting | Value |
| --- | --- |
| mode | `gpio` |
| hz | `1000000` |
| SPI pins | CS 0, SCK 3, MOSI 1, MISO 2 |
| SPI mode | 0 |
| SPI order | `msb` |
| I2C pins | SDA 0, SCL 1 |
| UART pins | TX 0, RX 1 |
| idle enable and data | `0x00` (Hi-Z) |

SPI, I2C, and UART commands check the current mode and answer `ERR mode` when it does not match. `oe`, `out`, `in`, `pulse`, and `buf.words` / `play` work in any mode.

## Commands

### id

```
id
OK pmodpirate
```

### help

Prints the command list. See the note above about the extra lines.

### mode

```
mode gpio
mode spi
mode i2c
mode uart
```

Reply is `OK`, or `ERR mode` when the name is not one of those four.

### hz

```
hz 1000000
hz 115200
```

Reply is `OK`, `ERR hz` when the token is missing or not an integer, or `ERR rate` when the rate cannot be represented.

### pins

```
pins spi <cs> <sck> <mosi> <miso>
pins i2c <sda> <scl>
pins uart <tx> <rx>
```

Each index is 0 through 7. The four SPI signals must be four different pins. Reply is `OK`, or `ERR pins`.

The default SPI map follows the Pmod connector. Pin 1 is JA0, pin 2 is JA1, pin 3 is JA2, and pin 4 is JA3:

| Signal | JA index | Pmod pin |
| --- | --- | --- |
| CS | 0 | 1 |
| MOSI | 1 | 2 |
| MISO | 2 | 3 |
| SCK | 3 | 4 |

### oe, out, in

```
oe <mask>
out <mask>
in
```

`oe` sets the idle output-enable mask. A 1 drives that pin, a 0 releases it. `out` sets the idle driven level. Both take effect immediately and are restored at the end of every play. A mask above 255 is `ERR mask`.

`in` reads the pins through the player synchronizer:

```
in
OK 03
```

The payload is two lowercase hex digits, one bit per JA pin, bit 0 on the right. This is a sampled level, not a timed capture.

### pulse

```
pulse <mask> <ticks>
```

Drives every pin in `mask` high for `ticks` play clocks, then low for the same time. Pins outside the mask are Hi-Z for the pulse. Idle levels return afterward. `ERR pulse` means a bad argument. `ERR play` means the player faulted.

### spi.mode, spi.order, spi xfer

```
spi.mode <0-3>
spi.order msb
spi.order lsb
spi xfer <hex>
```

`spi.mode` and `spi.order` may be set before `mode spi`. `spi xfer` requires `mode spi`.

The hex payload is an even number of digits. Spaces are allowed. `A5`, `a5`, and `A5 3C` are the same shape of payload. An odd digit or a non-hex character is `ERR hex`. At most 256 bytes are accepted.

Chip select is active low. CS, SCK, and MOSI are driven. MISO is an input. The transfer is one play: CS falls, every bit is clocked, CS rises, then idle is restored. Mode follows the usual CPOL and CPHA pair:

| Mode | Idle SCK | Data changes | MISO is sampled |
| --- | --- | --- | --- |
| 0 | low | while SCK is low | at the end of the SCK-high half |
| 1 | low | while SCK is high | at the end of the following SCK-low half |
| 2 | high | while SCK is high | at the end of the SCK-low half |
| 3 | high | while SCK is low | at the end of the following SCK-high half |

The reply is the bytes read from MISO, lowercase hex with no spaces:

```
spi xfer a5
OK 3c
```

An empty payload is `ERR play`.

### i2c

```
i2c start
i2c stop
i2c write <hex>
i2c read <n>
```

Requires `mode i2c`. These are open-drain waveforms. The selected SDA and SCL pins are driven only for a zero.

`i2c start` releases both pins, pulls SDA low while SCL stays released, then pulls SCL low.

`i2c stop` pulls both low, releases SCL while SDA stays low, then releases SDA.

`i2c write` sends each byte MSB first, then releases SDA for one SCL pulse so the target can ACK. The console does not print the ACK bit. At most 128 bytes. An empty payload is `ERR play`.

`i2c read` clocks `n` bytes with SDA released, and drives ACK low after every byte except the last, which is NACKed. `n` is 1 through 64. The reply is the bytes sampled while SCL was high:

```
i2c read 2
OK 1a4b
```

Each of these four commands is a separate play, and the pins return to idle when it finishes. Hold the bus across a transaction by setting idle to drive SDA and SCL low before `i2c start`, and clear that idle state after `i2c stop`:

```
mode i2c
pins i2c 0 1
hz 100000
oe 0x03
out 0x00
i2c start
i2c write a05a
i2c stop
oe 0x00
```

`i2c write a05a` is the address byte and one data byte. It does not generate START or STOP by itself.

### uart

```
uart tx <hex>
uart rx <nbytes>
```

Requires `mode uart`. Framing is 8N1, least significant bit first. `hz` is the baud. `uart tx` accepts 1 through 64 bytes. An empty payload is `ERR play`. `uart rx` accepts 1 through 32 bytes.

`uart tx` drives the TX pin for the start bit, eight data bits, and the stop bit. Set idle so TX is driven high if the line should mark between commands:

```
mode uart
pins uart 0 1
hz 115200
oe 0x01
out 0x01
uart tx 55
```

`uart rx` is a timed listen, not a UART that waits for a start bit. The window begins when the command is played, so the peer's start bit has to be lined up with that moment. The reply is the bytes assembled from the mid-bit samples:

```
uart rx 1
OK 55
```

During `uart rx` the waveform releases the pins. Idle is restored when the play ends.

### buf.words, play

```
buf.words <word> <word> ...
play
```

Loads a raw player stream and plays it. This is the escape hatch for a waveform the protocol compilers do not build. At most 64 words. Each word is a 32-bit integer, usually written in hex. `play` with an empty buffer is `ERR empty`. A bad token, or a 65th word, is `ERR words` and the buffer is cleared.

The word is little-endian in meaning, high byte first when written as a hex integer:

```
bits 31..24   output enable, 1 = drive
bits 23..16   output data
bits 15..0    duration in 200 MHz ticks, minimum 1
```

`0x01010014` drives pin 0 high for 20 ticks (100 ns). Pins with enable clear are Hi-Z for that word. The player samples all eight pins on the last tick of every word. `play` does not print those samples. It replies `OK`, or `ERR play` if the player faults. A duration of 0 faults.

```
buf.words 0x01010014 0x01010014
play
```

That is pin 0 high for 20 ticks, then pin 0 low for 20 ticks, then back to idle.

## Errors

| Reason | Typical cause |
| --- | --- |
| `command` | The first token is not a command. |
| `mode` | Bad mode name, or a protocol command used in the wrong mode. |
| `hz` | Missing or non-numeric rate. |
| `rate` | Rate is 0 or above 100 MHz. |
| `pins` | Missing index, an index outside 0..7, or two SPI signals on one pin. |
| `mask` | `oe` or `out` is missing or above 255. |
| `pulse` | `pulse` is missing an argument. |
| `order` | Not `msb` or `lsb`. |
| `hex` | Odd length, bad digit, or more bytes than the command allows. |
| `length` | `i2c read` or `uart rx` count is out of range. |
| `words` | A raw word is not an integer, or the raw buffer is full. |
| `empty` | `play` with no words loaded. |
| `full` | The compiled waveform does not fit in the player memory. |
| `wave` | The compiler rejected the request. A pulse of 0 ticks does this. |
| `play` | The player finished with a fault, or there was nothing to play. |
| `spi`, `i2c`, `uart` | The second token is not a known subcommand. |
