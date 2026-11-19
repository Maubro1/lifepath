"""LifePath app icon: a compass rose over a glowing heat trail. Writes icon-<look>.svg; render with render-icon.ps1.
Usage: python icon.py  (writes both looks next to this file)"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))
C, S = 512, 1024

LOOKS = {
    # background centre/edge, dial centre/edge, side points lit/shade, tick colour, trail glow
    'night': dict(bg=('#3B2C27', '#140F0D'), dial=('#2C2320', '#1B1513'), side=('#F4EEE3', '#C9BDA8'),
                  tick='#F1ECE2', tickop=0.55, ring=('#F7C978', '#C9862F', '#7A4A1C'), glow=0.95, cap='#F4EEE3'),
    'paper': dict(bg=('#FBF7EF', '#E6D9C2'), dial=('#FFFDF8', '#F1E8D8'), side=('#5A5148', '#2B2621'),
                  tick='#2B2621', tickop=0.5, ring=('#F2C766', '#C9862F', '#8A5520'), glow=0.75, cap='#FFFDF8'),
}


def pt(r, deg):
    a = math.radians(deg - 90)
    return C + r * math.cos(a), C + r * math.sin(a)


def f(p):
    return f'{p[0]:.2f},{p[1]:.2f}'


def point(deg, length, half, lit, shade):
    """One point of the rose as two facets: the left one catches the light, the right one is in shade."""
    tip, base_l, base_r = pt(length, deg), pt(half, deg - 45), pt(half, deg + 45)
    centre = (C, C)
    return (f'<polygon points="{f(centre)} {f(base_l)} {f(tip)}" fill="{lit}"/>'
            f'<polygon points="{f(centre)} {f(tip)} {f(base_r)}" fill="{shade}"/>')


def svg(look):
    L = LOOKS[look]
    ticks = []
    for i in range(72):
        deg = i * 5
        major = i % 18 == 0
        mid = i % 9 == 0
        r1 = 318 if major else 328 if mid else 336
        w = 5 if major else 3.2 if mid else 2
        ticks.append(f'<line x1="{f(pt(r1, deg)).split(",")[0]}" y1="{f(pt(r1, deg)).split(",")[1]}" '
                     f'x2="{f(pt(350, deg)).split(",")[0]}" y2="{f(pt(350, deg)).split(",")[1]}" stroke-width="{w}"/>')
    rose = []
    for deg in (45, 135, 225, 315):   # intercardinals: mustard, shorter, behind
        rose.append(point(deg, 205, 46, 'url(#mustardLit)', 'url(#mustardShade)'))
    for deg in (90, 180, 270):
        rose.append(point(deg, 292, 58, L['side'][0], L['side'][1]))
    rose.append(point(0, 300, 58, 'url(#northLit)', 'url(#northShade)'))
    # The trail: a walk that wanders in from the lower left and ends at the needle's centre.
    trail = 'M 214 838 C 262 770, 196 700, 268 650 S 392 640, 404 586 S 470 520, 512 512'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
<defs>
  <radialGradient id="bg" cx="50%" cy="42%" r="75%"><stop offset="0" stop-color="{L['bg'][0]}"/><stop offset="1" stop-color="{L['bg'][1]}"/></radialGradient>
  <radialGradient id="dial" cx="50%" cy="38%" r="65%"><stop offset="0" stop-color="{L['dial'][0]}"/><stop offset="1" stop-color="{L['dial'][1]}"/></radialGradient>
  <linearGradient id="ring" x1="0.2" y1="0" x2="0.8" y2="1"><stop offset="0" stop-color="{L['ring'][0]}"/><stop offset="0.55" stop-color="{L['ring'][1]}"/><stop offset="1" stop-color="{L['ring'][2]}"/></linearGradient>
  <linearGradient id="ringInner" x1="0.8" y1="1" x2="0.2" y2="0"><stop offset="0" stop-color="{L['ring'][0]}" stop-opacity="0.9"/><stop offset="1" stop-color="{L['ring'][2]}" stop-opacity="0.9"/></linearGradient>
  <linearGradient id="northLit" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB27A"/><stop offset="1" stop-color="#F08C4E"/></linearGradient>
  <linearGradient id="northShade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E0503F"/><stop offset="1" stop-color="#A9322A"/></linearGradient>
  <linearGradient id="mustardLit" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F6D27C"/><stop offset="1" stop-color="#E7B547"/></linearGradient>
  <linearGradient id="mustardShade" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#C9952E"/><stop offset="1" stop-color="#9C6E1E"/></linearGradient>
  <linearGradient id="trail" gradientUnits="userSpaceOnUse" x1="214" y1="838" x2="512" y2="512"><stop offset="0" stop-color="#E7B547" stop-opacity="0"/><stop offset="0.35" stop-color="#E7B547"/><stop offset="0.75" stop-color="#F08C4E"/><stop offset="1" stop-color="#E0503F"/></linearGradient>
  <radialGradient id="cap" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="{L['cap']}"/><stop offset="1" stop-color="#B9AC96"/></radialGradient>
  <filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="16"/></filter>
  <filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="5"/></filter>
  <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="16"/><feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF6DD" stop-opacity="0.9"/><stop offset="0.5" stop-color="#FFF6DD" stop-opacity="0"/></linearGradient>
  <clipPath id="face"><circle cx="{C}" cy="{C}" r="372"/></clipPath>
</defs>
<rect width="{S}" height="{S}" fill="url(#bg)"/>
<g transform="translate({C} {C}) scale(0.86) translate(-{C} -{C})">
<g filter="url(#shadow)">
  <circle cx="{C}" cy="{C}" r="404" fill="url(#ring)"/>
  <circle cx="{C}" cy="{C}" r="378" fill="url(#ringInner)"/>
  <circle cx="{C}" cy="{C}" r="372" fill="url(#dial)"/>
</g>
<circle cx="{C}" cy="{C}" r="400" fill="none" stroke="url(#sheen)" stroke-width="5"/>
<circle cx="{C}" cy="{C}" r="366" fill="none" stroke="#000" stroke-opacity="0.18" stroke-width="12" filter="url(#soft)" clip-path="url(#face)"/>
<g clip-path="url(#face)">
  <path d="{trail}" fill="none" stroke="url(#trail)" stroke-width="70" stroke-linecap="round" opacity="{L['glow'] * 0.6}" filter="url(#glow)"/>
  <path d="{trail}" fill="none" stroke="url(#trail)" stroke-width="26" stroke-linecap="round" opacity="{L['glow'] * 0.85}" filter="url(#soft)"/>
  <path d="{trail}" fill="none" stroke="url(#trail)" stroke-width="9" stroke-linecap="round" opacity="{L['glow']}"/>
</g>
<g stroke="{L['tick']}" stroke-linecap="round" opacity="{L['tickop']}">{''.join(ticks)}</g>
<g filter="url(#shadow)">{''.join(rose)}</g>
<circle cx="{C}" cy="{C}" r="36" fill="url(#cap)" filter="url(#shadow)"/>
<circle cx="{C}" cy="{C}" r="36" fill="none" stroke="#8A5520" stroke-opacity="0.35" stroke-width="2"/>
<circle cx="{C}" cy="{C}" r="11" fill="#E0503F"/>
</g>
</svg>'''


for look in LOOKS:
    with open(os.path.join(HERE, f'icon-{look}.svg'), 'w', encoding='utf-8') as fh:
        fh.write(svg(look))
print('ok')
