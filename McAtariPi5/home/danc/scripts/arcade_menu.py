#!/usr/bin/env python3
"""
arcade_menu.py - SDL/Pygame graphical menu replacement for Bash menu logic
"""
import os
import sys
import subprocess
import pygame
from pygame.locals import *

# Paths (adjust as needed)
HOME = os.path.expanduser("~")
SCRIPTS_DIR = os.path.join(HOME, "scripts")
DEF_KEY_FILE = os.path.join(HOME, ".def_key")
PANEL_FILE = os.path.join(HOME, ".panel")
LED_OFF_SCRIPT = os.path.join(SCRIPTS_DIR, "leds_off.py")
XINMO_SWAP_SCRIPT = os.path.join(SCRIPTS_DIR, "xinmo-swap.py")
XINMO_SWAPCHECK_SCRIPT = os.path.join(SCRIPTS_DIR, "xinmo-swapcheck.py")
DMARQUEES_SEND_SCRIPT = os.path.join(SCRIPTS_DIR, "dmarquees-send.sh")

# Menu definitions
MAIN_MENU = [
    ("E", "EmulationStation Normal/Horizontal"),
    ("V", "Vertical Arcade Portrait/Vertical"),
    ("M", "MAME Landscape Normal/Horizontal"),
    ("P", "MAME Portrait Portrait/Vertical"),
    ("A", "Advanced Config Initial Setup/Opt"),
    ("C", "Command Prompt (Exit Menu)"),
    ("X", "Exit to Desktop (X/Wayland Desktop)")
]
ADV_MENU = [
    ("D", "Toggle Pi5 Dual Display"),
    ("P", "Toggle Pi3 Present"),
    ("S", "Swap Xin-Mo Player 1 & 2"),
    ("I", "Panel Image..."),
    ("Q", "Return to Main Menu")
]
PANEL_MENU = [
    ("N", "None/Blank"),
    ("A", "Atari FS"),
    ("U", "UltraStick")
]

# State variables (simulate Bash script state)
PI5_DUAL_DISPLAY = True
PI3_PRESENT = True
PANEL = "DC"
XINMO_STATUS_MSG = "XinMo: OK"
MENU_TIMEOUT = 60

def run_script(path, args=None):
    if not os.path.exists(path):
        return
    cmd = [path]
    if args:
        cmd += args
    subprocess.Popen(cmd)

def run_python_script(path, args=None):
    if not os.path.exists(path):
        return
    cmd = [sys.executable, path]
    if args:
        cmd += args
    subprocess.Popen(cmd)

def send_dmarquees_cmd(cmd):
    if os.path.exists(DMARQUEES_SEND_SCRIPT):
        subprocess.Popen([DMARQUEES_SEND_SCRIPT, cmd])
    # Optionally, write to FIFO if needed

def persist_frontend_choice(choice):
    with open(DEF_KEY_FILE, "w") as f:
        f.write(choice)

def load_persisted_choice():
    if os.path.exists(DEF_KEY_FILE):
        with open(DEF_KEY_FILE) as f:
            return f.read().strip().replace('DEF_KEY=','').replace('"','')
    return "X"

def save_panel(panel):
    with open(PANEL_FILE, "w") as f:
        f.write(panel)

def load_panel():
    if os.path.exists(PANEL_FILE):
        with open(PANEL_FILE) as f:
            return f.read().strip()
    return "DC"

def check_xinmo_status():
    global XINMO_STATUS_MSG
    try:
        result = subprocess.run([sys.executable, XINMO_SWAPCHECK_SCRIPT], capture_output=True)
        if result.returncode == 1:
            XINMO_STATUS_MSG = "XinMo: Swap Required"
        else:
            XINMO_STATUS_MSG = "XinMo: OK"
    except Exception:
        XINMO_STATUS_MSG = "XinMo: Unknown"

