/*
 dmarquee v1.0.0

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

#define VERSION "1.0.0"
#define DEVICE_PATH "/dev/dri/card1"
#define IMAGE_DIR   "/home/danc/mnt/marquees"
#define CMD_FIFO     "/tmp/dmarquees_cmd"
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

static void sigint_handler(int sig) {
    (void)sig; running = false; }

/* Simple PNG loader -> RGBA buffer (malloc'd). Returns 0 on success. */
static int load_png_rgba(const char *path, unsigned char **out_buf, int *out_w, int *out_h) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror("fopen"); return -1; }
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) { fclose(fp); return -1; }
    png_infop info = png_create_info_struct(png);
    if (!info) { png_destroy_read_struct(&png, NULL, NULL); fclose(fp); return -1; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_read_struct(&png, &info, NULL); fclose(fp); return -1; }
    png_init_io(png, fp);
    png_read_info(png, info);

    int width = png_get_image_width(png, info);
    int height = png_get_image_height(png, info);
    png_byte color_type = png_get_color_type(png, info);
    png_byte bit_depth = png_get_bit_depth(png, info);

    if (bit_depth == 16) png_set_strip_16(png);
    if (color_type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);

    png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    png_set_gray_to_rgb(png);
    png_read_update_info(png, info);

    png_size_t rowbytes = png_get_rowbytes(png, info);
    unsigned char *data = malloc(rowbytes * height);
    if (!data) { png_destroy_read_struct(&png, &info, NULL); fclose(fp); return -1; }

    png_bytep *rows = malloc(sizeof(png_bytep) * height);
    if (!rows) { free(data); png_destroy_read_struct(&png, &info, NULL); fclose(fp); return -1; }
    for (int y = 0; y < height; ++y) rows[y] = data + y * rowbytes;
    png_read_image(png, rows);
    free(rows);

    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);

    *out_buf = data; *out_w = width; *out_h = height;
    return 0;
}

/* Nearest-neighbor scale/blit RGBA -> XRGB8888 framebuffer (dest is uint32_t array) */
static void scale_and_blit_to_xrgb(unsigned char *src, int sw, int sh,
                                   uint32_t *dest, int dw, int dh, int dest_stride_pixels,
                                   int dest_x, int dest_y) {
    if (!src || !dest) return;
    int target_w = dw;
    int target_h = dh / 2; // bottom half
    for (int ty = 0; ty < target_h; ++ty) {
        int sy = (ty * sh) / target_h;
        uint32_t *drow = dest + (dest_y + ty) * dest_stride_pixels + dest_x;
        for (int tx = 0; tx < target_w; ++tx) {
            int sx = (tx * sw) / target_w;
            unsigned char *p = src + (sy * sw + sx) * 4; // RGBA
            unsigned char r = p[0]; unsigned char g = p[1]; unsigned char b = p[2];
            uint32_t pixel = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b; // 0x00RRGGBB
            drow[tx] = pixel;
        }
    }
}

/* Find connector and mode (same logic as before) */
static int find_connector_mode(int fd, uint32_t *out_conn, uint32_t *out_crtc, drmModeModeInfo *out_mode) {
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) return -1;
    // preferred
    for (int i = 0; i < res->count_connectors; ++i) {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn) continue;
        if (conn->connection != DRM_MODE_CONNECTED) { drmModeFreeConnector(conn); continue; }
        for (int m = 0; m < conn->count_modes; ++m) {
            if ((int)conn->modes[m].hdisplay == PREFERRED_W && (int)conn->modes[m].vdisplay == PREFERRED_H) {
                uint32_t chosen_crtc = 0;
                if (conn->encoder_id) {
                    drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
                    if (enc) { chosen_crtc = enc->crtc_id; drmModeFreeEncoder(enc); }
                }
                if (!chosen_crtc && res->count_crtcs > 0) chosen_crtc = res->crtcs[0];
                *out_conn = conn->connector_id; *out_crtc = chosen_crtc; *out_mode = conn->modes[m];
                drmModeFreeConnector(conn); drmModeFreeResources(res); return 0;
            }
        }
        drmModeFreeConnector(conn);
    }
    // fallback
    for (int i = 0; i < res->count_connectors; ++i) {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn) continue;
        if (conn->connection != DRM_MODE_CONNECTED) { drmModeFreeConnector(conn); continue; }
        if (conn->count_modes == 0) { drmModeFreeConnector(conn); continue; }
        uint32_t chosen_crtc = 0;
        if (conn->encoder_id) { drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id); if (enc) { chosen_crtc = enc->crtc_id; drmModeFreeEncoder(enc); } }
        if (!chosen_crtc && res->count_crtcs > 0) chosen_crtc = res->crtcs[0];
        *out_conn = conn->connector_id; *out_crtc = chosen_crtc; *out_mode = conn->modes[0];
        drmModeFreeConnector(conn); drmModeFreeResources(res); return 0;
    }
    drmModeFreeResources(res);
    return -1;
}

