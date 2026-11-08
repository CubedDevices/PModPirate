#include "wave.h"
#include "stream_word.h"

static void bit_set(uint8_t *v, int pin, int on)
{
    if (pin < 0 || pin > 7)
        return;
    if (on)
        *v = (uint8_t)(*v | (uint8_t)(1u << pin));
    else
        *v = (uint8_t)(*v & (uint8_t)~(1u << pin));
}

int wave_emit(uint32_t *words, int max_words, int *count,
              uint8_t oe, uint8_t dout, uint32_t ticks)
{
    if (ticks == 0)
        return -1;
    while (ticks > 0) {
        uint32_t slice = ticks > 65535u ? 65535u : ticks;
        if (*count >= max_words)
            return -1;
        words[*count] = STREAM_PACK(oe, dout, (uint16_t)slice);
        *count += 1;
        ticks -= slice;
    }
    return 0;
}

static int spi_bit(const spi_cfg_t *cfg, uint8_t byte, int bit)
{
    int src = cfg->msb_first ? (7 - bit) : bit;
    return (byte >> src) & 1;
}

int wave_spi_sample_index(int bit, int lead)
{
    /* Each bit occupies two words and is sampled on the second. A lead word,
     * when present, is word 0. */
    return (lead ? 2 : 1) + (bit * 2);
}

int wave_spi_xfer(const spi_cfg_t *cfg, const uint8_t *tx, int nbytes,
                  uint32_t *words, int max_words)
{
    return wave_spi_bytes(cfg, tx, nbytes, words, max_words, 1, 1);
}

int wave_spi_bytes(const spi_cfg_t *cfg, const uint8_t *tx, int nbytes,
                   uint32_t *words, int max_words, int lead, int trail)
{
    int count = 0;
    int b, i;
    int cpol, cpha, idle;
    uint8_t oe = 0;

    if (cfg->half_ticks == 0 || nbytes < 0)
        return -1;
    if (cfg->mode < 0 || cfg->mode > 3)
        return -1;
    cpol = (cfg->mode >> 1) & 1;
    cpha = cfg->mode & 1;
    idle = cpol;

    bit_set(&oe, cfg->cs, 1);
    bit_set(&oe, cfg->sck, 1);
    bit_set(&oe, cfg->mosi, 1);

    /* CS falls with SCK at its idle level. */
    if (lead) {
        uint8_t dout = 0;
        bit_set(&dout, cfg->cs, 0);
        bit_set(&dout, cfg->sck, idle);
        if (wave_emit(words, max_words, &count, oe, dout, cfg->half_ticks))
            return -1;
    }

    for (b = 0; b < nbytes; b++) {
        for (i = 0; i < 8; i++) {
            int bit = spi_bit(cfg, tx[b], i);
            uint8_t setup = 0;
            uint8_t sample = 0;
            int setup_clk = cpha ? !idle : idle;
            int sample_clk = cpha ? idle : !idle;
            bit_set(&setup, cfg->cs, 0);
            bit_set(&setup, cfg->sck, setup_clk);
            bit_set(&setup, cfg->mosi, bit);
            bit_set(&sample, cfg->cs, 0);
            bit_set(&sample, cfg->sck, sample_clk);
            bit_set(&sample, cfg->mosi, bit);
            if (wave_emit(words, max_words, &count, oe, setup, cfg->half_ticks))
                return -1;
            if (wave_emit(words, max_words, &count, oe, sample, cfg->half_ticks))
                return -1;
        }
    }

    if (trail) {
        uint8_t dout = 0;
        bit_set(&dout, cfg->cs, 1);
        bit_set(&dout, cfg->sck, idle);
        if (wave_emit(words, max_words, &count, oe, dout, cfg->half_ticks))
            return -1;
    }
    return count;
}

static uint8_t i2c_oe(const i2c_cfg_t *cfg, int sda_low, int scl_low)
{
    uint8_t oe = 0;
    if (sda_low)
        bit_set(&oe, cfg->sda, 1);
    if (scl_low)
        bit_set(&oe, cfg->scl, 1);
    return oe;
}

int wave_i2c_start(const i2c_cfg_t *cfg, uint32_t *words, int max_words)
{
    int count = 0;
    if (cfg->half_ticks == 0)
        return -1;
    /* Bus idle, then SDA falls while SCL is released, then SCL falls. */
    if (wave_emit(words, max_words, &count, 0, 0, cfg->half_ticks))
        return -1;
    if (wave_emit(words, max_words, &count, i2c_oe(cfg, 1, 0), 0, cfg->half_ticks))
        return -1;
    if (wave_emit(words, max_words, &count, i2c_oe(cfg, 1, 1), 0, cfg->half_ticks))
        return -1;
    return count;
}

