#!/usr/bin/env python3 -I
"""Writes the code-lane hand-off into final/: per-family SVG and vector PDF art (light, dark),
and regions.json (hit polygons, part outlines, CID bindings per model). All coordinates are art
points: 100 x 124, origin top-left, y down, front of the mouse up.

usage: export.py <outdir>"""
import sys, os, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from geo4 import flatten, simplify
import mx, compact

def poly(p):
    return [[round(x, 2), round(y, 2)] for x, y in p]

def outline(d):
    return poly(simplify(flatten(d), every=4))

NAMES = {"middle": "Wheel click", "top": "Top button", "forward": "Forward", "back": "Back",
         "thumbWheel": "Thumb wheel", "thumbRest": "Thumb rest"}

def regions(mod):
    P, C = mod.parts(), mod.hit_cells()
    return {k: {"name": NAMES[k], "hit": poly(C[k]), "shape": outline(P[k])} for k in C}

def write_art(svg_text, base):
    open(base + ".svg", "w").write(svg_text)
    subprocess.run(["rsvg-convert", "-f", "pdf", "-d", "72", "-p", "72", "-o", base + ".pdf", base + ".svg"], check=True)

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for look in mx.PALETTE:
        write_art(mx.svg(look), f"{out}/mx-{look}")
    fams = {"mx": {"art": "mx", "regions": regions(mx)}}
    for v in compact.VARIANTS:
        compact.set_variant(v)
        for look in compact.PALETTE:
            write_art(compact.svg(look), f"{out}/compact-{v}-{look}")
        fams[f"compact-{v}"] = {"art": f"compact-{v}", "regions": regions(compact)}

    mx3 = {"middle": "0x0052", "top": "0x00C4", "forward": "0x0056", "back": "0x0053",
           "thumbWheel": "setting:thumbWheel", "thumbRest": "0x00C3"}
    mx4 = dict(mx3, thumbRest="0x01A0")
    any3 = {"middle": "0x0052", "top": "0x00C4", "forward": "0x0056", "back": "0x0053"}
    m750 = {"middle": "0x0052", "forward": "0x0056", "back": "0x0053"}
    models = [
        {"match": ["MX Master 3", "MX Master 3 for Mac", "MX Master 3S", "MX Master 3S for Mac"],
         "family": "mx", "bind": mx3, "listOnly": ["0x00D7"]},
        {"match": ["MX Master 4", "MX Master 4 for Mac"],
         "family": "mx", "bind": mx4, "listOnly": ["0x00C3", "0x00D7"]},
        {"match": ["MX Anywhere 3", "MX Anywhere 3 for Mac", "MX Anywhere 3S", "MX Anywhere 3S for Mac"],
         "family": "compact-anywhere", "bind": any3, "listOnly": ["0x00D7"], "fixture": False},
        {"match": ["Signature M750", "Signature M750 L", "Signature Plus M750"],
         "family": "compact-m750", "bind": m750, "listOnly": ["0x00FD", "0x00D7"]},
    ]
    doc = {
        "version": 1,
        "artSize": [100, 124],
        "coordinates": "art points, origin top-left, y down, front of the mouse up",
        "inert": ["0x0050", "0x0051"],
        "noDrawing": ["MX Master 2S", "any model not listed in models", "the plain fallback"],
        "families": fams,
        "models": models,
        "rules": [
            "Draw a region only when the connected mouse reports its CID (thumbWheel: when the thumb-wheel feature is present).",
            "A CID in listOnly, or any reported CID with no region, appears as a list row only.",
            "Hit-test with 'hit'; draw hover and selection overlays with 'shape'.",
        ],
    }
    json.dump(doc, open(f"{out}/regions.json", "w"), indent=1)
    print("wrote", sorted(os.listdir(out)))
