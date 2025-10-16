#ifndef HELPERS_H
#define HELPERS_H
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <png.h>

#define INI_DIR   "/opt/retropie/emulators/mame/ini"

unsigned char* load_png_rgba(const char* path, int* out_w, int* out_h);
bool game_has_multiple_screens(const char *romname);
void scale_and_blit_to_xrgb(uint8_t* src, int sw, int sh, uint32_t* dest, int dw, int dh,
                            int stride_pixels, int dest_x, int dest_y);
char* trim(char* str);
#endif
