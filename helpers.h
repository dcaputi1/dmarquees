#ifndef HELPERS_H
#define HELPERS_H
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <png.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

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

    // Global frontend mode (defined in dmarquees.c)
    extern FrontendMode g_frontend_mode;
// Command type enum and conversion helpers
typedef enum
{
    CMD_EXIT = 0,
    CMD_CLEAR = 1,
    CMD_RA = 2,
    CMD_SA = 3,
    CMD_NA = 4,
    CMD_ROM = 5
} CommandType;

CommandType toCommandType(const char *s);
const char *fromCommandType(CommandType c);

uint8_t *load_png_rgba(const char *path, int *out_w, int *out_h);
bool game_has_multiple_screens(const char *romname);
void scale_and_blit_to_xrgb(const uint8_t *src_rgba, int src_w, int src_h,
                            uint32_t *dst, int dst_w, int dst_h, int dst_stride,
                            int dest_x, int dest_y);
char *trim(char *s);
int parseFrontendModeArg(int argc, char **argv);

// Get current timestamp in HH:MM:SS format
void get_timestamp(char *buffer, size_t size);

// Timestamped printf wrapper
void ts_printf(const char *format, ...);

// Timestamped fprintf wrapper
void ts_fprintf(FILE *stream, const char *format, ...);

// Timestamped perror wrapper
void ts_perror(const char *s);

#endif