int wave_i2c_stop(const i2c_cfg_t *cfg, uint32_t *words, int max_words)
{
    int count = 0;
    if (cfg->half_ticks == 0)
        return -1;
    /* SCL rises while SDA is low, then SDA rises. */
    if (wave_emit(words, max_words, &count, i2c_oe(cfg, 1, 1), 0, cfg->half_ticks))
        return -1;
    if (wave_emit(words, max_words, &count, i2c_oe(cfg, 1, 0), 0, cfg->half_ticks))
        return -1;
    if (wave_emit(words, max_words, &count, 0, 0, cfg->half_ticks))
        return -1;
    return count;
}

static int i2c_bit(const i2c_cfg_t *cfg, int sda_low, uint32_t *words,
                   int max_words, int *count)
{
    /* SCL low while SDA is set, then SCL released so the sample word ends
     * with SCL high. */
    if (wave_emit(words, max_words, count, i2c_oe(cfg, sda_low, 1), 0, cfg->half_ticks))
        return -1;
    if (wave_emit(words, max_words, count, i2c_oe(cfg, sda_low, 0), 0, cfg->half_ticks))
        return -1;
    return 0;
}

int wave_i2c_write(const i2c_cfg_t *cfg, const uint8_t *tx, int nbytes,
                   uint32_t *words, int max_words)
{
    int count = 0;
    int b, i;
    if (cfg->half_ticks == 0 || nbytes < 0)
        return -1;
    for (b = 0; b < nbytes; b++) {
        for (i = 7; i >= 0; i--) {
            if (i2c_bit(cfg, ((tx[b] >> i) & 1) == 0, words, max_words, &count))
                return -1;
        }
        /* ACK bit: release SDA so the target can pull it. */
        if (i2c_bit(cfg, 0, words, max_words, &count))
            return -1;
    }
    return count;
}

int wave_i2c_read(const i2c_cfg_t *cfg, int nbytes, int ack_last,
                  uint32_t *words, int max_words)
{
    int count = 0;
    int b, i;
    if (cfg->half_ticks == 0 || nbytes < 0)
        return -1;
    for (b = 0; b < nbytes; b++) {
        for (i = 0; i < 8; i++) {
            if (i2c_bit(cfg, 0, words, max_words, &count))
                return -1;
        }
        /* ACK low except after the last byte when ack_last is clear (NACK). */
        {
            int last = (b == nbytes - 1);
            int drive_ack = !(last && !ack_last);
            if (i2c_bit(cfg, drive_ack, words, max_words, &count))
                return -1;
        }
    }
    return count;
}

static int uart_bit(const uart_cfg_t *cfg, int line_high, int drive,
                    uint32_t *words, int max_words, int *count)
{
    uint32_t half = cfg->bit_ticks / 2u;
    uint32_t rest = cfg->bit_ticks - half;
    uint8_t oe = 0;
    uint8_t dout = 0;
    if (half == 0 || rest == 0)
        return -1;
    if (drive) {
        bit_set(&oe, cfg->tx, 1);
        bit_set(&dout, cfg->tx, line_high);
    }
    /* First half ends at mid-bit: that capture is the bit sample. */
    if (wave_emit(words, max_words, count, oe, dout, half))
        return -1;
    if (wave_emit(words, max_words, count, oe, dout, rest))
        return -1;
    return 0;
}

static int uart_frame(const uart_cfg_t *cfg, int byte_or_minus, int drive,
                      uint32_t *words, int max_words, int *count)
{
    int i;
    if (uart_bit(cfg, 0, drive, words, max_words, count))
        return -1;
    for (i = 0; i < 8; i++) {
        int high = 1;
        if (byte_or_minus >= 0)
            high = (byte_or_minus >> i) & 1;
        if (uart_bit(cfg, high, drive, words, max_words, count))
            return -1;
    }
    if (uart_bit(cfg, 1, drive, words, max_words, count))
        return -1;
    return 0;
}

int wave_uart_tx(const uart_cfg_t *cfg, const uint8_t *tx, int nbytes,
                 uint32_t *words, int max_words)
{
    int count = 0;
    int b;
    if (cfg->bit_ticks < 2 || nbytes < 0)
        return -1;
    for (b = 0; b < nbytes; b++) {
        if (uart_frame(cfg, tx[b], 1, words, max_words, &count))
            return -1;
    }
    return count;
}

int wave_uart_rx(const uart_cfg_t *cfg, int nbytes,
                 uint32_t *words, int max_words)
{
    int count = 0;
    int b;
    if (cfg->bit_ticks < 2 || nbytes < 0)
        return -1;
    for (b = 0; b < nbytes; b++) {
        if (uart_frame(cfg, -1, 0, words, max_words, &count))
            return -1;
    }
    return count;
}

int wave_gpio_pulse(uint8_t mask, uint32_t ticks,
                    uint32_t *words, int max_words)
{
    int count = 0;
    if (wave_emit(words, max_words, &count, mask, mask, ticks))
        return -1;
    if (wave_emit(words, max_words, &count, mask, 0, ticks))
        return -1;
    return count;
}
