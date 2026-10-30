"""Side-by-side sheet: rows of labelled panels. usage: python sbs.py out.jpg "title" cols label=path ..."""
import sys, os
from PIL import Image, ImageDraw, ImageFont
out, title, cols = sys.argv[1], sys.argv[2], int(sys.argv[3])
items = [a.split("=", 1) for a in sys.argv[4:]]
W, H = 640, 300
f = ImageFont.truetype("arial.ttf", 18)
ft = ImageFont.truetype("arialbd.ttf", 22)
rows = (len(items) + cols - 1) // cols
img = Image.new("RGB", (W * cols, 34 + (H + 24) * rows), (24, 24, 24))
d = ImageDraw.Draw(img)
d.text((8, 5), title, fill=(255, 255, 255), font=ft)
for i, (lab, p) in enumerate(items):
    x, y = (i % cols) * W, 34 + (i // cols) * (H + 24)
    d.text((x + 6, y + 2), lab, fill=(255, 220, 0), font=f)
    if os.path.exists(p):
        im = Image.open(p).convert("RGB")
        im.thumbnail((W - 6, H))
        img.paste(im, (x + 3, y + 24))
    else:
        d.text((x + 20, y + 120), "MISSING " + os.path.basename(p), fill=(255, 80, 80), font=f)
img.save(out, quality=88)
print("ok", out)
