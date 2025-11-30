#define _POSIX_C_SOURCE 199309L  // For clock_gettime
#include "helpers.h"
#include <ctype.h>
#include <png.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h> // for strcasecmp
#include <time.h>
#include <unistd.h> // for getopt/optarg

/* Minimal PNG loader using libpng. Returns malloc'd RGBA (8-bit per channel) buffer. */
uint8_t *load_png_rgba(const char *path, int *out_w, int *out_h)
{
    FILE *fp = fopen(path, "rb");
    if (!fp)
    {
        perror("fopen");
        return NULL;
    }
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png)
    {
        fclose(fp);
        return NULL;
    }
    png_infop info = png_create_info_struct(png);
    if (!info)
    {
        png_destroy_read_struct(&png, NULL, NULL);
        fclose(fp);
        return NULL;
    }
    if (setjmp(png_jmpbuf(png)))
    {
        png_destroy_read_struct(&png, &info, NULL);
        fclose(fp);
        return NULL;
    }

    png_init_io(png, fp);
    png_read_info(png, info);

    int width = png_get_image_width(png, info);
    int height = png_get_image_height(png, info);
    png_byte color_type = png_get_color_type(png, info);
    png_byte bit_depth = png_get_bit_depth(png, info);

    if (bit_depth == 16)
        png_set_strip_16(png);
    if (color_type == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8)
        png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS))
        png_set_tRNS_to_alpha(png);

    png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    png_set_gray_to_rgb(png);
    png_read_update_info(png, info);

    png_size_t rowbytes = png_get_rowbytes(png, info);
    uint8_t *data = malloc(rowbytes * height);
    if (!data)
    {
        png_destroy_read_struct(&png, &info, NULL);
        fclose(fp);
        return NULL;
    }

    png_bytep *rows = malloc(sizeof(png_bytep) * height);
    for (int y = 0; y < height; y++)
        rows[y] = data + y * rowbytes;
    png_read_image(png, rows);
    free(rows);

    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);

    *out_w = width;
    *out_h = height;
    return data;
}

// Returns true if the game appears to use multiple screens
bool game_has_multiple_screens(const char *romname)
{
    char inipath[512];
    snprintf(inipath, sizeof(inipath), "%s/%s.ini", INI_DIR, romname);

    FILE *fp = fopen(inipath, "r");
    if (!fp)
        return false; // No ini file, assume single-screen

    char line[256];
    bool multi = false;
    while (fgets(line, sizeof(line), fp))
    {
        if (strncasecmp(line, "numscreens", 10) == 0)
        {
            // parse "numscreens <n>" using strtol to avoid sscanf
            char *p = line + 10; // after "numscreens"
            while (*p && isspace((unsigned char)*p))
                ++p;
            if (*p)
            {
                char *endptr = NULL;
                long val = strtol(p, &endptr, 10);
                if (endptr != p && val > 1)
                    multi = true;
            }
            break;
        }
    }

    fclose(fp);
    return multi;
}

/* Nearest-neighbor scale/blit RGBA -> XRGB8888 framebuffer (dest is uint32_t array) */
void scale_and_blit_to_xrgb(const uint8_t *src_rgba, int src_w, int src_h, uint32_t *dst, int dst_w, int dst_h,
                            int dst_stride, int dest_x, int dest_y)
{
    if (!src_rgba || !dst)
        return;

    // Determine destination region: fill width and from dest_y to bottom.
    int dst_x0 = dest_x >= 0 ? dest_x : 0;
    int dst_y0 = dest_y >= 0 ? dest_y : 0;
    int region_w = dst_w - dst_x0;
    int region_h = dst_h - dst_y0;
    if (region_w <= 0 || region_h <= 0)
        return;

    for (int y = 0; y < region_h; ++y)
    {
        int src_y = (y * src_h) / region_h;
        const uint8_t *src_row = src_rgba + (size_t)src_y * src_w * 4;
        uint32_t *dst_row = dst + (size_t)(dst_y0 + y) * dst_stride + dst_x0;
        for (int x = 0; x < region_w; ++x)
        {
            int src_x = (x * src_w) / region_w;
            const uint8_t *p = src_row + src_x * 4;
            uint8_t r = p[0];
            uint8_t g = p[1];
            uint8_t b = p[2];
            uint32_t pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
            dst_row[x] = pixel;
        }
    }
}

