"""L9 slicer: atlas-<id>.png -> <kind>.icon.<key>.png (96x96) per l9/jobs.json.

Usage (repo root): python games/robango-island/assets/icons/l9/slice.py [ids...]
Writes the pack icons in place (the row's existing path), plus l9/verify.json.
Never draws artwork; only crops, cleans alpha and resizes generated cells.
"""
import hashlib, json, os, sys
from PIL import Image

D = "games/robango-island/assets/icons"
L9 = D + "/l9"
jobs = json.load(open(L9 + "/jobs.json", encoding="utf8"))
want = sys.argv[1:] or [a["id"] for a in jobs["atlases"]]
verify = json.load(open(L9 + "/verify.json")) if os.path.exists(L9 + "/verify.json") else {}


def components(alpha, w, h):
    seen = bytearray(w * h)
    out = []
    for p in range(w * h):
        if seen[p] or alpha[p] < 8:
            continue
        stack, pts, touches = [p], [], False
        seen[p] = 1
        while stack:
            n = stack.pop()
            pts.append(n)
            x, y = n % w, n // w
            touches |= x in (0, w - 1) or y in (0, h - 1)
            for m in ((n - 1) if x else -1, (n + 1) if x < w - 1 else -1, (n - w) if y else -1, (n + w) if y < h - 1 else -1):
                if m >= 0 and not seen[m] and alpha[m] >= 8:
                    seen[m] = 1
                    stack.append(m)
        out.append((pts, touches))
    return out


for atlas in jobs["atlases"]:
    if atlas["id"] not in want:
        continue
    src = f"{L9}/atlas-{atlas['id']}.png"
    im = Image.open(src).convert("RGBA")
    W, H = im.size
    for i, key in enumerate(atlas["subjects"]):
        cx, cy = i % 4, i // 4
        ix, iy = round(W / 4 * 0.04), round(H / 4 * 0.04)
        box = (round(cx * W / 4) + ix, round(cy * H / 4) + iy, round((cx + 1) * W / 4) - ix, round((cy + 1) * H / 4) - iy)
        cell = im.crop(box)
        w, h = cell.size
        px = cell.load()
        alpha = [px[x, y][3] for y in range(h) for x in range(w)]
        comps = components(alpha, w, h)
        largest = max(len(c[0]) for c in comps)
        for pts, touches in comps:
            if len(pts) < largest / 4 and (touches or len(pts) < 40):
                for n in pts:
                    px[n % w, n // w] = (0, 0, 0, 0)
        for y in range(h):
            for x in range(w):
                if px[x, y][3] < 8:
                    px[x, y] = (0, 0, 0, 0)
        bbox = cell.getbbox()
        cell = cell.crop(bbox)
        side = round(max(cell.size) / 0.88)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.alpha_composite(cell, ((side - cell.size[0]) // 2, (side - cell.size[1]) // 2))
        tile = canvas.resize((96, 96), Image.LANCZOS)
        a = tile.getchannel("A")
        a = a.point(lambda v: 0 if v < 8 else v)
        tile.putalpha(a)
        hist = a.histogram()
        clear, visible = hist[0], sum(hist[129:])
        assert clear and visible, key
        kind = atlas["kind"]
        path = f"{D}/{kind}.icon.{key}.png"
        tile.save(path, optimize=True)
        entry = {k: v for k, v in jobs.items() if k in ("style", "route")}
        entry.update(atlas=atlas["id"], cell=i + 1, subject=atlas["subjects"][key])
        verify[f"{kind}.icon.{key}"] = {
            "atlas": f"l9/atlas-{atlas['id']}.png",
            "cell": i + 1,
            "clear": clear,
            "visible": visible,
            "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(),
            "inputVersion": hashlib.sha256(json.dumps(entry, sort_keys=True).encode()).hexdigest(),
        }
        print("SLICED", path, clear, visible)
json.dump(verify, open(L9 + "/verify.json", "w"), indent=1, sort_keys=True)
