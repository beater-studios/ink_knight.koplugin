"""Writes the icons of the bar of buttons as SVG, in black on a transparent ground, from the shapes approved in the mockups of the redesign (direction B). The plugin draws each one through its alpha, in black or white.

Usage, from the plugin folder: python3 -I tools/icons/make_icons.py ink_knight/icons
Each icon is centered in a square of 32 units, its strokes 3.4 thick, as the mockups draw them at 24 px.
"""
import os
import sys

OUT = sys.argv[1]
STROKE = 3.4


def polyline(points, width=STROKE):
    return '<polyline points="%s" fill="none" stroke="#000" stroke-width="%g" stroke-linecap="round" stroke-linejoin="round"/>' % (
        " ".join("%g,%g" % p for p in points), width)


def line(a, b, width=STROKE):
    return polyline([a, b], width)


def rect(x0, y0, x1, y1, radius=0, fill="#000"):
    return '<rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s"/>' % (x0, y0, x1 - x0, y1 - y0, radius, fill)


def circle(cx, cy, r, fill="#000", stroke=None, width=STROKE):
    if stroke:
        return '<circle cx="%g" cy="%g" r="%g" fill="%s" stroke="%s" stroke-width="%g"/>' % (cx, cy, r, fill, stroke, width)
    return '<circle cx="%g" cy="%g" r="%g" fill="%s"/>' % (cx, cy, r, fill)


def polygon(points):
    return '<polygon points="%s" fill="#000"/>' % " ".join("%g,%g" % p for p in points)


def path(d, width=STROKE, fill="none"):
    return '<path d="%s" fill="%s" stroke="#000" stroke-width="%g" stroke-linecap="butt"/>' % (d, fill, width)


ICONS = {
    "back": [polyline([(6, -10), (-5, 0), (6, 10)])],
    "previous": [polyline([(5, -10), (-5, 0), (5, 10)])],
    "next": [polyline([(-5, -10), (5, 0), (-5, 10)])],
    "first": [rect(-11, -10, -7.5, 10), polyline([(9, -10), (-2, 0), (9, 10)])],
    "last": [rect(7.5, -10, 11, 10), polyline([(-9, -10), (2, 0), (-9, 10)])],
    "comment": [polyline([(-9, -10), (1, 0), (-9, 10)]), polyline([(1, -10), (11, 0), (1, 10)])],
    "hint": [circle(0, -4, 8.5, fill="none", stroke="#000"), rect(-4.5, 6, 4.5, 9), rect(-3.5, 11, 3.5, 13.5)],
    # A circle open at the top left, its arrowhead pointing left; and its mirror, open at the top right.
    "undo": [path("M 0 -7.5 A 9 9 0 1 1 -7.794 -3"), polygon([(-7, -7.5), (2, -13.5), (2, -1.5)])],
    "again": [path("M 7.794 -3 A 9 9 0 1 1 0 -7.5"), polygon([(7, -7.5), (-2, -13.5), (-2, -1.5)])],
    "moves": [rect(-11, dy - 1.7, 11, dy + 1.7, 1.5) for dy in (-8, 0, 8)],
    "flag": [rect(-9, -12, -6, 13), polygon([(-6, -12), (11, -6), (-6, 1)])],
    "more": [circle(dx, 0, 3.4) for dx in (-9, 0, 9)],
    "review": [circle(-3, -3, 8.5, fill="none", stroke="#000"), line((3.5, 3.5), (11, 11), STROKE + 1)],
    "stop": [rect(-9, -9, 9, 9, 2)],
    "flip": [line((-6, 11), (-6, -6)), polygon([(-12, -5), (0, -5), (-6, -13)]), line((6, -11), (6, 6)), polygon([(0, 5), (12, 5), (6, 13)])],
    "pause": [rect(-8, -10, -2.5, 10, 1.5), rect(2.5, -10, 8, 10, 1.5)],
    "turn": [circle(0, 0, 10, fill="none", stroke="#000"), '<path d="M 0 -10 A 10 10 0 0 0 0 10 Z" fill="#000"/>'],
    "done": [polyline([(-10, 0), (-3, 8), (11, -9)], STROKE + 0.6)],
    "solution": [circle(0, 0, 11, fill="none", stroke="#000"), circle(0, 0, 4)],
    "options": sum([[rect(-11, dy - 1.3, 11, dy + 1.3), circle(knob, dy, 4)] for dy, knob in ((-7, 4), (0, -4), (7, 2))], []),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, shapes in sorted(ICONS.items()):
        svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-16 -16 32 32" width="32" height="32">%s</svg>\n' % "".join(shapes)
        with open(os.path.join(OUT, name + ".svg"), "w") as handle:
            handle.write(svg)
    print("%d icons in %s" % (len(ICONS), OUT))


if __name__ == "__main__":
    main()