/* Create and map a dumb buffer, add FB, keep mapping pointer in fb_map */
static int create_dumb_fb(int fd, uint32_t width, uint32_t height) {
    struct drm_mode_create_dumb creq = {0};
    creq.width = width; creq.height = height; creq.bpp = 32;
    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        perror("DRM_IOCTL_MODE_CREATE_DUMB"); return -1; }
    dumb_handle = creq.handle; stride = creq.pitch; bo_size = creq.size;
    // map
    struct drm_mode_map_dumb mreq = {0}; mreq.handle = dumb_handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) { perror("DRM_IOCTL_MODE_MAP_DUMB"); return -1; }
    fb_map = mmap(0, bo_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (fb_map == MAP_FAILED) { perror("mmap"); fb_map = NULL; return -1; }
    // create FB
    if (drmModeAddFB(fd, width, height, 24, 32, stride, dumb_handle, &fb_id)) { perror("drmModeAddFB"); munmap(fb_map, bo_size); fb_map = NULL; return -1; }
    return 0;
}

static void destroy_dumb_fb(int fd) {
    if (fb_id) { drmModeRmFB(fd, fb_id); fb_id = 0; }
    if (fb_map) { munmap(fb_map, bo_size); fb_map = NULL; }
    if (dumb_handle) { struct drm_mode_destroy_dumb dreq = { .handle = dumb_handle }; ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq); dumb_handle = 0; }
}

int main(int argc, char **argv) {
    fprintf(stderr, "dmarquee v%s starting...\n", VERSION);
    signal(SIGINT, sigint_handler);

    // ensure FIFO exists
    if (mkfifo(CMD_FIFO, 0666) < 0) {
        if (errno != EEXIST) { perror("mkfifo"); return 1; }
    }
    chmod(CMD_FIFO, 0666); // allow any user to write commands

    // open DRM device
    drm_fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) { perror("open drm"); return 1; }

    // attempt to become DRM master (recommended for daemon)
    if (drmSetMaster(drm_fd) != 0) {
        perror("drmSetMaster (continuing anyway)");
        // continue: we may still be able to set the CRTC depending on environment
    }

    // locate connector & mode
    if (find_connector_mode(drm_fd, &conn_id, &crtc_id, &chosen_mode) != 0) {
        fprintf(stderr, "Failed to find connected output\n"); close(drm_fd); return 1; }
    fprintf(stderr, "Selected connector %u mode %dx%d crtc %u\n", conn_id, chosen_mode.hdisplay, chosen_mode.vdisplay, crtc_id);

    // create persistent dumb framebuffer sized to chosen_mode
    if (create_dumb_fb(drm_fd, chosen_mode.hdisplay, chosen_mode.vdisplay) != 0) {
        fprintf(stderr, "Failed to create dumb FB\n"); close(drm_fd); return 1; }

    // Clear framebuffer (black)
    if (fb_map) memset(fb_map, 0x00, bo_size);

    // set CRTC once to show our FB (this may fail with EPERM if another master exists)
    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0) {
        perror("drmModeSetCrtc"); // we'll still run and accept commands; writes will not be visible until we succeed
    } else {
        fprintf(stderr, "Initial FB presented\n");
    }

    // main loop: read FIFO lines and act on them
    while (running) {
        int fifo = open(CMD_FIFO, O_RDONLY);
        if (fifo < 0) { perror("open fifo"); break; }
        char buf[512];
        ssize_t n = read(fifo, buf, sizeof(buf)-1);
        close(fifo);
        if (n <= 0) { usleep(100000); continue; }
        buf[n] = '\0';
        // strip newline and whitespace
        char *p = buf; while (*p && (*p=='\n' || *p=='\r')) p++; // cheap trim front
        // trim trailing
        for (int i = strlen(buf)-1; i >= 0; --i) { if (buf[i]=='\n' || buf[i]=='\r' || buf[i]==' ' || buf[i]=='\t') buf[i] = '\0'; else break; }
        if (strlen(buf) == 0) continue;
        fprintf(stderr, "cmd: '%s'\n", buf);
        if (strcasecmp(buf, "EXIT") == 0) { running = false; break; }
        if (strcasecmp(buf, "CLEAR") == 0) {
            if (fb_map) memset(fb_map, 0x00, bo_size);
            // no need to re-add fb; kernel shows updated memory
            continue;
        }
        // otherwise treat as rom shortname
        char imgpath[512]; snprintf(imgpath, sizeof(imgpath), "%s/%s.png", IMAGE_DIR, buf);
        struct stat st; if (stat(imgpath, &st) != 0) { fprintf(stderr, "image missing: %s\n", imgpath); continue; }
        unsigned char *img = NULL; int iw=0, ih=0;
        if (load_png_rgba(imgpath, &img, &iw, &ih) != 0) { fprintf(stderr, "png load failed %s\n", imgpath); continue; }
        // clear bottom half to black first
        if (fb_map) {
            uint32_t *fbptr = (uint32_t *)fb_map;
            int fb_w = chosen_mode.hdisplay;
            int fb_h = chosen_mode.vdisplay;
            int stride_pixels = stride / 4;
            int dest_x = 0;
            int dest_y = fb_h - (fb_h/2);
            // black area already zeroed earlier; just overwrite bottom-half region
            scale_and_blit_to_xrgb(img, iw, ih, fbptr, fb_w, fb_h, stride_pixels, dest_x, dest_y);
            // After writing to mmap'd framebuffer memory, the kernel should display it. If needed, call drmModeSetCrtc again.
            if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0) {
                if (errno == EPERM) fprintf(stderr, "drmModeSetCrtc: Permission denied\n"); else perror("drmModeSetCrtc");
            }
        }
        free(img);
    }

    // cleanup
    destroy_dumb_fb(drm_fd);
    if (drm_fd >= 0) { drmDropMaster(drm_fd); close(drm_fd); }
    unlink(CMD_FIFO);
    fprintf(stderr, "dmarquee exiting\n");
    return 0;
}
