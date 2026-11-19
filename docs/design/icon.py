"""LifePath app icon: a compass needle over a heat glow. Writes icon-<look>.svg next to this file; render with render-icon.sh.

One idea, built on one centre: the heat ramp (light core, cherry, satsuma, mustard) as one radial glow, the way a
place you return to glows on the heat map, and a two-faceted needle across it. Everything is radial, so nothing
competes with the needle; light comes from the upper left throughout."""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))
C, S = 512, 1024
ANGLE = 40   # needle bearing in degrees, clockwise from north: it points ahead instead of standing still

LOOKS = {
    'night': dict(bg=('#33261F', '#140E0B'), north=('#FFF8EC', '#EAD6B6'), south=('#4A2A22', '#2A1712')),
    'paper': dict(bg=('#FBF6EC', '#EADCC4'), north=('#FFF8EC', '#EAD6B6'), south=('#4A2A22', '#2A1712')),
}

# The heat ramp as one continuous glow, hot centre out: offset, colour, opacity. A small light core under the pivot,
# cherry close in, satsuma, then mustard fading to nothing, so the glow has no edge to read as a target ring.
GLOW_R = 430
GLOW = [(0, '#FFF1DA', 1), (0.12, '#FFD9A8', 1), (0.25, '#E0503F', 1), (0.5, '#F08C4E', 0.97), (0.68, '#E7B547', 0.8),
        (0.84, '#E7B547', 0.32), (0.94, '#E7B547', 0.08), (1, '#E7B547', 0)]


def pt(r, deg):
    a = math.radians(deg - 90)
    return C + r * math.cos(a), C + r * math.sin(a)


def f(p):
    return f'{p[0]:.2f},{p[1]:.2f}'


def half(deg, length, width, lit, shade):
    """Half a needle: a long kite from the centre, split along its axis into a lit and a shaded facet."""
    tip, l, r = pt(length, deg), pt(width, deg - 90), pt(width, deg + 90)
    c = (C, C)
    return (f'<polygon points="{f(c)} {f(l)} {f(tip)}" fill="{lit}"/>'
            f'<polygon points="{f(c)} {f(tip)} {f(r)}" fill="{shade}"/>')


def svg(look):
    L = LOOKS[look]
    stops = ''.join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in GLOW)
    needle = half(ANGLE, 330, 60, L['north'][0], L['north'][1]) + half(ANGLE + 180, 330, 60, L['south'][0], L['south'][1])
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs>
  <radialGradient id="bg" cx="38%" cy="30%" r="90%"><stop offset="0" stop-color="{L['bg'][0]}"/><stop offset="1" stop-color="{L['bg'][1]}"/></radialGradient>
  <radialGradient id="glow" cx="50%" cy="50%" r="50%">{stops}</radialGradient>
  <radialGradient id="pivot" cx="38%" cy="32%" r="70%"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#D9C6A6"/></radialGradient>
  <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dx="10" dy="22"/><feComponentTransfer><feFuncA type="linear" slope="0.38"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="{S}" height="{S}" fill="url(#bg)"/>
<circle cx="{C}" cy="{C}" r="{GLOW_R}" fill="url(#glow)"/>
<g filter="url(#shadow)">{needle}</g>
<circle cx="{C}" cy="{C}" r="30" fill="url(#pivot)" filter="url(#shadow)"/>
</svg>'''


for look in LOOKS:
    with open(os.path.join(HERE, f'icon-{look}.svg'), 'w', encoding='utf-8') as fh:
        fh.write(svg(look))
print('ok')
