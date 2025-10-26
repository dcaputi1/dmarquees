/*
 dmarquee - RetroPie Marquee Daemon

 Lightweight DRM marquee daemon for Raspberry Pi / RetroPie.
 - Runs as a long-lived daemon (run as root at boot).
 - Owns /dev/dri/card1 (attempts drmSetMaster) and modesets the chosen connector.
 - Listens on a named FIFO /tmp/dmarquee_cmd for commands written by your plugin.
 - Commands:
     <shortname>   => load /home/danc/mnt/marquees/<shortname>.png and display it
     CLEAR         => clear the screen (black)
     EXIT          => exit the daemon
     RA            => set frontend mode to RetroArch
     SA            => set frontend mode to StandAlone
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

 The plugin writes the rom shortname to /tmp/dmarquee_cmd, e.g.
   echo sf > /tmp/dmarquee_cmd
*/

#define _GNU_SOURCE
#include "helpers.h"
#include <drm/drm.h>
#include <drm/drm_mode.h>
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

#define VERSION "1.3.16"
#define DEVICE_PATH "/dev/dri/card1"
#define IMAGE_DIR "/home/danc/mnt/marquees"
#define CMD_FIFO "/tmp/dmarquees_cmd"
#define PROGRAM_DIR "/home/danc/marquees"
#define DEF_MARQUEE_DIR PROGRAM_DIR "/images"
#define DEF_MARQUEE_NAME "RetroPieMarquee"
#define DEF_RA_MARQUEE_NAME "RetroArch_logo"
#define DEF_SA_MARQUEE_NAME "MAMELogoR"
#define PREFERRED_W 1920
#define PREFERRED_H 1080
#define RETRY_DELAY_MSEC 250
#define ERROR_LOG_THROTTLE_SEC 1
#define RA_INIT_HOLD_SEC 5

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
static void* fb_map = NULL;

static bool g_is_master = false;

FrontendMode g_frontend_mode = eNA;

// State for retry logic and error throttling
static bool g_needs_crtc_reset = false;
static time_t g_last_crtc_error_log = 0;
static char g_current_image_path[512] = {0};
static time_t g_ra_init_hold_start = 0;
static bool g_in_ra_init_hold = false;

// Check if another process currently holds DRM master
static bool is_drm_master_held_by_other(void)
{
    // Try to become master temporarily to test availability
    if (drmSetMaster(drm_fd) == 0)
    {
        // We got master, so it wasn't held by another process
        drmDropMaster(drm_fd);
        g_is_master = false;
        return false;
    }
    // Failed to get master, likely held by another process
    return true;
}

// Try to reset CRTC by becoming master, setting CRTC, then dropping master
// Returns true if drmModeSetCrtc succeeded, updates g_is_master appropriately
static bool try_reset_crtc(void)
{
    bool crtc_success = false;
    time_t now = time(NULL);

    if (drmSetMaster(drm_fd) != 0)
    {
        // Only log error if we haven't logged recently to avoid spam
        if (now - g_last_crtc_error_log >= ERROR_LOG_THROTTLE_SEC)
        {
            ts_perror("drmSetMaster (try_reset_crtc)");
            g_last_crtc_error_log = now;
        }
        return false;
    }

    g_is_master = true;

    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
    {
        if (now - g_last_crtc_error_log >= ERROR_LOG_THROTTLE_SEC)
        {
            ts_perror("drmModeSetCrtc (try_reset_crtc)");
            g_last_crtc_error_log = now;
        }
    }
    else
    {
        crtc_success = true;
        g_needs_crtc_reset = false; // Success, clear retry flag
    }

    if (drmDropMaster(drm_fd) != 0)
    {
        if (now - g_last_crtc_error_log >= ERROR_LOG_THROTTLE_SEC)
        {
            ts_perror("drmDropMaster (try_reset_crtc)");
            g_last_crtc_error_log = now;
        }
    }
    else
    {
        g_is_master = false;
    }

    return crtc_success;
}

