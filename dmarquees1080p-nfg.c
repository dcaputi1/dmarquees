/*
 dmarquee.c v1.0.1

 Lightweight DRM marquee daemon for Raspberry Pi / RetroPie.
 - Runs as a long-lived daemon (run as root at boot).
 - Owns /dev/dri/card1 (attempts drmSetMaster) and modesets the chosen connector.
 - Listens on a named FIFO /tmp/dmarquees_cmd for commands written by your plugin.
 - Commands:
     <shortname>   => load /home/danc/mnt/marquees/<shortname>.png and display it
     CLEAR         => clear the screen (black)
     EXIT          => exit the daemon
 - Image is scaled to width = 1920 px, proportional height, capped to 1080 px
 - display static marquee PNG using DRM dumb buffer
 - Background cleared black, marquee bottom-aligned and horizontally centered.

 Build:
   sudo apt update
   sudo apt install build-essential libdrm-dev libpng-dev pkg-config
   gcc -O2 -o dmarquees dmarquees.c -ldrm -lpng

 Run (recommended from system startup as root):
   sudo ./dmarquees &

 Your plugin writes the rom shortname to /tmp/dmarquees_cmd, e.g.
   echo sf > /tmp/dmarquees_cmd

*/

#define _GNU_SOURCE
#include "png_loader.h"
#include <drm.h>
#include <errno.h>
#include <fcntl.h>
#include <png.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define VERSION "1.0.1"
#define DEVICE_PATH "/dev/dri/card1"
#define IMAGE_DIR "/home/danc/mnt/marquees"
#define CMD_FIFO "/tmp/dmarquees_cmd"
#define INI_DIR "/opt/retropie/emulators/mame/ini"
#define PREFERRED_W 1920
#define PREFERRED_H 1080

static volatile bool running = true;
static int drm_fd = -1;
static uint32_t conn_id = 0;
static uint32_t crtc_id = 0;
static drmModeModeInfo chosen_mode;

/* DRM dumb buffer state */
static uint32_t dumb_handle = 0;
static uint32_t fb_id = 0;
static uint32_t stride = 0;
static uint64_t bo_size = 0;
static void *fb_map = NULL;

static void sigint_handler(int sig)
{
    (void)sig;
    running = false;
}

// Returns true if the game appears to use multiple screens
static bool game_has_multiple_screens(const char *romname)
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
static void scale_and_blit_to_xrgb(unsigned char *src, int sw, int sh, uint32_t *dest, int dw, int dh,
                                   int dest_stride_pixels, int dest_x, int dest_y)
{
    if (!src || !dest)
        return;
    int target_w = dw;
    int target_h = dh / 2; // bottom half
    for (int ty = 0; ty < target_h; ++ty)
    {
        int sy = (ty * sh) / target_h;
        uint32_t *drow = dest + (dest_y + ty) * dest_stride_pixels + dest_x;
        for (int tx = 0; tx < target_w; ++tx)
        {
            int sx = (tx * sw) / target_w;
            unsigned char *p = src + (sy * sw + sx) * 4; // RGBA
            unsigned char r = p[0];
            unsigned char g = p[1];
            unsigned char b = p[2];
            uint32_t pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b; // 0x00RRGGBB
            drow[tx] = pixel;
        }
    }
}

