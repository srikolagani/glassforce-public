import io, cairosvg
from PIL import Image, ImageFilter, ImageChops

S = 1024
SQ = dict(x=100, y=100, w=824, h=824, r=186)  # macOS app icon grid
BOLT = "M604 178 L328 584 L486 584 L420 852 L704 432 L542 432 Z"
FACET = "M542 432 L704 432 L420 852 L486 584 Z"

def svg(body, defs=""):
    doc = f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}"><defs>{defs}</defs>{body}</svg>'
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=doc.encode()))).convert("RGBA")

sq = f'<rect x="{SQ["x"]}" y="{SQ["y"]}" width="{SQ["w"]}" height="{SQ["h"]}" rx="{SQ["r"]}"/>'

def layer_mask():
    return svg(sq.replace("<rect", '<rect fill="#fff"'))

def build():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # 1. drop shadow
    sh = svg(sq.replace("<rect", '<rect fill="#000"'))
    sh = Image.merge("RGBA", (*sh.split()[:3], sh.split()[3].point(lambda a: int(a * 0.38))))
    sh = sh.filter(ImageFilter.GaussianBlur(22))
    canvas.alpha_composite(sh, (0, 14))

    # 2. background: deep indigo -> electric blue, with soft glows
    bg = svg(
        sq.replace("<rect", '<rect fill="url(#base)"')
        + sq.replace("<rect", '<rect fill="url(#glowA)"')
        + sq.replace("<rect", '<rect fill="url(#glowB)"'),
        defs="""
        <linearGradient id="base" x1="0.15" y1="1" x2="0.85" y2="0">
          <stop offset="0" stop-color="#070B2E"/>
          <stop offset="0.55" stop-color="#1B2A9E"/>
          <stop offset="1" stop-color="#3D63F5"/>
        </linearGradient>
        <radialGradient id="glowA" cx="0.30" cy="0.22" r="0.55">
          <stop offset="0" stop-color="#7FA2FF" stop-opacity="0.55"/>
          <stop offset="1" stop-color="#7FA2FF" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="glowB" cx="0.85" cy="0.92" r="0.5">
          <stop offset="0" stop-color="#7B4DFF" stop-opacity="0.55"/>
          <stop offset="1" stop-color="#7B4DFF" stop-opacity="0"/>
        </radialGradient>""",
    )
    canvas.alpha_composite(bg)
    mask = layer_mask().split()[3]

    # 3. a tilted glass pane behind the mark
    pane = svg(
        '<g transform="rotate(-9 512 512)">'
        '<rect x="262" y="262" width="500" height="500" rx="112" fill="url(#paneFill)"/>'
        '<rect x="263.5" y="263.5" width="497" height="497" rx="110.5" fill="none" stroke="url(#paneEdge)" stroke-width="3"/>'
        '</g>',
        defs="""
        <linearGradient id="paneFill" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.26"/>
          <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.08"/>
          <stop offset="1" stop-color="#9FC0FF" stop-opacity="0.14"/>
        </linearGradient>
        <linearGradient id="paneEdge" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/>
          <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.12"/>
          <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.45"/>
        </linearGradient>""",
    )
    canvas.alpha_composite(pane)

    # 4. refracted glow under the bolt (cyan, offset like light through glass)
    glow = svg(f'<path d="{BOLT}" fill="#5FE0FF"/>')
    glow = Image.merge("RGBA", (*glow.split()[:3], glow.split()[3].point(lambda a: int(a * 0.75))))
    glow = glow.filter(ImageFilter.GaussianBlur(26))
    canvas.alpha_composite(glow, (10, 16))

    # 5. the bolt: a glass shard with bright edges
    bolt = svg(
        f'<path d="{BOLT}" fill="url(#boltFill)" stroke="url(#boltEdge)" stroke-width="7" stroke-linejoin="round"/>'
        f'<path d="{FACET}" fill="#6E9BFF" fill-opacity="0.30"/>'
        f'<path d="M604 178 L328 584 L486 584" fill="none" stroke="#FFFFFF" stroke-opacity="0.95" stroke-width="5" stroke-linejoin="round" stroke-linecap="round"/>',
        defs="""
        <linearGradient id="boltFill" x1="0.2" y1="0" x2="0.8" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/>
          <stop offset="0.45" stop-color="#E4EEFF" stop-opacity="0.92"/>
          <stop offset="1" stop-color="#9CCBFF" stop-opacity="0.78"/>
        </linearGradient>
        <linearGradient id="boltEdge" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/>
          <stop offset="1" stop-color="#BFE9FF" stop-opacity="0.7"/>
        </linearGradient>""",
    )
    canvas.alpha_composite(bolt)

    # 6. top gloss + inner rim, clipped to the squircle
    gloss = svg(
        '<ellipse cx="512" cy="150" rx="520" ry="300" fill="url(#gloss)"/>'
        + sq.replace("<rect", '<rect fill="none" stroke="url(#rim)" stroke-width="4"'),
        defs="""
        <radialGradient id="gloss" cx="0.5" cy="0" r="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.20"/>
          <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.45"/>
          <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.05"/>
          <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.18"/>
        </linearGradient>""",
    )
    ga = ImageChops.multiply(gloss.split()[3], mask)
    gloss.putalpha(ga)
    canvas.alpha_composite(gloss)
    return canvas

if __name__ == "__main__":
    icon = build()
    icon.save("AppIcon-1024.png")
    preview = Image.new("RGBA", (1400, 1100), (236, 238, 244, 255))
    preview.alpha_composite(icon.resize((640, 640), Image.LANCZOS), (60, 230))
    for i, s in enumerate([256, 128, 64, 32]):
        preview.alpha_composite(icon.resize((s, s), Image.LANCZOS), (760 + [0, 280, 430, 520][i], 420 + (256 - s) // 2))
    preview.save("icon-preview.png")
