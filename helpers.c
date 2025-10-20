#include "helpers.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <png.h>
#include <strings.h> // for strcasecmp

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
            int n = 0;
            if (sscanf(line, "numscreens %d", &n) == 1 && n > 1)
                multi = true;
            break;
        }
    }

    fclose(fp);
    return multi;
}

/* Nearest-neighbor scale/blit RGBA -> XRGB8888 framebuffer (dest is uint32_t array) */
void scale_and_blit_to_xrgb(uint8_t *src, int sw, int sh, uint32_t *dest, int dw, int dh,
                            int stride_pixels, int dest_x, int dest_y)
{
    if (!src || !dest)
        return;
    int target_w = dw;
    int target_h = dh / 2; // bottom half
    for (int ty = 0; ty < target_h; ++ty)
    {
        int sy = (ty * sh) / target_h;
        uint32_t *drow = dest + (dest_y + ty) * stride_pixels + dest_x;
        for (int tx = 0; tx < target_w; ++tx)
        {
            int sx = (tx * sw) / target_w;
            uint8_t *p = src + (sy * sw + sx) * 4; // RGBA
            uint8_t r = p[0];
            uint8_t g = p[1];
            uint8_t b = p[2];
            uint32_t pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b; // 0x00RRGGBB
            drow[tx] = pixel;
        }
    }
}

char* trim(char* str)
{
    if (!str)
        return NULL;

    // Trim leading whitespace
    while (*str && isspace(*str))
        str++;

    if (*str == 0) // All spaces
        return str;

    // Trim trailing whitespace
    char* end = str + strlen(str) - 1;
    while (end > str && isspace(*end))
        end--;

    *(end + 1) = '\0';
    return str;
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