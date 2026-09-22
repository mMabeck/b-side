"""Render the app icon: a risograph half-LP rising out of a flat orange field.

Reuses the riso print simulator in ~/Claude/fun/riso (engine.py) — spot inks,
paper knockout, halftone, grain — so the icon is printed rather than drawn.

usage: python3 assets/icon/icon.py [--size 1024] [--arm] [--out out.png]
"""
import argparse
import math
import os
import sys

RISO = os.path.expanduser("~/Claude/fun/riso")
sys.path.insert(0, RISO)

from engine import Canvas, arc_pts, circle_pts  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024  # design resolution; everything below is in these units


def icon(c, arm=True, seed=7):
    """Top half of the record, cut by the bottom edge, orange above."""
    sd = seed
    cx, cy, R = S * 0.50, S * 0.94, S * 0.465

    bg = c.ink("orange")
    bg.rect(-40, -40, S + 40, S + 40)
    shade = c.ink("wine")   # light screen in the top corners so the field is not dead flat
    shade.halftone([(-40, -40), (S + 40, -40), (S + 40, S + 40), (-40, S + 40)],
                   (S * 0.5, -S * 0.15), (S * 0.5, S * 0.60), seed=sd * 3 + 51,
                   pitch=19, d0=0.40, d1=0.0, vmax=105)

    c.paper_ink().circle(cx, cy, R + 8, seed=sd * 5 + 52, amp=3.4, n=220)
    c.ink("black").circle(cx, cy, R, seed=sd * 5 + 52, amp=3.4, n=220)

    gap = c.paper_ink()   # grooves, then two sheens catching the light
    for i in range(16):
        rr = R * (0.34 + (0.63 * i) / 15)
        gap.ring(cx, cy, rr, w=2.4, seed=sd * 61 + i, amp=2.2, v=115)
    for a0, rr, w, v in ((-2.35, 0.84, 24, 185), (-1.05, 0.60, 15, 150)):
        gap.stroke(arc_pts(cx, cy, R * rr, a0 - 0.34, a0 + 0.34, 30), w=w,
                   seed=sd * 67 + int(rr * 10), amp=2.6, v=v)
    gap.circle(cx, cy, R * 0.345, seed=sd * 73 + 1, amp=2.6)

    label = c.ink("pink")
    lr = R * 0.335
    label.circle(cx, cy, lr, seed=sd * 73 + 1, amp=2.6)
    label.halftone(list(circle_pts(cx, cy, lr, 64)), (cx - lr, cy), (cx + lr, cy),
                   seed=sd * 74 + 2, pitch=11, d0=0.0, d1=0.7, vmax=190)

    marks = c.ink("black")   # spokes only where the label is actually visible
    for i in range(7):
        a = math.pi + 0.36 + (2 * math.pi - 0.72) * i / 6
        if math.sin(a) > -0.10:
            continue
        marks.stroke([(cx + lr * 0.50 * math.cos(a), cy + lr * 0.50 * math.sin(a)),
                      (cx + lr * 0.86 * math.cos(a), cy + lr * 0.86 * math.sin(a))],
                     w=9, seed=sd * 79 + i, amp=1.8, taper=0.35)
    marks.stroke(arc_pts(cx, cy, lr * 0.66, math.pi + 0.55, 2 * math.pi - 0.55, 26),
                 w=10, seed=sd * 83 + 2, amp=2.0)

    if arm:   # tonearm coming in from the top right, halo'd clear of the grooves
        pivot = (S * 1.14, S * 0.02)
        head = (S * 0.66, S * 0.56)
        kn = c.paper_ink()
        kn.stroke([pivot, head], w=40, seed=sd * 96 + 4, amp=2.0)
        kn.circle(head[0], head[1], 46, seed=sd * 102 + 6, amp=2.4)
        kn.circle(pivot[0], pivot[1], 104, seed=sd * 100 + 5, amp=2.4)
        a = c.ink("ink")
        a.stroke([pivot, head], w=28, seed=sd * 97 + 4, amp=1.8)
        a.circle(head[0], head[1], 38, seed=sd * 103 + 6, amp=2.2)
        a.circle(pivot[0], pivot[1], 94, seed=sd * 101 + 5, amp=2.4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-arm", action="store_true")
    ap.add_argument("--out", default=os.path.join(HERE, "icon.png"))
    a = ap.parse_args()

    c = Canvas(S, S, seed=a.seed)
    icon(c, arm=not a.no_arm, seed=a.seed)
    img = c.composite(vignette=0.07)
    if a.size != S:
        from PIL import Image
        img = img.resize((a.size, a.size), Image.LANCZOS)
    img.save(a.out)
    print(a.out)


if __name__ == "__main__":
    main()