def main_menu(screen):
    clock = pygame.time.Clock()
    font = pygame.font.SysFont(None, 36)
    selected = 0
    default_choice = load_persisted_choice()
    for i, (key, _) in enumerate(MAIN_MENU):
        if key == default_choice:
            selected = i
            break
    running = True
    while running:
        screen.fill((0,0,0))
        y = 100
        for i, (key, label) in enumerate(MAIN_MENU):
            color = (255,255,0) if i == selected else (255,255,255)
            text = font.render(f"{key}: {label}", True, color)
            screen.blit(text, (100, y))
            y += 50
        # Show XinMo status
        status = font.render(XINMO_STATUS_MSG, True, (0,255,255))
        screen.blit(status, (100, y+20))
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == QUIT:
                pygame.quit()
                sys.exit(0)
            elif event.type == KEYDOWN:
                if event.key == K_UP:
                    selected = (selected - 1) % len(MAIN_MENU)
                elif event.key == K_DOWN:
                    selected = (selected + 1) % len(MAIN_MENU)
                elif event.key in (K_RETURN, K_KP_ENTER):
                    key, _ = MAIN_MENU[selected]
                    persist_frontend_choice(key)
                    if key == "A":
                        advanced_menu(screen)
                    elif key == "E":
                        send_dmarquees_cmd("RA")
                        run_python_script(LED_OFF_SCRIPT)
                        # Replace with actual emulationstation launch
                        subprocess.Popen(["emulationstation"])
                    elif key == "V":
                        send_dmarquees_cmd("RA")
                        run_python_script(LED_OFF_SCRIPT)
                        subprocess.Popen(["emulationstation", "--screenrotate", "3", "--screensize", "1200", "1600"])
                    elif key == "M":
                        send_dmarquees_cmd("SA")
                        subprocess.Popen(["mame", "-norol", "-inipath", "/opt/retropie/emulators/mame/ini", "-cfg_directory", "/opt/retropie/emulators/mame/cfg", "-joystickprovider", "sdljoy"])
                    elif key == "P":
                        send_dmarquees_cmd("SA")
                        subprocess.Popen(["mame", "-rol", "-inipath", "/opt/retropie/emulators/mame/ini;/opt/retropie/emulators/mame/ini_horz_ror", "-cfg_directory", "/opt/retropie/emulators/mame/cfg", "-joystickprovider", "sdljoy"])
                    elif key == "C":
                        running = False
                    elif key == "X":
                        # Replace with actual desktop launch
                        subprocess.Popen(["startx"])
                        running = False
                    else:
                        running = False
        clock.tick(30)

def advanced_menu(screen):
    global PI5_DUAL_DISPLAY, PI3_PRESENT, PANEL
    clock = pygame.time.Clock()
    font = pygame.font.SysFont(None, 36)
    selected = 0
    running = True
    while running:
        screen.fill((0,0,32))
        y = 100
        for i, (key, label) in enumerate(ADV_MENU):
            color = (0,255,0) if i == selected else (200,200,200)
            text = font.render(f"{key}: {label}", True, color)
            screen.blit(text, (100, y))
            y += 50
        # Show current states
        state_text = font.render(f"Dual Display: {'ON' if PI5_DUAL_DISPLAY else 'OFF'} | Pi3 Present: {'ON' if PI3_PRESENT else 'OFF'} | Panel: {PANEL}", True, (255,255,0))
        screen.blit(state_text, (100, y+20))
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == QUIT:
                pygame.quit()
                sys.exit(0)
            elif event.type == KEYDOWN:
                if event.key == K_UP:
                    selected = (selected - 1) % len(ADV_MENU)
                elif event.key == K_DOWN:
                    selected = (selected + 1) % len(ADV_MENU)
                elif event.key in (K_RETURN, K_KP_ENTER):
                    key, _ = ADV_MENU[selected]
                    if key == "D":
                        PI5_DUAL_DISPLAY = not PI5_DUAL_DISPLAY
                    elif key == "P":
                        PI3_PRESENT = not PI3_PRESENT
                    elif key == "S":
                        run_python_script(XINMO_SWAP_SCRIPT, ["/opt/retropie/emulators/mame/cfg_ra", "1"])
                        run_python_script(XINMO_SWAP_SCRIPT, ["/opt/retropie/emulators/mame/cfg_sa", "1"])
                        check_xinmo_status()
                    elif key == "I":
                        panel_menu(screen)
                    elif key == "Q":
                        running = False
        clock.tick(30)

def panel_menu(screen):
    global PANEL
    clock = pygame.time.Clock()
    font = pygame.font.SysFont(None, 36)
    selected = 0
    running = True
    while running:
        screen.fill((32,0,0))
        y = 100
        for i, (key, label) in enumerate(PANEL_MENU):
            color = (255,0,255) if i == selected else (200,200,200)
            text = font.render(f"{key}: {label}", True, color)
            screen.blit(text, (100, y))
            y += 50
        pygame.display.flip()
        for event in pygame.event.get():
            if event.type == QUIT:
                pygame.quit()
                sys.exit(0)
            elif event.type == KEYDOWN:
                if event.key == K_UP:
                    selected = (selected - 1) % len(PANEL_MENU)
                elif event.key == K_DOWN:
                    selected = (selected + 1) % len(PANEL_MENU)
                elif event.key in (K_RETURN, K_KP_ENTER):
                    key, _ = PANEL_MENU[selected]
                    if key == "N":
                        PANEL = "NA"
                    elif key == "A":
                        PANEL = "MC"
                    elif key == "U":
                        PANEL = "DC"
                    save_panel(PANEL)
                    running = False
        clock.tick(30)

def main():
    pygame.init()
    screen = pygame.display.set_mode((800, 600))
    pygame.display.set_caption("Arcade Menu")
    check_xinmo_status()
    main_menu(screen)
    pygame.quit()

if __name__ == "__main__":
    main()
