#include "stream_word.h"
#include "wave.h"

#include <stdio.h>
#include <stdlib.h>

static int g_fails;

static void expect_eq(const char *what, unsigned long got, unsigned long want)
{
    if (got != want) {
        fprintf(stderr, "FAIL %s: got 0x%lx want 0x%lx\n", what, got, want);
        g_fails++;
    }
}

static void test_spi_mode0_a5(void)
{
    spi_cfg_t cfg = {0, 1, 2, 3, 0, 1, 4};
    uint8_t byte = 0xA5;
    uint32_t words[32];
    int n = wave_spi_xfer(&cfg, &byte, 1, words, 32);
    /* 0xA5 MSB first is 1,0,1,0,0,1,0,1. Sample words carry SCK high. */
    const uint8_t sample_dout[8] = {0x06, 0x02, 0x06, 0x02, 0x02, 0x06, 0x02, 0x06};
    int bit;

    expect_eq("spi count", (unsigned long)n, 18);
    expect_eq("spi lead oe", STREAM_OE(words[0]), 0x07);
    expect_eq("spi lead dout", STREAM_DOUT(words[0]), 0x00);
    expect_eq("spi lead dur", STREAM_DUR(words[0]), 4);
    for (bit = 0; bit < 8; bit++) {
        int idx = wave_spi_sample_index(bit, 1);
        char name[32];
        snprintf(name, sizeof name, "spi sample %d", bit);
        expect_eq(name, STREAM_DOUT(words[idx]), sample_dout[bit]);
        expect_eq("spi sample oe", STREAM_OE(words[idx]), 0x07);
        expect_eq("spi sample dur", STREAM_DUR(words[idx]), 4);
        expect_eq("spi sample sck", (STREAM_DOUT(words[idx]) >> 1) & 1, 1);
    }
    expect_eq("spi trail dout", STREAM_DOUT(words[17]), 0x01);
    expect_eq("spi trail cs", STREAM_DOUT(words[17]) & 1, 1);
}

static void test_i2c_start(void)
{
    i2c_cfg_t cfg = {0, 1, 10};
    uint32_t words[8];
    int n = wave_i2c_start(&cfg, words, 8);
    int i;

    expect_eq("i2c start count", (unsigned long)n, 3);
    expect_eq("i2c idle oe", STREAM_OE(words[0]), 0x00);
    expect_eq("i2c idle dout", STREAM_DOUT(words[0]), 0x00);
    /* SDA driven, SCL released: open-drain low is OE with data 0. */
    expect_eq("i2c sda oe", STREAM_OE(words[1]), 0x01);
    expect_eq("i2c sda dout", STREAM_DOUT(words[1]), 0x00);
    expect_eq("i2c both oe", STREAM_OE(words[2]), 0x03);
    expect_eq("i2c both dout", STREAM_DOUT(words[2]), 0x00);
    for (i = 0; i < n; i++)
        expect_eq("i2c dur", STREAM_DUR(words[i]), 10);
}

static void test_uart_55(void)
{
    uart_cfg_t cfg = {0, 1, 10};
    uint8_t byte = 0x55;
    uint32_t words[24];
    int n = wave_uart_tx(&cfg, &byte, 1, words, 24);
    /* 0x55 LSB first: start 0, then 1,0,1,0,1,0,1,0, stop 1. */
    const int level[10] = {0, 1, 0, 1, 0, 1, 0, 1, 0, 1};
    int bit;

    expect_eq("uart count", (unsigned long)n, 20);
    for (bit = 0; bit < 10; bit++) {
        int idx = bit * 2;
        expect_eq("uart oe", STREAM_OE(words[idx]), 0x01);
        expect_eq("uart level", STREAM_DOUT(words[idx]), (unsigned long)level[bit]);
        expect_eq("uart mid", STREAM_DOUT(words[idx + 1]), (unsigned long)level[bit]);
        expect_eq("uart half", STREAM_DUR(words[idx]), 5);
        expect_eq("uart half2", STREAM_DUR(words[idx + 1]), 5);
    }
    /* Mid-bit sample is the first half of each bit. */
    expect_eq("uart start sample", STREAM_DOUT(words[0]), 0);
    expect_eq("uart lsb sample", STREAM_DOUT(words[2]), 1);
}

static void test_long_level(void)
{
    uint32_t words[4];
    int count = 0;
    int rc = wave_emit(words, 4, &count, 0x0F, 0x03, 70000);
    expect_eq("emit rc", (unsigned long)rc, 0);
    expect_eq("emit count", (unsigned long)count, 2);
    expect_eq("emit dur0", STREAM_DUR(words[0]), 65535);
    expect_eq("emit dur1", STREAM_DUR(words[1]), 70000 - 65535);
    expect_eq("emit oe", STREAM_OE(words[0]), 0x0F);
    expect_eq("emit dout", STREAM_DOUT(words[1]), 0x03);
}

static void test_gpio_pulse(void)
{
    uint32_t words[4];
    int n = wave_gpio_pulse(0x80, 20, words, 4);
    expect_eq("pulse count", (unsigned long)n, 2);
    expect_eq("pulse high oe", STREAM_OE(words[0]), 0x80);
    expect_eq("pulse high dout", STREAM_DOUT(words[0]), 0x80);
    expect_eq("pulse low dout", STREAM_DOUT(words[1]), 0x00);
    expect_eq("pulse low oe", STREAM_OE(words[1]), 0x80);
    expect_eq("pulse ticks", STREAM_DUR(words[0]), 20);
}

int main(void)
{
    test_spi_mode0_a5();
    test_i2c_start();
    test_uart_55();
    test_long_level();
    test_gpio_pulse();
    if (g_fails) {
        fprintf(stderr, "%d checks failed\n", g_fails);
        return 1;
    }
    printf("test_wave: PASS\n");
    return 0;
}
