#!/usr/bin/env python3 -I
"""MX Master family drawing (3, 3S, 4), plan view, front up, 100 x 124 art points.
Original construction for PureMouse: Hobby curves through a handful of anchors with set tangents,
rounded polygons with named radii, every anchor on the half-point grid.

usage: mx.py <outdir>   writes mx-light.svg, mx-dark.svg, mx-regions.json and prints the checks."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geo4 import hobby, rounded_polygon, capsule, rrect, f, pt, flatten, inside, bbox, inset, clip, filleted_path, simplify, roller, roller_defs, roller_shape

W, H = 100, 124
CX = 61            # centreline of the top shell (wheel, split, top button)

# Body outline, clockwise from the front-left corner. (x, y, tangent in degrees; 0 = right, 90 = down)
BODY = [
    (39, 6.5, 300),        # front-left corner
    (51, 3, 0),            # front
    (78.5, 16.5, 48),      # front-right shoulder
    (90, 64, 90),          # widest point, right
    (82, 106, 128),        # rear-right
    (61, 121.5, 180),      # rear
    (38, 116.5, 205),      # rear-left, under the wing
    (13.5, 96.5, 242),     # wing, lower corner
    (10.5, 80, 272),       # wing, outer edge
    (14.5, 61, 300),       # wing, upper corner
    (26, 51.5, 335),       # wing, top edge
    (36.5, 45, 274, 1.1),  # waist, where the wing meets the shell; the shell's left side runs straight up
]

# Rear edge of the left and right buttons, a shallow arc across the shell.
SEAM = [(25, 44, 6), (CX, 47.5, 0), (97, 42, -9)]

# Flank: the band from the waist to the rear-left where the shell turns down to the thumb side.
FLANK = [(36.5, 45, 55), (56.5, 75, 85), (56, 104, 98), (49, 120, 115)]

# Main wheel in its channel, the top button just behind it.
WHEEL = dict(cx=CX, cy=28, len=16, wid=7, slot_len=20, slot_wid=10)
TOP = dict(cx=CX, cy=42, size=6, r=2)

# Thumb flank, on the wing (left of the shell, not near the centre line): Forward (front) and
# Back side by side in one line near the wing's outer edge, the thumb wheel parallel just above
# them (inboard), and the thumb rest on the lower wing behind them. Keys and wheel are drawn larger
# than true scale so each gets a 20 x 20 pt hit cell.
KEY_W, KEY_L, KEY_GAP = 7, 14, 2
KEY_X = 24                        # key centre line, about 3.5 pt in from the wing's edge
KEYS_TOP = 57
THUMB = dict(cx=40, cy=KEYS_TOP + KEY_L + KEY_GAP / 2, len=20, wid=8, slot_len=24, slot_wid=11)
# The thumb rest is a band concentric with the wing's lower edge: between the body inset by
# PAD_INSET and by PAD_INSET + PAD_W, from PAD_TOP down, ending square at x = PAD_RIGHT; fillets PAD_R.
PAD_INSET, PAD_W, PAD_TOP, PAD_RIGHT, PAD_R = 3.5, 13, 92, 47, 4

def _arc(poly, keep):
    """The longest run of consecutive points of a closed polygon satisfying keep, in order."""
    n = len(poly); flags = [keep(p) for p in poly]
    start = next(i for i in range(n) if flags[i] and not flags[i - 1])
    run, i = [], start
    while flags[i % n] and len(run) < n:
        run.append(poly[i % n]); i += 1
    return run

def pad_path():
    body = flatten(hobby(BODY))
    keep = lambda p: p[1] >= PAD_TOP and p[0] <= PAD_RIGHT
    outer = _arc(inset(body, PAD_INSET), keep)
    inner = _arc(inset(body, PAD_INSET + PAD_W), keep)
    if outer[0][1] < outer[-1][1]: outer = outer[::-1]   # walk the outer edge from the rear end
    if inner[0][1] > inner[-1][1]: inner = inner[::-1]   # and back along the inner edge
    return filleted_path(outer + inner, PAD_R)

def keys():
    fwd = rrect(KEY_X - KEY_W / 2, KEYS_TOP, KEY_W, KEY_L, KEY_W / 2)
    back = rrect(KEY_X - KEY_W / 2, KEYS_TOP + KEY_L + KEY_GAP, KEY_W, KEY_L, KEY_W / 2)
    return fwd, back

def parts():
    fwd, back = keys()
    return {
        "middle": roller_shape(WHEEL["cx"], WHEEL["cy"], WHEEL["len"], WHEEL["wid"]),
        "top": rrect(TOP["cx"] - TOP["size"] / 2, TOP["cy"] - TOP["size"] / 2, TOP["size"], TOP["size"], TOP["r"]),
        "forward": fwd,
        "back": back,
        "thumbWheel": roller_shape(THUMB["cx"], THUMB["cy"], THUMB["len"], THUMB["wid"]),
        "thumbRest": pad_path(),
    }

# Hit cells (art points): a partition around the parts, inside the body, none overlapping, each
# at least 20 x 20. Keys column x <= KC, thumb-wheel column KC..KC+20, thumb rest below REST_Y.
KEY_SPLIT = KEYS_TOP + KEY_L + KEY_GAP / 2
KC, REST_Y = 32, 92

def body_cell(x1, y0, y1):
    p = inset(flatten(hobby(BODY)), 0.5)
    p = clip(p, 1, 0, -x1)                # x <= x1
    p = clip(p, 0, -1, y0)                # y >= y0
    p = clip(p, 0, 1, -y1)                # y <= y1
    return simplify(p)

def hit_cells():
    return {
        "middle":     [(51, 15), (71, 15), (71, 36.5), (51, 36.5)],
        "top":        [(51, 36.5), (71, 36.5), (71, 56.5), (51, 56.5)],
        "forward":    body_cell(KC, KEY_SPLIT - 20, KEY_SPLIT),
        "back":       body_cell(KC, KEY_SPLIT, REST_Y),
        "thumbWheel": [(KC, 56.5), (KC + 20, 56.5), (KC + 20, REST_Y), (KC, REST_Y)],
        "thumbRest":  body_cell(58, REST_Y, 130),
    }

def ridges(cx, cy, length, width, n):
    d = ""
    for i in range(n):
        y = cy - length / 2 + 1.5 + (length - 3) * (i + 0.5) / n
        d += f"M{pt((cx - width / 2 + 0.9, y))}L{pt((cx + width / 2 - 0.9, y))}"
    return d

PALETTE = {
    "light": dict(shadow="#000000", shadow_o=0.16, palm="#4B4D52", side="#45474C", buttons="#5A5D63",
                  rest="#5D6066", seam="#2C2D31", slot="#1E1F22", metal="#C4C7CC", metal_edge="#8A8D94", knurl="#5E6168",
                  key="#9A9DA4"),
    "dark":  dict(shadow="#000000", shadow_o=0.45, palm="#6B6E74", side="#646769", buttons="#7B7E84",
                  rest="#83868C", seam="#45474C", slot="#2E3034", metal="#DCDEE2", metal_edge="#9EA1A8", knurl="#6E7178",
                  key="#B7BAC0"),
}

LINE = 'fill="none" stroke-linecap="round" stroke-linejoin="round"'

def svg(look, hover=None, select=None, accent=None, cells=False):
    c = PALETTE[look]
    P = parts()
    body = hobby(BODY)
    seam = hobby(SEAM, closed=False)
    side = hobby(FLANK, closed=False) + "L-10 130L-10 30Z"
    above = f"M-10 -10L110 -10L110 {f(SEAM[-1][1])}" + "L" + hobby(list(reversed([(x, y, t + 180) for x, y, t in SEAM])), closed=False)[1:] + f"L-10 {f(SEAM[0][1])}Z"
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         "<!-- MX Master family, plan view, front up. Original drawing for PureMouse. -->",
         f'<defs><clipPath id="body"><path d="{body}"/></clipPath>{roller_defs(c)}</defs>']
    # one soft shadow: two faint offset copies of the silhouette
    s.append(f'<path d="{body}" transform="translate(0 1.5)" fill="{c["shadow"]}" fill-opacity="{c["shadow_o"]}"/>')
    s.append(f'<path d="{body}" transform="translate(50 63) scale(1.025) translate(-50 -61.5)" fill="{c["shadow"]}" fill-opacity="{c["shadow_o"] * 0.35}"/>')
    s.append(f'<path d="{body}" fill="{c["palm"]}"/>')
    s.append('<g clip-path="url(#body)">')
    s.append(f'<path d="{side}" fill="{c["side"]}"/>')
    s.append(f'<path d="{above}" fill="{c["buttons"]}"/>')
    s.append(f'<path d="{seam}" {LINE} stroke="{c["seam"]}" stroke-width="0.5"/>')
    # split between left and right buttons, interrupted by the wheel channel
    slot_end = WHEEL["cy"] + WHEEL["slot_len"] / 2
    split = (f'M{f(CX)} 0V{f(WHEEL["cy"] - WHEEL["slot_len"] / 2)}'
             f'M{f(CX)} {f(slot_end)}V{f(TOP["cy"] - TOP["size"] / 2 - 1)}'
             f'M{f(CX)} {f(TOP["cy"] + TOP["size"] / 2 + 1)}V{f(SEAM[1][1])}')
    s.append(f'<path d="{split}" {LINE} stroke="{c["seam"]}" stroke-width="0.5"/>')
    s.append('</g>')
    # main wheel channel and wheel
    s += roller(c, WHEEL["cx"], WHEEL["cy"], WHEEL["len"], WHEEL["wid"], WHEEL["slot_len"], WHEEL["slot_wid"], "part-middle")
    s.append(f'<path id="part-top" d="{P["top"]}" fill="{c["key"]}"/>')
    # thumb wheel in its slot
    s += roller(c, THUMB["cx"], THUMB["cy"], THUMB["len"], THUMB["wid"], THUMB["slot_len"], THUMB["slot_wid"], "part-thumbWheel")
    # thumb rest
    s.append(f'<path id="part-thumbRest" d="{P["thumbRest"]}" fill="{c["rest"]}" stroke="{c["seam"]}" stroke-width="0.5" stroke-opacity="0.7"/>')
    for k in ("forward", "back"):
        s.append(f'<path id="part-{k}" d="{P[k]}" fill="{c["key"]}"/>')
    if hover:
        s.append(f'<path d="{P[hover]}" fill="{accent}" fill-opacity="0.6"/>')
    if select:
        s.append(f'<path d="{P[select]}" fill="{accent}"/>')
    if cells:
        for k, poly in hit_cells().items():
            d = "M" + "L".join(pt(p) for p in poly) + "Z"
            s.append(f'<path d="{d}" fill="#FF2D55" fill-opacity="0.10" stroke="#FF2D55" stroke-width="0.4"/>')
    s.append("</svg>")
    return "\n".join(s) + "\n"

def check():
    body = flatten(hobby(BODY))
    P = parts()
    ok = True
    def in_cell(poly, x, y): return inside(poly, x, y)
    CELLS = hit_cells()
    for k, cell in CELLS.items():
        x0, y0, x1, y1 = bbox(cell)
        pts = [(x0 + (x1 - x0) * (i + .5) / 40, y0 + (y1 - y0) * (j + .5) / 40) for i in range(40) for j in range(40)]
        pts = [p for p in pts if inside(cell, *p)]
        out = sum(not inside(body, *p) for p in pts) / len(pts)
        part = flatten(P[k])
        px0, py0, px1, py1 = bbox(part)
        g = [(px0 + (px1 - px0) * (i + .5) / 30, py0 + (py1 - py0) * (j + .5) / 30) for i in range(30) for j in range(30)]
        g = [p for p in g if inside(part, *p)]
        held = sum(inside(cell, *p) for p in g) / len(g)
        w, h = x1 - x0, y1 - y0
        flag = []
        if out > 0: flag.append(f"{out:.0%} outside body")
        if held < 0.98: flag.append(f"holds {held:.0%} of part")
        if w < 20 or h < 20: flag.append("under 20x20")
        ok &= not (out > 0 or held < 0.98)
        print(f"{k:11} cell {f(w)} x {f(h)}  {'; '.join(flag) or 'ok'}")
    keysl = list(CELLS)
    for i, a in enumerate(keysl):
        for b in keysl[i + 1:]:
            x0, y0, x1, y1 = bbox(CELLS[a])
            pts = [(x0 + (x1 - x0) * (u + .5) / 40, y0 + (y1 - y0) * (v + .5) / 40) for u in range(40) for v in range(40)]
            o = sum(inside(CELLS[a], *p) and inside(CELLS[b], *p) for p in pts)
            if o: print(f"overlap {a}/{b}"); ok = False
    print("cells ok" if ok else "cells need work")

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    tag = "mx"
    for look in PALETTE:
        open(f"{out}/{tag}-{look}.svg", "w").write(svg(look))
    json.dump(hit_cells(), open(f"{out}/{tag}-regions.json", "w"))
    check()

NAME = "MX Master 3S"
STATES = [
    dict(id="rest", caption=""),
    dict(id="hover-back", hover="back", caption="Back: Back"),
    dict(id="select-rest", select="thumbRest", caption="Gesture button: Mission Control"),
    dict(id="cells", cells=True, caption="Hit cells"),
]
