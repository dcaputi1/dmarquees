#!/usr/bin/env python3
"""
menu_preview.py — Windows-side Pillow preview for pic_frontend.py main_menu layout.

Simulates the Pi5 pygame rendering (Arial Bold 24px ≈ pygame SysFont(None,36) on Linux).
Run:  py -3 menu_preview.py
Output: menu_preview.png (640×480, same as horizontal screen)

Adjust constants to match pic_frontend.py and re-run to iterate on layout.
"""

from PIL import Image, ImageDraw, ImageFont

# ── match pic_frontend.py visual constants ────────────────────────────────────
MENU_W    = 490
MENU_H    = 490
SCREEN_W  = 640
SCREEN_H  = 480
BORDER_PX = 2
BORDER_SZ = 10

BLACK    = (0, 0, 0)
CYAN     = (0, 255, 255)
GREEN    = (0, 255, 0)
RED      = (255, 0, 0)
YELLOW   = (255, 255, 0)
DK_BLUE  = (25, 25, 112)
LT_GRAY  = (128, 128, 128)
UNSEL    = (200, 200, 200)

# ── preview-specific settings ─────────────────────────────────────────────────
FONT_PATH    = "C:/Windows/Fonts/arialbd.ttf"
FONT_SIZE    = 24          # approx pygame SysFont(None,36) on Linux
SELECTED_IDX = 0           # which menu item is highlighted
XINMO_LABEL  = "XinMo: OK" # or "XinMo: Swap!" / "XinMo: Err"
XINMO_COLOR  = GREEN       # RED if swap required, LT_GRAY if error
COUNTDOWN    = 60

MENU_ITEMS = [
    "EmulationStation",
    "MAME Standalone",
    "Advanced Config Setup/Options",
    "Command Prompt (Exit to Shell)",
    "Exit to X/Wayland Desktop",
]

OUT_PATH = "menu_preview.png"

# ── render ────────────────────────────────────────────────────────────────────
fnt = ImageFont.truetype(FONT_PATH, FONT_SIZE)

screen = Image.new("RGB", (SCREEN_W, SCREEN_H), DK_BLUE)
menu   = Image.new("RGB", (MENU_W, MENU_H), BLACK)
draw   = ImageDraw.Draw(menu)

# title
title = "MAIN MENU"
tb = draw.textbbox((0, 0), title, font=fnt)
tx = (MENU_W - (tb[2] - tb[0])) // 2 - tb[0]
ty = 40 - tb[1]
draw.text((tx, ty), title, font=fnt, fill=CYAN)
ttb = draw.textbbox((tx, ty), title, font=fnt)
tt, tb2 = ttb[1], ttb[3]
# title border outer: BORDER_SZ inset, 9px vertical padding
draw.rectangle([BORDER_SZ,     tt - 9, MENU_W - 1 - BORDER_SZ,       tb2 + 9], outline=CYAN, width=BORDER_PX)
# title border inner: BORDER_SZ+5 inset, 4px vertical padding
draw.rectangle([BORDER_SZ + 5, tt - 4, MENU_W - 1 - (BORDER_SZ + 5), tb2 + 4], outline=CYAN, width=BORDER_PX)

# menu items
start_y = 100
spacing = (480 - start_y - 40) // len(MENU_ITEMS)
for i, label in enumerate(MENU_ITEMS):
    color = YELLOW if i == SELECTED_IDX else UNSEL
    ib = draw.textbbox((0, 0), label, font=fnt)
    ix = (MENU_W - (ib[2] - ib[0])) // 2 - ib[0]
    iy = (start_y + i * spacing) - (ib[3] - ib[1]) // 2 - ib[1]
    draw.text((ix, iy), label, font=fnt, fill=color)
    if i == SELECTED_IDX:
        itb = draw.textbbox((ix, iy), label, font=fnt)
        draw.rectangle(
            [BORDER_SZ, itb[1] - 3, MENU_W - 1 - BORDER_SZ, itb[3] + 3],
            outline=YELLOW, width=BORDER_PX,
        )

# status bar: XinMo left, countdown right — shared dotted rectangle
auto_label = f"Auto-select: {COUNTDOWN}s"

xb = draw.textbbox((0, 0), XINMO_LABEL, font=fnt)
xinmo_x = BORDER_SZ + 6
xinmo_y = 460 - (xb[3] - xb[1]) // 2 - xb[1]
draw.text((xinmo_x, xinmo_y), XINMO_LABEL, font=fnt, fill=XINMO_COLOR)
xinmo_drawn = draw.textbbox((xinmo_x, xinmo_y), XINMO_LABEL, font=fnt)

ab = draw.textbbox((0, 0), auto_label, font=fnt)
auto_x = MENU_W - BORDER_SZ - 6 - (ab[2] - ab[0]) - ab[0]
auto_y = 460 - (ab[3] - ab[1]) // 2 - ab[1]
draw.text((auto_x, auto_y), auto_label, font=fnt, fill=LT_GRAY)
auto_drawn = draw.textbbox((auto_x, auto_y), auto_label, font=fnt)

status_top    = min(xinmo_drawn[1], auto_drawn[1]) - 3
status_bottom = max(xinmo_drawn[3], auto_drawn[3]) + 3
x0, y0 = BORDER_SZ,         status_top
x1, y1 = MENU_W - 1 - BORDER_SZ, status_bottom
dash = 6
for x in range(x0, x1, dash * 2):
    draw.line([(x, y0), (min(x + dash, x1), y0)], fill=LT_GRAY, width=BORDER_PX)
    draw.line([(x, y1), (min(x + dash, x1), y1)], fill=LT_GRAY, width=BORDER_PX)
for y in range(y0, y1, dash * 2):
    draw.line([(x0, y), (x0, min(y + dash, y1))], fill=LT_GRAY, width=BORDER_PX)
    draw.line([(x1, y), (x1, min(y + dash, y1))], fill=LT_GRAY, width=BORDER_PX)

# menu border
draw.rectangle([0, 0, MENU_W - 1, MENU_H - 1], outline=CYAN, width=BORDER_PX)

# blit to screen centered
screen.paste(menu, ((SCREEN_W - MENU_W) // 2, (SCREEN_H - MENU_H) // 2))
screen.save(OUT_PATH)
print(f"saved → {OUT_PATH}")
