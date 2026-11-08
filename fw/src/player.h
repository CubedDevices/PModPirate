#ifndef PLAYER_H
#define PLAYER_H

#include <stdint.h>

void player_init(void);
void player_set_idle(uint8_t oe, uint8_t out);
uint8_t player_read_pins(void);

/* Copy words into the player TX buffer at `offset`. */
int player_load(int offset, const uint32_t *words, int count);

/* Play `total` words already loaded at offset 0. `cap` may be NULL. */
int player_start(int total, uint8_t *cap, int cap_max);

/* One captured pin byte from the most recent play. */
uint8_t player_sample(int index);

/* Load then play. */
int player_play(const uint32_t *words, int count, uint8_t *cap, int cap_max);

#endif
