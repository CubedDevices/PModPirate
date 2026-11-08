#ifndef STREAM_WORD_H
#define STREAM_WORD_H

#include <stdint.h>

/* Play-domain timebase. A word holds its pins for `duration` of these clocks. */
#define PLAY_HZ 200000000u

#define STREAM_PACK(oe, dout, dur) \
    (((uint32_t)(uint8_t)(oe) << 24) | ((uint32_t)(uint8_t)(dout) << 16) | \
     ((uint32_t)(uint16_t)(dur)))

#define STREAM_OE(w)   ((uint8_t)(((w) >> 24) & 0xFFu))
#define STREAM_DOUT(w) ((uint8_t)(((w) >> 16) & 0xFFu))
#define STREAM_DUR(w)  ((uint16_t)((w) & 0xFFFFu))

#define PMOD_TX_WORDS 8192

/* Half-period of a square wave at `hz`, in play clocks. 0 if `hz` is not
 * representable (zero, or so fast that a half-period is under one tick). */
static inline uint32_t stream_half_ticks(uint32_t hz)
{
    if (hz == 0 || hz > (PLAY_HZ / 2u))
        return 0;
    return PLAY_HZ / (2u * hz);
}

#endif
