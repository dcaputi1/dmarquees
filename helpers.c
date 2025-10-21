#include "helpers.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <png.h>
#include <strings.h> // for strcasecmp
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
            while (*p && isspace((unsigned char)*p)) ++p;
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
void scale_and_blit_to_xrgb(const uint8_t *src_rgba, int src_w, int src_h,
                            uint32_t *dst, int dst_w, int dst_h, int dst_stride,
                            int dest_x, int dest_y)
{
    if (!src_rgba || !dst) return;

    // Determine destination region: fill width and from dest_y to bottom.
    int dst_x0 = dest_x >= 0 ? dest_x : 0;
    int dst_y0 = dest_y >= 0 ? dest_y : 0;
    int region_w = dst_w - dst_x0;
    int region_h = dst_h - dst_y0;
    if (region_w <= 0 || region_h <= 0) return;

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

char *trim(char *s)
{
    if (!s) return s;
    char *p = s;
    // trim left
    while (*p && isspace((unsigned char)*p)) ++p;
    if (p != s) memmove(s, p, strlen(p) + 1);
    // trim right
    size_t len = strlen(s);
    while (len > 0 && isspace((unsigned char)s[len - 1])) s[--len] = '\0';
    return s;
}

FrontendMode toFrontendMode(const char *s)
{
    if (!s) return eNA;
    if (strcasecmp(s, "RA") == 0 || strcasecmp(s, "RetroArch") == 0) return eRA;
    if (strcasecmp(s, "SA") == 0 || strcasecmp(s, "StandAlone") == 0) return eSA;
    if (strcasecmp(s, "NA") == 0 || strcasecmp(s, "None") == 0) return eNA;
    return eNA;
}

const char *fromFrontendMode(FrontendMode m)
{
    switch (m)
    {
    case eRA: return "RA";
    case eSA: return "SA";
    case eNA:
    default:  return "NA";
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
            if (g_frontend_mode == eNA && strcasecmp(optarg, "NA") != 0 && strcasecmp(optarg, "None") != 0)
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
    if (!s) return CMD_ROM;
    if (strcasecmp(s, "EXIT") == 0) return CMD_EXIT;
    if (strcasecmp(s, "CLEAR") == 0) return CMD_CLEAR;
    if (strcasecmp(s, "RA") == 0) return CMD_RA;
    if (strcasecmp(s, "SA") == 0) return CMD_SA;
    // If not a known command, treat as ROM
    return CMD_ROM;
}

const char *fromCommandType(CommandType c)
{
    switch (c)
    {
    case CMD_EXIT:  return "EXIT";
    case CMD_CLEAR: return "CLEAR";
    case CMD_RA:    return "RA";
    case CMD_SA:    return "SA";
    case CMD_ROM:
    default:        return "ROM";
    }
}