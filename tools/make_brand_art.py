"""Draws the icon, the README banner and the GitHub social preview, in English and Portuguese, or with `screensaver` the full-screen sleep screen cover in assets/.

Usage: KOREADER_DIR=<desktop KOReader> python3 -I tools/make_brand_art.py [screensaver]
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
# The texts and screenshots of each language: English for README.md and GitHub, Portuguese for README_pt.md and posts in Portuguese.
TEXTS = {
    "en": {
        "tagline": "Chess on e-ink, offline and on Lichess.",
        "details": ["An engine, puzzles, lessons and a clock with no internet,", "and live and correspondence games on Lichess.", "A KOReader plugin, not an official Lichess product."],
        "screenshots": os.path.join("docs", "screenshots"),
        "suffix": "",
    },
    "pt": {
        "tagline": "Xadrez em e-ink, offline e no Lichess.",
        "details": ["Motor, táticas, lições e relógio sem internet,", "e partidas ao vivo e por correspondência no Lichess.", "Um plugin do KOReader, não um produto oficial do Lichess."],
        "screenshots": os.path.join("docs", "screenshots", "pt"),
        "suffix": "_pt",
    },
}
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


def place_screen(image, folder, name, center, height, angle):
    screen = Image.open(os.path.join(ROOT, folder, name + ".png")).convert("L")
    screen = screen.resize((round(height * screen.width / screen.height), height), Image.LANCZOS)
    framed = Image.new("L", (screen.width + 12, screen.height + 12), WHITE)
    framed.paste(screen, (6, 6))
    rotated = framed.convert("LA").rotate(angle, expand=True, resample=Image.BICUBIC)
    image.paste(rotated.getchannel("L"), (round(center[0] - rotated.width / 2), round(center[1] - rotated.height / 2)), rotated.getchannel("A"))


def draw_header(width, height, fonts, icon, layout, texts):
    k = 2
    image = Image.new("L", (width * k, height * k), BLACK)
    middle, screen_height, offset, text = layout["middle"], layout["screen_height"], layout["offset"], layout["text"]
    halftone(image, middle * k, height // 2 * k, round(layout["halftone"] * k), 26 * k)
    # The first screen, with both ways to play, beside a game, as the plugin is both offline and on Lichess.
    place_screen(image, texts["screenshots"], "start", ((middle - offset) * k, (height // 2 + 8) * k), screen_height * k, 6)
    place_screen(image, texts["screenshots"], "game", ((middle + offset) * k, (height // 2 - 8) * k), screen_height * k, -5)
    margin = 58
    icon_size = round(112 * text)
    title_size = round(68 * text)
    tagline_size = round(24 * text)
    details_size = round(18 * text)
    details = layout.get("details") and texts["details"]
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
    d.text((margin * k, y * k), texts["tagline"], font=ImageFont.truetype(fonts["italic"], tagline_size * k), fill=WHITE)
    y += tagline_size + round(30 * text)
    if details:
        font = ImageFont.truetype(fonts["regular"], details_size * k)
        for line in details:
            d.text((margin * k, y * k), line, font=font, fill=205)
            y += round(details_size * 1.45)
    return image.resize((width, height), Image.LANCZOS)


def draw_screensaver(fonts, icon, knight_font_path, sans_bold):
    # The sleep screen when the plugin is open with no game to show, in the look of the plugin: the knight in a white circle and the name on black, and below, on the light gray of the pages, a crescent moon for resting. No words of any language, since one image serves all of them. Laid out in 600x800 units and saved at twice that, so larger screens get a sharp image and 600x800 gets a clean halving.
    k, w, h = 4, 600, 800
    paper = 238
    image = Image.new("L", (w * k, h * k), paper)
    d = ImageDraw.Draw(image)
    d.rectangle([0, 0, w * k, 560 * k], fill=BLACK)
    cx = w // 2
    d.ellipse([(cx - 96) * k, 154 * k, (cx + 96) * k, 346 * k], fill=WHITE)
    d.text((cx * k, 250 * k), KNIGHT, font=ImageFont.truetype(knight_font_path, 150 * k), fill=BLACK, anchor="mm")
    d.text((cx * k, 410 * k), "Ink Knight", font=ImageFont.truetype(sans_bold, 44 * k), fill=WHITE, anchor="mm")
    moon_r = 34
    d.ellipse([(cx - moon_r) * k, (680 - moon_r) * k, (cx + moon_r) * k, (680 + moon_r) * k], fill=BLACK)
    shift_x, shift_y, inner = moon_r * 0.45, moon_r * 0.35, moon_r * 0.82
    d.ellipse([(cx + shift_x - inner) * k, (680 - shift_y - inner) * k, (cx + shift_x + inner) * k, (680 - shift_y + inner) * k], fill=paper)
    image = image.resize((w * 2, h * 2), Image.LANCZOS)
    return image.point(lambda v: round(v / 17) * 17)


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
    if sys.argv[1:] == ["screensaver"]:
        os.makedirs(os.path.join(ROOT, "assets"), exist_ok=True)
        draw_screensaver(fonts, icon, os.path.join(koreader, "fonts", "freefont", "FreeSerif.ttf"), os.path.join(noto, "NotoSans-Bold.ttf")).save(os.path.join(ROOT, "assets", "screensaver.png"), optimize=True)
        print("Image generated in assets/screensaver.png")
        return
    icon.save(os.path.join(brand, "icon.png"), optimize=True)
    for texts in TEXTS.values():
        suffix = texts["suffix"]
        draw_header(1280, 400, fonts, icon, {"middle": 1000, "screen_height": 330, "offset": 110, "text": 1, "halftone": 280}, texts).save(os.path.join(brand, "banner" + suffix + ".png"), optimize=True)
        draw_header(1280, 640, fonts, icon, {"middle": 960, "screen_height": 430, "offset": 112, "text": 1.02, "halftone": 360, "details": True}, texts).save(os.path.join(ROOT, "docs", "social-preview" + suffix + ".png"), optimize=True)
    print("Images generated in docs/brand and docs/social-preview.png, with the Portuguese copies ending in _pt")


main()
