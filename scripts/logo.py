"""Generate the herdr-nvim logo (assets/logo.svg and assets/logo.png).

An original mark: a terminal prompt and a curled, tapering horn in a
green-to-blue gradient on a dark rounded tile.

    python3 scripts/logo.py            # writes assets/logo.svg
    rsvg-convert -w 512 assets/logo.svg -o assets/logo.png
"""
import math
import sys

def horn_path(cx, cy, r0, r1, turns, start_deg, w0, w1, n=240):
    """Filled, tapering spiral: thick at the base (outer end), thin at the tip."""
    cl = []
    for i in range(n + 1):
        t = i / n
        ang = math.radians(start_deg) + t * turns * 2 * math.pi
        r = r0 + (r1 - r0) * (t ** 0.9)
        cl.append((cx + r * math.cos(ang), cy + r * math.sin(ang), t))
    left, right = [], []
    for i, (x, y, t) in enumerate(cl):
        x0, y0, _ = cl[max(i - 1, 0)]
        x1, y1, _ = cl[min(i + 1, n)]
        dx, dy = x1 - x0, y1 - y0
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        w = (w0 + (w1 - w0) * (t ** 0.8)) / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    pts = left + right[::-1]
    d = "M %.2f %.2f " % pts[0] + " ".join("L %.2f %.2f" % p for p in pts[1:]) + " Z"
    # round cap at the base and the tip
    bx, by, _ = cl[0]
    tx, ty, _ = cl[-1]
    return d, (bx, by, w0 / 2), (tx, ty, w1 / 2)

def icon(size=256, horn=(160, 136, 58, 11, 1.42, 208, 32, 9), tile="#16181D", fg="#E8EAED"):
    d, base, tip = horn_path(*horn)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="{size}" height="{size}">
  <defs>
    <linearGradient id="horn" gradientUnits="userSpaceOnUse" x1="110" y1="70" x2="206" y2="186">
      <stop offset="0" stop-color="#72D35F"/>
      <stop offset="0.55" stop-color="#3FB3A0"/>
      <stop offset="1" stop-color="#3E86D8"/>
    </linearGradient>
  </defs>
  <rect x="8" y="8" width="240" height="240" rx="56" fill="{tile}"/>
  <g fill="url(#horn)">
    <path d="{d}"/>
    <circle cx="{base[0]:.2f}" cy="{base[1]:.2f}" r="{base[2]:.2f}"/>
    <circle cx="{tip[0]:.2f}" cy="{tip[1]:.2f}" r="{tip[2]:.2f}"/>
  </g>
  <g fill="none" stroke="{fg}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="40,120 63,138 40,156"/>
    <line x1="76" y1="160" x2="96" y2="160"/>
  </g>
</svg>'''

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/logo.svg"
    with open(out, "w") as f:
        f.write(icon() + "\n")
