#include "player.h"

#include "xil_io.h"
#include "xparameters.h"

#define PLAYER_BASE XPAR_PMOD_STREAM_0_BASEADDR

#define REG_CTRL     0x0000u
#define REG_STATUS   0x0004u
#define REG_LENGTH   0x0008u
#define REG_CAPCOUNT 0x000Cu
#define REG_IDLE_OUT 0x0010u
#define REG_IDLE_OE  0x0014u
#define REG_PIN_IN   0x0018u
#define TX_BASE      0x1000u
#define RX_BASE      0x9000u

#define ST_BUSY  0x1u
#define ST_DONE  0x2u
#define ST_FAULT 0x4u

void player_init(void)
{
    Xil_Out32(PLAYER_BASE + REG_STATUS, ST_DONE | ST_FAULT);
    Xil_Out32(PLAYER_BASE + REG_IDLE_OE, 0);
    Xil_Out32(PLAYER_BASE + REG_IDLE_OUT, 0);
}

void player_set_idle(uint8_t oe, uint8_t out)
{
    Xil_Out32(PLAYER_BASE + REG_IDLE_OE, oe);
    Xil_Out32(PLAYER_BASE + REG_IDLE_OUT, out);
}

uint8_t player_read_pins(void)
{
    return (uint8_t)(Xil_In32(PLAYER_BASE + REG_PIN_IN) & 0xFFu);
}

int player_load(int offset, const uint32_t *words, int count)
{
    int i;
    if (offset < 0 || count < 0 || offset + count > 8192)
        return -1;
    for (i = 0; i < count; i++)
        Xil_Out32(PLAYER_BASE + TX_BASE + ((uint32_t)(offset + i) << 2), words[i]);
    return 0;
}

static void read_cap(uint8_t *cap, int n)
{
    int i;
    for (i = 0; i < n; i++)
        cap[i] = player_sample(i);
}

uint8_t player_sample(int index)
{
    uint32_t w;
    if (index < 0)
        return 0;
    w = Xil_In32(PLAYER_BASE + RX_BASE + ((uint32_t)(index >> 2) << 2));
    return (uint8_t)((w >> (8 * (index & 3))) & 0xFFu);
}

int player_play(const uint32_t *words, int count, uint8_t *cap, int cap_max)
{
    if (player_load(0, words, count))
        return -1;
    return player_start(count, cap, cap_max);
}

int player_start(int count, uint8_t *cap, int cap_max)
{
    uint32_t spins;
    uint32_t status;

    if (count <= 0 || count > 8192)
        return -1;

    Xil_Out32(PLAYER_BASE + REG_STATUS, ST_DONE | ST_FAULT);
    Xil_Out32(PLAYER_BASE + REG_LENGTH, (uint32_t)count);
    Xil_Out32(PLAYER_BASE + REG_CTRL, 0x1u);

    for (spins = 0; spins < 200000000u; spins++) {
        status = Xil_In32(PLAYER_BASE + REG_STATUS);
        if ((status & ST_DONE) && !(status & ST_BUSY))
            break;
    }
    if (!(status & ST_DONE) || (status & ST_FAULT) || (status & ST_BUSY))
        return -1;

    if (cap != 0 && cap_max > 0) {
        uint32_t got = Xil_In32(PLAYER_BASE + REG_CAPCOUNT) & 0xFFFFu;
        int n = (int)got;
        if (n > count)
            n = count;
        if (n > cap_max)
            n = cap_max;
        read_cap(cap, n);
    }
    return 0;
}
