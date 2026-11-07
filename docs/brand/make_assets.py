import io, sys, cairosvg
from PIL import Image
repo = sys.argv[1]
icon = Image.open("AppIcon-1024.png")
# iconset for iconutil + an .icns built directly
sizes = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for pt, scale in sizes:
    px = pt * scale
    name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
    icon.resize((px, px), Image.LANCZOS).save(f"{repo}/Resources/AppIcon.iconset/{name}", optimize=True)
icon.save(f"{repo}/Resources/AppIcon.icns", sizes=[(16,16),(32,32),(64,64),(128,128),(256,256),(512,512),(1024,1024)])
icon.save(f"{repo}/docs/brand/glassforce-icon-1024.png", optimize=True)

def wordmark(text_color, out, bg=None):
    W, H = 1600, 400
    icon_png = icon.resize((300, 300), Image.LANCZOS)
    doc = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
      {'<rect width="100%" height="100%" fill="'+bg+'"/>' if bg else ''}
      <text x="390" y="252" font-family="Geist" font-weight="600" font-size="168" letter-spacing="-5" fill="{text_color}">Glass<tspan font-weight="300">force</tspan></text>
    </svg>'''
    im = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=doc.encode()))).convert("RGBA")
    im.alpha_composite(icon_png, (50, 50))
    im.save(out, optimize=True)
    return doc

wordmark("#0B1240", f"{repo}/docs/brand/glassforce-wordmark-light.png")
wordmark("#FFFFFF", f"{repo}/docs/brand/glassforce-wordmark-dark.png")
wordmark("#0B1240", "wordmark-preview-light.png", bg="#F4F6FB")
wordmark("#FFFFFF", "wordmark-preview-dark.png", bg="#0A0F2C")

# colour palette swatch
pal = [("Midnight","#070B2E"),("Indigo","#1B2A9E"),("Electric Blue","#3D63F5"),("Glow","#7FA2FF"),("Violet","#7B4DFF"),("Refraction Cyan","#5FE0FF"),("Frost","#F4F6FB")]
cells = "".join(f'<rect x="{40+i*220}" y="40" width="200" height="200" rx="28" fill="{c}" stroke="#00000014"/><text x="{40+i*220}" y="285" font-family="Geist" font-weight="600" font-size="24" fill="#0B1240">{n}</text><text x="{40+i*220}" y="318" font-family="Geist Mono" font-size="20" fill="#5A6380">{c}</text>' for i,(n,c) in enumerate(pal))
svgdoc = f'<svg xmlns="http://www.w3.org/2000/svg" width="{80+len(pal)*220}" height="350"><rect width="100%" height="100%" fill="#FFFFFF"/>{cells}</svg>'
open(f"{repo}/docs/brand/palette.svg","w").write(svgdoc)
Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svgdoc.encode()))).save(f"{repo}/docs/brand/palette.png", optimize=True)

# PR / README hero: icon + wordmark on dark
hero = Image.new("RGBA", (1600, 900), (0,0,0,0))
bgdoc = '''<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"><defs><radialGradient id="g" cx="0.3" cy="0.2" r="1"><stop offset="0" stop-color="#1B2A9E"/><stop offset="1" stop-color="#070B2E"/></radialGradient></defs><rect width="100%" height="100%" fill="url(#g)"/>
<text x="800" y="760" text-anchor="middle" font-family="Geist" font-weight="400" font-size="44" fill="#BFD0FF">Your org, one keystroke away.</text></svg>'''
hero = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=bgdoc.encode()))).convert("RGBA")
hero.alpha_composite(icon.resize((440,440), Image.LANCZOS), (580, 120))
wm = Image.open(f"{repo}/docs/brand/glassforce-wordmark-dark.png")
wm = wm.crop((360, 0, wm.width, wm.height))
wm = wm.crop(wm.getbbox())
wm = wm.resize((int(wm.width*0.62), int(wm.height*0.62)), Image.LANCZOS)
hero.alpha_composite(wm, ((1600-wm.width)//2, 600 - wm.height//2))
hero.save(f"{repo}/docs/brand/glassforce-hero.png", optimize=True)
