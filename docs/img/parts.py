"""Component artwork for the wiring diagram.

Drawn rather than imported: Fritzing's library is CC-BY-SA, which would put
a ShareAlike obligation on the diagram, and it has neither a 3-channel relay
module nor a capacitive v1.2 probe anyway. These are stylised but keep the
proportions, connector positions and colours of the actual parts.
"""

def relay_module(x, y, s=1.0):
    """Blue 3-channel opto-isolated board. Returns (svg, pin_xy dict)."""
    W, H = 330, 170
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append(f'<rect width="{W}" height="{H}" rx="6" fill="#15619b" stroke="#0d4470" stroke-width="2"/>')
    for cx, cy in ((14,14),(W-14,14),(14,H-14),(W-14,H-14)):
        g.append(f'<circle cx="{cx}" cy="{cy}" r="6.5" fill="#0d3f66"/><circle cx="{cx}" cy="{cy}" r="3.5" fill="#cfd8dc"/>')
    # three relay cans + their screw terminals
    for i in range(3):
        rx = 26 + i*100
        g.append(f'<rect x="{rx}" y="52" width="76" height="64" rx="3" fill="#eef2f4" stroke="#b7c2c8" stroke-width="1.5"/>')
        g.append(f'<text x="{rx+38}" y="90" font-size="13" font-weight="700" fill="#5b6b73" text-anchor="middle" font-family="Helvetica,Arial">SRD</text>')
        g.append(f'<rect x="{rx-2}" y="10" width="80" height="34" rx="3" fill="#1f7a3f" stroke="#14532b" stroke-width="1.5"/>')
        for k in range(3):
            sx = rx + 10 + k*26
            g.append(f'<circle cx="{sx}" cy="27" r="8" fill="#d8dee2" stroke="#8a969c" stroke-width="1.2"/>')
            g.append(f'<rect x="{sx-5}" y="26" width="10" height="2.5" fill="#6d787e"/>')
    # 5-pin control header, bottom left
    pins = {}
    names = ["GND","IN1","IN2","IN3","VCC"]
    for i, nm in enumerate(names):
        px = 30 + i*30
        g.append(f'<rect x="{px-9}" y="{H-34}" width="18" height="24" rx="2" fill="#101418"/>')
        g.append(f'<rect x="{px-4}" y="{H-30}" width="8" height="16" fill="#c9a227"/>')
        g.append(f'<text x="{px}" y="{H-38}" font-size="11" font-weight="700" fill="#dbe7ef" text-anchor="middle" font-family="Helvetica,Arial">{nm}</text>')
        pins[nm] = (x + px*s, y + (H-10)*s)
    g.append(f'<text x="{W-16}" y="{H-16}" font-size="13" fill="#a9c6dd" text-anchor="end" font-family="Helvetica,Arial">3-channel relay</text>')
    g.append('</g>')
    return "\n".join(g), pins


def dht11(x, y, s=1.0):
    W, H = 120, 150
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append(f'<rect width="{W}" height="{H}" rx="5" fill="#1b64a6" stroke="#12456f" stroke-width="2"/>')
    g.append(f'<rect x="18" y="16" width="84" height="86" rx="4" fill="#7fb3dd" stroke="#4d87b5" stroke-width="1.5"/>')
    for i in range(7):                      # the grille
        g.append(f'<rect x="26" y="{26+i*10}" width="68" height="5" rx="2.5" fill="#37658c" opacity="0.75"/>')
    pins = {}
    for i, nm in enumerate(["VCC","DATA","GND"]):
        px = 26 + i*34
        g.append(f'<rect x="{px-8}" y="{H-30}" width="16" height="22" rx="2" fill="#101418"/>')
        g.append(f'<rect x="{px-3.5}" y="{H-26}" width="7" height="14" fill="#c9a227"/>')
        g.append(f'<text x="{px}" y="{H-34}" font-size="10.5" font-weight="700" fill="#dbe7ef" text-anchor="middle" font-family="Helvetica,Arial">{nm}</text>')
        pins[nm] = (x + px*s, y + (H-8)*s)
    g.append('</g>')
    return "\n".join(g), pins