/* Find connector and mode (same logic as before) */
static int find_connector_mode(int fd, uint32_t *out_conn, uint32_t *out_crtc, drmModeModeInfo *out_mode)
{
    drmModeRes *res = drmModeGetResources(fd);
    if (!res)
        return -1;
    // preferred
    for (int i = 0; i < res->count_connectors; ++i)
    {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn)
            continue;
        if (conn->connection != DRM_MODE_CONNECTED)
        {
            drmModeFreeConnector(conn);
            continue;
        }
        for (int m = 0; m < conn->count_modes; ++m)
        {
            if ((int)conn->modes[m].hdisplay == PREFERRED_W && (int)conn->modes[m].vdisplay == PREFERRED_H)
            {
                uint32_t chosen_crtc = 0;
                if (conn->encoder_id)
                {
                    drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
                    if (enc)
                    {
                        chosen_crtc = enc->crtc_id;
                        drmModeFreeEncoder(enc);
                    }
                }
                if (!chosen_crtc && res->count_crtcs > 0)
                    chosen_crtc = res->crtcs[0];
                *out_conn = conn->connector_id;
                *out_crtc = chosen_crtc;
                *out_mode = conn->modes[m];
                drmModeFreeConnector(conn);
                drmModeFreeResources(res);
                return 0;
            }
        }
        drmModeFreeConnector(conn);
    }
    // fallback
    for (int i = 0; i < res->count_connectors; ++i)
    {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn)
            continue;
        if (conn->connection != DRM_MODE_CONNECTED)
        {
            drmModeFreeConnector(conn);
            continue;
        }
        if (conn->count_modes == 0)
        {
            drmModeFreeConnector(conn);
            continue;
        }
        uint32_t chosen_crtc = 0;
        if (conn->encoder_id)
        {
            drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
            if (enc)
            {
                chosen_crtc = enc->crtc_id;
                drmModeFreeEncoder(enc);
            }
        }
        if (!chosen_crtc && res->count_crtcs > 0)
            chosen_crtc = res->crtcs[0];
        *out_conn = conn->connector_id;
        *out_crtc = chosen_crtc;
        *out_mode = conn->modes[0];
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        return 0;
    }
    drmModeFreeResources(res);
    return -1;
}

/* Create and map a dumb buffer, add FB, keep mapping pointer in fb_map */
static int create_dumb_fb(int fd, uint32_t width, uint32_t height)
{
    struct drm_mode_create_dumb creq = {0};
    creq.width = width;
    creq.height = height;
    creq.bpp = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0)
    {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        return -1;
    }
    dumb_handle = creq.handle;
    stride = creq.pitch;
    bo_size = creq.size;
    // map
    struct drm_mode_map_dumb mreq = {0};
    mreq.handle = dumb_handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0)
    {
        perror("DRM_IOCTL_MODE_MAP_DUMB");
        return -1;
    }
    fb_map = mmap(0, bo_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (fb_map == MAP_FAILED)
    {
        perror("mmap");
        fb_map = NULL;
        return -1;
    }
    // create FB
    if (drmModeAddFB(fd, width, height, 24, 32, stride, dumb_handle, &fb_id))
    {
        perror("drmModeAddFB");
        munmap(fb_map, bo_size);
        fb_map = NULL;
        return -1;
    }
    return 0;
}

static void destroy_dumb_fb(int fd)
{
    if (fb_id)
    {
        drmModeRmFB(fd, fb_id);
        fb_id = 0;
    }
    if (fb_map)
    {
        munmap(fb_map, bo_size);
        fb_map = NULL;
    }
    if (dumb_handle)
    {
        struct drm_mode_destroy_dumb dreq = {.handle = dumb_handle};
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        dumb_handle = 0;
    }
}


