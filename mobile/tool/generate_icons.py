"""Generates the Hally app icon, Android adaptive icon layers and splash logos.

Run from mobile/:  python3 tool/generate_icons.py   (needs Pillow)
The mark is two cherries on one branch (the parents), the joined stems draw a roof (home) and the leaf is the
growing child. It is drawn in a 100x100 design space; lib/core/design/brand.dart paints the same geometry.
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CHERRY = (0xAD, 0x52, 0x68)  # soft cherry (lib/core/design/tokens.dart HallyColors.cherry)
SS = 4  # supersampling

# Colour sets: (cherries, stems, leaf)
ON_BRAND = ((255, 255, 255, 255), (0xF3, 0xE4, 0xE7, 255), (0xDC, 0xE5, 0xD7, 255))
ON_LIGHT = (CHERRY + (255,), (0x6E, 0x3A, 0x44, 255), (0x8F, 0xAE, 0x8F, 255))
WHITE = ((255, 255, 255, 255),) * 3


def bezier(p0, p1, p2, p3, n=40):
    pts = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def mark(size, scale=1.0, colours=ON_BRAND):
    """Transparent layer with the mark; scale 1.0 maps the 100-unit design space onto the whole layer."""
    big = size * SS
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    k = big * scale / 100
    off = (big - big * scale) / 2

    def p(x, y):
        return (off + x * k, off + (y - 2) * k)

    cherry, stem, leaf = colours
    w = 5.5 * k
    for c1, c2, end in (((45, 34), (37, 47), (32, 60)), ((55, 34), (63, 47), (68, 60))):
        pts = [p(*q) for q in bezier((50, 22), c1, c2, end)]
        d.line(pts, fill=stem, width=round(w), joint="curve")
        for q in (pts[0], pts[-1]):
            d.ellipse((q[0] - w / 2, q[1] - w / 2, q[0] + w / 2, q[1] + w / 2), fill=stem)
    leaf_pts = bezier((50, 22), (57, 10), (72, 8), (81, 13)) + bezier((81, 13), (74, 23), (60, 26), (50, 22))
    d.polygon([p(*q) for q in leaf_pts], fill=leaf)
    for cx in (31, 69):
        x, y = p(cx, 72)
        r = 15 * k
        d.ellipse((x - r, y - r, x + r, y + r), fill=cherry)
    return layer.resize((size, size), Image.LANCZOS)


def solid(size, colour=CHERRY):
    return Image.new("RGBA", (size, size), colour + (255,))


def app_icon(size):
    bg = solid(size)
    bg.alpha_composite(mark(size, 0.92))
    return bg.convert("RGB")  # App Store icons must not have alpha


def rounded(img, radius):
    m = Image.new("L", (img.width * SS, img.height * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), radius * SS, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m.resize(img.size, Image.LANCZOS))
    return out


def main():
    master = app_icon(1024)
    master.save(ROOT.parent / "docs/design/app_icon_1024.png")  # store listing / marketing

    # iOS
    ios = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for f in ios.glob("Icon-App-*.png"):
        pt, scale = f.stem.removeprefix("Icon-App-").split("@")
        px = round(float(pt.split("x")[0]) * int(scale.removesuffix("x")))
        master.resize((px, px), Image.LANCZOS).save(f)

    # Android legacy (rounded square) + adaptive layers (108dp canvas, mark inside the 66dp safe zone)
    res = ROOT / "android/app/src/main/res"
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, k in densities.items():
        d = res / f"mipmap-{name}"
        legacy = round(48 * k)
        rounded(app_icon(legacy * 4).resize((legacy, legacy), Image.LANCZOS), legacy * 0.22).save(d / "ic_launcher.png")
        adaptive = round(108 * k)
        solid(adaptive).convert("RGB").save(d / "ic_launcher_background.png")
        mark(adaptive, 0.62).save(d / "ic_launcher_foreground.png")
        mark(adaptive, 0.62, WHITE).save(d / "ic_launcher_monochrome.png")
        # Splash logo: 96dp rounded icon
        logo = round(96 * k)
        rounded(app_icon(logo * 2).resize((logo, logo), Image.LANCZOS), logo * 0.24).save(d / "launch_image.png")

    # iOS launch image: 96pt rounded icon at 1x/2x/3x
    launch = ROOT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for suffix, k in (("", 1), ("@2x", 2), ("@3x", 3)):
        px = 96 * k
        rounded(app_icon(px * 2).resize((px, px), Image.LANCZOS), px * 0.24).save(launch / f"LaunchImage{suffix}.png")


if __name__ == "__main__":
    main()
