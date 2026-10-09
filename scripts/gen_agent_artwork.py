#!/usr/bin/env python3
"""Convert the WPF path geometry for the Claude and Codex agent icons into SwiftUI Path code."""
import math
import re
import sys

XAML = "src/AgentHud/MainWindow.xaml"
OUT = "src/AgentHud.macOS/AgentHud/Utils/AgentArtwork.swift"


def extract_paths(xaml_text):
    paths = re.findall(r'Value="F1 ([^"]+)"', xaml_text)
    if len(paths) < 2:
        raise SystemExit(f"expected 2 path definitions, found {len(paths)}")
    return paths[0], paths[1]  # codex (OpenAI knot), claude (starburst)


def parse(path):
    i, n = 0, len(path)
    segments = []
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    last_ctrl = None
    last_cmd = None

    def skip_ws():
        nonlocal i
        while i < n and path[i] in " ,\t\n\r":
            i += 1

    def read_number():
        nonlocal i
        skip_ws()
        m = re.match(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?", path[i:])
        if not m:
            raise ValueError(f"expected number at {i}: {path[i:i + 20]!r}")
        i += len(m.group(0))
        return float(m.group(0))

    def read_flag():
        nonlocal i
        skip_ws()
        ch = path[i]
        if ch not in "01":
            raise ValueError(f"expected flag at {i}: {ch!r}")
        i += 1
        return ch == "1"

    def has_number():
        skip_ws()
        if i >= n:
            return False
        return path[i] in "+-.0123456789"

    while i < n:
        skip_ws()
        if i >= n:
            break
        c = path[i]
        if c not in "MmLlHhVvCcSsQqTtAaZz":
            raise ValueError(f"expected command at {i}: {c!r}")
        i += 1
        if c in "Zz":
            segments.append(("Z", []))
            current = start
            last_ctrl = None
        elif c in "Aa":
            while has_number():
                rx = read_number()
                ry = read_number()
                rot = read_number()
                large = read_flag()
                sweep = read_flag()
                x = read_number()
                y = read_number()
                if c == "a":
                    x += current[0]
                    y += current[1]
                segments.append(("A", [current, rx, ry, rot, large, sweep, (x, y)]))
                current = (x, y)
            last_ctrl = None
        elif c in "Mm":
            first = True
            while has_number():
                x = read_number()
                y = read_number()
                if c == "m":
                    x += current[0]
                    y += current[1]
                if first:
                    segments.append(("M", [(x, y)]))
                    start = (x, y)
                    first = False
                else:
                    segments.append(("L", [(x, y)]))
                current = (x, y)
                c = "l" if c == "m" else "L"
            last_ctrl = None
        elif c in "Ll":
            while has_number():
                x = read_number()
                y = read_number()
                if c == "l":
                    x += current[0]
                    y += current[1]
                segments.append(("L", [(x, y)]))
                current = (x, y)
            last_ctrl = None
        elif c in "Hh":
            while has_number():
                x = read_number()
                if c == "h":
                    x += current[0]
                segments.append(("L", [(x, current[1])]))
                current = (x, current[1])
            last_ctrl = None
        elif c in "Vv":
            while has_number():
                y = read_number()
                if c == "v":
                    y += current[1]
                segments.append(("L", [(current[0], y)]))
                current = (current[0], y)
            last_ctrl = None
        elif c in "Cc":
            while has_number():
                x1, y1 = read_number(), read_number()
                x2, y2 = read_number(), read_number()
                x, y = read_number(), read_number()
                if c == "c":
                    x1 += current[0]; y1 += current[1]
                    x2 += current[0]; y2 += current[1]
                    x += current[0]; y += current[1]
                segments.append(("C", [current, (x1, y1), (x2, y2), (x, y)]))
                last_ctrl = (x2, y2)
                current = (x, y)
        elif c in "Ss":
            while has_number():
                x2, y2 = read_number(), read_number()
                x, y = read_number(), read_number()
                if c == "s":
                    x2 += current[0]; y2 += current[1]
                    x += current[0]; y += current[1]
                if last_cmd in "CcSs" and last_ctrl is not None:
                    x1 = 2 * current[0] - last_ctrl[0]
                    y1 = 2 * current[1] - last_ctrl[1]
                else:
                    x1, y1 = current
                segments.append(("C", [current, (x1, y1), (x2, y2), (x, y)]))
                last_ctrl = (x2, y2)
                current = (x, y)
        elif c in "Qq":
            while has_number():
                x1, y1 = read_number(), read_number()
                x, y = read_number(), read_number()
                if c == "q":
                    x1 += current[0]; y1 += current[1]
                    x += current[0]; y += current[1]
                segments.append(("Q", [current, (x1, y1), (x, y)]))
                last_ctrl = (x1, y1)
                current = (x, y)
        elif c in "Tt":
            while has_number():
                x, y = read_number(), read_number()
                if c == "t":
                    x += current[0]; y += current[1]
                if last_cmd in "QqTt" and last_ctrl is not None:
                    x1 = 2 * current[0] - last_ctrl[0]
                    y1 = 2 * current[1] - last_ctrl[1]
                else:
                    x1, y1 = current
                segments.append(("Q", [current, (x1, y1), (x, y)]))
                last_ctrl = (x1, y1)
                current = (x, y)
        last_cmd = c
    return segments


def arc_to_cubics(p0, rx, ry, rot_deg, large, sweep, p1):
    if p0 == p1 or (rx == 0 and ry == 0):
        return [("L", [p1])]
    phi = math.radians(rot_deg % 360)
    cosphi, sinphi = math.cos(phi), math.sin(phi)
    dx2 = (p0[0] - p1[0]) / 2.0
    dy2 = (p0[1] - p1[1]) / 2.0
    x1p = cosphi * dx2 + sinphi * dy2
    y1p = -sinphi * dx2 + cosphi * dy2
    rx, ry = abs(rx), abs(ry)
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = max(0.0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(num / den) if den != 0 else 0.0
    if large == sweep:
        coef = -coef
    cxp = coef * (rx * y1p / ry)
    cyp = coef * (-(ry * x1p / rx))
    cx = cosphi * cxp - sinphi * cyp + (p0[0] + p1[0]) / 2.0
    cy = sinphi * cxp + cosphi * cyp + (p0[1] + p1[1]) / 2.0

    def angle(ux, uy, vx, vy):
        d = ux * vx + uy * vy
        nv = math.hypot(ux, uy) * math.hypot(vx, vy)
        if nv == 0:
            return 0.0
        a = math.acos(max(-1.0, min(1.0, d / nv)))
        return a if (ux * vy - uy * vx) >= 0 else -a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    if sweep and dtheta < 0:
        dtheta += 2 * math.pi

    nseg = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2.0))))
    seg = dtheta / nseg

    def point(t):
        return (cx + rx * cosphi * math.cos(t) - ry * sinphi * math.sin(t),
                cy + rx * sinphi * math.cos(t) + ry * cosphi * math.sin(t))

    def deriv(t):
        return (-rx * cosphi * math.sin(t) - ry * sinphi * math.cos(t),
                -rx * sinphi * math.sin(t) + ry * cosphi * math.cos(t))

    out = []
    for k in range(nseg):
        t1 = theta1 + k * seg
        t2 = t1 + seg
        alpha = 4.0 / 3.0 * math.tan(seg / 4.0)
        ps = point(t1)
        pe = point(t2)
        d1 = deriv(t1)
        d2 = deriv(t2)
        c1 = (ps[0] + alpha * d1[0], ps[1] + alpha * d1[1])
        c2 = (pe[0] - alpha * d2[0], pe[1] - alpha * d2[1])
        out.append(("C", [ps, c1, c2, pe]))
    return out


