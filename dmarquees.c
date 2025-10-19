/*
 dmarquee v1.3.0

 Lightweight DRM marquee daemon for Raspberry Pi / RetroPie.
 - Runs as a long-lived daemon (run as root at boot).
 - Owns /dev/dri/card1 (attempts drmSetMaster) and modesets the chosen connector.
 - Listens on a named FIFO /tmp/dmarquee_cmd for commands written by your plugin.
 - Commands:
     <shortname>   => load /home/danc/mnt/marquees/<shortname>.png and display it
     CLEAR         => clear the screen (black)
     EXIT          => exit the daemon
 - Image is scaled nearest-neighbor to fill the width and bottom-half of the screen.
 - Uses a single persistent dumb framebuffer; the daemon blits into the mapped buffer
   and calls drmModeSetCrtc() once at startup to show the FB. Subsequent blits update
   the same FB memory (the kernel presents the updated contents).

 Build:
   sudo apt update
   sudo apt install build-essential libdrm-dev libpng-dev pkg-config
   gcc -O2 -o dmarquee dmarquee.c -ldrm -lpng

 Run (recommended from system startup as root):
   sudo ./dmarquee &

 Your plugin writes the rom shortname to /tmp/dmarquee_cmd, e.g.
   echo sf > /tmp/dmarquee_cmd
*/

#define _GNU_SOURCE
#include "helpers.h"
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

#define VERSION "1.3.0"
#define DEVICE_PATH "/dev/dri/card1"
#define IMAGE_DIR "/home/danc/mnt/marquees"
#define CMD_FIFO "/tmp/dmarquees_cmd"
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

static bool initialized = false;

typedef enum
{
    eSA = 0,
    eRA = 1
} FrontendMode;
static FrontendMode g_frontend_mode = eSA;

static void print_usage(const char *prog)
{
    fprintf(stderr, "Usage: %s [-f SA|RA]\n", prog);
}

static int parseFrontendModeArg(int argc, char **argv)
{
    int opt;
    while ((opt = getopt(argc, argv, "f:h")) != -1)
    {
        switch (opt)
        {
        case 'f':
            if (strcasecmp(optarg, "RA") == 0 || strcasecmp(optarg, "RetroArch") == 0)
            {
                g_frontend_mode = eRA;
            }
            else if (strcasecmp(optarg, "SA") == 0 || strcasecmp(optarg, "StandAlone") == 0)
            {
                g_frontend_mode = eSA;
            }
            else
            {
                fprintf(stderr, "error: invalid frontend '%s'\n", optarg);
                print_usage(argv[0]);
                return 2;
            }
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 2;
        }
    }
    return 0;
}

static void sigint_handler(int sig)
{
    (void)sig;
    running = false;
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

static int initialize(void)
{
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

    // open DRM device
    drm_fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
    {
        perror("open drm");
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
        fprintf(stderr, "error: Failed to find connected output\n");
        close(drm_fd);
        return 1;
    }

    printf("dmarquees: Selected connector %u mode %dx%d crtc %u\n", conn_id, chosen_mode.hdisplay, chosen_mode.vdisplay,
           crtc_id);

    // create persistent dumb framebuffer sized to chosen_mode
    if (create_dumb_fb(drm_fd, chosen_mode.hdisplay, chosen_mode.vdisplay) != 0)
    {
        fprintf(stderr, "error: Failed to create dumb FB\n");
        close(drm_fd);
        return 1;
    }

    memset(fb_map, 0x00, bo_size); // Clear framebuffer (black)

    // set CRTC once to show our FB (this may fail with EPERM if another master exists)
    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
        perror("drmModeSetCrtc"); // we'll still run and accept commands; writes will not be visible until we succeed
    else
        printf("dmarquees: drmModeSetCrtc(1) - Initial FB presented\n");

    // Release DRM master so other apps (like MAME) can take control
    if (drmDropMaster(drm_fd) != 0)
        fprintf(stderr, "warning: drmDropMaster failed (%s)\n", strerror(errno));
    else
        printf("dmarquees: DRM master dropped - MAME can safely start.\n");

    return 0;
}

int main(int argc, char **argv)
{
    printf("dmarquees: v%s starting...\n", VERSION);

    // parse command line for frontend mode
    int parse_result = parseFrontendModeArg(argc, argv);
    if (parse_result != 0)
    {
        return parse_result;
    }
    printf("dmarquees: frontend=%s\n", (g_frontend_mode == eRA) ? "RA" : "SA");

    signal(SIGINT, sigint_handler);

    if (g_frontend_mode == eSA)
    {
        if (initialize() != 0)
        {
            return 1;
        }
        initialized = true;
    }

    printf("stdout: entering main loop\n");
    fprintf(stderr, "stderr: listening on %s\n", CMD_FIFO);

    // main loop: read FIFO lines and act on them
    while (running)
    {
        int fifo = open(CMD_FIFO, O_RDONLY);
        if (fifo < 0)
        {
            perror("open fifo");
            break;
        }

        char buf[128];
        ssize_t n = read(fifo, buf, sizeof(buf) - 1);
        close(fifo);

        if (n <= 0)
        {
            usleep(100000);
            continue;
        }

        buf[n] = '\0';

        // strip newline and whitespace
        char *cmd = trim(buf);
        if (!(cmd && strlen(cmd)))
            continue;

        printf("dmarquees: command received: '%s'\n", buf);

        if (strcasecmp(cmd, "EXIT") == 0)
        {
            running = false;
            break;
        }
        if (strcasecmp(cmd, "CLEAR") == 0)
        {
            memset(fb_map, 0x00, bo_size);
            continue; // no need to re-add fb; kernel shows updated memory
        }
        if (game_has_multiple_screens(cmd))
        {
            printf("dmarquees: Skipping multi-screen game: %s\n", cmd);
            continue;
        }

        // otherwise treat as rom shortname
        char imgpath[512];
        snprintf(imgpath, sizeof(imgpath), "%s/%s.png", IMAGE_DIR, cmd);
        struct stat st;
        if (stat(imgpath, &st) != 0)
        {
            fprintf(stderr, "warning: image missing: %s\n", imgpath);
            continue;
        }

        int iw = 0, ih = 0;
        uint8_t *img = load_png_rgba(imgpath, &iw, &ih);
        if (img == NULL)
        {
            fprintf(stderr, "error: png load failed %s\n", imgpath);
            continue;
        }

        // Game is started - prepare for marquee display
        if (!initialized)
        {
            if (initialize() != 0)
            {
                free(img);
                fprintf(stderr, "error: Failed to initialize DRM\n");
                continue;
            }
            initialized = true;
        }

        // clear bottom half to black first
        if (fb_map)
        {
            uint32_t *fbptr = (uint32_t *)fb_map;
            int fb_w = chosen_mode.hdisplay;
            int fb_h = chosen_mode.vdisplay;
            int stride_pixels = stride / 4;
            int dest_x = 0;
            int dest_y = fb_h - (fb_h / 2);

            // black area already zeroed earlier; just overwrite bottom-half region
            scale_and_blit_to_xrgb(img, iw, ih, fbptr, fb_w, fb_h, stride_pixels, dest_x, dest_y);

            // After writing to mmap'd framebuffer memory, the kernel should display it.
            // If needed, call drmModeSetCrtc again.
            if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
                perror("drmModeSetCrtc");
        }
        free(img);
    }

    // cleanup
    destroy_dumb_fb(drm_fd);
    if (drm_fd >= 0)
    {
        drmDropMaster(drm_fd);
        close(drm_fd);
    }
    unlink(CMD_FIFO);
    printf("dmarquees: exiting\n");
    return 0;
}
