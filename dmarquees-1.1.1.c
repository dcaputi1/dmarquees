/*
 dmarquees v1.1.1

 Persistent DRM marquees daemon.
 - Listens on FIFO /tmp/dmarquees_cmd
 - Commands: <shortname>, CLEAR, EXIT
 - Creates a persistent dumb framebuffer and presents it on chosen connector
 - Scales loaded PNGs to 1920px width (preserve aspect). Height capped at 1080px.
 - Bottom-aligns and centers the scaled image on the full-resolution framebuffer.
 - Attempts to become DRM master at startup to create FB, then drops master so other apps like MAME can initialize.
 - Skips marquee for multi-screen games by checking a game-specific ini for "numscreens".

 Build:
   sudo apt update
   sudo apt install build-essential libdrm-dev libpng-dev pkg-config
   gcc -O2 -o dmarquees dmarquees.c -ldrm -lpng

 Run (as root at boot, recommended):
   sudo ./dmarquees &

 MAME plugin writes the rom shortname to /tmp/dmarquees_cmd, e.g.
   echo sf > /tmp/dmarquees_cmd
*/

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <png.h>
#include <drm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "png_loader.h"

#define VERSION     "1.1.1"
#define DEVICE_PATH "/dev/dri/card1"
#define IMAGE_DIR "/home/danc/mnt/marquees"
#define CMD_FIFO  "/tmp/dmarquees_cmd"
#define INI_DIR   "/opt/retropie/emulators/mame/ini"
#define PREFERRED_W 3840
#define PREFERRED_H 2160

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
static void scale_and_blit_to_xrgb_region(unsigned char *src, int sw, int sh, uint32_t *dest,
                                          int dest_w, int dest_h, int dest_stride_pixels,
                                          int dest_x, int dest_y, int draw_w, int draw_h)
{
    if (!src || !dest)
        return;

    for (int y = 0; y < draw_h; ++y)
    {
        int sy = (y * sh) / draw_h;
        if (sy >= sh) sy = sh - 1;
        uint32_t *drow = dest + (dest_y + y) * dest_stride_pixels + dest_x;

        for (int x = 0; x < draw_w; ++x)
        {
            int sx = (x * sw) / draw_w;
            if (sx >= sw) sx = sw - 1;
            unsigned char *p = src + (sy * sw + sx) * 4;
            unsigned char r = p[0];
            unsigned char g = p[1];
            unsigned char b = p[2];
            uint32_t pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
            drow[x] = pixel;
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


int main(void)
{
    printf("dmarquees: v%s starting...\n", VERSION);
    signal(SIGINT, sigint_handler);

    // ensure FIFO exists
    if (mkfifo(CMD_FIFO, 0666) < 0 && errno != EEXIST)
    {
        perror("mkfifo");
        return 1;
    }
    chmod(CMD_FIFO, 0666); // allow any user to write commands

    // open DRM device
    drm_fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
    {
        perror("open DRM");
        return 1;
    }

    // attempt to become DRM master (recommended for daemon)
    if (drmSetMaster(drm_fd) != 0)
    {
        perror("drmSetMaster (continuing anyway)");
        // continue: we may still be able to set the CRTC depending on environment
    }

    // locate connector & mode
    if (find_connector_mode(drm_fd, &conn_id, &crtc_id, &chosen_mode) != 0)
    {
        fprintf(stderr, "error: No connector found.\n");
        close(drm_fd);
        return 1;
    }
    printf("dmarquees: Selected connector %u mode %dx%d crtc %u\n", conn_id, chosen_mode.hdisplay, chosen_mode.vdisplay,
            crtc_id);

    // create persistent dumb framebuffer sized to chosen_mode
    if (create_dumb_fb(drm_fd, chosen_mode.hdisplay, chosen_mode.vdisplay) != 0)
    {
        fprintf(stderr, "error: Failed to create framebuffer.\n");
        close(drm_fd);
        return 1;
    }

    // Clear framebuffer (black)
    memset(fb_map, 0, bo_size);

    // set CRTC once to show our FB (this may fail with EPERM if another master exists)
    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
        perror("drmModeSetCrtc"); // we'll still run and accept commands; writes will not be visible until we succeed
    else
        printf("dmarquees: Initial FB presented\n");

    // NEW CODE — release DRM master to avoid blocking MAME
    if (drmDropMaster(drm_fd) != 0)
        fprintf(stderr, "warning: drmDropMaster failed (%s)\n", strerror(errno));
    else
        printf("dmarquees: DRM master dropped — MAME can safely start.\n");

    printf("dmarquees: Waiting for commands...\n");

    int fifo_fd;
    char cmd[128];

    // main loop: read FIFO lines and act on them
    while (running)
    {
        fifo_fd = open(CMD_FIFO, O_RDONLY);
        if (fifo_fd < 0)
        {
            sleep(1);
            continue;
        }

        while (running && fgets(cmd, sizeof(cmd), fdopen(fifo_fd, "r")))
        {
            cmd[strcspn(cmd, "\n")] = '\0';
            if (strcasecmp(cmd, "EXIT") == 0)
            {
                running = false;
                break;
            }
            else if (strcasecmp(cmd, "CLEAR") == 0)
            {
                memset(fb_map, 0, bo_size);
                drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode);
            }
            else if (cmd[0])
            {
                if (game_has_multiple_screens(cmd))
                {
                    printf("dmarquees: Skipping multi-screen game: %s\n", cmd);
                    continue;
                }

                char imagepath[512];
                snprintf(imagepath, sizeof(imagepath), "%s/%s.png", IMAGE_DIR, cmd);
                struct stat st;
                if (stat(imagepath, &st) != 0)
                {
                    fprintf(stderr, "warning: No marquee image for %s\n", imagepath);
                    continue;
                }

                int iw, ih;
                unsigned char* pixels = load_png_rgba(imagepath, &iw, &ih);
                if (!pixels)
                {
                    fprintf(stderr, "error: png load failed %s\n", imagepath);
                }
                else
                {
                    memset(fb_map, 0, bo_size);
                    int draw_w = 1920;
                    int draw_h = (int)((float)draw_w * (float)ih / (float)iw);
                    if (draw_h > 1080)
                    {
                        draw_h = 1080;
                        draw_w = (int)((float)draw_h * (float)iw / (float)ih);
                    }

                    int draw_x = (chosen_mode.hdisplay - draw_w) / 2;
                    int draw_y = chosen_mode.vdisplay - draw_h;
                    scale_and_blit_to_xrgb_region(pixels, iw, ih, fb_map,
                                                  chosen_mode.hdisplay, chosen_mode.vdisplay,
                                                  stride / 4, draw_x, draw_y, draw_w, draw_h);

                    free(pixels);
                    drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode);
                    printf("dmarquees: Scaled image for display: %dx%d at (%d,%d)\n", draw_w, draw_h, draw_x, draw_y);
                }
            }
        }
        close(fifo_fd);
    }

    // cleanup
    destroy_dumb_fb(drm_fd);
    close(drm_fd);
    unlink(CMD_FIFO);
    printf("dmarquees: exiting\n");
    return 0;
}
