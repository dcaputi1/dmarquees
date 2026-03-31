/*
 dmarquee - RetroPie Marquee Daemon

 Lightweight DRM marquee daemon for Raspberry Pi / RetroPie.
 - Runs as a long-lived daemon (run as root at boot).
 - Owns /dev/dri/card1 (attempts drmSetMaster) and modesets the chosen connector.
 - Listens on a named FIFO /tmp/dmarquee_cmd for commands written by your plugin.
 - Commands:
     <shortname>   => load $HOME/mnt/marquees/<shortname>.png and display it
     CLEAR         => clear the screen (black)
     EXIT          => exit the daemon
     RA            => set frontend mode to RetroArch
     SA            => set frontend mode to StandAlone
     RESET         => reset the CRTC (re-acquire display)
     REFRESH       => reload the current image from disk
 - Image is scaled nearest-neighbor to fit the screen width while preserving aspect ratio.
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
#include <limits.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define VERSION "1.8.0"
#define CMD_FIFO "/tmp/dmarquees_cmd"
#define DEF_MARQUEE_NAME "RetroPieMarquee"
#define DEF_RA_MARQUEE_NAME "RetroArch_logo"
#define DEF_SA_MARQUEE_NAME "MAMELogoR"
#define PREFERRED_W 1920
#define PREFERRED_H 1080
#define FIFO_RETRY_DELAY_MSEC 250
#define CRTC_RESET_HOLD_SEC   10
#define PANEL_TMP_DC_SVG "/tmp/dmarquees_dcpanel.svg"
#define PANEL_TMP_DC_PNG "/tmp/dmarquees_dcpanel.png"
#define PANEL_TMP_MC_SVG "/tmp/dmarquees_mcpanel.svg"
#define PANEL_TMP_MC_PNG "/tmp/dmarquees_mcpanel.png"
#define HOME_PATH "/home/danc"

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

bool _this_is_pi5 = false;
bool _pi5_dual_display = false;
FrontendMode _frontend_mode = eNA;
bool _splash_mode = false;
char _drm_device_path[128] = "";
char _drm_connector_name[32] = "";
static time_t _ra_init_hold = 0;
static uint8_t* image = NULL;
static char last_image_path[PATH_MAX] = {0};
static char current_rom_shortname[128] = {0};

static const char* _image_dir = HOME_PATH "/mnt/marquees";
static const char* _image_dir_alt = HOME_PATH "/RetroPie/roms/mame/media/marquees";
static const char* _program_dir = HOME_PATH "/IvarArcade";
static const char* _default_marquee_dir = HOME_PATH "/IvarArcade/images";
static const char* _dcpanel_template = HOME_PATH "/IvarArcade/images/dcpanel-1-labels.svg";
static const char* _mcpanel_template = HOME_PATH "/IvarArcade/images/mcpanel-1-labels.svg";
static const char* _labels_dir = HOME_PATH "/IvarArcade/labels";
static const char* _this_is_pi5_file = HOME_PATH "/.this_is_pi5";
static const char* _pi5_dual_display_file = HOME_PATH "/.pi5_dual_display";
static const char* _pi3_is_present_file = HOME_PATH "/.pi3_present";

static bool join_path(char *out, size_t out_size, const char *dir, const char *file)
{
    if (!out || out_size == 0 || !dir || !file)
        return false;

    size_t dir_len = strlen(dir);
    size_t file_len = strlen(file);
    if (dir_len + 1 + file_len + 1 > out_size)
        return false;

    memcpy(out, dir, dir_len);
    out[dir_len] = '/';
    memcpy(out + dir_len + 1, file, file_len);
    out[dir_len + 1 + file_len] = '\0';
    return true;
}

static bool build_png_path(char *out, size_t out_size, const char *dir, const char *name)
{
    if (!out || out_size == 0 || !dir || !name)
        return false;

    size_t dir_len = strlen(dir);
    size_t name_len = strlen(name);
    const size_t ext_len = 4; // ".png"

    if (dir_len + 1 + name_len + ext_len + 1 > out_size)
        return false;

    memcpy(out, dir, dir_len);
    out[dir_len] = '/';
    memcpy(out + dir_len + 1, name, name_len);
    memcpy(out + dir_len + 1 + name_len, ".png", ext_len + 1);
    return true;
}

// Try to reset CRTC by becoming master, setting CRTC, then dropping master
// Returns true if drmModeSetCrtc succeeded
static bool try_reset_crtc(void)
{
    ts_printf("dmarquees: trying CRTC reset\n");

    bool crtc_success = false;
    bool got_master = drmSetMaster(drm_fd) == 0;
    if (!got_master)
        ts_perror("drmSetMaster (try_reset_crtc)");
    else
        ts_printf("dmarquees: master set\n");

    if (drmModeSetCrtc(drm_fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &chosen_mode) != 0)
        ts_perror("drmModeSetCrtc (try_reset_crtc)");
    else
    {
        ts_printf("dmarquees: crtc reset success!\n");
        crtc_success = true;
    }

    if (got_master)
    {
        if (drmDropMaster(drm_fd) != 0)
            ts_perror("drmDropMaster (try_reset_crtc)");
        else
            ts_printf("dmarquees: master dropped\n");
    }
    return crtc_success;
}

// Pick default marquee name based on frontend mode
static const char *default_marquee_name_for(FrontendMode m)
{
    switch (m)
    {
    case eSA: return DEF_SA_MARQUEE_NAME;
    case eRA: return DEF_RA_MARQUEE_NAME;
    case eNA:
    default:  return DEF_MARQUEE_NAME;
}

static bool read_bool_file(const char *path, bool default_value = false)
{
    FILE *fp = fopen(path, "r");

    if (!fp)
        return default_value;

    char buf[20] = {0};
    if (!fgets(buf, sizeof(buf), fp))
    {
        fclose(fp);
        return default_value;
    }

    fclose(fp);

    // Trim whitespace
    char *p = buf;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
        ++p;

    for (char *q = p; *q; ++q)
        if (*q == '\n' || *q == '\r')
            *q = 0;

    return strcasecmp(p, "true") == 0;
}

static void initialize_globals()
{
    _this_is_pi5 = read_bool_file(_this_is_pi5_file, true);
    _pi5_dual_display = read_bool_file(_pi5_dual_display_file, true);
    _pi3_present = read_bool_file(_pi3_is_present_file, true);

    _splash_mode = _this_is_pi5 && _pi3_present && _pi5_dual_display;

    if (!_this_is_pi5 || !_pi5_dual_display)
    {
        strncpy(_drm_connector_name, sizeof(_drm_connector_name), "HDMI-A-1");
        strncpy(_drm_device_path, sizeof(_drm_device_path), "/dev/dri/card0");
    }
    else
    {
        strncpy(_drm_connector_name, sizeof(_drm_connector_name), "HDMI-A-2");
        strncpy(_drm_device_path, sizeof(_drm_device_path), "/dev/dri/card1");
    }
}

// Draw the default marquee. Clears screen to black first.
static void show_default_marquee(void)
{
    if (!fb_map)
        return;

    const char *name = default_marquee_name_for(_frontend_mode);
    char imgpath[PATH_MAX];
    if (!build_png_path(imgpath, sizeof(imgpath), _default_marquee_dir, name))
    {
        ts_fprintf(stderr, "error: default marquee path too long: %s/%s.png\n", _default_marquee_dir, name);
        return;
    }

    int fb_w = chosen_mode.hdisplay;
    int fb_h = chosen_mode.vdisplay;

    // Clear entire screen to black
    memset(fb_map, 0x00, bo_size);

    int iw = 0, ih = 0;
    if (image)
        free(image);
    image = load_png_rgba(imgpath, &iw, &ih);
    if (!image)
    {
        ts_fprintf(stderr, "warning: default marquee load failed: %s\n", imgpath);
        return; // screen remains black
    }

    ts_printf("dmarquees: showing default marquee: %s\n", imgpath);

    scale_and_blit_to_xrgb(image, iw, ih, (uint32_t*)fb_map, fb_w, fb_h, stride / 4, 0, _splash_mode);
    try_reset_crtc();
    
    // Save the current image path for REFRESH command
    snprintf(last_image_path, sizeof(last_image_path), "%s", imgpath);
}

static const char *connector_type_name(uint32_t type)
{
    switch (type)
    {
    case DRM_MODE_CONNECTOR_Unknown: return "Unknown";
    case DRM_MODE_CONNECTOR_VGA: return "VGA";
    case DRM_MODE_CONNECTOR_DVII: return "DVI-I";
    case DRM_MODE_CONNECTOR_DVID: return "DVI-D";
    case DRM_MODE_CONNECTOR_DVIA: return "DVI-A";
    case DRM_MODE_CONNECTOR_Composite: return "Composite";
    case DRM_MODE_CONNECTOR_SVIDEO: return "SVIDEO";
    case DRM_MODE_CONNECTOR_LVDS: return "LVDS";
    case DRM_MODE_CONNECTOR_Component: return "Component";
    case DRM_MODE_CONNECTOR_9PinDIN: return "DIN";
    case DRM_MODE_CONNECTOR_DisplayPort: return "DP";
    case DRM_MODE_CONNECTOR_HDMIA: return "HDMI-A";
    case DRM_MODE_CONNECTOR_HDMIB: return "HDMI-B";
    case DRM_MODE_CONNECTOR_TV: return "TV";
    case DRM_MODE_CONNECTOR_eDP: return "eDP";
    case DRM_MODE_CONNECTOR_VIRTUAL: return "Virtual";
    case DRM_MODE_CONNECTOR_DSI: return "DSI";
    case DRM_MODE_CONNECTOR_DPI: return "DPI";
    case DRM_MODE_CONNECTOR_WRITEBACK: return "Writeback";
    case DRM_MODE_CONNECTOR_SPI: return "SPI";
    case DRM_MODE_CONNECTOR_USB: return "USB";
    default: return "Unknown";
    }
}

static bool connector_name_matches(const drmModeConnector *conn, const char *name)
{
    if (!conn || !name || !name[0])
        return false;

    char connector_name[32];
    snprintf(connector_name, sizeof(connector_name), "%s-%u", connector_type_name(conn->connector_type), conn->connector_type_id);
    return strcmp(connector_name, name) == 0;
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

    if (_drm_connector_name[0] != '\0')
    {
        for (int i = 0; i < res->count_connectors; ++i)
        {
            drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[i]);
            if (!conn)
                continue;
            if (!connector_name_matches(conn, _drm_connector_name) || conn->connection != DRM_MODE_CONNECTED || conn->count_modes == 0)
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

            int picked_mode = -1;
            for (int m = 0; m < conn->count_modes; ++m)
            {
                if ((int)conn->modes[m].hdisplay == PREFERRED_W && (int)conn->modes[m].vdisplay == PREFERRED_H)
                {
                    picked_mode = m;
                    break;
                }
            }
            if (picked_mode < 0)
                picked_mode = 0;
            *out_mode = conn->modes[picked_mode];

            drmModeFreeConnector(conn);
            drmModeFreeResources(res);
            return 0;
        }

        ts_fprintf(stderr, "warning: connector '%s' not found/connected, falling back to automatic selection\n", _drm_connector_name);
    }
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
    initialize_globals();

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

    // open DRM device (default is /dev/dri/card1, overridable with -d)
    drm_fd = open(_drm_device_path, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0)
    {
        ts_perror("open drm");
        ts_fprintf(stderr, "error: failed to open DRM device: %s\n", _drm_device_path);
        return 1;
    }

    // attempt to become DRM master (recommended for daemon)
    bool is_master = (drmSetMaster(drm_fd) == 0);
    if (!is_master)
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

    // Release DRM master so other apps (like MAME) can take control
    if (is_master)
    {
        if (drmDropMaster(drm_fd) != 0)
            ts_fprintf(stderr, "warning: drmDropMaster(1) failed (%s)\n", strerror(errno));
        else
            ts_printf("dmarquees: DRM master dropped - MAME can safely start.\n");
    }

    show_default_marquee();     // draw default marquee (RetroPie NA frontend)

    return 0;
}

static bool show_game_marquee(const char* cmd_str)
{
    char imgpath[PATH_MAX];
    if (!build_png_path(imgpath, sizeof(imgpath), _image_dir, cmd_str))
    {
        ts_fprintf(stderr, "warning: image path too long: %s/%s.png\n", _image_dir, cmd_str);
        return false;
    }

    struct stat st;
    if (stat(imgpath, &st) != 0)
    {
        // Try IMAGE_DIR_ALT as fallback
        if (!build_png_path(imgpath, sizeof(imgpath), _image_dir_alt, cmd_str))
        {
            ts_fprintf(stderr, "warning: alternate image path too long: %s/%s.png\n", _image_dir_alt, cmd_str);
            return false;
        }
        if (stat(imgpath, &st) != 0)
        {
            ts_fprintf(stderr, "warning: image missing in both directories: %s/%s.png\n", _image_dir, cmd_str);
            return false;
        }
        ts_printf("dmarquees: using alternate image directory: %s\n", imgpath);
    }

    int iw = 0, ih = 0;

    if (image)
        free(image);

    image = load_png_rgba(imgpath, &iw, &ih);

    if (image == NULL)
    {
        ts_fprintf(stderr, "error: png load failed %s\n", imgpath);
        return false;
    }

    ts_printf("dmarquees: game marquee loaded: %s.png\n", cmd_str);

    // clear screen to black first and blit ROM marquee
    if (fb_map)
    {
        uint32_t* fbptr = (uint32_t*)fb_map;
        int fb_w = chosen_mode.hdisplay;
        int fb_h = chosen_mode.vdisplay;
        int stride_pixels = stride / 4;
        int dest_x = 0;

        // Clear screen before blit (to avoid remnants)
        memset(fb_map, 0, bo_size);

        scale_and_blit_to_xrgb(image, iw, ih, fbptr, fb_w, fb_h, stride_pixels, dest_x, false);
        try_reset_crtc();
        
        // Save the current image path for REFRESH command
        snprintf(last_image_path, sizeof(last_image_path), "%s", imgpath);
    }
    return true;
}

static char *read_text_file(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp)
        return NULL;

    if (fseek(fp, 0, SEEK_END) != 0)
    {
        fclose(fp);
        return NULL;
    }

    long size = ftell(fp);
    if (size < 0)
    {
        fclose(fp);
        return NULL;
    }

    if (fseek(fp, 0, SEEK_SET) != 0)
    {
        fclose(fp);
        return NULL;
    }

    char *buf = (char *)malloc((size_t)size + 1);
    if (!buf)
    {
        fclose(fp);
        return NULL;
    }

    size_t nread = fread(buf, 1, (size_t)size, fp);
    fclose(fp);
    if (nread != (size_t)size)
    {
        free(buf);
        return NULL;
    }

    buf[nread] = '\0';
    return buf;
}

static bool write_text_file(const char *path, const char *content)
{
    FILE *fp = fopen(path, "wb");
    if (!fp)
        return false;

    size_t len = strlen(content);
    bool ok = fwrite(content, 1, len, fp) == len;
    fclose(fp);
    return ok;
}

static char *xml_escape_text(const char *src)
{
    if (!src)
        return NULL;

    size_t extra = 0;
    for (const char *p = src; *p; ++p)
    {
        switch (*p)
        {
        case '&': extra += 4; break; // &amp;
        case '<':
        case '>': extra += 3; break; // &lt; / &gt;
        case '"':
        case '\'': extra += 5; break; // &quot; / &apos;
        default: break;
        }
    }

    size_t len = strlen(src);
    char *out = (char *)malloc(len + extra + 1);
    if (!out)
        return NULL;

    char *d = out;
    for (const char *p = src; *p; ++p)
    {
        switch (*p)
        {
        case '&': memcpy(d, "&amp;", 5); d += 5; break;
        case '<': memcpy(d, "&lt;", 4); d += 4; break;
        case '>': memcpy(d, "&gt;", 4); d += 4; break;
        case '"': memcpy(d, "&quot;", 6); d += 6; break;
        case '\'': memcpy(d, "&apos;", 6); d += 6; break;
        default: *d++ = *p; break;
        }
    }
    *d = '\0';
    return out;
}

static bool replace_label_text(char **svg_buf, const char *label_id, const char *new_text)
{
    if (!svg_buf || !*svg_buf || !label_id || !new_text)
        return false;

    char id_key[256];
    snprintf(id_key, sizeof(id_key), "id=\"%s\"", label_id);

    char *svg = *svg_buf;
    char *id_pos = strstr(svg, id_key);
    if (!id_pos)
        return false;

    char *text_start = id_pos;
    while (text_start > svg && strncmp(text_start, "<text", 5) != 0)
        --text_start;
    if (strncmp(text_start, "<text", 5) != 0)
        return false;

    char *text_tag_end = strchr(text_start, '>');
    char *text_close = strstr(text_start, "</text>");
    if (!text_tag_end || !text_close || text_tag_end >= text_close)
        return false;

    char *content_start = text_tag_end + 1;
    char *content_end = text_close;

    char *tspan = strstr(content_start, "<tspan");
    if (tspan && tspan < text_close)
    {
        char *tspan_end_tag = strstr(tspan, "</tspan>");
        char *tspan_open_end = strchr(tspan, '>');
        if (tspan_end_tag && tspan_open_end && tspan_open_end < tspan_end_tag)
        {
            content_start = tspan_open_end + 1;
            content_end = tspan_end_tag;
        }
    }

    size_t old_len = strlen(svg);
    size_t prefix_len = (size_t)(content_start - svg);
    size_t suffix_len = old_len - (size_t)(content_end - svg);
    size_t repl_len = strlen(new_text);

    char *updated = (char *)malloc(prefix_len + repl_len + suffix_len + 1);
    if (!updated)
        return false;

    memcpy(updated, svg, prefix_len);
    memcpy(updated + prefix_len, new_text, repl_len);
    memcpy(updated + prefix_len + repl_len, content_end, suffix_len);
    updated[prefix_len + repl_len + suffix_len] = '\0';

    free(*svg_buf);
    *svg_buf = updated;
    return true;
}

// Normalize a CSV field in-place: trim caller-provided whitespace, then
// strip wrapping double quotes and unescape doubled quotes ("").
static char *normalize_csv_field(char *field)
{
    if (!field)
        return NULL;

    size_t len = strlen(field);
    if (len >= 2 && field[0] == '"' && field[len - 1] == '"')
    {
        field[len - 1] = '\0';
        char *src = field + 1;
        char *dst = field;
        while (*src)
        {
            if (src[0] == '"' && src[1] == '"')
            {
                *dst++ = '"';
                src += 2;
            }
            else
            {
                *dst++ = *src++;
            }
        }
        *dst = '\0';
    }

    return field;
}

static int apply_substitutions_from_csv(char **svg_buf, const char *csv_path)
{
    FILE *fp = fopen(csv_path, "r");
    if (!fp)
        return -1;

    int applied = 0;
    char line[1024];
    while (fgets(line, sizeof(line), fp))
    {
        char *line_trimmed = trim(line, strlen(line));
        if (!line_trimmed || line_trimmed[0] == '#')
            continue;

        char *comma = strchr(line_trimmed, ',');
        if (!comma)
            continue;

        *comma = '\0';
        char *id = trim(line_trimmed, strlen(line_trimmed));
        char *text = trim(comma + 1, strlen(comma + 1));
        if (!id || !text)
            continue;

        id = normalize_csv_field(id);
        text = normalize_csv_field(text);
        if (!id || !text)
            continue;

        char *escaped = xml_escape_text(text);
        if (!escaped)
            continue;

        if (replace_label_text(svg_buf, id, escaped))
            applied++;

        free(escaped);
    }

    fclose(fp);
    return applied;
}

static bool find_panel_map(const char *shortname, bool dc_panel, char *out_path, size_t out_size)
{
    if (!shortname || !out_path || out_size == 0)
        return false;

    struct stat st;
    char file_name[256];
    const char *ext = dc_panel ? ".dcp" : ".mcp";
    size_t short_len = strlen(shortname);
    size_t ext_len = strlen(ext);
    if (short_len + ext_len + 1 > sizeof(file_name))
        return false;

    memcpy(file_name, shortname, short_len);
    memcpy(file_name + short_len, ext, ext_len + 1);

    if (!join_path(out_path, out_size, _labels_dir, file_name))
        return false;

    if (stat(out_path, &st) == 0)
        return true;

    return false;
}

static bool convert_svg_to_png(const char *svg_path, const char *png_path)
{
    char cmd[PATH_MAX * 2 + 128];

    // Prefer rsvg-convert if available
    snprintf(cmd, sizeof(cmd), "rsvg-convert -o \"%s\" \"%s\" >/dev/null 2>&1", png_path, svg_path);
    if (system(cmd) == 0)
        return true;

    // Fallback: ImageMagick convert
    snprintf(cmd, sizeof(cmd), "convert \"%s\" \"%s\" >/dev/null 2>&1", svg_path, png_path);
    return system(cmd) == 0;
}

static bool show_panel_marquee(const char *shortname, bool dc_panel)
{
    const char *template_path = dc_panel ? _dcpanel_template : _mcpanel_template;
    const char *tmp_svg = dc_panel ? PANEL_TMP_DC_SVG : PANEL_TMP_MC_SVG;
    const char *tmp_png = dc_panel ? PANEL_TMP_DC_PNG : PANEL_TMP_MC_PNG;

    char *svg = read_text_file(template_path);
    if (!svg)
    {
        ts_fprintf(stderr, "error: panel template missing: %s\n", template_path);
        return false;
    }

    char map_path[PATH_MAX];
    int applied = 0;
    if (find_panel_map(shortname, dc_panel, map_path, sizeof(map_path)))
    {
        int n = apply_substitutions_from_csv(&svg, map_path);
        if (n >= 0)
        {
            applied = n;
            ts_printf("dmarquees: panel substitutions applied: %d (%s)\n", applied, map_path);
        }
    }
    else
    {
        ts_fprintf(stderr, "warning: panel map not found for %s (%s panel)\n", shortname, dc_panel ? "dc" : "mc");
    }

    if (!write_text_file(tmp_svg, svg))
    {
        free(svg);
        ts_fprintf(stderr, "error: failed writing temp svg: %s\n", tmp_svg);
        return false;
    }
    free(svg);

    if (!convert_svg_to_png(tmp_svg, tmp_png))
    {
        ts_fprintf(stderr, "error: svg conversion failed (need rsvg-convert or convert)\n");
        return false;
    }

    int iw = 0, ih = 0;
    if (image)
        free(image);
    image = load_png_rgba(tmp_png, &iw, &ih);
    if (!image)
    {
        ts_fprintf(stderr, "error: converted panel png load failed: %s\n", tmp_png);
        return false;
    }

    if (fb_map)
    {
        uint32_t *fbptr = (uint32_t *)fb_map;
        int fb_w = chosen_mode.hdisplay;
        int fb_h = chosen_mode.vdisplay;
        int stride_pixels = stride / 4;

        memset(fb_map, 0, bo_size);
        scale_and_blit_to_xrgb(image, iw, ih, fbptr, fb_w, fb_h, stride_pixels, 0, false);
        try_reset_crtc();
        snprintf(last_image_path, sizeof(last_image_path), "%s", tmp_png);
    }

    ts_printf("dmarquees: showing %s panel for %s (%d substitutions)\n", dc_panel ? "DC" : "MC", shortname, applied);
    return true;
}

static bool toggle_panel_display(bool dc_panel, bool panel_on)
{
    const char *panel_name = dc_panel ? "DCPANEL" : "MCPANEL";
    if (current_rom_shortname[0] == '\0')
    {
        ts_fprintf(stderr, "warning: %s ignored - no tracked ROM yet\n", panel_name);
        return false;
    }

    if (panel_on)
        return show_panel_marquee(current_rom_shortname, dc_panel);

    return show_game_marquee(current_rom_shortname);
}

static void refresh_current_marquee(void);

static void handle_fifo_command(char *cmd_str)
{
    if (!cmd_str)
        return;

    char token[128] = {0};
    char arg[128] = {0};
    int parsed = sscanf(cmd_str, "%127s %127s", token, arg);
    if (parsed <= 0)
        return;

    CommandType command = toCommandType(token);

    switch (command)
    {
    case CMD_RA:
        _frontend_mode = eRA;
        ts_printf("dmarquees: frontend mode changed to RA\n");
        show_default_marquee();
        break;

    case CMD_SA:
        _frontend_mode = eSA;
        ts_printf("dmarquees: frontend mode changed to SA\n");
        show_default_marquee();
        break;

    case CMD_NA:
        _frontend_mode = eNA;
        ts_printf("dmarquees: frontend mode changed to NA\n");
        show_default_marquee();
        break;

    case CMD_EXIT:
        running = false;
        break;

    case CMD_CLEAR:
        show_default_marquee();
        break;

    case CMD_RESET:
        try_reset_crtc();
        break;

    case CMD_REFRESH:
        refresh_current_marquee();
        break;

    case CMD_DCPANEL:
        if (_splash_mode)
        {
            ts_printf("dmarquees: splash mode - DCPANEL ignored\n");
            break;
        }
        if (parsed < 2 || (strcmp(arg, "0") != 0 && strcmp(arg, "1") != 0))
        {
            ts_fprintf(stderr, "warning: DCPANEL requires 0 or 1 (e.g. DCPANEL 1)\n");
            break;
        }
        if (!toggle_panel_display(true, strcmp(arg, "1") == 0))
            show_default_marquee();
        break;

    case CMD_MCPANEL:
        if (_splash_mode)
        {
            ts_printf("dmarquees: splash mode - MCPANEL ignored\n");
            break;
        }
        if (parsed < 2 || (strcmp(arg, "0") != 0 && strcmp(arg, "1") != 0))
        {
            ts_fprintf(stderr, "warning: MCPANEL requires 0 or 1 (e.g. MCPANEL 1)\n");
            break;
        }
        if (!toggle_panel_display(false, strcmp(arg, "1") == 0))
            show_default_marquee();
        break;

    case CMD_ROM:
        // In splash screen mode: blank the display so dual-screen games (e.g. Punch-Out)
        // can use the secondary monitor.  No game marquee art is shown.
        if (_splash_mode)
        {
            ts_printf("dmarquees: splash mode - blanking screen for game\n");
            if (fb_map)
            {
                memset(fb_map, 0x00, bo_size);
                try_reset_crtc();
            }
            break;
        }
        // Strip optional RC: prefix (marks command from trusted runcommand source).
        // Accept RC: in all frontend modes so the MAME plugin can reliably sync
        // the current ROM shortname regardless of which mode the daemon is in.
        if (!strncmp(cmd_str, "RC:", 3))
            cmd_str += 3;
        // In RA mode: reject plain ROM names (could be spurious RA plugin signals).
        else if (_frontend_mode == eRA)
            break;

        // If we reach here, it's either eROM or an unknown command - treat as ROM shortname
        if (game_has_multiple_screens(cmd_str))
        {
            ts_printf("dmarquees: Skipping multi-screen game: %s\n", cmd_str);
            break;
        }

        // otherwise treat as rom shortname
        if (!show_game_marquee(cmd_str))
        {
            // Fallback: show default marquee
            show_default_marquee();
        }
        else
        {
            snprintf(current_rom_shortname, sizeof(current_rom_shortname), "%s", cmd_str);
        }
        break;

    default: // never happens
        break;
    }
}

static void refresh_current_marquee(void)
{
    if (!fb_map)
        return;
    
    if (last_image_path[0] == '\0')
    {
        ts_printf("dmarquees: REFRESH - no image loaded yet\n");
        return;
    }
    
    ts_printf("dmarquees: REFRESH - reloading %s\n", last_image_path);
    
    int iw = 0, ih = 0;
    
    if (image)
        free(image);
    
    image = load_png_rgba(last_image_path, &iw, &ih);
    
    if (image == NULL)
    {
        ts_fprintf(stderr, "error: png load failed during refresh: %s\n", last_image_path);
        return;
    }
    
    // Clear screen and blit refreshed image
    uint32_t* fbptr = (uint32_t*)fb_map;
    int fb_w = chosen_mode.hdisplay;
    int fb_h = chosen_mode.vdisplay;
    int stride_pixels = stride / 4;
    
    memset(fb_map, 0, bo_size);
    scale_and_blit_to_xrgb(image, iw, ih, fbptr, fb_w, fb_h, stride_pixels, 0, _splash_mode);
    try_reset_crtc();
    
    ts_printf("dmarquees: REFRESH complete\n");
}

int main(int argc, char **argv)
{
    ts_printf("dmarquees: v%s starting...\n", VERSION);

    _frontend_mode = eNA;

    signal(SIGINT, sigint_handler);

    if (initialize() != 0)
        return 1;

    ts_printf("dmarquees: entering main loop\n");

    char buf[128];
    int spam_count = 0;

    // main loop: read FIFO lines and act on them
    while (running)
    {
        int fifo = open(CMD_FIFO, O_RDONLY);
        if (fifo < 0)
        {
            ts_perror("open");
            ts_fprintf(stderr, "dmarquees: FATAL - can't access command fifo\n");
            break;  // get out of main loop
        }

        if (spam_count++ < 5)
            ts_printf("dmarquees (%d): read on %s\n", spam_count, CMD_FIFO);
        else if (spam_count == 6)
            ts_printf("dmarquees: further logging for fifo suppressed\n");

        ssize_t read_len = read(fifo, buf, sizeof(buf) - 1);

        close(fifo);

        if (read_len > 0)
        {
            // Looks like we have one or more newline-delimited commands.
            buf[read_len] = '\0';
        }
        else if (_ra_init_hold && (time(NULL) > _ra_init_hold))
        {
            ts_printf("dmarquees: retrying crtc now...\n");
            if (try_reset_crtc())
                _ra_init_hold = 0;                 // clear hold
            else
                _ra_init_hold = time(NULL) + 1;    // try again in 1 second

            continue;
        }
        else
        {
            usleep(FIFO_RETRY_DELAY_MSEC * 1000);
            continue;
        }

        for (char *line = buf; line && *line; )
        {
            char *next = strchr(line, '\n');
            if (next)
                *next++ = '\0';

            char *cmd_str = trim(line, strlen(line));
            if (cmd_str)
            {
                ts_printf("dmarquees: command received: '%s'\n", cmd_str);
                handle_fifo_command(cmd_str);
            }

            line = next;
        }
    }

    // cleanup
    destroy_dumb_fb(drm_fd);
    if (drm_fd >= 0)
    {
        drmDropMaster(drm_fd);
        close(drm_fd);
    }
    unlink(CMD_FIFO);
    ts_printf("dmarquees: exiting\n");
    return 0;
}
