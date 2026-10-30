"""L9 re-slicer for art that crosses the atlas grid lines.

Usage (repo root): python games/robango-island/assets/icons/l9/reslice.py [--dry] [atlas:cell ...]

slice.py crops each fixed 4x4 cell, so an object that spills over a grid line gets a straight cut
edge (hoe-t2's blade, axe-t2's head). This script labels connected objects on the WHOLE atlas
(alpha >= 8, 8-connected), gives every object to the cell that holds its centroid, and keeps the
cell's objects whole: tight crop, centred at 88% fill, LANCZOS 96x96 (same framing as slice.py).
Objects smaller than 2% of the cell's largest object are dropped as specks. Never draws artwork.

With no cell arguments it re-slices every cell whose object reaches past slice.py's 4%-inset crop
box (that crop cut the art); it writes the pack icon and refreshes l9/verify.json for that key and
its variants. --dry writes nothing in the pack and only prints the list (l9/reslice-report.json).
An object that is merged with a neighbour cell's object (bbox wider than 1.25 cells) aborts.
"""
import hashlib, json, shutil, sys
import numpy as np
from PIL import Image
from scipy import ndimage

D = "games/robango-island/assets/icons"
L9 = D + "/l9"
jobs = json.load(open(L9 + "/jobs.json", encoding="utf8"))
verify = json.load(open(L9 + "/verify.json"))
dry = "--dry" in sys.argv
only = {a for a in sys.argv[1:] if a != "--dry"}
EIGHT = np.ones((3, 3), dtype=bool)


def cell_box(W, H, i):
    cx, cy = i % 4, i // 4
    return round(cx * W / 4), round(cy * H / 4), round((cx + 1) * W / 4), round((cy + 1) * H / 4)


def reslice(atlas):
    im = Image.open(f"{L9}/atlas-{atlas['id']}.png").convert("RGBA")
    arr = np.array(im)
    H, W = arr.shape[:2]
    lab, n = ndimage.label(arr[:, :, 3] >= 8, structure=EIGHT)
    sizes = ndimage.sum(np.ones_like(lab), lab, index=np.arange(1, n + 1))
    cents = ndimage.center_of_mass(np.ones_like(lab), lab, index=np.arange(1, n + 1))
    owner = {}
    for k, (cy, cx) in enumerate(cents, start=1):
        owner[k] = min(3, int(cy // (H / 4))) * 4 + min(3, int(cx // (W / 4)))
    out = {}
    for i, key in enumerate(atlas["subjects"]):
        mine = [k for k in owner if owner[k] == i]
        if not mine:
            raise SystemExit(f"no object in atlas {atlas['id']} cell {i + 1} ({key})")
        big = max(sizes[k - 1] for k in mine)
        keep = [k for k in mine if sizes[k - 1] >= big * 0.02 and sizes[k - 1] >= 40]
        mask = np.isin(lab, keep)
        ys, xs = np.nonzero(mask)
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        crop = arr[y0:y1, x0:x1].copy()
        crop[~mask[y0:y1, x0:x1]] = 0
        cell = Image.fromarray(crop, "RGBA")
        side = round(max(cell.size) / 0.88)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.alpha_composite(cell, ((side - cell.size[0]) // 2, (side - cell.size[1]) // 2))
        tile = canvas.resize((96, 96), Image.LANCZOS)
        a = tile.getchannel("A").point(lambda v: 0 if v < 8 else v)
        tile.putalpha(a)
        bx0, by0, bx1, by1 = cell_box(W, H, i)
        ix, iy = round(W / 4 * 0.04), round(H / 4 * 0.04)
        cut = [s for s, c in (("L", x0 < bx0 + ix), ("T", y0 < by0 + iy), ("R", x1 > bx1 - ix), ("B", y1 > by1 - iy)) if c]
        if x1 - x0 > W / 4 * 1.25 or y1 - y0 > H / 4 * 1.25:
            raise SystemExit(f"atlas {atlas['id']} cell {i + 1} ({key}) is merged with a neighbour: {x0},{y0}-{x1},{y1}")
        out[key] = (tile, {"bbox": [int(x0), int(y0), int(x1), int(y1)], "cut": cut, "objects": len(keep)})
    return out


if __name__ == "__main__":
    targets = {(a.split(":")[0], int(a.split(":")[1])) for a in only}
    variants = {}
    for k, v in verify.items():
        if "variantOf" in v:
            variants.setdefault(v["variantOf"], []).append(k)
    report = []
    for atlas in jobs["atlases"]:
        if targets and not any(t[0] == atlas["id"] for t in targets):
            continue
        res = reslice(atlas)
        for i, key in enumerate(atlas["subjects"]):
            tile, info = res[key]
            if (atlas["id"], i + 1) not in targets if targets else not info["cut"]:
                continue
            icon = f"{atlas['kind']}.icon.{key}"
            report.append({"icon": icon, "atlas": atlas["id"], "cell": i + 1, **info})
            if dry:
                print("WOULD", icon, info)
                continue
            path = f"{D}/{icon}.png"
            tile.save(path, optimize=True)
            hist = tile.getchannel("A").histogram()
            sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
            v = verify[icon]
            v.update(clear=hist[0], visible=sum(hist[129:]), sha256=sha, reslice="l9/reslice.py")
            for t in variants.get(icon, []):
                shutil.copyfile(path, f"{D}/{t}.png")
                verify[t].update(clear=v["clear"], visible=v["visible"], sha256=sha, reslice="l9/reslice.py")
            print("RESLICED", icon, info, "variants", len(variants.get(icon, [])))
    if not dry:
        json.dump(verify, open(L9 + "/verify.json", "w"), indent=1, sort_keys=True)
    json.dump(report, open(L9 + "/reslice-report.json", "w"), indent=1)
