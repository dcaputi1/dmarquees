#!/usr/bin/env python3
"""
pic_demo.py — Minimal pygame KMS/DRM display demo for RetroPie forum.

Attempts to open a fullscreen window via SDL2 kmsdrm, probing each DRM card
in order, and renders "Hello pygame world" as text.  Intended to expose
KMS/DRM initialisation failures on a Pi 5 booted to the TTY console.

Expected environment:
  - Booted to console (no X11/Wayland running)
  - /dev/dri/card0 present
  - pygame installed (e.g. pip install pygame or apt install python3-pygame)

Run as:
  python3 pic_demo.py
"""

import os
import sys

os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"

import pygame

screen = None

if os.environ.get("DISPLAY"):
    # Running inside X11/Wayland desktop — let SDL pick its own driver.
    print("[INFO] DISPLAY detected — using default SDL video driver (desktop mode).", file=sys.stderr)
    pygame.init()
    # (0, 0) + FULLSCREEN tells pygame to use the display's current native
    # resolution rather than requesting a mode change (avoids blank screen).
    screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
else:
    # On Pi 5, card0 is the V3D GPU; card1 is the display controller.
    # Probe each card index until one succeeds.
    drm_cards = sorted(
        e.name for e in os.scandir("/dev/dri") if e.name.startswith("card")
    ) if os.path.isdir("/dev/dri") else []
    print(f"[INFO] DRM devices found: {drm_cards}", file=sys.stderr)

    for card in drm_cards:
        idx = card.replace("card", "")
        os.environ["SDL_VIDEODRIVER"] = "kmsdrm"
        os.environ["SDL_KMSDRM_DEVICE_INDEX"] = idx
        print(f"[INFO] Trying kmsdrm on card{idx}...", file=sys.stderr)
        pygame.init()
        try:
            screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
            print(f"[INFO] kmsdrm opened on card{idx}.", file=sys.stderr)
            break
        except pygame.error as e:
            print(f"[WARN] card{idx} failed: {e}", file=sys.stderr)
            pygame.quit()
            screen = None

    if screen is None:
        print("[ERROR] No usable KMS/DRM card found. Exiting.", file=sys.stderr)
        sys.exit(1)
pygame.display.set_caption("pic_demo")

WIDTH, HEIGHT = screen.get_size()
print(f"[INFO] Surface size: {WIDTH}x{HEIGHT}", file=sys.stderr)

font = pygame.font.SysFont(None, 72)
text = font.render("Hello pygame world", True, (255, 255, 0))
text_rect = text.get_rect(center=(WIDTH // 2, HEIGHT // 2))

screen.fill((0, 0, 0))
screen.blit(text, text_rect)
pygame.display.flip()

print("[INFO] Display OK — press any key or Q to quit.", file=sys.stderr)

running = True
while running:
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False
        elif event.type == pygame.KEYDOWN:
            running = False

pygame.quit()
sys.exit(0)