char *trim(char *s, size_t len)
{
    if (!s)
        return s;
    s[--len] = '\0'; // ensure null-termination
    // trim right
    while (len > 0 && isspace(s[len - 1]))
        s[--len] = '\0';
    // trim left
    char *p = s;
    while (*p && isspace(*p))
        ++p;
    if (p != s)
        memmove(s, p, strlen(p) + 1);
    if (strlen(s) == 0)
        return NULL;

    return s;
}

FrontendMode toFrontendMode(const char *s)
{
    if (!s)
        return eNA;
    if (strcmp(s, "RA") == 0 || strcmp(s, "RetroArch") == 0)
        return eRA;
    if (strcmp(s, "SA") == 0 || strcmp(s, "StandAlone") == 0)
        return eSA;

    return eNA;
}

const char *fromFrontendMode(FrontendMode m)
{
    switch (m)
    {
    case eRA:
        return "RA";
    case eSA:
        return "SA";
    case eNA:
    default:
        return "NA";
    }
}

int parseFrontendModeArg(int argc, char **argv)
{
    extern FrontendMode g_frontend_mode;
    int opt;
    while ((opt = getopt(argc, argv, "f:h")) != -1)
    {
        switch (opt)
        {
        case 'f':
            g_frontend_mode = toFrontendMode(optarg);
            if (g_frontend_mode == eNA && strcmp(optarg, "NA") != 0 && strcmp(optarg, "None") != 0)
            {
                fprintf(stderr, "error: invalid frontend '%s'\n", optarg);
                fprintf(stderr, "Usage: %s [-f SA|RA|NA]\n", argv[0]);
                return 2;
            }
            break;
        case 'h':
            fprintf(stderr, "Usage: %s [-f SA|RA|NA]\n", argv[0]);
            return 0;
        default:
            fprintf(stderr, "Usage: %s [-f SA|RA|NA]\n", argv[0]);
            return 2;
        }
    }
    return 0;
}

CommandType toCommandType(const char *s)
{
    if (!s)
        return CMD_ROM;
    if (strcmp(s, "EXIT") == 0)
        return CMD_EXIT;
    if (strcmp(s, "CLEAR") == 0)
        return CMD_CLEAR;
    if (strcmp(s, "RA") == 0)
        return CMD_RA;
    if (strcmp(s, "SA") == 0)
        return CMD_SA;
    if (strcmp(s, "NA") == 0)
        return CMD_NA;
    if (strcmp(s, "RESET") == 0)
        return CMD_RESET;
    // If not a known command, treat as ROM
    return CMD_ROM;
}

const char *fromCommandType(CommandType c)
{
    switch (c)
    {
    case CMD_EXIT:
        return "EXIT";
    case CMD_CLEAR:
        return "CLEAR";
    case CMD_RA:
        return "RA";
    case CMD_SA:
        return "SA";
    case CMD_RESET:
        return "RESET";
    case CMD_ROM:
    default:
        return "ROM";
    }
}

// Get current timestamp in HH:MM:SS.mmm format
void get_timestamp(char *buffer, size_t size)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    
    struct tm *tm_info = localtime(&ts.tv_sec);
    int milliseconds = ts.tv_nsec / 1000000;
    
    strftime(buffer, size - 4, "%H:%M:%S", tm_info);  // Leave room for .mmm
    snprintf(buffer + strlen(buffer), size - strlen(buffer), ".%03d", milliseconds);
}

// Timestamped printf wrapper
void ts_printf(const char *format, ...)
{
    char timestamp[16];
    get_timestamp(timestamp, sizeof(timestamp));
    printf("%s ", timestamp);

    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    fflush(stdout);
}

// Timestamped fprintf wrapper
void ts_fprintf(FILE *stream, const char *format, ...)
{
    char timestamp[16];
    get_timestamp(timestamp, sizeof(timestamp));
    fprintf(stream, "%s ", timestamp);

    va_list args;
    va_start(args, format);
    vfprintf(stream, format, args);
    va_end(args);
    fflush(stream);
}

// Timestamped perror wrapper
void ts_perror(const char *s)
{
    char timestamp[16];
    get_timestamp(timestamp, sizeof(timestamp));
    fprintf(stderr, "%s ", timestamp);
    perror(s);
    fflush(stderr);
}