// Handle framebuffer update and CRTC reset for RetroArch mode
static void handle_fb_update_for_ra_mode(const char* image_description)
{
    if (g_frontend_mode == eRA && !g_is_master)
    {
        // Store current image info for retry logic
        snprintf(g_current_image_path, sizeof(g_current_image_path), "%s", image_description);
        
        // Start RA init hold period to give lr-mame time to acquire DRM master
        g_ra_init_hold_start = time(NULL);
        g_in_ra_init_hold = true;
        g_needs_crtc_reset = true;
        
        ts_printf("dmarquees: Starting RA init hold period for %s (waiting %d seconds)\n", 
                 image_description, RA_INIT_HOLD_SEC);
    }
}

// Pick default marquee name based on frontend mode
static const char* default_marquee_name_for(FrontendMode m)
{
    switch (m)
    {
        case eSA: return DEF_SA_MARQUEE_NAME;
        case eRA: return DEF_RA_MARQUEE_NAME;
        case eNA:
        default: return DEF_MARQUEE_NAME;
    }
}

// Draw the default marquee (bottom half). Clears bottom half to black first.
static void show_default_marquee(void)
{
    if (!fb_map)
        return;

    const char* name = default_marquee_name_for(g_frontend_mode);
    char imgpath[512];
    snprintf(imgpath, sizeof(imgpath), "%s/%s.png", DEF_MARQUEE_DIR, name);

    int fb_w = chosen_mode.hdisplay;
    int fb_h = chosen_mode.vdisplay;
    int dest_y = fb_h / 2;

    // Clear only bottom half to black
    uint8_t* bottom = (uint8_t*)fb_map + (size_t)dest_y * stride;
    size_t bottom_bytes = (size_t)(fb_h - dest_y) * stride;
    memset(bottom, 0x00, bottom_bytes);

    int iw = 0, ih = 0;
    uint8_t* img = load_png_rgba(imgpath, &iw, &ih);
    if (!img)
    {
        ts_fprintf(stderr, "warning: default marquee load failed: %s\n", imgpath);
        return; // bottom half remains black
    }

    ts_printf("dmarquees: showing default marquee: %s\n", imgpath);

    uint32_t* fbptr = (uint32_t*)fb_map;
    int stride_pixels = stride / 4;
    scale_and_blit_to_xrgb(img, iw, ih, fbptr, fb_w, fb_h, stride_pixels, /*dest_x=*/0, dest_y);
    free(img);

    // Handle RetroArch mode CRTC reset
    handle_fb_update_for_ra_mode(name);
}

static void __attribute__((unused)) print_usage(const char* prog)
{
    ts_fprintf(stderr, "Usage: %s [-f SA|RA|NA]\n", prog);
}

static void sigint_handler(int sig)
{
    (void)sig;
    running = false;
}

