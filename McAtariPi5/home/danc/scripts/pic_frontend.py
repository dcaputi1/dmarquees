#!/usr/bin/env python3

import os
import subprocess
import sys

# --- SDL/Pygame environment setup for console/framebuffer ---
#
# IMPORTANT: SDL2 DRM/KMS errors such as:
#   "ERROR: Could not set videomode on CRTC."
#   "ERROR: Could not queue pageflip: -28"
# are printed by the SDL2 C library directly to the OS-level stderr fd.
# They NEVER become Python exceptions, so try/except is blind to them.
# We must redirect fd 2 at the OS level to catch them.

_FATAL_SDL_ERRORS = [
    "could not set videomode on crtc",
    "could not queue pageflip",
]

def _capture_sdl_stderr(func):
    """
    Call func() while redirecting the OS-level stderr file descriptor to a pipe,
    so that SDL2 C-library error messages are captured rather than printed to the TTY.
    Returns (result, captured_text).
    Re-raises any Python exception from func() after stderr is restored.
    """
    import fcntl
    try:
        real_stderr_fd = sys.stderr.fileno()
    except Exception:
        # No real fd (e.g. redirected StringIO); just call normally.
        return func(), ""

    saved_fd = os.dup(real_stderr_fd)
    r_fd, w_fd = os.pipe()
    os.dup2(w_fd, real_stderr_fd)
    os.close(w_fd)

    result = None
    exc = None
    try:
        result = func()
    except Exception as e:
        exc = e
    finally:
        try:
            sys.stderr.flush()
        except Exception:
            pass
        os.dup2(saved_fd, real_stderr_fd)
        os.close(saved_fd)

    # Drain the pipe (non-blocking so we don't hang)
    flags = fcntl.fcntl(r_fd, fcntl.F_GETFL)
    fcntl.fcntl(r_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    captured = b""
    try:
        while True:
            chunk = os.read(r_fd, 4096)
            if not chunk:
                break
            captured += chunk
    except (BlockingIOError, OSError):
        pass
    finally:
        os.close(r_fd)

    if exc is not None:
        raise exc
    return result, captured.decode(errors="replace")


def _die_on_sdl_errors(captured_text):
    """
    If captured SDL2 stderr contains a fatal DRM/CRTC error, print it and
    hard-exit immediately via os._exit() to avoid a hung/spamming TTY.
    """
    lower = captured_text.lower()
    for msg in _FATAL_SDL_ERRORS:
        if msg in lower:
            # Write directly to the real stderr (already restored at this point)
            print(captured_text.rstrip(), file=sys.stderr)
            print(f"\n[FATAL] SDL2 DRM error detected: '{msg}'\n"
                  "Cannot initialize display from console TTY. "
                  "Ensure no other display server is running and KMS/DRM is available.\n"
                  "Exiting.", file=sys.stderr)
            sys.stderr.flush()
            os._exit(1)  # hard exit — skip all cleanup to avoid further TTY spam


# Build ordered list of SDL video drivers to attempt.
# On console: try kmsdrm first, fall back to fbdev if kmsdrm can't set a videomode.
# Under X11/Wayland: honour whatever DISPLAY points to.
if not os.environ.get("DISPLAY"):
    # Console mode: kmsdrm or fbdev only, no window manager.
    # On Pi 5, card0 is the RP1 chip (no display connectors); card1 is the
    # display controller.  Try card1 first, then card0 as a fallback.
    # kmsdrm REQUIRES fullscreen mode — windowed set_mode() produces
    # "Could not set videomode on CRTC" from the SDL2 C library.
    _CONSOLE_DISPLAY = True
    _drm_cards = sorted(
        e.name for e in os.scandir("/dev/dri") if e.name.startswith("card")
    ) if os.path.isdir("/dev/dri") else []
    print(f"[INFO] DRM devices found: {_drm_cards}", file=sys.stderr)
    _SDL_DRIVERS_TO_TRY = [
        ("kmsdrm", "1"),  # Pi 5: card1 is the display controller
        ("kmsdrm", "0"),
        ("fbdev",  None),
    ]
    os.environ.pop("SDL_FBDEV", None)
else:
    _CONSOLE_DISPLAY = False
    print("[INFO] X11/Wayland display detected.", file=sys.stderr)
    _SDL_DRIVERS_TO_TRY = [(os.environ.get("SDL_VIDEODRIVER", ""), None)]

os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame

# ---------------------------------------------------------------------------
# Visual constants — edit these to restyle all menus globally.
#
# pygame.Color() is used where an exact named color exists in pygame's X11
# color dictionary (no init required; it is a standalone data class).
# Plain RGB tuples are used where no exact pygame named color exists.
# ---------------------------------------------------------------------------
BLACK_RGB      = pygame.Color('black')        # (0, 0, 0)
WHITE_RGB      = pygame.Color('white')        # (255, 255, 255)
YELLOW_RGB     = pygame.Color('yellow')       # (255, 255, 0)
CYAN_RGB       = pygame.Color('cyan')         # (0, 255, 255)
GREEN_RGB      = pygame.Color('lime')         # (0, 255, 0) — X11 'lime' is pure green
RED_RGB        = pygame.Color('red')          # (255, 0, 0)
DK_BLUE_RGB    = pygame.Color('midnightblue') # (25, 25, 112) — exact X11/CSS name
LT_GRAY_RGB    = (128, 128, 128)              # no exact pygame named color
UNSEL_ITEM_RGB = (200, 200, 200)              # no exact pygame named color

MENU_W    = 490   # menu surface width in pixels
MENU_H    = 490   # menu surface height in pixels
FONT_SZ   = 36    # system font point size
BORDER_PX = 2     # line thickness for all outline draws (menu border, selection rectangle, title borders)
BORDER_SZ = 10    # gap in pixels between the menu border and any inner rectangle (title borders, selection rectangle, timer dotted rect)

MENU_BG_COLOR     = BLACK_RGB      # menu surface background fill
SCREEN_BG_COLOR   = DK_BLUE_RGB   # screen background fill (visible behind centered menu surface)
SELECT_RECT_COLOR = YELLOW_RGB    # selection rectangle outline and selected item text color

# State file paths
HOME = os.path.expanduser("~")
PI5_DUAL_DISPLAY_FILE = os.path.join(HOME, ".pi5_dual_display")
PI3_PRESENT_FILE = os.path.join(HOME, ".pi3_present")
PANEL_FILE = os.path.join(HOME, ".panel")
SCREEN_ORIENTATION_FILE = os.path.join(HOME, ".horizontal")
DEF_KEY_FILE = os.path.join(HOME, ".def_key")

# Load or initialize state
def load_state(path, default):
    if os.path.exists(path):
        with open(path, "r") as f:
            val = f.read().strip()
            if val.lower() in ("true", "1", "on"):
                return True
            if val.lower() in ("false", "0", "off"):
                return False
            return val
    else:
        with open(path, "w") as f:
            f.write(str(default))
        return default

def save_state(path, value):
    with open(path, "w") as f:
        f.write(str(value).lower() if isinstance(value, bool) else str(value).strip())

# Initial state
dual_display = load_state(PI5_DUAL_DISPLAY_FILE, True)
pi3_present = load_state(PI3_PRESENT_FILE, True)
panel = load_state(PANEL_FILE, "DC")  # DC, MC, NA
screen_horizontal = load_state(SCREEN_ORIENTATION_FILE, True)

# --- NEW: Window/fullscreen mode and dynamic sizing ---
WINDOWED = True
FULLSCREEN = False
def get_screen_size():
    if screen_horizontal:
        return (640, 480)
    else:
        return (480, 640)

def set_screen(fullscreen):
    global screen, WINDOWED, FULLSCREEN
    size = get_screen_size()
    if _CONSOLE_DISPLAY:
        # kmsdrm/fbdev require fullscreen; use native resolution (0,0) to
        # avoid mode-mismatch failures when the display doesn't support the
        # hardcoded size.  The rendering code centers content on the surface.
        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        FULLSCREEN = True
        WINDOWED = False
    elif fullscreen:
        screen = pygame.display.set_mode(size, pygame.FULLSCREEN)
        FULLSCREEN = True
        WINDOWED = False
    else:
        screen = pygame.display.set_mode(size)
        FULLSCREEN = False
        WINDOWED = True


# Initialize pygame, trying each driver in _SDL_DRIVERS_TO_TRY order.
# kmsdrm errors come from the SDL2 C library directly to stderr; we capture
# them at the OS fd level and fall through to the next driver rather than
# aborting, so that fbdev gets a chance if kmsdrm can't set a videomode.
_init_ok = False
for _drv, _kmsdrm_dev in _SDL_DRIVERS_TO_TRY:
    if _drv:
        os.environ["SDL_VIDEODRIVER"] = _drv
    else:
        os.environ.pop("SDL_VIDEODRIVER", None)
    if _kmsdrm_dev is not None:
        os.environ["SDL_KMSDRM_DEVICE_INDEX"] = _kmsdrm_dev
    else:
        os.environ.pop("SDL_KMSDRM_DEVICE_INDEX", None)
    _drv_label = f"{_drv}(dev={_kmsdrm_dev})" if _kmsdrm_dev is not None else _drv
    try:
        pygame.quit()   # reset any partial state from a previous attempt
    except Exception:
        pass
    try:
        _, _sdl_out = _capture_sdl_stderr(pygame.init)
    except Exception as e:
        print(f"[WARN] pygame.init failed with driver '{_drv_label}': {e}", file=sys.stderr)
        continue
    if any(msg in _sdl_out.lower() for msg in _FATAL_SDL_ERRORS):
        print(f"[WARN] SDL2 driver '{_drv_label}' init error (trying next):\n{_sdl_out.rstrip()}", file=sys.stderr)
        continue
    try:
        _, _sdl_out2 = _capture_sdl_stderr(lambda: set_screen(fullscreen=False))
    except Exception as e:
        print(f"[WARN] set_screen failed with driver '{_drv_label}': {e}", file=sys.stderr)
        continue
    if any(msg in _sdl_out2.lower() for msg in _FATAL_SDL_ERRORS):
        print(f"[WARN] SDL2 driver '{_drv_label}' set_screen error (trying next):\n{_sdl_out2.rstrip()}", file=sys.stderr)
        continue
    pygame.display.set_caption("Arcade Menu")
    print(f"[INFO] Display initialized with SDL_VIDEODRIVER={_drv_label}", file=sys.stderr)
    _init_ok = True
    break

if not _init_ok:
    tried = [f"{d}(dev={k})" if k is not None else d for d, k in _SDL_DRIVERS_TO_TRY]
    print(f"\n[ERROR] Could not initialize display with any SDL driver.\n"
          f"Tried: {tried}\n",
          file=sys.stderr)
    sys.exit(1)

font = pygame.font.SysFont(None, FONT_SZ)

def toggle_fullscreen():
    global FULLSCREEN
    set_screen(not FULLSCREEN)

def _draw_dotted_rect(surface, color, rect, dash=6, gap=4, width=1):
    """Draw a dashed/dotted rectangle border on surface."""
    x, y, w, h = rect
    for axis in range(4):
        if axis == 0:   # top
            p1, p2, fixed, along = x, x + w, y, True
        elif axis == 1: # bottom
            p1, p2, fixed, along = x, x + w, y + h - 1, True
        elif axis == 2: # left
            p1, p2, fixed, along = y, y + h, x, False
        else:           # right
            p1, p2, fixed, along = y, y + h, x + w - 1, False
        pos = p1
        while pos < p2:
            end = min(pos + dash, p2)
            if along:
                pygame.draw.line(surface, color, (pos, fixed), (end, fixed), width)
            else:
                pygame.draw.line(surface, color, (fixed, pos), (fixed, end), width)
            pos += dash + gap

# Map .def_key values back to main_menu selected index
_DEF_KEY_TO_IDX = {"E": 0, "M": 1, "A": 2, "C": 3, "X": 4}

def _load_def_key_index():
    """Return the main_menu index corresponding to the persisted .def_key, or 0 if absent/unknown."""
    if os.path.exists(DEF_KEY_FILE):
        with open(DEF_KEY_FILE, "r") as f:
            key = f.read().strip().upper()
        return _DEF_KEY_TO_IDX.get(key, 0)
    return 0

def _output_choice(choice):
    """Persist choice to .def_key and exit cleanly; bash reloads all state and reads .def_key to decide what to launch."""
    save_state(DEF_KEY_FILE, choice)
    pygame.quit()
    sys.exit(0)

def panel_menu():
    global panel, screen_horizontal
    options = [("None/Blank", "NA"), ("Atari FS", "MC"), ("UltraStick", "DC")]
    idx = [i for i, (_, code) in enumerate(options) if code == panel]
    idx = idx[0] if idx else 0
    running = True
    while running:
        # menu surface: MENU_W x MENU_H black canvas; all elements are drawn here before blitting to the screen
        base_surface = pygame.Surface((MENU_W, MENU_H))
        base_surface.fill(MENU_BG_COLOR)
        full_w = base_surface.get_width()   # MENU_W — reference width for full-span and inset rects
        full_h = base_surface.get_height()  # MENU_H — reference height for the menu border rect

        # title text: centered at (x=240, y=40) on the menu surface
        title = font.render("Panel Image", True, CYAN_RGB)
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        # title border (inner): cyan rect, inset BORDER_SZ+5 horizontally and 4px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ + 5, title_rect.top - 4, full_w - 2*(BORDER_SZ + 5), title_rect.height + 8), BORDER_PX)
        # title border (outer): cyan rect, inset BORDER_SZ horizontally and 9px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ, title_rect.top - 9, full_w - 2*BORDER_SZ, title_rect.height + 18), BORDER_PX)
        for i, (label, code) in enumerate(options):
            color = SELECT_RECT_COLOR if i == idx else UNSEL_ITEM_RGB
            # menu item: centered at x=240; y starts at 120 with 70px fixed spacing between items
            text = font.render(label, True, color)
            text_rect = text.get_rect(center=(240, 120 + i*70))
            base_surface.blit(text, text_rect)
            if i == idx:
                # selection rectangle: yellow outline, inset BORDER_SZ from surface edges, 3px padding above/below item text
                pygame.draw.rect(base_surface, SELECT_RECT_COLOR, pygame.Rect(BORDER_SZ, text_rect.top - 3, full_w - 2*BORDER_SZ, text_rect.height + 6), BORDER_PX)
        # menu border: cyan outline drawn at the inner edge of the menu surface
        # (negative coords are clipped by pygame, so draw at (0,0) not (-3,-3))
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(0, 0, full_w, full_h), BORDER_PX)
        if screen_horizontal:
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            # blit menu surface centered on screen: offset = (screen_size - MENU_W/H) // 2 per axis
            screen.blit(base_surface, ((screen.get_width()-MENU_W)//2, (screen.get_height()-MENU_H)//2))
        else:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            screen.blit(rotated, rect)  # rotated menu surface centered on screen
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                sys.exit(0)
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_UP:
                    idx = (idx - 1) % len(options)
                elif event.key == pygame.K_DOWN:
                    idx = (idx + 1) % len(options)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    panel = options[idx][1]
                    save_state(PANEL_FILE, panel)
                    running = False
                elif event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_F11:
                    toggle_fullscreen()

def advanced_menu():
    global dual_display, pi3_present, screen_horizontal
    MENU_ITEMS = [
        ("Pi5 Dual Display:", lambda: toggle_dual_display()),
        ("Pi3 Present:", lambda: toggle_pi3_present()),
        ("Screen Orientation:", lambda: toggle_screen_orientation()),
        ("Swap XinMo P1 & P2", lambda: toggle_xinmo_swap()),
        ("Panel Image:", lambda: panel_menu()),
        ("Return to Main Menu", lambda: None),
    ]
    selected = 0
    running = True
    while running:
        # menu surface: MENU_W x MENU_H black canvas; all elements are drawn here before blitting to the screen
        base_surface = pygame.Surface((MENU_W, MENU_H))
        base_surface.fill(MENU_BG_COLOR)
        full_w = base_surface.get_width()   # MENU_W — reference width for full-span and inset rects
        full_h = base_surface.get_height()  # MENU_H — reference height for the menu border rect

        # title text: centered at (x=240, y=40) on the menu surface
        title = font.render("Advanced Config", True, CYAN_RGB)
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        # title border (inner): cyan rect, inset BORDER_SZ+5 horizontally and 4px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ + 5, title_rect.top - 4, full_w - 2*(BORDER_SZ + 5), title_rect.height + 8), BORDER_PX)
        # title border (outer): cyan rect, inset BORDER_SZ horizontally and 9px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ, title_rect.top - 9, full_w - 2*BORDER_SZ, title_rect.height + 18), BORDER_PX)
        item_count = len(MENU_ITEMS)
        start_y = 100  # y-coordinate of the first menu item on the menu surface
        # spacing: distributes items evenly from start_y to 40px above the bottom of the menu surface
        spacing = (480 - start_y - 40) // max(item_count, 1)
        for i, (label, _) in enumerate(MENU_ITEMS):
            suffix = ""
            if "Dual Display" in label:
                suffix = "ON" if dual_display else "OFF"
            elif "Pi3 Present" in label:
                suffix = "ON" if pi3_present else "OFF"
            elif "Screen Orientation" in label:
                suffix = "Landscape" if screen_horizontal else "Portrait"
            elif "Panel Image" in label:
                suffix = {"DC":"UltraStick/Spinners", "MC":"Atari/FightStick", "NA":"None/Blank"}.get(panel, "None/Blank")
            color = SELECT_RECT_COLOR if i == selected else UNSEL_ITEM_RGB
            # menu item: centered at x=240; y = start_y + i * spacing (evenly distributed)
            text = font.render(f"{label} {suffix}", True, color)
            text_rect = text.get_rect(center=(240, start_y + i*spacing))
            base_surface.blit(text, text_rect)
            if i == selected:
                # selection rectangle: yellow outline, inset BORDER_SZ from surface edges, 3px padding above/below item text
                pygame.draw.rect(base_surface, SELECT_RECT_COLOR, pygame.Rect(BORDER_SZ, text_rect.top - 3, full_w - 2*BORDER_SZ, text_rect.height + 6), BORDER_PX)
        # menu border: cyan outline drawn at the inner edge of the menu surface
        # (negative coords are clipped by pygame, so draw at (0,0) not (-3,-3))
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(0, 0, full_w, full_h), BORDER_PX)
        if screen_horizontal:
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            # blit menu surface centered on screen: offset = (screen_size - MENU_W/H) // 2 per axis
            screen.blit(base_surface, ((screen.get_width()-MENU_W)//2, (screen.get_height()-MENU_H)//2))
        else:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            screen.blit(rotated, rect)  # rotated menu surface centered on screen
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                sys.exit(0)
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_UP:
                    selected = (selected - 1) % len(MENU_ITEMS)
                elif event.key == pygame.K_DOWN:
                    selected = (selected + 1) % len(MENU_ITEMS)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    if MENU_ITEMS[selected][0] == "Return to Main Menu":
                        running = False
                        break
                    MENU_ITEMS[selected][1]()
                elif event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_F11:
                    toggle_fullscreen()

def toggle_xinmo_swap():
    """Run xinmo-swap.py on both MAME cfg dirs (RetroArch and standalone), matching autostart-nogui.sh."""
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    swap_script = os.path.join(scripts_dir, "xinmo-swap.py")
    mame_base   = "/opt/retropie/emulators/mame"
    for cfg_dir in ("cfg_ra", "cfg_sa"):
        cfg_path = os.path.join(mame_base, cfg_dir)
        try:
            subprocess.run([sys.executable, swap_script, cfg_path, "1"], timeout=10)
        except Exception as e:
            print(f"[WARN] xinmo-swap failed for {cfg_path}: {e}", file=sys.stderr)

def toggle_screen_orientation():
    global screen_horizontal
    screen_horizontal = not screen_horizontal
    save_state(SCREEN_ORIENTATION_FILE, screen_horizontal)
    set_screen(FULLSCREEN)

def toggle_dual_display():
    global dual_display
    dual_display = not dual_display
    save_state(PI5_DUAL_DISPLAY_FILE, dual_display)

def toggle_pi3_present():
    global pi3_present
    pi3_present = not pi3_present
    save_state(PI3_PRESENT_FILE, pi3_present)

def _check_xinmo():
    """Run xinmo-swapcheck.py and return (label, color) for the status bar."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "xinmo-swapcheck.py")
    try:
        result = subprocess.run([sys.executable, script], timeout=10)
        if result.returncode == 1:
            return "XinMo: Swap!", RED_RGB
        elif result.returncode == 0:
            return "XinMo: OK", GREEN_RGB
        else:
            return "XinMo: Err", LT_GRAY_RGB
    except Exception:
        return "XinMo: ?", LT_GRAY_RGB

def main_menu():
    MENU_ITEMS = [
        ("EmulationStation", lambda: launch_emulationstation()),
        ("MAME Standalone", lambda: launch_mame()),
        ("Advanced Config Setup/Options", lambda: advanced_menu()),
        ("Command Prompt (Exit to Shell)", lambda: _output_choice("C")),
        ("Exit to X/Wayland Desktop", lambda: _output_choice("X")),
    ]
    def launch_emulationstation():
        _output_choice("E")

    def launch_mame():
        _output_choice("M")

    TIMEOUT_SECS = 60
    TICK_EVENT = pygame.USEREVENT + 1
    pygame.time.set_timer(TICK_EVENT, 1000)  # fire every 1 second
    countdown = TIMEOUT_SECS

    xinmo_label, xinmo_color = _check_xinmo()

    selected = _load_def_key_index()
    running = True
    while running:
        # menu surface: MENU_W x MENU_H black canvas; all elements are drawn here before blitting to the screen
        base_surface = pygame.Surface((MENU_W, MENU_H))
        base_surface.fill(MENU_BG_COLOR)
        full_w = base_surface.get_width()   # MENU_W — reference width for full-span and inset rects
        full_h = base_surface.get_height()  # MENU_H — reference height for the menu border rect

        # title text: centered at (x=240, y=40) on the menu surface
        title = font.render("Arcade Menu", True, CYAN_RGB)
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        # title border (inner): cyan rect, inset BORDER_SZ+5 horizontally and 4px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ + 5, title_rect.top - 4, full_w - 2*(BORDER_SZ + 5), title_rect.height + 8), BORDER_PX)
        # title border (outer): cyan rect, inset BORDER_SZ horizontally and 9px vertically from title text
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(BORDER_SZ, title_rect.top - 9, full_w - 2*BORDER_SZ, title_rect.height + 18), BORDER_PX)
        item_count = len(MENU_ITEMS)
        start_y = 100  # y-coordinate of the first menu item on the menu surface
        # spacing: distributes items evenly from start_y to 40px above the bottom of the menu surface
        spacing = (480 - start_y - 40) // max(item_count, 1)
        for i, (label, _) in enumerate(MENU_ITEMS):
            color = SELECT_RECT_COLOR if i == selected else UNSEL_ITEM_RGB
            # menu item: centered at x=240; y = start_y + i * spacing (evenly distributed)
            text = font.render(label, True, color)
            text_rect = text.get_rect(center=(240, start_y + i*spacing))
            base_surface.blit(text, text_rect)
            if i == selected:
                # selection rectangle: yellow outline, inset BORDER_SZ from surface edges, 3px padding above/below item text
                pygame.draw.rect(base_surface, SELECT_RECT_COLOR, pygame.Rect(BORDER_SZ, text_rect.top - 3, full_w - 2*BORDER_SZ, text_rect.height + 6), BORDER_PX)
        # status bar: XinMo status on the left, countdown on the right — both share one dotted rectangle
        xinmo_surf = font.render(xinmo_label, True, xinmo_color)
        auto_surf  = font.render(f"Auto-select: {countdown}s", True, LT_GRAY_RGB)
        # anchor both labels vertically at y=460 (baseline center)
        xinmo_rect = xinmo_surf.get_rect(midleft=(BORDER_SZ + 6, 460))
        auto_rect  = auto_surf.get_rect(midright=(full_w - BORDER_SZ - 6, 460))
        base_surface.blit(xinmo_surf, xinmo_rect)
        base_surface.blit(auto_surf, auto_rect)
        # derive dotted rect bounds from the taller of the two labels
        status_top    = min(xinmo_rect.top, auto_rect.top) - 3
        status_bottom = max(xinmo_rect.bottom, auto_rect.bottom) + 3
        timer_rect = pygame.Rect(BORDER_SZ, status_top, full_w - 2*BORDER_SZ, status_bottom - status_top)
        # timer dotted rectangle: gray dashed outline around the whole status bar
        _draw_dotted_rect(base_surface, LT_GRAY_RGB, timer_rect)
        # menu border: cyan outline drawn at the inner edge of the menu surface
        # (negative coords are clipped by pygame, so draw at (0,0) not (-3,-3))
        pygame.draw.rect(base_surface, CYAN_RGB, pygame.Rect(0, 0, full_w, full_h), BORDER_PX)
        if screen_horizontal:
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            # blit menu surface centered on screen: offset = (screen_size - MENU_W/H) // 2 per axis
            screen.blit(base_surface, ((screen.get_width()-MENU_W)//2, (screen.get_height()-MENU_H)//2))
        else:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill(SCREEN_BG_COLOR)  # screen background: dark blue, fills the entire display
            screen.blit(rotated, rect)  # rotated menu surface centered on screen
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                sys.exit(0)
            elif event.type == TICK_EVENT:
                countdown -= 1
                if countdown <= 0:
                    pygame.time.set_timer(TICK_EVENT, 0)
                    MENU_ITEMS[selected][1]()
            elif event.type == pygame.KEYDOWN:
                # Any keypress cancels the timeout
                countdown = TIMEOUT_SECS
                if event.key == pygame.K_UP:
                    selected = (selected - 1) % len(MENU_ITEMS)
                elif event.key == pygame.K_DOWN:
                    selected = (selected + 1) % len(MENU_ITEMS)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    pygame.time.set_timer(TICK_EVENT, 0)
                    if MENU_ITEMS[selected][0] == "Advanced Config Setup/Options":
                        save_state(DEF_KEY_FILE, "A")
                    MENU_ITEMS[selected][1]()
                    # restart timer after returning from a submenu (e.g. advanced_menu)
                    countdown = TIMEOUT_SECS
                    pygame.time.set_timer(TICK_EVENT, 1000)
                    # refresh xinmo status in case user swapped from advanced_menu
                    xinmo_label, xinmo_color = _check_xinmo()
                elif event.key == pygame.K_ESCAPE:
                    sys.exit(0)
                elif event.key == pygame.K_F11:
                    toggle_fullscreen()

def launch_placeholder(name):
    # Placeholder for launching external apps
    pass

if __name__ == "__main__":
    main_menu()