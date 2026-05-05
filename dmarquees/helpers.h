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

FrontendMode toFrontendMode(const char* s);
const char*  fromFrontendMode(FrontendMode m);

// Control panels and conversion helpers
typedef enum
{
    ePANEL_NA = 0,  // no panel selected
    eATARI_MC = 1,  // Atari MicroCenter
    eULTRA_DC = 2,  // UltraStick, 2x spinners
    eWHEEL_MK = 3   // MarioKart wheel controller
} ControlPanel;

ControlPanel toControlPanel(const char* s);

// Command type enum and conversion helpers
typedef enum
{
    CMD_UNKNOWN = -1,
    CMD_EXIT = 0,
    CMD_CLEAR = 1,
    CMD_RA = 2,
    CMD_SA = 3,
    CMD_NA = 4,
    CMD_RESET = 5,
    CMD_REFRESH = 6,
    CMD_ROM = 7,
    CMD_DCPANEL = 8,
    CMD_MCPANEL = 9,
    CMD_MKWHEEL = 10
} CommandType;

CommandType toCommandType(const char *s);
const char *fromCommandType(CommandType c);

uint8_t *load_png_rgba(const char *path, int *out_w, int *out_h);
bool game_has_multiple_screens(const char *romname);
void scale_and_blit_to_xrgb(const uint8_t *src_rgba, int src_w, int src_h,
                            uint32_t *dst, int dst_w, int dst_h, int dst_stride,
                            int dest_x, bool center);
char *trim(char *s, size_t len);

// Get current timestamp in HH:MM:SS format
void get_timestamp(char *buffer, size_t size);

// Timestamped printf wrapper
void ts_printf(const char *format, ...);

// Timestamped fprintf wrapper
void ts_fprintf(FILE *stream, const char *format, ...);

// Timestamped perror wrapper
void ts_perror(const char *s);

#endif
