#include "console.h"

#include "player.h"
#include "stream_word.h"
#include "wave.h"

#include "xil_printf.h"

#include <stdlib.h>
#include <string.h>

#define CHUNK_WORDS 512
#define LINE_MAX    240

enum {
    MODE_GPIO = 0,
    MODE_SPI,
    MODE_I2C,
    MODE_UART
};

static int g_mode = MODE_GPIO;
static uint32_t g_hz = 1000000;
static int g_spi_mode = 0;
static int g_spi_msb = 1;
static uint8_t g_idle_oe;
static uint8_t g_idle_out;

/* Pmod SPI: pin 1 CS, pin 2 MOSI, pin 3 MISO, pin 4 SCK. */
static spi_cfg_t g_spi = {0, 3, 1, 2, 0, 1, 0};
static i2c_cfg_t g_i2c = {0, 1, 0};
static uart_cfg_t g_uart = {0, 1, 0};

static uint32_t g_raw[64];
static int g_raw_n;

static uint32_t g_chunk[CHUNK_WORDS];
static uint8_t g_cap[CHUNK_WORDS];

extern char inbyte(void);

static void ok(const char *msg)
{
    xil_printf("OK %s\r\n", msg);
}

static void ok_bare(void)
{
    xil_printf("OK\r\n");
}

static void err(const char *msg)
{
    xil_printf("ERR %s\r\n", msg);
}

static int parse_u32(const char *s, uint32_t *out)
{
    char *end;
    unsigned long v;
    if (s == 0 || *s == '\0')
        return -1;
    v = strtoul(s, &end, 0);
    if (end == s || *end != '\0')
        return -1;
    *out = (uint32_t)v;
    return 0;
}

