"""Draws the icon, the README banner and the GitHub social preview.

Usage: KOREADER_DIR=<desktop KOReader> python3 -I tools/make_brand_art.py
Run tools/koreader/render_readme_screens.lua first. Needs Pillow, and the fonts that come with KOReader.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BLACK, WHITE, FOLD = 0, 255, 170
ICON_SIZE = 1024
SUPERSAMPLE = 3
KNIGHT = "♞"
TAGLINE = "A Lichess client for KOReader."
DETAILS = ["Play live and by correspondence, solve puzzles", "and review your games on e-ink.", "Not an official Lichess product."]
# The sheet of paper, in icon coordinates.
PAGE_LEFT, PAGE_TOP, PAGE_RIGHT, PAGE_BOTTOM, EAR = 222, 130, 802, 894, 170


def draw_icon(knight_font_path):
    k = SUPERSAMPLE
    size = ICON_SIZE
    large = Image.new("L", (size * k, size * k), BLACK)
    d = ImageDraw.Draw(large)
    page = [(PAGE_LEFT, PAGE_TOP), (PAGE_RIGHT - EAR, PAGE_TOP), (PAGE_RIGHT, PAGE_TOP + EAR), (PAGE_RIGHT, PAGE_BOTTOM), (PAGE_LEFT, PAGE_BOTTOM)]
    d.polygon([(x * k, y * k) for x, y in page], fill=WHITE)
    ear = [(PAGE_RIGHT - EAR, PAGE_TOP), (PAGE_RIGHT - EAR, PAGE_TOP + EAR), (PAGE_RIGHT, PAGE_TOP + EAR)]
    d.polygon([(x * k, y * k) for x, y in ear], fill=FOLD)
    font = ImageFont.truetype(knight_font_path, 620 * k)
    left, top, right, bottom = d.textbbox((0, 0), KNIGHT, font=font)
    x = (PAGE_LEFT + PAGE_RIGHT) / 2 * k - (left + right) / 2
    y = (PAGE_TOP + EAR * 0.45 + PAGE_BOTTOM) / 2 * k - (top + bottom) / 2
    d.text((x, y), KNIGHT, font=font, fill=BLACK)
    final = large.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=190 * 4, fill=255)
    icon = Image.new("LA", (size, size))
    icon.paste(final)
    icon.putalpha(mask.resize((size, size), Image.LANCZOS))
    return icon


def halftone(image, cx, cy, radius, spacing):
    d = ImageDraw.Draw(image)
    row, y = 0, cy - radius
    while y <= cy + radius:
        x = cx - radius + (spacing / 2 if row % 2 else 0)
        while x <= cx + radius:
            distance = math.hypot(x - cx, y - cy) / radius
            if distance <= 1:
                dot = spacing * 0.34 * (1 - distance * 0.72)
                d.ellipse([x - dot, y - dot, x + dot, y + dot], fill=88)
            x += spacing
        y += spacing * 0.87
        row += 1


def place_screen(image, name, center, height, angle):
    screen = Image.open(os.path.join(ROOT, "docs", "screenshots", name + ".png")).convert("L")
    screen = screen.resize((round(height * screen.width / screen.height), height), Image.LANCZOS)
    framed = Image.new("L", (screen.width + 12, screen.height + 12), WHITE)
    framed.paste(screen, (6, 6))
    rotated = framed.convert("LA").rotate(angle, expand=True, resample=Image.BICUBIC)
    image.paste(rotated.getchannel("L"), (round(center[0] - rotated.width / 2), round(center[1] - rotated.height / 2)), rotated.getchannel("A"))


def draw_header(width, height, fonts, icon, layout):
    k = 2
    image = Image.new("L", (width * k, height * k), BLACK)
    middle, screen_height, offset, text = layout["middle"], layout["screen_height"], layout["offset"], layout["text"]
    halftone(image, middle * k, height // 2 * k, round(layout["halftone"] * k), 26 * k)
    place_screen(image, "games", ((middle - offset) * k, (height // 2 + 8) * k), screen_height * k, 6)
    place_screen(image, "game", ((middle + offset) * k, (height // 2 - 8) * k), screen_height * k, -5)
    margin = 58
    icon_size = round(112 * text)
    title_size = round(68 * text)
    tagline_size = round(24 * text)
    details_size = round(18 * text)
    details = layout.get("details")
    block = icon_size + title_size + tagline_size + round(44 * text)
    if details:
        block += round(details_size * 1.45 * len(details)) + round(22 * text)
    y = (height - block) // 2
    small = icon.resize((icon_size * k, icon_size * k), Image.LANCZOS)
    # The drawing starts inside the icon's black square, which disappears on this background.
    inset = round(icon_size * PAGE_LEFT / ICON_SIZE)
    image.paste(small.getchannel("L"), ((margin - inset) * k, y * k), small.getchannel("A"))
    y += icon_size + round(6 * text)
    d = ImageDraw.Draw(image)
    d.text((margin * k, y * k), "Ink Knight", font=ImageFont.truetype(fonts["bold"], title_size * k), fill=WHITE)
    y += title_size + round(26 * text)
    d.text((margin * k, y * k), TAGLINE, font=ImageFont.truetype(fonts["italic"], tagline_size * k), fill=WHITE)
    y += tagline_size + round(30 * text)
    if details:
        font = ImageFont.truetype(fonts["regular"], details_size * k)
        for line in details:
            d.text((margin * k, y * k), line, font=font, fill=205)
            y += round(details_size * 1.45)
    return image.resize((width, height), Image.LANCZOS)


def main():
    koreader = os.environ.get("KOREADER_DIR")
    if not koreader:
        sys.exit("Set KOREADER_DIR to the KOReader folder, which has the fonts.")
    noto = os.path.join(koreader, "fonts", "noto")
    fonts = {
        "bold": os.path.join(noto, "NotoSerif-Bold.ttf"),
        "italic": os.path.join(noto, "NotoSerif-Italic.ttf"),
        "regular": os.path.join(noto, "NotoSerif-Regular.ttf"),
    }
    brand = os.path.join(ROOT, "docs", "brand")
    os.makedirs(brand, exist_ok=True)
    icon = draw_icon(os.path.join(koreader, "fonts", "freefont", "FreeSerif.ttf"))
    icon.save(os.path.join(brand, "icon.png"), optimize=True)
    draw_header(1280, 400, fonts, icon, {"middle": 1000, "screen_height": 330, "offset": 110, "text": 1, "halftone": 280}).save(os.path.join(brand, "banner.png"), optimize=True)
    draw_header(1280, 640, fonts, icon, {"middle": 960, "screen_height": 430, "offset": 112, "text": 1.02, "halftone": 360, "details": DETAILS}).save(os.path.join(ROOT, "docs", "social-preview.png"), optimize=True)
    print("Images generated in docs/brand and docs/social-preview.png")


main()