def fmt(v):
    s = f"{v:.5f}".rstrip("0").rstrip(".")
    return s if s != "-0" else "0"


def emit(name, segments, out):
    out.write(f"    /// {name}\n")
    out.write(f"    static func {name}() -> Path {{\n")
    out.write("        var path = Path()\n")
    for kind, points in segments:
        if kind == "M":
            (x, y), = points
            out.write(f"        path.move(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}))\n")
        elif kind == "L":
            (x, y), = points
            out.write(f"        path.addLine(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}))\n")
        elif kind == "C":
            _, c1, c2, p = points
            out.write(f"        path.addCurve(to: CGPoint(x: {fmt(p[0])}, y: {fmt(p[1])}), "
                      f"control1: CGPoint(x: {fmt(c1[0])}, y: {fmt(c1[1])}), "
                      f"control2: CGPoint(x: {fmt(c2[0])}, y: {fmt(c2[1])}))\n")
        elif kind == "Q":
            _, c, p = points
            out.write(f"        path.addQuadCurve(to: CGPoint(x: {fmt(p[0])}, y: {fmt(p[1])}), "
                      f"control: CGPoint(x: {fmt(c[0])}, y: {fmt(c[1])}))\n")
        elif kind == "A":
            p0, rx, ry, rot, large, sweep, p1 = points
            for sub_kind, sub_points in arc_to_cubics(p0, rx, ry, rot, large, sweep, p1):
                if sub_kind == "L":
                    (x, y), = sub_points
                    out.write(f"        path.addLine(to: CGPoint(x: {fmt(x)}, y: {fmt(y)}))\n")
                else:
                    _, c1, c2, p = sub_points
                    out.write(f"        path.addCurve(to: CGPoint(x: {fmt(p[0])}, y: {fmt(p[1])}), "
                              f"control1: CGPoint(x: {fmt(c1[0])}, y: {fmt(c1[1])}), "
                              f"control2: CGPoint(x: {fmt(c2[0])}, y: {fmt(c2[1])}))\n")
        elif kind == "Z":
            out.write("        path.closeSubpath()\n")
    out.write("        return path\n")
    out.write("    }\n\n")


def main():
    xaml = open(XAML, encoding="utf-8").read()
    codex_src, claude_src = extract_paths(xaml)

    codex_segments = parse(codex_src)
    claude_segments = parse(claude_src)
    print(f"codex segments: {len(codex_segments)} (arcs: {sum(1 for s in codex_segments if s[0] == 'A')})")
    print(f"claude segments: {len(claude_segments)} (arcs: {sum(1 for s in claude_segments if s[0] == 'A')})")

    def bbox(segments):
        xs, ys = [], []
        for kind, points in segments:
            if kind == "A":
                p0, p1 = points[0], points[6]
                xs += [p0[0], p1[0]]
                ys += [p0[1], p1[1]]
            else:
                for p in points:
                    xs.append(p[0])
                    ys.append(p[1])
        return min(xs), min(ys), max(xs), max(ys)

    print("codex bbox:", tuple(round(v, 2) for v in bbox(codex_segments)))
    print("claude bbox:", tuple(round(v, 2) for v in bbox(claude_segments)))

    with open(OUT, "w", encoding="utf-8") as out:
        out.write("import SwiftUI\n\n")
        out.write("/// Vector artwork for the agent icons, converted from the Windows app's path geometry.\n")
        out.write("enum AgentArtwork {\n")
        emit("codex", codex_segments, out)
        emit("claude", claude_segments, out)
        out.write("}\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
