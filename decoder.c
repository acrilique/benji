/*
 * Benji: a Discord bot that plays a folder of audio files in a voice channel.
 *
 * Copyright (C) 2026 Lluc Simó Margalef <lluc.simo@protonmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DEVICE_IO
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#include "vendor/miniaudio/miniaudio.h"
#include <stdlib.h>
#include <stdint.h>

void *decoder_open(const char *path) {
    ma_decoder_config config = ma_decoder_config_init(ma_format_s16, 2, 48000);
    ma_decoder *decoder = malloc(sizeof(ma_decoder));
    if (!decoder) return NULL;
    if (ma_decoder_init_file(path, &config, decoder) != MA_SUCCESS) {
        free(decoder);
        return NULL;
    }
    return decoder;
}

// Returns frames read, 0 at end of file, -1 on error.
int64_t decoder_read(void *decoder, int16_t *out, uint64_t frames) {
    ma_uint64 read = 0;
    ma_result result = ma_decoder_read_pcm_frames(decoder, out, frames, &read);
    if (result != MA_SUCCESS && result != MA_AT_END) return -1;
    return (int64_t)read;
}

void decoder_close(void *decoder) {
    if (!decoder) return;
    ma_decoder_uninit(decoder);
    free(decoder);
}