int main(int argc, char **argv)
{
    fprintf(stderr, "dmarquees v%s starting...\n", VERSION);
    signal(SIGINT, sigint_handler);

    // ensure FIFO exists
    if (mkfifo(CMD_FIFO, 0666) < 0)
    {
        if (errno != EEXIST)
        {
            perror("mkfifo");
            return 1;
        }
    }
    chmod(CMD_FIFO, 0666); // allow any user to write commands

    char imagepath[512];
    snprintf(imagepath, sizeof(imagepath), "%s/%s.png", IMAGE_DIR, argv[1]);
    struct stat st;
    if (stat(imagepath, &st) != 0)
    {
        fprintf(stderr, "No marquee image for %s\n", imagepath);
        return 1;
    }

    int iw, ih;
    unsigned char *img = load_png(imagepath, &iw, &ih);
    if (!img)
    {
        fprintf(stderr, "Failed to load %s\n", imagepath);
        return 1;
    }

    int drm_fd = open("/dev/dri/card1", O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
    {
        perror("open card1");
        free(img);
        return 1;
    }

    drmModeRes *res = drmModeGetResources(drm_fd);
    if (!res)
    {
        perror("drmModeGetResources");
        close(drm_fd);
        free(img);
        return 1;
    }

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++)
    {
        conn = drmModeGetConnector(drm_fd, res->connectors[i]);
        if (conn && conn->connection == DRM_MODE_CONNECTED)
            break;
        drmModeFreeConnector(conn);
        conn = NULL;
    }
    if (!conn)
    {
        fprintf(stderr, "No connected connector\n");
        drmModeFreeResources(res);
        close(drm_fd);
        free(img);
        return 1;
    }

    drmModeModeInfo mode = conn->modes[0];
    drmModeEncoder *enc = drmModeGetEncoder(drm_fd, conn->encoder_id);
    uint32_t crtc_id = enc->crtc_id;

    printf("Using mode %dx%d\n", mode.hdisplay, mode.vdisplay);

    struct drm_mode_create_dumb creq = {0};
    creq.width = mode.hdisplay;
    creq.height = mode.vdisplay;
    creq.bpp = 32;
    if (drmIoctl(drm_fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0)
    {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        return 1;
    }

    uint32_t handle = creq.handle;
    uint32_t pitch = creq.pitch;
    uint64_t size = creq.size;
    uint32_t fb;
    if (drmModeAddFB(drm_fd, mode.hdisplay, mode.vdisplay, 24, 32, pitch, handle, &fb))
    {
        perror("drmModeAddFB");
        return 1;
    }

    struct drm_mode_map_dumb mreq = {.handle = handle};
    drmIoctl(drm_fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq);
    uint8_t *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_SHARED, drm_fd, mreq.offset);
    if (map == MAP_FAILED)
    {
        perror("mmap");
        return 1;
    }

    // Clear screen to black
    memset(map, 0, size);

    // Compute scaling for marquee (target width 1920, maintain aspect)
    float scale = 1920.0f / iw;
    int new_w = 1920;
    int new_h = (int)(ih * scale);
    if (new_h > 1080)
    { // clamp height if taller than 1080p
        new_h = 1080;
        scale = (float)new_h / ih;
        new_w = (int)(iw * scale);
    }

    int x_off = (mode.hdisplay - new_w) / 2;
    int y_off = mode.vdisplay - new_h; // bottom aligned

    // Copy scaled image
    for (int y = 0; y < new_h; y++)
    {
        int sy = (int)(y / scale);
        if (sy >= ih)
            sy = ih - 1;
        uint8_t *dst = map + (y_off + y) * pitch + x_off * 4;
        for (int x = 0; x < new_w; x++)
        {
            int sx = (int)(x / scale);
            if (sx >= iw)
                sx = iw - 1;
            uint8_t *s = &img[(sy * iw + sx) * 4];
            dst[x * 4 + 0] = s[2];
            dst[x * 4 + 1] = s[1];
            dst[x * 4 + 2] = s[0];
            dst[x * 4 + 3] = 0xFF;
        }
    }

    if (drmModeSetCrtc(drm_fd, crtc_id, fb, 0, 0, &conn->connector_id, 1, &mode))
    {
        perror("drmModeSetCrtc");
    }

    printf("Displayed %s scaled to %dx%d\n", argv[1], new_w, new_h);
    while (running)
        pause();

    munmap(map, size);
    drmModeRmFB(drm_fd, fb);
    struct drm_mode_destroy_dumb dreq = {.handle = handle};
    drmIoctl(drm_fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
    drmModeFreeConnector(conn);
    drmModeFreeEncoder(enc);
    drmModeFreeResources(res);
    close(drm_fd);
    free(img);
    return 0;
}