/* Find connector and mode (same logic as before) */
static int find_connector_mode(int fd, uint32_t* out_conn, uint32_t* out_crtc, drmModeModeInfo* out_mode)
{
    drmModeRes* res = drmModeGetResources(fd);
    if (!res)
        return -1;
    // preferred
    for (int i = 0; i < res->count_connectors; ++i)
    {
        drmModeConnector* conn = drmModeGetConnector(fd, res->connectors[i]);
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
                    drmModeEncoder* enc = drmModeGetEncoder(fd, conn->encoder_id);
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
        drmModeConnector* conn = drmModeGetConnector(fd, res->connectors[i]);
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
            drmModeEncoder* enc = drmModeGetEncoder(fd, conn->encoder_id);
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
        ts_perror("DRM_IOCTL_MODE_CREATE_DUMB");
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
        ts_perror("DRM_IOCTL_MODE_MAP_DUMB");
        return -1;
    }
    fb_map = mmap(0, bo_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (fb_map == MAP_FAILED)
    {
        ts_perror("mmap");
        fb_map = NULL;
        return -1;
    }
    // create FB
    if (drmModeAddFB(fd, width, height, 24, 32, stride, dumb_handle, &fb_id))
    {
        ts_perror("drmModeAddFB");
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
            ts_perror("mkfifo");
            return 1;
        }
    }
    chmod(CMD_FIFO, 0666); // allow any user to write commands

    // open DRM device
    drm_fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
    {
        ts_perror("open drm");
        return 1;
    }

    // attempt to become DRM master (recommended for daemon)
    g_is_master = (drmSetMaster(drm_fd) == 0);
    if (!g_is_master)
    {
        ts_perror("drmSetMaster (ignored)");
        // continue: we may still be able to set the CRTC depending on environment
    }

    // locate connector & mode
    if (find_connector_mode(drm_fd, &conn_id, &crtc_id, &chosen_mode) != 0)
    {
        ts_fprintf(stderr, "error: Failed to find connected output\n");
        close(drm_fd);
        return 1;
    }

    ts_printf("dmarquees: Selected connector %u mode %dx%d crtc %u\n", conn_id, chosen_mode.hdisplay,
              chosen_mode.vdisplay, crtc_id);

    // create persistent dumb framebuffer sized to chosen_mode
    if (create_dumb_fb(drm_fd, chosen_mode.hdisplay, chosen_mode.vdisplay) != 0)
    {
        ts_fprintf(stderr, "error: Failed to create dumb FB\n");
        close(drm_fd);
        return 1;
    }

    memset(fb_map, 0x00, bo_size); // Clear framebuffer (black)

    // Optional: draw default marquee based on current frontend mode
    show_default_marquee();

    // set CRTC once to show our FB (this may fail with EPERM if another master exists)
    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
        ts_perror("drmModeSetCrtc"); // we'll still run and accept commands; writes will not be visible until we succeed
    else
        ts_printf("dmarquees: drmModeSetCrtc(1) - Initial FB presented\n");

    // Release DRM master so other apps (like MAME) can take control
    if (g_is_master)
    {
        if (drmDropMaster(drm_fd) != 0)
        {
            ts_fprintf(stderr, "warning: drmDropMaster failed (%s)\n", strerror(errno));
        }
        else
        {
            g_is_master = false;
            ts_printf("dmarquees: DRM master dropped - MAME can safely start.\n");
        }
    }
    return 0;
}

