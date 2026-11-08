#ifndef WAVE_H
#define WAVE_H

#include <stdint.h>

typedef struct {
    int cs;
    int sck;
    int mosi;
    int miso;
    int mode;       /* 0..3 */
    int msb_first;  /* nonzero = MSB first */
    uint32_t half_ticks;
} spi_cfg_t;

typedef struct {
    int sda;
    int scl;
    uint32_t half_ticks;
} i2c_cfg_t;

typedef struct {
    int tx;
    int rx;
    uint32_t bit_ticks;
} uart_cfg_t;

/* Append one level, splitting holds longer than 65535 ticks. Returns 0, or
 * -1 if the buffer would overflow. *count is the running length. */
int wave_emit(uint32_t *words, int max_words, int *count,
              uint8_t oe, uint8_t dout, uint32_t ticks);

/* SPI master bytes. Two words per bit; the second word of each pair is the
 * MISO sample. `lead` asserts CS first, `trail` releases it after the bytes.
 * A chunked transfer sets lead only on the first chunk and trail only on the
 * last, so CS stays low across plays. Returns the word count, or -1. */
int wave_spi_bytes(const spi_cfg_t *cfg, const uint8_t *tx, int nbytes,
                   uint32_t *words, int max_words, int lead, int trail);

/* Full transfer: CS asserted around the bytes. */
int wave_spi_xfer(const spi_cfg_t *cfg, const uint8_t *tx, int nbytes,
                  uint32_t *words, int max_words);

/* Word index of the MISO sample for `bit` when the waveform includes `lead`. */
int wave_spi_sample_index(int bit, int lead);

/* I2C open-drain edges. write/read include the ACK bit as the 9th sample. */
int wave_i2c_start(const i2c_cfg_t *cfg, uint32_t *words, int max_words);
int wave_i2c_stop(const i2c_cfg_t *cfg, uint32_t *words, int max_words);
int wave_i2c_write(const i2c_cfg_t *cfg, const uint8_t *tx, int nbytes,
                   uint32_t *words, int max_words);
int wave_i2c_read(const i2c_cfg_t *cfg, int nbytes, int ack_last,
                  uint32_t *words, int max_words);

/* 8N1. Each bit is two equal halves so the first half ends at mid-bit. */
int wave_uart_tx(const uart_cfg_t *cfg, const uint8_t *tx, int nbytes,
                 uint32_t *words, int max_words);
int wave_uart_rx(const uart_cfg_t *cfg, int nbytes,
                 uint32_t *words, int max_words);

/* Drive `mask` high for `ticks`, then low for `ticks`. Other pins stay Hi-Z. */
int wave_gpio_pulse(uint8_t mask, uint32_t ticks,
                    uint32_t *words, int max_words);

#endif
