import os
import pygame
import sys

# State file paths
HOME = os.path.expanduser("~")
PI5_DUAL_DISPLAY_FILE = os.path.join(HOME, ".pi5_dual_display")
PI3_PRESENT_FILE = os.path.join(HOME, ".pi3_present")
PANEL_FILE = os.path.join(HOME, ".panel")

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

# Menu options
MENU_ITEMS = [
    ("Toggle Pi5 Dual Display", lambda: toggle_dual_display()),
    ("Toggle Pi3 Present", lambda: toggle_pi3_present()),
    ("Panel Image...", lambda: panel_menu()),
    ("Quit", lambda: sys.exit(0)),
]

def toggle_dual_display():
    global dual_display
    dual_display = not dual_display
    save_state(PI5_DUAL_DISPLAY_FILE, dual_display)

def toggle_pi3_present():
    global pi3_present
    pi3_present = not pi3_present
    save_state(PI3_PRESENT_FILE, pi3_present)

def panel_menu():
    global panel
    options = [("None/Blank", "NA"), ("Atari FS", "MC"), ("UltraStick", "DC")]
    idx = [i for i, (_, code) in enumerate(options) if code == panel]
    idx = idx[0] if idx else 0
    running = True
    while running:
        screen.fill((0,0,0))
        for i, (label, code) in enumerate(options):
            color = (255,255,0) if i == idx else (200,200,200)
            text = font.render(label, True, color)
            screen.blit(text, (100, 100 + i*50))
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

pygame.init()
screen = pygame.display.set_mode((600, 400))
pygame.display.set_caption("Advanced Config Initial Setup/Options")
font = pygame.font.SysFont(None, 36)

def draw_menu(selected):
    screen.fill((0,0,0))
    # Draw menu items
    for i, (label, _) in enumerate(MENU_ITEMS):
        suffix = ""
        if "Dual Display" in label:
            suffix = "ON" if dual_display else "OFF"
        elif "Pi3 Present" in label:
            suffix = "ON" if pi3_present else "OFF"
        elif "Panel Image" in label:
            suffix = {"DC":"UltraStick/Spinners", "MC":"Atari/FightStick", "NA":"None/Blank"}.get(panel, "None/Blank")
        color = (255,255,0) if i == selected else (200,200,200)
        text = font.render(f"{label}: {suffix}", True, color)
        screen.blit(text, (60, 80 + i*60))
    pygame.display.flip()

def main():
    selected = 0
    while True:
        draw_menu(selected)
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

if __name__ == "__main__":
    main()