static int nibble(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/* Read a hex string into bytes. Odd trailing nibble is rejected. */
static int parse_hex_bytes(const char *s, uint8_t *dst, int max)
{
    int n = 0;
    int hi = -1;
    if (s == 0)
        return -1;
    for (; *s; s++) {
        int d;
        if (*s == ' ' || *s == '\t')
            continue;
        d = nibble(*s);
        if (d < 0)
            return -1;
        if (hi < 0) {
            hi = d;
        } else {
            if (n >= max)
                return -1;
            dst[n++] = (uint8_t)((hi << 4) | d);
            hi = -1;
        }
    }
    if (hi >= 0)
        return -1;
    return n;
}

static int pin_ok(int pin)
{
    return pin >= 0 && pin <= 7;
}

static int apply_rate(void)
{
    uint32_t half = stream_half_ticks(g_hz);
    uint32_t bit = (g_hz == 0) ? 0 : (PLAY_HZ / g_hz);
    if (half == 0)
        return -1;
    g_spi.half_ticks = half;
    g_spi.mode = g_spi_mode;
    g_spi.msb_first = g_spi_msb;
    g_i2c.half_ticks = half;
    if (bit < 2)
        return -1;
    g_uart.bit_ticks = bit;
    return 0;
}

static int play_chunk(const uint32_t *words, int n, uint8_t *cap)
{
    if (n <= 0)
        return 0;
    return player_play(words, n, cap, n);
}

static void hex_out(const uint8_t *b, int n)
{
    int i;
    xil_printf("OK ");
    for (i = 0; i < n; i++)
        xil_printf("%02x", b[i]);
    xil_printf("\r\n");
}

static void cmd_help(void)
{
    xil_printf("OK commands:\r\n");
    xil_printf("  id\r\n");
    xil_printf("  mode gpio|spi|i2c|uart\r\n");
    xil_printf("  hz <rate>\r\n");
    xil_printf("  pins spi <cs> <sck> <mosi> <miso>\r\n");
    xil_printf("  pins i2c <sda> <scl>\r\n");
    xil_printf("  pins uart <tx> <rx>\r\n");
    xil_printf("  oe <mask>  out <mask>  in\r\n");
    xil_printf("  pulse <mask> <ticks>\r\n");
    xil_printf("  spi.mode <0-3>  spi.order msb|lsb  spi xfer <hex>\r\n");
    xil_printf("  i2c start|stop|write <hex>|read <n>\r\n");
    xil_printf("  uart tx <hex>  uart rx <nbytes>\r\n");
    xil_printf("  buf.words <hex...>  play\r\n");
}

static void cmd_spi_xfer(const char *hex)
{
    uint8_t bytes[256];
    uint8_t miso[256];
    int nbytes, i;
    int offset = 0;
    int starts[256];

    if (g_mode != MODE_SPI) {
        err("mode");
        return;
    }
    nbytes = parse_hex_bytes(hex, bytes, (int)sizeof bytes);
    if (nbytes < 0) {
        err("hex");
        return;
    }
    if (apply_rate()) {
        err("rate");
        return;
    }
    memset(miso, 0, (size_t)nbytes);
    for (i = 0; i < nbytes; i++) {
        uint32_t one[18];
        int lead = (i == 0);
        int trail = (i == nbytes - 1);
        int n = wave_spi_bytes(&g_spi, &bytes[i], 1, one, 18, lead, trail);
        if (n < 0) {
            err("wave");
            return;
        }
        starts[i] = offset;
        if (player_load(offset, one, n)) {
            err("full");
            return;
        }
        offset += n;
    }
    if (player_start(offset, 0, 0)) {
        err("play");
        return;
    }
    for (i = 0; i < nbytes; i++) {
        int bit;
        int lead = (i == 0);
        for (bit = 0; bit < 8; bit++) {
            int idx = starts[i] + wave_spi_sample_index(bit, lead);
            int level = (player_sample(idx) >> g_spi.miso) & 1;
            if (g_spi.msb_first)
                miso[i] = (uint8_t)((miso[i] << 1) | level);
            else
                miso[i] = (uint8_t)(miso[i] | (level << bit));
        }
    }
    hex_out(miso, nbytes);
}

static void cmd_i2c_write(const char *hex)
{
    uint8_t bytes[128];
    int nbytes, i;
    if (g_mode != MODE_I2C) {
        err("mode");
        return;
    }
    nbytes = parse_hex_bytes(hex, bytes, (int)sizeof bytes);
    if (nbytes < 0) {
        err("hex");
        return;
    }
    if (apply_rate()) {
        err("rate");
        return;
    }
    int offset = 0;
    for (i = 0; i < nbytes; i++) {
        int n = wave_i2c_write(&g_i2c, &bytes[i], 1, g_chunk, CHUNK_WORDS);
        if (n < 0 || player_load(offset, g_chunk, n)) {
            err("wave");
            return;
        }
        offset += n;
    }
    if (player_start(offset, 0, 0)) {
        err("play");
        return;
    }
    ok_bare();
}

static void cmd_i2c_read(int n)
{
    uint8_t got[64];
    int b;
    if (g_mode != MODE_I2C) {
        err("mode");
        return;
    }
    if (n < 1 || n > (int)sizeof got) {
        err("length");
        return;
    }
    if (apply_rate()) {
        err("rate");
        return;
    }
    int offset = 0;
    int starts[64];
    for (b = 0; b < n; b++) {
        int last = (b == n - 1);
        int nw = wave_i2c_read(&g_i2c, 1, last ? 0 : 1, g_chunk, CHUNK_WORDS);
        if (nw < 0 || player_load(offset, g_chunk, nw)) {
            err("wave");
            return;
        }
        starts[b] = offset;
        offset += nw;
    }
    if (player_start(offset, 0, 0)) {
        err("play");
        return;
    }
    for (b = 0; b < n; b++) {
        int bit;
        uint8_t val = 0;
        /* 8 data bits then ACK. Each bit is two words; sample is the second. */
        for (bit = 0; bit < 8; bit++) {
            int idx = starts[b] + bit * 2 + 1;
            int level = (player_sample(idx) >> g_i2c.sda) & 1;
            val = (uint8_t)((val << 1) | level);
        }
        got[b] = val;
    }
    hex_out(got, n);
}

static void cmd_uart_tx(const char *hex)
{
    uint8_t bytes[64];
    int nbytes, i;
    if (g_mode != MODE_UART) {
        err("mode");
        return;
    }
    nbytes = parse_hex_bytes(hex, bytes, (int)sizeof bytes);
    if (nbytes < 0) {
        err("hex");
        return;
    }
    if (apply_rate()) {
        err("rate");
        return;
    }
    int offset = 0;
    for (i = 0; i < nbytes; i++) {
        int n = wave_uart_tx(&g_uart, &bytes[i], 1, g_chunk, CHUNK_WORDS);
        if (n < 0 || player_load(offset, g_chunk, n)) {
            err("wave");
            return;
        }
        offset += n;
    }
    if (player_start(offset, 0, 0)) {
        err("play");
        return;
    }
    ok_bare();
}

static void cmd_uart_rx(int n)
{
    uint8_t got[32];
    int b;
    if (g_mode != MODE_UART) {
        err("mode");
        return;
    }
    if (n < 1 || n > (int)sizeof got) {
        err("length");
        return;
    }
    if (apply_rate()) {
        err("rate");
        return;
    }
    int offset = 0;
    int starts[32];
    for (b = 0; b < n; b++) {
        int nw = wave_uart_rx(&g_uart, 1, g_chunk, CHUNK_WORDS);
        if (nw < 0 || player_load(offset, g_chunk, nw)) {
            err("wave");
            return;
        }
        starts[b] = offset;
        offset += nw;
    }
    if (player_start(offset, 0, 0)) {
        err("play");
        return;
    }
    for (b = 0; b < n; b++) {
        int bit;
        uint8_t val = 0;
        /* start, 8 data LSB first, stop. Each bit is two words; sample the first. */
        for (bit = 0; bit < 8; bit++) {
            int idx = starts[b] + (1 + bit) * 2;
            int level = (player_sample(idx) >> g_uart.rx) & 1;
            val = (uint8_t)(val | (level << bit));
        }
        got[b] = val;
    }
    hex_out(got, n);
}

static void handle(char *line)
{
    char *cmd;
    char *a1;
    char *a2;

    while (*line == ' ' || *line == '\t')
        line++;
    if (*line == '\0')
        return;

    cmd = strtok(line, " \t");
    if (cmd == 0)
        return;

    if (!strcmp(cmd, "help")) {
        cmd_help();
        return;
    }
    if (!strcmp(cmd, "id")) {
        ok("pmodpirate");
        return;
    }
    if (!strcmp(cmd, "mode")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "gpio"))
            g_mode = MODE_GPIO;
        else if (a1 && !strcmp(a1, "spi"))
            g_mode = MODE_SPI;
        else if (a1 && !strcmp(a1, "i2c"))
            g_mode = MODE_I2C;
        else if (a1 && !strcmp(a1, "uart"))
            g_mode = MODE_UART;
        else {
            err("mode");
            return;
        }
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "hz")) {
        uint32_t v;
        a1 = strtok(0, " \t");
        if (parse_u32(a1, &v) || v == 0) {
            err("hz");
            return;
        }
        g_hz = v;
        if (apply_rate()) {
            err("rate");
            return;
        }
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "pins")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "spi")) {
            uint32_t p[4];
            int i;
            for (i = 0; i < 4; i++) {
                int j;
                if (parse_u32(strtok(0, " \t"), &p[i]) || !pin_ok((int)p[i])) {
                    err("pins");
                    return;
                }
                for (j = 0; j < i; j++) {
                    if (p[j] == p[i]) {
                        err("pins");
                        return;
                    }
                }
            }
            g_spi.cs = (int)p[0];
            g_spi.sck = (int)p[1];
            g_spi.mosi = (int)p[2];
            g_spi.miso = (int)p[3];
            ok_bare();
            return;
        }
        if (a1 && !strcmp(a1, "i2c")) {
            uint32_t sda, scl;
            if (parse_u32(strtok(0, " \t"), &sda) || parse_u32(strtok(0, " \t"), &scl) ||
                !pin_ok((int)sda) || !pin_ok((int)scl)) {
                err("pins");
                return;
            }
            g_i2c.sda = (int)sda;
            g_i2c.scl = (int)scl;
            ok_bare();
            return;
        }
        if (a1 && !strcmp(a1, "uart")) {
            uint32_t tx, rx;
            if (parse_u32(strtok(0, " \t"), &tx) || parse_u32(strtok(0, " \t"), &rx) ||
                !pin_ok((int)tx) || !pin_ok((int)rx)) {
                err("pins");
                return;
            }
            g_uart.tx = (int)tx;
            g_uart.rx = (int)rx;
            ok_bare();
            return;
        }
        err("pins");
        return;
    }
    if (!strcmp(cmd, "oe") || !strcmp(cmd, "out")) {
        uint32_t v;
        a1 = strtok(0, " \t");
        if (parse_u32(a1, &v) || v > 0xFFu) {
            err("mask");
            return;
        }
        if (!strcmp(cmd, "oe"))
            g_idle_oe = (uint8_t)v;
        else
            g_idle_out = (uint8_t)v;
        player_set_idle(g_idle_oe, g_idle_out);
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "in")) {
        xil_printf("OK %02x\r\n", player_read_pins());
        return;
    }
    if (!strcmp(cmd, "pulse")) {
        uint32_t mask, ticks;
        int n;
        a1 = strtok(0, " \t");
        a2 = strtok(0, " \t");
        if (parse_u32(a1, &mask) || parse_u32(a2, &ticks) || mask > 0xFFu) {
            err("pulse");
            return;
        }
        n = wave_gpio_pulse((uint8_t)mask, ticks, g_chunk, CHUNK_WORDS);
        if (n < 0 || play_chunk(g_chunk, n, g_cap)) {
            err("play");
            return;
        }
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "spi.mode")) {
        uint32_t v;
        if (parse_u32(strtok(0, " \t"), &v) || v > 3) {
            err("mode");
            return;
        }
        g_spi_mode = (int)v;
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "spi.order")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "msb"))
            g_spi_msb = 1;
        else if (a1 && !strcmp(a1, "lsb"))
            g_spi_msb = 0;
        else {
            err("order");
            return;
        }
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "spi")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "xfer")) {
            cmd_spi_xfer(strtok(0, ""));
            return;
        }
        err("spi");
        return;
    }
    if (!strcmp(cmd, "i2c")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "start")) {
            int n;
            if (g_mode != MODE_I2C) {
                err("mode");
                return;
            }
            if (apply_rate()) {
                err("rate");
                return;
            }
            n = wave_i2c_start(&g_i2c, g_chunk, CHUNK_WORDS);
            if (n < 0 || play_chunk(g_chunk, n, g_cap))
                err("play");
            else
                ok_bare();
            return;
        }
        if (a1 && !strcmp(a1, "stop")) {
            int n;
            if (g_mode != MODE_I2C) {
                err("mode");
                return;
            }
            if (apply_rate()) {
                err("rate");
                return;
            }
            n = wave_i2c_stop(&g_i2c, g_chunk, CHUNK_WORDS);
            if (n < 0 || play_chunk(g_chunk, n, g_cap))
                err("play");
            else
                ok_bare();
            return;
        }
        if (a1 && !strcmp(a1, "write")) {
            cmd_i2c_write(strtok(0, ""));
            return;
        }
        if (a1 && !strcmp(a1, "read")) {
            uint32_t n;
            if (parse_u32(strtok(0, " \t"), &n)) {
                err("length");
                return;
            }
            cmd_i2c_read((int)n);
            return;
        }
        err("i2c");
        return;
    }
    if (!strcmp(cmd, "uart")) {
        a1 = strtok(0, " \t");
        if (a1 && !strcmp(a1, "tx")) {
            cmd_uart_tx(strtok(0, ""));
            return;
        }
        if (a1 && !strcmp(a1, "rx")) {
            uint32_t n;
            if (parse_u32(strtok(0, " \t"), &n)) {
                err("length");
                return;
            }
            cmd_uart_rx((int)n);
            return;
        }
        err("uart");
        return;
    }
    if (!strcmp(cmd, "buf.words")) {
        g_raw_n = 0;
        for (;;) {
            char *tok = strtok(0, " \t");
            uint32_t w;
            if (tok == 0)
                break;
            if (parse_u32(tok, &w) || g_raw_n >= (int)(sizeof g_raw / sizeof g_raw[0])) {
                err("words");
                g_raw_n = 0;
                return;
            }
            g_raw[g_raw_n++] = w;
        }
        ok_bare();
        return;
    }
    if (!strcmp(cmd, "play")) {
        if (g_raw_n == 0) {
            err("empty");
            return;
        }
        if (play_chunk(g_raw, g_raw_n, g_cap))
            err("play");
        else
            ok_bare();
        return;
    }
    err("command");
}

void console_run(void)
{
    char line[LINE_MAX];
    int n = 0;

    xil_printf("OK pmodpirate\r\n");
    player_init();
    apply_rate();

    for (;;) {
        char c = inbyte();
        if (c == '\r' || c == '\n') {
            line[n] = '\0';
            handle(line);
            n = 0;
            continue;
        }
        if (n < LINE_MAX - 1)
            line[n++] = c;
    }
}
