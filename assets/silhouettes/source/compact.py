#!/usr/bin/env python3 -I
"""Compact family drawing (MX Anywhere 3/3S, Signature M750), plan view, front up, 100 x 124 art
points. Same construction and palette as mx.py: a symmetric shell, the wheel in its channel, and
two side keys in one line on the left flank. Two variants: "anywhere" has the top (SmartShift)
button behind the wheel; "m750" has no top shape (its DPI button 0x00FD is a list row only).
Unknown mice get no drawing, so there is no generic variant.

usage: compact.py <outdir>   writes compact-<variant>-<look>.svg and compact-regions.json"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geo4 import hobby, capsule, rrect, f, pt, flatten, inside, bbox, inset, clip, simplify, resample, filleted_path, roller, roller_defs, roller_shape
import mx

W, H = 100, 124
CX = 50
VARIANTS = {"anywhere": "MX Anywhere 3S", "m750": "Signature M750"}
VARIANT = "anywhere"
NAME = VARIANTS[VARIANT]

# Right half, front to rear; the left half mirrors it.
HALF = [
    (CX, 6, 0),            # front
    (71.5, 16.5, 42),      # front shoulder
    (84.5, 71, 90),        # widest point, behind the middle
    (77.5, 107, 128),      # rear shoulder
    (CX, 118, 180),        # rear
]
def body_anchors():
    right = HALF
    left = [(2 * CX - x, y, (360 - t) % 360) for x, y, t in reversed(HALF[1:-1])]
    return right + left

SEAM = [(10, 49, 6), (CX, 53, 0), (90, 49, -6)]
WHEEL = dict(cx=CX, cy=28, len=16, wid=7, slot_len=20, slot_wid=10)
TOP_SPEC = dict(cx=CX, cy=43, size=6, r=2)
TOP = TOP_SPEC
# Side keys: Forward (front) and Back, one line along the left flank, inset from the edge.
# Slightly larger than true scale, to match the MX keys.
KEYS = dict(x=21.5, w=6, l=13.5, gap=2, top=57)

def set_variant(v):
    global VARIANT, NAME, TOP
    VARIANT, NAME = v, VARIANTS[v]
    TOP = TOP_SPEC if v == "anywhere" else None

# The side rail: a band concentric with the left edge, RAIL wide, holding the keys.
RAIL = dict(width=10, top=50.5, bottom=93, r=3)

def rail_path():
    outer = [p for p in inset(flatten(hobby(body_anchors())), -3) if p[0] < CX]   # past the edge; the body clips it
    inner = [p for p in inset(flatten(hobby(body_anchors())), RAIL["width"]) if p[0] < CX]
    # walk the outer edge (rear to front on the left side) then back down the inner edge
    o = sorted([p for p in outer if RAIL["top"] <= p[1] <= RAIL["bottom"]], key=lambda p: -p[1])
    i = sorted([p for p in inner if RAIL["top"] <= p[1] <= RAIL["bottom"]], key=lambda p: p[1])
    return filleted_path(o + i, RAIL["r"])

def keys():
    k = KEYS
    fwd = rrect(k["x"] - k["w"] / 2, k["top"], k["w"], k["l"], k["w"] / 2)
    back = rrect(k["x"] - k["w"] / 2, k["top"] + k["l"] + k["gap"], k["w"], k["l"], k["w"] / 2)
    return fwd, back

def parts():
    p = {"middle": roller_shape(WHEEL["cx"], WHEEL["cy"], WHEEL["len"], WHEEL["wid"])}
    if TOP:
        p["top"] = rrect(TOP["cx"] - TOP["size"] / 2, TOP["cy"] - TOP["size"] / 2, TOP["size"], TOP["size"], TOP["r"])
    if KEYS:
        p["forward"], p["back"] = keys()
    return p

def hit_cells():
    c = {"middle": [(40, 16), (60, 16), (60, 39 if TOP else 47), (40, 39 if TOP else 47)]}
    if TOP:
        c["top"] = [(40, 39), (60, 39), (60, 59), (40, 59)]
    if KEYS:
        split = KEYS["top"] + KEYS["l"] + KEYS["gap"] / 2
        body = inset(flatten(hobby(body_anchors())), 0.5)
        def column(y0, y1):
            p = clip(body, 1, 0, -40)          # x <= 40
            p = clip(p, 0, -1, y0)             # y >= y0
            p = clip(p, 0, 1, -y1)             # y <= y1
            return simplify(p)
        c["forward"] = column(48, split)
        c["back"] = column(split, 95)
    return c

PALETTE = mx.PALETTE
LINE = mx.LINE

def svg(look, hover=None, select=None, accent=None, cells=False):
    c = PALETTE[look]
    P = parts()
    body = hobby(body_anchors())
    seam = hobby(SEAM, closed=False)
    above = f"M-10 -10L110 -10L110 {f(SEAM[-1][1])}" + "L" + hobby(list(reversed([(x, y, t + 180) for x, y, t in SEAM])), closed=False)[1:] + f"L-10 {f(SEAM[0][1])}Z"
    # the left flank: the body's edge band, inset, where the side keys sit
    flank_in = inset(flatten(body), 7)
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         "<!-- Compact symmetric mouse, plan view, front up. Original drawing for PureMouse. -->",
         f'<defs><clipPath id="body"><path d="{body}"/></clipPath>{roller_defs(c)}</defs>',
         f'<path d="{body}" transform="translate(0 1.5)" fill="{c["shadow"]}" fill-opacity="{c["shadow_o"]}"/>',
         f'<path d="{body}" transform="translate(50 63) scale(1.025) translate(-50 -61.5)" fill="{c["shadow"]}" fill-opacity="{c["shadow_o"] * 0.35}"/>',
         f'<path d="{body}" fill="{c["palm"]}"/>',
         '<g clip-path="url(#body)">']
    s.append(f'<path d="{above}" fill="{c["buttons"]}"/>')
    if KEYS:
        s.append(f'<g clip-path="url(#body)"><path d="{rail_path()}" fill="{c["side"]}"/></g>')
    s.append(f'<path d="{seam}" {LINE} stroke="{c["seam"]}" stroke-width="0.5"/>')
    slot_end = WHEEL["cy"] + WHEEL["slot_len"] / 2
    split = f'M{f(CX)} 0V{f(WHEEL["cy"] - WHEEL["slot_len"] / 2)}'
    if TOP:
        split += (f'M{f(CX)} {f(slot_end)}V{f(TOP["cy"] - TOP["size"] / 2 - 1)}'
                  f'M{f(CX)} {f(TOP["cy"] + TOP["size"] / 2 + 1)}V{f(SEAM[1][1])}')
    else:
        split += f'M{f(CX)} {f(slot_end)}V{f(SEAM[1][1])}'
    s.append(f'<path d="{split}" {LINE} stroke="{c["seam"]}" stroke-width="0.5"/>')
    s.append('</g>')
    s += roller(c, WHEEL["cx"], WHEEL["cy"], WHEEL["len"], WHEEL["wid"], WHEEL["slot_len"], WHEEL["slot_wid"], "part-middle")
    for k in ("top", "forward", "back"):
        if k in P:
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
    body = flatten(hobby(body_anchors()))
    P, C = parts(), hit_cells()
    for k, cell in C.items():
        x0, y0, x1, y1 = bbox(cell)
        g = [(x0 + (x1 - x0) * (i + .5) / 40, y0 + (y1 - y0) * (j + .5) / 40) for i in range(40) for j in range(40)]
        g = [p for p in g if inside(cell, *p)]
        out = sum(not inside(body, *p) for p in g) / len(g)
        part = flatten(P[k]); a, b, c2, d = bbox(part)
        h = [(a + (c2 - a) * (i + .5) / 30, b + (d - b) * (j + .5) / 30) for i in range(30) for j in range(30)]
        h = [p for p in h if inside(part, *p)]
        held = sum(inside(cell, *p) for p in h) / len(h)
        flags = [m for m, bad in ((f"{out:.0%} outside body", out > 0), (f"holds {held:.0%}", held < 0.98),
                                  ("under 20x20", x1 - x0 < 20 or y1 - y0 < 20)) if bad]
        print(f"{VARIANT:8} {k:8} cell {f(x1 - x0)} x {f(y1 - y0)}  {'; '.join(flags) or 'ok'}")
    ks = list(C)
    for i, a in enumerate(ks):
        for b in ks[i + 1:]:
            x0, y0, x1, y1 = bbox(C[a])
            g = [(x0 + (x1 - x0) * (u + .5) / 40, y0 + (y1 - y0) * (v + .5) / 40) for u in range(40) for v in range(40)]
            if any(inside(C[a], *p) and inside(C[b], *p) for p in g): print(f"overlap {a}/{b}")

STATES = [
    dict(id="any-rest", variant="anywhere"),
    dict(id="any-hover-back", variant="anywhere", hover="back", caption="Back: Back"),
    dict(id="any-select-top", variant="anywhere", select="top", caption="Top button: SmartShift"),
    dict(id="any-cells", variant="anywhere", cells=True, caption="Hit cells"),
    dict(id="m750-rest", variant="m750"),
    dict(id="m750-hover-fwd", variant="m750", hover="forward", caption="Forward: Forward"),
    dict(id="m750-cells", variant="m750", cells=True, caption="Hit cells"),
]

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    regions = {}
    for v in VARIANTS:
        set_variant(v)
        for look in PALETTE:
            open(f"{out}/compact-{v}-{look}.svg", "w").write(svg(look))
        regions[v] = hit_cells()
        check()
    json.dump(regions, open(f"{out}/compact-regions.json", "w"))
