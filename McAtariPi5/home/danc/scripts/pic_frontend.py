#!/usr/bin/env python3

import os
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
    # On Pi 5 the display may be on DRM device 1 (card1) rather than card0.
    # Try kmsdrm with each device index before falling back to fbdev.
    _SDL_DRIVERS_TO_TRY = [
        ("kmsdrm", "0"),
        ("kmsdrm", "1"),
        ("fbdev",  None),
    ]
    os.environ.pop("SDL_FBDEV", None)
else:
    print("[INFO] X11/Wayland display detected.", file=sys.stderr)
    _SDL_DRIVERS_TO_TRY = [(os.environ.get("SDL_VIDEODRIVER", ""), None)]

os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame

# State file paths
HOME = os.path.expanduser("~")
PI5_DUAL_DISPLAY_FILE = os.path.join(HOME, ".pi5_dual_display")
PI3_PRESENT_FILE = os.path.join(HOME, ".pi3_present")
PANEL_FILE = os.path.join(HOME, ".panel")
SCREEN_ORIENTATION_FILE = os.path.join(HOME, ".screen_orientation")

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
        f.write(str(value))

# Initial state
dual_display = load_state(PI5_DUAL_DISPLAY_FILE, True)
pi3_present = load_state(PI3_PRESENT_FILE, True)
panel = load_state(PANEL_FILE, "DC")  # DC, MC, NA
screen_portrait = load_state(SCREEN_ORIENTATION_FILE, False)

# --- NEW: Window/fullscreen mode and dynamic sizing ---
WINDOWED = True
FULLSCREEN = False
def get_screen_size():
    if screen_portrait:
        return (480, 640)
    else:
        return (640, 480)

def set_screen(fullscreen):
    global screen, WINDOWED, FULLSCREEN
    size = get_screen_size()
    if fullscreen:
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
        os.environ["SDL_VIDEO_KMSDRM_DEVICE"] = _kmsdrm_dev
    else:
        os.environ.pop("SDL_VIDEO_KMSDRM_DEVICE", None)
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

font = pygame.font.SysFont(None, 36)

def toggle_fullscreen():
    global FULLSCREEN
    set_screen(not FULLSCREEN)

def _output_choice(choice):
    """Print a menu choice to stdout and exit cleanly; bash reads this to decide what to launch."""
    pygame.quit()
    print(choice, flush=True)
    sys.exit(0)

def panel_menu():
    global panel, screen_portrait
    options = [("None/Blank", "NA"), ("Atari FS", "MC"), ("UltraStick", "DC")]
    idx = [i for i, (_, code) in enumerate(options) if code == panel]
    idx = idx[0] if idx else 0
    running = True
    while running:
        base_surface = pygame.Surface((480, 480))
        base_surface.fill((0,0,0))
        title = font.render("Panel Image", True, (0,255,255))
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        for i, (label, code) in enumerate(options):
            color = (255,255,0) if i == idx else (200,200,200)
            text = font.render(label, True, color)
            text_rect = text.get_rect(center=(240, 120 + i*70))
            base_surface.blit(text, text_rect)
        if screen_portrait:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill((0,0,0))
            screen.blit(rotated, rect)
        else:
            screen.fill((0,0,0))
            screen.blit(base_surface, ((screen.get_width()-480)//2, (screen.get_height()-480)//2))
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
    global dual_display, pi3_present, screen_portrait
    MENU_ITEMS = [
        ("Pi5 Dual Display:", lambda: toggle_dual_display()),
        ("Pi3 Present:", lambda: toggle_pi3_present()),
        ("Screen Orientation:", lambda: toggle_screen_orientation()),
        ("Panel Image:", lambda: panel_menu()),
        ("Return to Main Menu", lambda: None),
        ("Quit", lambda: sys.exit(0)),
    ]
    selected = 0
    running = True
    while running:
        base_surface = pygame.Surface((480, 480))
        base_surface.fill((0,0,0))
        title = font.render("Advanced Config", True, (0,255,255))
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        item_count = len(MENU_ITEMS)
        start_y = 100
        spacing = (480 - start_y - 40) // max(item_count, 1)
        for i, (label, _) in enumerate(MENU_ITEMS):
            suffix = ""
            if "Dual Display" in label:
                suffix = "ON" if dual_display else "OFF"
            elif "Pi3 Present" in label:
                suffix = "ON" if pi3_present else "OFF"
            elif "Screen Orientation" in label:
                suffix = "Portrait" if screen_portrait else "Landscape"
            elif "Panel Image" in label:
                suffix = {"DC":"UltraStick/Spinners", "MC":"Atari/FightStick", "NA":"None/Blank"}.get(panel, "None/Blank")
            color = (255,255,0) if i == selected else (200,200,200)
            text = font.render(f"{label} {suffix}", True, color)
            text_rect = text.get_rect(center=(240, start_y + i*spacing))
            base_surface.blit(text, text_rect)
        if screen_portrait:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill((0,0,0))
            screen.blit(rotated, rect)
        else:
            screen.fill((0,0,0))
            screen.blit(base_surface, ((screen.get_width()-480)//2, (screen.get_height()-480)//2))
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

def toggle_screen_orientation():
    global screen_portrait
    screen_portrait = not screen_portrait
    save_state(SCREEN_ORIENTATION_FILE, screen_portrait)
    set_screen(FULLSCREEN)

def toggle_dual_display():
    global dual_display
    dual_display = not dual_display
    save_state(PI5_DUAL_DISPLAY_FILE, dual_display)

def toggle_pi3_present():
    global pi3_present
    pi3_present = not pi3_present
    save_state(PI3_PRESENT_FILE, pi3_present)

def main_menu():
    MENU_ITEMS = [
        ("EmulationStation", lambda: launch_emulationstation()),
        ("MAME Standalone", lambda: launch_mame()),
        ("Advanced Config Setup/Options", lambda: advanced_menu()),
        ("Command Prompt (Exit to Shell)", lambda: _output_choice("C")),
        ("Exit to X/Wayland Desktop", lambda: _output_choice("X")),
    ]
    def launch_emulationstation():
        _output_choice("V" if screen_portrait else "E")

    def launch_mame():
        _output_choice("P" if screen_portrait else "M")
    selected = 0
    running = True
    while running:
        base_surface = pygame.Surface((480, 480))
        base_surface.fill((0,0,0))
        title = font.render("Arcade Menu", True, (0,255,255))
        title_rect = title.get_rect(center=(240, 40))
        base_surface.blit(title, title_rect)
        item_count = len(MENU_ITEMS)
        start_y = 100
        spacing = (480 - start_y - 40) // max(item_count, 1)
        for i, (label, _) in enumerate(MENU_ITEMS):
            color = (255,255,0) if i == selected else (200,200,200)
            text = font.render(label, True, color)
            text_rect = text.get_rect(center=(240, start_y + i*spacing))
            base_surface.blit(text, text_rect)
        if screen_portrait:
            rotated = pygame.transform.rotate(base_surface, 90)
            rect = rotated.get_rect(center=screen.get_rect().center)
            screen.fill((0,0,0))
            screen.blit(rotated, rect)
        else:
            screen.fill((0,0,0))
            screen.blit(base_surface, ((screen.get_width()-480)//2, (screen.get_height()-480)//2))
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
                    MENU_ITEMS[selected][1]()
                elif event.key == pygame.K_ESCAPE:
                    sys.exit(0)
                elif event.key == pygame.K_F11:
                    toggle_fullscreen()

def launch_placeholder(name):
    # Placeholder for launching external apps
    pass

if __name__ == "__main__":
    main_menu()