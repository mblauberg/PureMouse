"""Geometry for the v4 device drawings: Hobby curves through anchors with set tangents, rounded
polygons with one corner radius, capsules, and the flatten/inside helpers the region checks use.
Pure Python, no dependencies. Coordinates are art points, y down, front of the mouse up."""
import math, re

def f(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s

def pt(p):
    return f"{f(p[0])} {f(p[1])}"

def _rho(a, b):
    """Hobby's velocity: handle length / chord for departure angle a and arrival angle b."""
    sa, sb, ca, cb = math.sin(a), math.sin(b), math.cos(a), math.cos(b)
    num = 2 + math.sqrt(2) * (sa - sb / 16) * (sb - sa / 16) * (ca - cb)
    den = 3 * (1 + 0.5 * (math.sqrt(5) - 1) * ca + 0.5 * (3 - math.sqrt(5)) * cb)
    return num / den

def _seg(p0, t0, p1, t1, tension=1.0):
    """One cubic from p0 leaving at t0 degrees to p1 arriving at t1 degrees."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    d = math.hypot(dx, dy)
    chord = math.atan2(dy, dx)
    wrap = lambda x: (x + math.pi) % (2 * math.pi) - math.pi
    a = wrap(math.radians(t0) - chord)
    b = wrap(chord - math.radians(t1))
    h0 = d * _rho(a, b) / tension
    h1 = d * _rho(b, a) / tension
    c0 = (p0[0] + h0 * math.cos(math.radians(t0)), p0[1] + h0 * math.sin(math.radians(t0)))
    c1 = (p1[0] - h1 * math.cos(math.radians(t1)), p1[1] - h1 * math.sin(math.radians(t1)))
    return c0, c1

def hobby(anchors, closed=True, tension=1.0, start=True):
    """anchors: (x, y, tangent degrees). Returns an SVG path (absolute M/C[/Z])."""
    d = f"M{pt(anchors[0][:2])}" if start else ""
    n = len(anchors)
    for i in range(n if closed else n - 1):
        a0, a1 = anchors[i], anchors[(i + 1) % n]
        tens = a0[3] if len(a0) > 3 else tension
        c0, c1 = _seg(a0[:2], a0[2], a1[:2], a1[2], tens)
        d += f"C{pt(c0)} {pt(c1)} {pt(a1[:2])}"
    return d + ("Z" if closed else "")

def rounded_polygon(verts, r):
    """A polygon whose corners are circular arcs of radius r (or a per-vertex list)."""
    n = len(verts)
    rs = r if isinstance(r, (list, tuple)) else [r] * n
    d = ""
    for i in range(n):
        p0, p1, p2 = verts[i - 1], verts[i], verts[(i + 1) % n]
        v1 = (p0[0] - p1[0], p0[1] - p1[1]); v2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1 = (v1[0] / l1, v1[1] / l1); u2 = (v2[0] / l2, v2[1] / l2)
        ang = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        t = rs[i] / math.tan(ang / 2)
        t = min(t, l1 / 2, l2 / 2)
        rr = t * math.tan(ang / 2)
        a = (p1[0] + u1[0] * t, p1[1] + u1[1] * t)
        b = (p1[0] + u2[0] * t, p1[1] + u2[1] * t)
        # cubic arc approximation: handle = 4/3 tan(theta/4) * r, theta = pi - ang
        theta = math.pi - ang
        k = 4 / 3 * math.tan(theta / 4) * rr
        c0 = (a[0] - u1[0] * k, a[1] - u1[1] * k)
        c1 = (b[0] - u2[0] * k, b[1] - u2[1] * k)
        d += (f"M{pt(a)}" if i == 0 else f"L{pt(a)}") + f"C{pt(c0)} {pt(c1)} {pt(b)}"
    return d + "Z"

def capsule(cx, cy, length, width, angle=90):
    """A pill of `length` along `angle` degrees (90 = vertical) and `width` across."""
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)
    vx, vy = -uy, ux
    h = (length - width) / 2
    r = width / 2
    p = lambda s, t: (cx + ux * s + vx * t, cy + uy * s + vy * t)
    return rounded_polygon([p(-h - r, -r), p(h + r, -r), p(h + r, r), p(-h - r, r)], r - 1e-6)

def rrect(x, y, w, h, r):
    return rounded_polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], min(r, w / 2 - 1e-6, h / 2 - 1e-6))

# MARK: checks

def flatten(d, steps=20):
    nums = lambda s: list(map(float, re.findall(r"-?\d+(?:\.\d+)?", s)))
    pts, cur, start = [], (0, 0), (0, 0)
    for cmd, args in re.findall(r"([MLCZ])([^MLCZ]*)", d):
        a = nums(args)
        if cmd == "M": cur = start = (a[0], a[1]); pts.append(cur)
        elif cmd == "L": cur = (a[0], a[1]); pts.append(cur)
        elif cmd == "C":
            p0, p1, p2, p3 = cur, (a[0], a[1]), (a[2], a[3]), (a[4], a[5])
            for i in range(1, steps + 1):
                t = i / steps; u = 1 - t
                pts.append((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
                            u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]))
            cur = p3
    return pts

def inside(poly, x, y):
    c = False
    for i in range(len(poly)):
        (x1, y1), (x2, y2) = poly[i], poly[i - 1]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1: c = not c
    return c

def bbox(poly):
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)

# MARK: concentric shapes (inset of the body, clipped by straight edges, filleted)

def area(poly):
    return sum(poly[i - 1][0] * poly[i][1] - poly[i][0] * poly[i - 1][1] for i in range(len(poly))) / 2

def resample(poly, step=0.25):
    out = []
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        n = max(1, int(math.hypot(b[0] - a[0], b[1] - a[1]) / step))
        out += [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(n)]
    return out

def inset(poly, d):
    """Offset a smooth closed polyline inwards by d (curvature radius must exceed d)."""
    poly = resample(poly)
    s = 1 if area(poly) > 0 else -1   # y-down: positive area is clockwise on screen
    out, n = [], len(poly)
    for i in range(n):
        p0, p2 = poly[i - 1], poly[(i + 1) % n]
        tx, ty = p2[0] - p0[0], p2[1] - p0[1]
        l = math.hypot(tx, ty) or 1
        nx, ny = -ty / l * s, tx / l * s
        out.append((poly[i][0] + nx * d, poly[i][1] + ny * d))
    return out

def clip(poly, a, b, c):
    """Keep the part of poly where a*x + b*y + c <= 0 (Sutherland-Hodgman, one edge)."""
    out = []
    for i in range(len(poly)):
        p, q = poly[i - 1], poly[i]
        fp, fq = a * p[0] + b * p[1] + c, a * q[0] + b * q[1] + c
        if fq <= 0:
            if fp > 0:
                t = fp / (fp - fq); out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
            out.append(q)
        elif fp <= 0:
            t = fp / (fp - fq); out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out

def corners(poly, min_turn=25):
    """Indices where the polyline turns sharply (the clip corners)."""
    idx, n = [], len(poly)
    for i in range(n):
        p0, p1, p2 = poly[i - 1], poly[i], poly[(i + 1) % n]
        a1 = math.atan2(p1[1] - p0[1], p1[0] - p0[0]); a2 = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
        t = abs((math.degrees(a2 - a1) + 180) % 360 - 180)
        if t > min_turn: idx.append(i)
    return idx

def filleted_path(poly, r):
    """SVG path of poly with each sharp corner replaced by a circular fillet of radius r."""
    poly = resample(poly)
    n = len(poly)
    cs = set(corners(poly))
    def walk(i, step, dist):
        j, acc = i, 0.0
        while acc < dist:
            k = (j + step) % n
            acc += math.hypot(poly[k][0] - poly[j][0], poly[k][1] - poly[j][1]); j = k
        return j
    skip, arcs = set(), {}
    for i in cs:
        p = poly[i]
        # direction along each side from a point a little way off (robust on a resampled curve)
        jb, jf = walk(i, -1, 1.5), walk(i, 1, 1.5)
        u1 = (poly[jb][0] - p[0], poly[jb][1] - p[1]); l1 = math.hypot(*u1); u1 = (u1[0] / l1, u1[1] / l1)
        u2 = (poly[jf][0] - p[0], poly[jf][1] - p[1]); l2 = math.hypot(*u2); u2 = (u2[0] / l2, u2[1] / l2)
        ang = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        t = r / math.tan(ang / 2)
        jb, jf = walk(i, -1, t), walk(i, 1, t)
        a, b = poly[jb], poly[jf]
        k = 4 / 3 * math.tan((math.pi - ang) / 4) * r
        c0 = (a[0] - u1[0] * k, a[1] - u1[1] * k); c1 = (b[0] - u2[0] * k, b[1] - u2[1] * k)
        j = jb
        while j != jf:
            j = (j + 1) % n
            if j != jf: skip.add(j)
        arcs[jb] = (c0, c1, b)
    d, started = "", False
    for i in range(n):
        if i in skip: continue
        d += ("L" if started else "M") + pt(poly[i]); started = True
        if i in arcs:
            c0, c1, b = arcs[i]
            d += f"C{pt(c0)} {pt(c1)} {pt(b)}"
    return d + "Z"

def simplify(poly, every=8):
    """Thin a dense polyline, keeping its sharp corners."""
    keep = set(corners(poly, 10)) | set(range(0, len(poly), every))
    return [(round(poly[i][0], 2), round(poly[i][1], 2)) for i in sorted(keep)]

# MARK: rollers (both wheels): a dark slot, a cylinder with squared ends, shaded across its
# width, and knurl lines across it, so a wheel never reads as a pill-shaped button.

def roller_defs(c, gid="roller"):
    return (f'<linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="0">'
            f'<stop offset="0" stop-color="{c["metal_edge"]}"/><stop offset="0.45" stop-color="{c["metal"]}"/>'
            f'<stop offset="0.55" stop-color="{c["metal"]}"/><stop offset="1" stop-color="{c["metal_edge"]}"/></linearGradient>')

def roller_shape(cx, cy, length, width):
    return rrect(cx - width / 2, cy - length / 2, width, length, 1.5)

def roller(c, cx, cy, length, width, slot_len, slot_wid, part_id, pitch=1.6):
    out = [f'<path d="{rrect(cx - slot_wid / 2, cy - slot_len / 2, slot_wid, slot_len, min(slot_wid / 2, 3.5))}" fill="{c["slot"]}"/>',
           f'<path id="{part_id}" d="{roller_shape(cx, cy, length, width)}" fill="url(#roller)"/>']
    n = int((length - 2) / pitch)
    y0 = cy - (n - 1) * pitch / 2
    d = "".join(f"M{pt((cx - width / 2, y0 + i * pitch))}H{f(cx + width / 2)}" for i in range(n))
    out.append(f'<path d="{d}" fill="none" stroke="{c["knurl"]}" stroke-width="0.5"/>')
    return out
