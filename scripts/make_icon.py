#!/usr/bin/env python3
"""Moto Road app icon: a winding road seen from the rider's eyes, disappearing between mountains at the horizon.
Racing orange to hot red on carbon, with a warm glow. The road is drawn on the ground plane and projected in
perspective, so its width, bends and dashes shrink naturally with distance.

Usage: python scripts/make_icon.py OUT.png [SIZE]   (requires Pillow)
"""
from __future__ import annotations

import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4                       # supersampling (anti-aliasing)
N = 1024 * S
ORANGE = (255, 94, 26)      # #FF5E1A
HOT = (255, 41, 84)         # #FF2954
HORIZON = 372               # horizon line on the 1024 canvas
FOCAL = 760                 # focal length × camera height, in pixels
WIDTH = 0.62                # road width on the ground (camera heights)
Z_NEAR, Z_FAR = 0.82, 90.0


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(round(lerp(a, b, t))) for a, b in zip(c1, c2))


def centre_x(z: float) -> float:
    """Lateral position of the road's centre on the ground at depth z: it leaves the bottom centre, then bends
    evenly in depth (log scale), wide enough to stay readable far away."""
    z_bottom = FOCAL / (1024 - HORIZON)                 # depth seen at the bottom edge: centred there
    amplitude = 0.26 * z / (1 + (z / 12) ** 1.15)        # bends narrow towards the pass on the horizon
    return amplitude * math.sin(2.25 * math.log(max(z, 1e-3) / z_bottom))


def project(x: float, z: float) -> tuple[float, float]:
    return (512 + FOCAL * x / z) * S, (HORIZON + FOCAL / z) * S


def ground_normal(z: float) -> tuple[float, float]:
    dz = 1e-3
    dxdz = (centre_x(z + dz) - centre_x(z - dz)) / (2 * dz)
    n = math.hypot(1, dxdz)
    return 1 / n, -dxdz / n                      # perpendicular to the tangent (dx/dz, 1)


def strip(z0: float, z1: float, offset0: float, offset1: float, steps: int = 40) -> list[tuple[float, float]]:
    """Polygon of a band of the road between depths z0..z1 and lateral offsets offset0..offset1 (ground units)."""
    left, right = [], []
    for i in range(steps + 1):
        z = lerp(z0, z1, i / steps)
        nx, nz = ground_normal(z)
        cx = centre_x(z)
        left.append(project(cx + nx * offset0, z + nz * offset0))
        right.append(project(cx + nx * offset1, z + nz * offset1))
    return left + right[::-1]


def depth_samples():
    # Denser near the camera, where the road is large on screen.
    z, out = Z_NEAR, []
    while z < Z_FAR:
        out.append(z)
        z *= 1.012
    return out + [Z_FAR]


def vertical_gradient(stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    g = Image.new("RGB", (1, 1024))
    for y in range(1024):
        t = y / 1023
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                g.putpixel((0, y), mix(c0, c1, (t - t0) / (t1 - t0)))
                break
    return g.resize((N, N), Image.BICUBIC)


def soft_ellipse(box, color, alpha, blur):
    layer = Image.new("RGBA", (N, N), color + (0,))
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).ellipse([v * S for v in box], fill=int(alpha * 255))
    layer.putalpha(m.filter(ImageFilter.GaussianBlur(blur * S)))
    return layer


def smooth(points: list[tuple[float, float]], per: int = 24) -> list[tuple[float, float]]:
    """Catmull-Rom curve through the points (rounded ridges)."""
    pts = [points[0]] + points + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for k in range(per):
            t = k / per
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t ** 3) for j in range(2)))
    return out + [points[-1]]


RIDGES = (
    ([(-20, 318), (110, 292), (220, 312), (330, 252), (430, 300), (512, 360)], (44, 40, 50)),
    ([(512, 360), (600, 318), (690, 270), (790, 300), (880, 246), (1044, 300)], (36, 34, 43)),
)


def mountains(img: Image.Image) -> None:
    """Two ridges at the horizon, the road vanishing in the pass between them, rim-lit by the warm sky."""
    rim = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    for ridge, color in RIDGES:
        curve = [(x * S, y * S) for x, y in smooth(ridge)]
        layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(curve + [(curve[-1][0], (HORIZON + 4) * S), (curve[0][0], (HORIZON + 4) * S)],
                                      fill=color + (255,))
        img.alpha_composite(layer)
        rd.line(curve, fill=(255, 140, 80, 140), width=3 * S, joint="curve")
    img.alpha_composite(rim.filter(ImageFilter.GaussianBlur(1.5 * S)))


def main(out: str, size: int = 1024) -> None:
    # Sky and ground: carbon, warmer near the horizon.
    img = vertical_gradient([(0.0, (22, 23, 29)), (0.30, (52, 36, 40)), (0.364, (92, 46, 40)),
                             (0.366, (20, 20, 25)), (1.0, (8, 9, 12))]).convert("RGBA")
    img.alpha_composite(soft_ellipse((250, 250, 774, 470), (255, 110, 50), 0.38, 60))      # sunset haze
    img.alpha_composite(soft_ellipse((330, 340, 694, 430), (255, 120, 60), 0.22, 30))      # warm light on the ground
    mountains(img)

    zs = depth_samples()
    road = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    rd = ImageDraw.Draw(road)
    half = WIDTH / 2
    # Asphalt in thin depth slices: orange near, hot red far, fading into the haze.
    for z0, z1 in zip(zs, zs[1:]):
        t = min(1.0, math.log(z0 / Z_NEAR) / math.log(Z_FAR / Z_NEAR))
        color = mix(ORANGE, HOT, t ** 0.55)
        alpha = int(255 * (1 - max(0.0, (t - 0.72) / 0.28) ** 1.5))
        rd.polygon(strip(z0, z1 * 1.004, -half, half, steps=2), fill=color + (alpha,))
    glow = Image.new("RGBA", (N, N), ORANGE + (0,))
    glow.putalpha(road.getchannel("A").filter(ImageFilter.GaussianBlur(34 * S)).point(lambda a: int(a * 0.75)))
    img.alpha_composite(glow)
    img.alpha_composite(road)

    # Edge lines and centre dashes, painted on the ground (they shrink with distance).
    paint = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    pd = ImageDraw.Draw(paint)
    line_w = 0.022
    for side in (-1, 1):
        o = side * (half - 0.05)
        pd.polygon(strip(Z_NEAR, 38, o - line_w / 2, o + line_w / 2, steps=400), fill=(255, 236, 225, 150))
    dash, gap, z = 0.42, 0.38, Z_NEAR
    while z < 42:
        pd.polygon(strip(z, z + dash, -0.016, 0.016, steps=6), fill=(255, 255, 255, 245))
        z += dash + gap
    img.alpha_composite(paint)

    # Subtle vignette for depth.
    vignette = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    vm = Image.new("L", (N, N), 0)
    ImageDraw.Draw(vm).rectangle([0, 0, N, N], fill=110)
    ImageDraw.Draw(vm).ellipse([-200 * S, -120 * S, 1224 * S, 1200 * S], fill=0)
    vignette.putalpha(vm.filter(ImageFilter.GaussianBlur(120 * S)))
    img.alpha_composite(vignette)

    img.convert("RGB").resize((size, size), Image.LANCZOS).save(out, optimize=True)


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1024)
