#ifndef HELPERS_H
#define HELPERS_H
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <png.h>

#define INI_DIR   "/opt/retropie/emulators/mame/ini"

// Frontend mode enum and conversion helpers
typedef enum
{
    eNA = 0, // no frontend specified
    eSA = 1,
    eRA = 2
} FrontendMode;

FrontendMode toFrontendMode(const char *s);
const char *fromFrontendMode(FrontendMode m);

// Command type enum and conversion helpers
typedef enum
{
    CMD_EXIT = 0,
    CMD_CLEAR = 1,
    CMD_RA = 2,
    CMD_SA = 3,
    CMD_ROM = 4
} CommandType;

CommandType toCommandType(const char *s);
const char *fromCommandType(CommandType c);

unsigned char* load_png_rgba(const char* path, int* out_w, int* out_h);
bool game_has_multiple_screens(const char *romname);
void scale_and_blit_to_xrgb(uint8_t* src, int sw, int sh, uint32_t* dest, int dw, int dh,
                            int stride_pixels, int dest_x, int dest_y);
char* trim(char* str);
int parseFrontendModeArg(int argc, char **argv);
#endif
