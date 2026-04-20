import os
import pygame
import sys

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

pygame.init()
set_screen(fullscreen=False)
pygame.display.set_caption("Arcade Menu")
font = pygame.font.SysFont(None, 36)

def toggle_fullscreen():
    global FULLSCREEN
    set_screen(not FULLSCREEN)

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
        ("Toggle Pi5 Dual Display", lambda: toggle_dual_display()),
        ("Toggle Pi3 Present", lambda: toggle_pi3_present()),
        ("Screen Orientation (Landscape/Portrait)", lambda: toggle_screen_orientation()),
        ("Panel Image...", lambda: panel_menu()),
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
            text = font.render(f"{label}: {suffix}", True, color)
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
        ("Advanced Config Initial Setup/Opt", lambda: advanced_menu()),
        ("Command Prompt (Exit to Shell)", lambda: sys.exit(0)),
        ("Exit to Desktop X/Wayland Desktop", lambda: sys.exit(0)),
    ]
    def launch_emulationstation():
        if screen_portrait:
            launch_placeholder("Vertical Arcade Portrait/Vertical")
        else:
            launch_placeholder("EmulationStation Normal/Horizontal")

    def launch_mame():
        if screen_portrait:
            launch_placeholder("MAME Portrait Portrait/Vertical")
        else:
            launch_placeholder("MAME Landscape Normal/Horizontal")
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