int main(int argc, char** argv)
{
    ts_printf("dmarquees: v%s starting...\n", VERSION);

    // parse command line for frontend mode
    int parse_result = parseFrontendModeArg(argc, argv);
    if (parse_result != 0)
        return parse_result;
    ts_printf("dmarquees: frontend=%s\n", fromFrontendMode(g_frontend_mode));

    signal(SIGINT, sigint_handler);

    if (initialize() != 0)
        return 1;

    ts_printf("stdout: entering main loop\n");
    ts_fprintf(stderr, "stderr: listening on %s\n", CMD_FIFO);

    // main loop: read FIFO lines and act on them
    while (running)
    {
        int fifo = open(CMD_FIFO, O_RDONLY);
        if (fifo < 0)
        {
            ts_perror("open fifo");
            break;
        }

        char buf[128];
        ssize_t n = read(fifo, buf, sizeof(buf) - 1);
        close(fifo);

        if (n <= 0)
        {
            // No new command, check if we need to retry CRTC reset
            if (g_needs_crtc_reset && g_frontend_mode == eRA)
            {
                time_t now = time(NULL);
                
                if (g_in_ra_init_hold)
                {
                    // Check if we should abort init hold due to DRM master activity
                    bool master_held = is_drm_master_held_by_other();
                    static bool prev_master_held = false;
                    
                    // Detect transition: master was held, now available (lr-mame finished)
                    if (prev_master_held && !master_held)
                    {
                        ts_printf("dmarquees: DRM master released by other process, ending init hold early\n");
                        g_in_ra_init_hold = false;
                    }
                    // Check if init hold timeout expired
                    else if (now - g_ra_init_hold_start >= RA_INIT_HOLD_SEC)
                    {
                        ts_printf("dmarquees: RA init hold timeout expired\n");
                        g_in_ra_init_hold = false;
                    }
                    
                    prev_master_held = master_held;
                }
                
                // Only try CRTC reset if not in init hold period
                if (!g_in_ra_init_hold)
                {
                    if (try_reset_crtc())
                        ts_printf("dmarquees: CRTC reset successful for %s\n", g_current_image_path);
                }
            }
            
            usleep(RETRY_DELAY_MSEC * 1000);
            continue;
        }

        buf[n] = '\0';

        // strip newline and whitespace
        char* cmd = trim(buf);
        if (!(cmd && strlen(cmd)))
            continue;

        ts_printf("dmarquees: command received: '%s'\n", cmd);

        // Clear retry flag when new command received
        g_needs_crtc_reset = false;
        g_current_image_path[0] = '\0';
        g_in_ra_init_hold = false;

        // Process command using switch statement
        CommandType command = toCommandType(cmd);
        switch (command)
        {
            case CMD_RA:
                g_frontend_mode = eRA;
                ts_printf("dmarquees: frontend mode changed to RA\n");
                show_default_marquee();
                continue;

            case CMD_SA:
                g_frontend_mode = eSA;
                ts_printf("dmarquees: frontend mode changed to SA\n");
                show_default_marquee();
                continue;

            case CMD_NA:
                g_frontend_mode = eNA;
                ts_printf("dmarquees: frontend mode changed to NA\n");
                show_default_marquee();
                continue;

            case CMD_EXIT: running = false; break;

            case CMD_CLEAR: show_default_marquee(); continue;

            case CMD_ROM:
            default:
                // Handle as ROM shortname (including unknown commands)
                break;
        }

        // If we reach here, it's either eROM or an unknown command - treat as ROM shortname
        if (game_has_multiple_screens(cmd))
        {
            ts_printf("dmarquees: Skipping multi-screen game: %s\n", cmd);
            continue;
        }

        // otherwise treat as rom shortname
        char imgpath[512];
        snprintf(imgpath, sizeof(imgpath), "%s/%s.png", IMAGE_DIR, cmd);
        struct stat st;
        if (stat(imgpath, &st) != 0)
        {
            ts_fprintf(stderr, "warning: image missing: %s\n", imgpath);
            // Fallback: show default marquee
            show_default_marquee();
            continue;
        }

        int iw = 0, ih = 0;
        uint8_t* img = load_png_rgba(imgpath, &iw, &ih);
        if (img == NULL)
        {
            ts_fprintf(stderr, "error: png load failed %s\n", imgpath);
            // Fallback: show default marquee
            show_default_marquee();
            continue;
        }

        ts_printf("dmarquees: displaying game marquee: %s.png\n", cmd);

        // clear bottom half to black first and blit ROM marquee
        if (fb_map)
        {
            uint32_t* fbptr = (uint32_t*)fb_map;
            int fb_w = chosen_mode.hdisplay;
            int fb_h = chosen_mode.vdisplay;
            int stride_pixels = stride / 4;
            int dest_x = 0;
            int dest_y = fb_h / 2;

            // Clear bottom half before blit (to avoid remnants)
            uint8_t* bottom = (uint8_t*)fb_map + (size_t)dest_y * stride;
            size_t bottom_bytes = (size_t)(fb_h - dest_y) * stride;
            memset(bottom, 0x00, bottom_bytes);

            scale_and_blit_to_xrgb(img, iw, ih, fbptr, fb_w, fb_h, stride_pixels, dest_x, dest_y);

#ifdef USE_MODE_SET_AFTER_EACH_UPDATE
            if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
                ts_perror("drmModeSetCrtc");
#endif
        }
        free(img);

        // Handle RetroArch mode CRTC reset after ROM image update
        handle_fb_update_for_ra_mode(cmd);
    }

    // cleanup
    destroy_dumb_fb(drm_fd);
    if (drm_fd >= 0)
    {
        if (g_is_master)
            drmDropMaster(drm_fd);
        close(drm_fd);
    }
    unlink(CMD_FIFO);
    ts_printf("dmarquees: exiting\n");
    return 0;
}