def soil_probe(x, y, s=1.0):
    """Capacitive v1.2: pale board, black corrosion-resistant blade."""
    W, H = 330, 78
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append(f'<rect x="70" y="10" width="{W-70}" height="58" rx="6" fill="#2a2f33"/>')     # blade
    g.append(f'<path d="M{W} 10 l0 58 l-26 -12 l0 -34 Z" fill="#1b1f22"/>')
    g.append(f'<rect x="0" y="4" width="120" height="70" rx="6" fill="#d9cfa8" stroke="#b3a87f" stroke-width="1.5"/>')
    g.append(f'<rect x="16" y="16" width="34" height="20" rx="2" fill="#2b2f33"/>')          # 555 + regulator
    g.append(f'<rect x="58" y="18" width="18" height="14" rx="2" fill="#3a3f44"/>')
    g.append(f'<text x="150" y="46" font-size="14" font-weight="700" fill="#cfd6da" font-family="Helvetica,Arial">capacitive v1.2</text>')
    pins = {}
    for i, nm in enumerate(["VCC","AOUT","GND"]):
        py = 20 + i*18
        g.append(f'<rect x="-6" y="{py-6}" width="20" height="13" rx="2" fill="#101418"/>')
        g.append(f'<rect x="-2" y="{py-3}" width="12" height="7" fill="#c9a227"/>')
        pins[nm] = (x + (-6)*s, y + py*s)
    g.append('</g>')
    return "\n".join(g), pins


def mosfet_to220(x, y, s=1.0):
    """TO-220, tab up, legs down: G D S left to right."""
    W, H = 96, 132
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append(f'<rect x="10" y="0" width="76" height="30" rx="3" fill="#b9c0c4" stroke="#8d959a" stroke-width="1.5"/>')
    g.append(f'<circle cx="48" cy="15" r="7" fill="#f7f9fa" stroke="#8d959a" stroke-width="1.5"/>')
    g.append(f'<rect x="10" y="28" width="76" height="58" rx="3" fill="#1c1f22"/>')
    g.append(f'<text x="48" y="56" font-size="11" font-weight="700" fill="#c8ced2" text-anchor="middle" font-family="Helvetica,Arial">IRLZ44N</text>')
    g.append(f'<text x="48" y="72" font-size="9" fill="#8e979c" text-anchor="middle" font-family="Helvetica,Arial">TO-220</text>')
    pins = {}
    for i, nm in enumerate(["G","D","S"]):
        px = 26 + i*22
        g.append(f'<rect x="{px-3}" y="86" width="6" height="40" fill="#aeb6ba"/>')
        g.append(f'<text x="{px}" y="{H+13}" font-size="11" font-weight="700" fill="#141a17" text-anchor="middle" font-family="Helvetica,Arial">{nm}</text>')
        pins[nm] = (x + px*s, y + (H-6)*s)
    g.append('</g>')
    return "\n".join(g), pins


def fan(x, y, s=1.0):
    """Square case fan: swept blades, not a gear."""
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append('<rect width="92" height="92" rx="8" fill="#242a2e"/>')
    for cx, cy in ((13,13),(79,13),(13,79),(79,79)):
        g.append(f'<circle cx="{cx}" cy="{cy}" r="4.5" fill="#12171a"/>')
    g.append('<circle cx="46" cy="46" r="38" fill="#14181b"/>')
    for i in range(7):
        g.append('<path d="M46 46 C 60 30, 76 34, 80 46 C 66 44, 56 40, 46 46 Z" '
                 f'fill="#4a545b" transform="rotate({i*51.4} 46 46)"/>')
    g.append('<circle cx="46" cy="46" r="12" fill="#6b767e"/>')
    g.append('<circle cx="46" cy="46" r="4" fill="#2a3136"/>')
    g.append('</g>')
    return "\n".join(g)


def pump(x, y, s=1.0):
    """12 V diaphragm pump: motor can + head with two barbed ports."""
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append('<rect x="6" y="22" width="54" height="48" rx="8" fill="#39434b"/>')
    g.append('<rect x="6" y="22" width="54" height="10" rx="5" fill="#4a555e"/>')
    g.append('<rect x="58" y="16" width="40" height="60" rx="7" fill="#8f9aa2"/>')
    g.append('<circle cx="78" cy="46" r="13" fill="#6d7981"/>')
    g.append('<rect x="94" y="22" width="16" height="11" rx="3" fill="#5d6970"/>')
    g.append('<rect x="94" y="59" width="16" height="11" rx="3" fill="#5d6970"/>')
    g.append('</g>')
    return "\n".join(g)


def valve(x, y, s=1.0):
    """Solenoid valve: brass body, coil block on top."""
    g = [f'<g transform="translate({x},{y}) scale({s})">']
    g.append('<rect x="26" y="4" width="50" height="40" rx="5" fill="#2f3941"/>')
    g.append('<rect x="32" y="10" width="38" height="28" rx="3" fill="#48555f"/>')
    g.append('<rect x="46" y="42" width="12" height="12" fill="#7e6a45"/>')
    g.append('<rect x="10" y="52" width="82" height="28" rx="8" fill="#a98a55"/>')
    g.append('<rect x="10" y="52" width="82" height="9" rx="4" fill="#c2a068"/>')
    g.append('<rect x="0" y="58" width="12" height="16" rx="3" fill="#8d7346"/>')
    g.append('<rect x="90" y="58" width="12" height="16" rx="3" fill="#8d7346"/>')
    g.append('</g>')
    return "\n".join(g)
