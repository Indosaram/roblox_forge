"""B2a creatures: skinned, textured meshes for the theropod, ceratopsian and sauropod body plans
and the 11 species mapped to them (asset catalog section 5).

Run (repo root, headless only):
  blender -b --factory-startup --python games/robango-island/assets/blender/gen_creatures.py -- <outdir> <species>

Rules applied (A2b REPORT recipe):
- built at final stud scale (1 Blender unit = 1 stud); the runtime never scales a skinned model;
- one rig per plan with the catalog bone count (theropod 22, ceratopsian 20, sauropod 26);
- every bone's local X is the creature's side axis, so +X rotation lifts a bone's tip (pitch)
  and Z rotation is yaw; the Root bone points up (local Y up, local Z forward);
- palette fed through C.hexlin (linear), CC0 leather micro-detail box-projected;
- S/M creatures bake 512 x3, L/XL 1024 x3; triangle totals stay inside the size class.
Needs build/a2b/src/brown_leather/ (SOURCES.md).
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

import common as C

SEED = 4210
X = Vector((1, 0, 0))

# Muted species palettes (sRGB hex): content wildlifeDetails visual colours pulled toward the
# A2b palette family targets (hide #6b5f3e, belly #8a7a58) so the herd reads realistic, not toy.
SPECIES = {
    "compsognathus": dict(plan="theropod", envelope=(1, 1.5, 3), tris=4000, tex=512, length=3.0,
        body="#8f9a52", stripe="#3e4a22", belly="#e2dcb4", accent="#6e7a3a", dorsal="#56622e",
        head="#c07a34", plume="#6a7438", plume_tip="#e6dfbc", skin="feathers", pop=0.45, rim="#f2e2a6",
        knobs=dict(neck=1.15, head=0.9, tail=1.25, girth=0.8, legs=1.0, arms=1.0, snout=1.0, neckr=0.85, headw=0.85),
        features=["feathers"]),
    "oviraptor": dict(plan="theropod", envelope=(1.5, 3, 3), tris=4000, tex=512, length=3.0,
        body="#a4623e", stripe="#4a2618", belly="#e6d8b8", accent="#4e8aa2", dorsal="#6a3a24",
        head="#4e8aa2", plume="#6a4430", plume_tip="#f0e4cc", skin="feathers", pop=0.45, rim="#f6d6a0",
        knobs=dict(neck=1.1, head=1.0, tail=0.9, girth=1.0, legs=1.0, arms=1.15, snout=0.6, neckr=0.85, headw=0.9),
        features=["crest", "feathers"]),
    "gallimimus": dict(plan="theropod", envelope=(2, 6, 5), tris=7000, tex=512, length=5.0,
        body="#d6d2c8", stripe="#2e3034", belly="#eeebe4", accent="#5e4a32", dorsal="#a8a396",
        head="#a42c22", plume="#464950", plume_tip="#9a9ca0", skin="feathers", neck="#3a3d43",
        knobs=dict(neck=1.6, head=0.72, tail=1.0, girth=0.9, legs=1.45, arms=1.1, snout=1.1, neckr=0.7, headw=0.8),
        features=["feathers"]),
    "utahraptor": dict(plan="theropod", envelope=(3, 6, 6), tris=7000, tex=512, length=6.0,
        body="#bdb7aa", stripe="#2e2924", belly="#e6e1d6", accent="#a07c46", dorsal="#6e675e",
        head="#9a2e22", plume="#4e4740", plume_tip="#b8b0a4", skin="feathers",
        knobs=dict(neck=1.0, head=1.05, tail=1.0, girth=1.15, legs=1.05, arms=1.15, snout=1.0, neckr=0.8, headw=0.82),
        features=["sickle", "feathers"]),
    "velociraptor": dict(plan="theropod", envelope=(2, 4, 4), tris=4000, tex=512, length=4.0,
        body="#a08e76", stripe="#2e241c", belly="#e2dacb", accent="#6e4630", dorsal="#5e4e3e",
        head="#a83626", plume="#5a4434", plume_tip="#c8b498", skin="feathers", pop=0.3, rim="#f0e0c0",
        knobs=dict(neck=1.0, head=0.95, tail=1.1, girth=0.85, legs=1.0, arms=1.05, snout=1.15, neckr=0.78, headw=0.78),
        features=["sickle", "feathers"]),
    "dilophosaurus": dict(plan="theropod", envelope=(3, 6, 6), tris=7000, tex=512, length=6.0,
        body="#4e6a58", stripe="#2a3c32", belly="#94a088", accent="#a08844",
        knobs=dict(neck=1.15, head=1.0, tail=1.0, girth=1.0, legs=1.05, arms=1.0, snout=1.1),
        features=["twincrest"]),
    "allosaurus": dict(plan="theropod", envelope=(5, 9, 12), tris=10000, tex=1024, length=12.0,
        body="#6e6246", stripe="#3e3424", belly="#9a8e6c", accent="#8a4a34",
        knobs=dict(neck=1.0, head=1.25, tail=1.0, girth=1.2, legs=1.0, arms=0.85, snout=1.0),
        features=["brow"]),
    "tyrannosaurus": dict(plan="theropod", envelope=(7, 12, 16), tris=14000, tex=1024, length=16.0,
        body="#5a6048", stripe="#30342a", belly="#8e8c6c", accent="#6e4a34",
        knobs=dict(neck=0.9, head=1.6, tail=1.0, girth=1.35, legs=1.1, arms=0.45, snout=0.9),
        features=["brow"]),
    "protoceratops": dict(plan="ceratopsian", envelope=(2.5, 3, 4), tris=4000, tex=512, length=4.0,
        body="#cfc6b0", stripe="#1e1a16", belly="#e2dccb", accent="#3a2e26", dorsal="#bdb39a",
        knobs=dict(frill=0.75, horns=0.0, girth=0.95, legs=1.0), features=["frill"]),
    "triceratops": dict(plan="ceratopsian", envelope=(5, 5, 8), tris=7000, tex=512, length=8.0,
        body="#7e6650", stripe="#3a2c22", belly="#b8a88c", accent="#8a6446", dorsal="#5e4a3a",
        knobs=dict(frill=1.1, horns=1.0, girth=1.1, legs=1.05), features=["frill", "horns"]),
    "brachiosaurus": dict(plan="sauropod", envelope=(8, 24, 18), tris=14000, tex=1024, length=18.0,
        body="#7e8266", stripe="#4a4e3a", belly="#b4b096", accent="#5e6448", dorsal="#646850",
        knobs=dict(girth=1.0), features=["nasalarch"]),
    # ---- B2b body plans. `fit` caps the scale so the mesh stays inside its render envelope.
    "stegosaurus": dict(plan="armored", envelope=(5, 6, 9), tris=10000, tex=1024, length=9.0,
        body="#6a7046", stripe="#3e4428", belly="#a09a72", accent="#8a4a32", stripe_lo=0.36, skin="plates",
        knobs=dict(girth=0.95, hind=1.25, fore=0.8), features=["plates", "thagomizer"]),
    "ankylosaurus": dict(plan="armored", envelope=(4, 4, 7), tris=7000, tex=512, length=7.0,
        body="#7a6a4c", stripe="#4a3e2c", belly="#a8987a", accent="#5a4c36", stripe_lo=9, skin="plates",
        knobs=dict(girth=1.65, hind=0.7, fore=0.65, flat=0.6), features=["osteoderms", "club", "sidespikes"]),
    "parasaurolophus": dict(plan="hadrosaur", envelope=(3, 7, 7), tris=7000, tex=512, length=7.0,
        body="#4e6a62", stripe="#2e443e", belly="#9aa490", accent="#a0603a",
        knobs=dict(girth=1.0), features=["tubecrest", "duckbill"]),
    "smilodon": dict(plan="mammal", envelope=(3, 4, 5), tris=7000, tex=512, length=5.0,
        body="#b08e5e", stripe="#6a5034", belly="#e4d6b8", accent="#7a5c3a", stripe_lo=9, skin="fur", dorsal="#8e6c44", height_shade=True, pop=0.2, rim="#f0dcb0",
        knobs=dict(girth=1.12, legs=0.95, neck=0.9, head=1.1, snout=0.75, tail=0.55, maner=1.25, ear=0.7),
        features=["saber"], saber=0.24, foot="paw"),
    "tropicalSmilodon": dict(plan="mammal", envelope=(2.5, 3.5, 5), tris=7000, tex=512, length=5.0,
        body="#b8843e", stripe="#3a2a1c", belly="#e4d4b4", accent="#6a4a2c", stripe_lo=0.28, skin="fur", height_shade=True, pop=0.2, rim="#f4d8a0",
        knobs=dict(girth=0.95, legs=0.95, neck=0.9, head=1.0, snout=0.75, tail=1.15, ear=0.75),
        features=["saber"], saber=0.13, foot="paw"),
    "direWolf": dict(plan="mammal", envelope=(2.5, 3.5, 5), tris=7000, tex=512, length=5.0,
        body="#948a7c", stripe="#3e3a36", belly="#e0dace", accent="#5a544c", stripe_lo=9, skin="fur", dorsal="#4e4842", height_shade=True, pop=0.25, rim="#efe6d6",
        knobs=dict(girth=0.9, legs=1.05, neck=1.0, head=1.0, snout=1.35, tail=1.25, tailr=1.4, maner=1.3, ear=0.95),
        features=[], foot="paw"),
    "boar": dict(plan="mammal", envelope=(2.5, 3, 4), tris=4000, tex=512, length=4.0,
        body="#86684e", stripe="#3c2e24", belly="#b8a088", accent="#3a2c22", stripe_lo=9, skin="fur", height_shade=True, pop=0.25, rim="#e0c8a4",
        knobs=dict(girth=1.25, legs=0.72, neck=0.6, head=1.2, snout=1.3, headup=0.2, tail=0.4, chestr=1.15),
        features=["tusks"], foot="hoof"),
    "deer": dict(plan="mammal", envelope=(2, 5, 4), tris=7000, tex=512, length=4.0,
        body="#93704c", stripe="#6a5034", belly="#d0c4ae", accent="#5a4430", stripe_lo=9, skin="fur",
        knobs=dict(girth=0.82, legs=1.3, neck=1.0, head=0.95, snout=1.1, headup=1.0, tail=0.3, tailup=1, ear=1.3, legr=0.75),
        features=["antlers"], foot="hoof", ivory="#8a7454", iris="#2a1e16"),
    "mammoth": dict(plan="elephant", envelope=(7, 10, 12), tris=10000, tex=1024, length=12.0,
        body="#9a6a40", stripe="#4e3220", belly="#b48a5e", accent="#4a3224", stripe_lo=9, skin="fur", dorsal="#6a4426", height_shade=True, pop=0.2, rim="#e8c494",
        knobs=dict(girth=1.1, hump=1.0, ear=0.45), features=["longtusks"], iris="#2a1e16"),
    "elephant": dict(plan="elephant", envelope=(6, 9, 10), tris=10000, tex=1024, length=10.0,
        body="#8a8274", stripe="#544c44", belly="#a69e90", accent="#6a6258", stripe_lo=9, skin="wrinkle", dorsal="#a49a88", height_shade=True, pop=0.2, rim="#eadcc6",
        knobs=dict(girth=1.0, hump=0.0, ear=1.0), features=["tusks"], iris="#2a1e16"),
    "crocodile": dict(plan="crocodilian", envelope=(3, 2, 7), tris=7000, tex=512, length=7.0,
        body="#66764a", stripe="#2e3a24", belly="#d0c896", accent="#4a5836", stripe_lo=0.34, skin="plates", pop=0.25, rim="#e0dca8",
        knobs=dict(girth=1.0), features=["scutes", "teeth"]),
    "turtle": dict(plan="turtle", envelope=(1.5, 1, 2), tris=4000, tex=512, length=2.0,
        body="#748452", stripe="#2e3a22", belly="#d4ca98", accent="#9a7646", stripe_lo=9, skin="plates", dorsal="#56643a", pop=0.35, rim="#eae0aa",
        knobs=dict(girth=1.0), features=["shell"], iris="#2a1e16"),
    "dodo": dict(plan="bird", envelope=(1.5, 2, 2), tris=4000, tex=512, length=2.0,
        body="#7e766a", stripe="#4a4238", belly="#cfc8b8", accent="#c09a52", stripe_lo=9, skin="feathers",
        knobs=dict(girth=1.0), features=["beak", "wings", "tuft"]),
}
# v2 (L4) per-species hide patterns: layered masks over the countershaded base, sizes as a
# fraction of body length. (kind, colour key or hex, strength, region, params).
PATTERNS = {
    "compsognathus": [("spots", "stripe", 0.75, "upper", dict(size=0.035, r=0.3)), ("saddle", "stripe", 0.35, None, {}), ("head", "head", 0.85, None, dict(r=0.75))],
    "oviraptor": [("blotch", "stripe", 0.55, "upper", dict(size=0.08, t=0.55)), ("saddle", "stripe", 0.4, None, {}), ("head", "head", 0.85, None, dict(r=0.75))],
    # Raptor lane: banded coats (dorsal bands that carry onto the tail) and, for gallimimus, the
    # dark R11-6 neck under a red head.
    "gallimimus": [("saddle", "dorsal", 0.4, None, {}), ("bands", "stripe", 0.42, "upper", dict(count=10, distortion=5)), ("neck", "neck", 0.92, None, {}), ("head", "head", 0.85, None, dict(r=0.6))],
    "utahraptor": [("bands", "stripe", 0.7, "upper", dict(count=10, distortion=6)), ("spots", "stripe", 0.2, "upper", dict(size=0.02, r=0.25)), ("neck", "plume", 0.45, None, {}), ("head", "head", 0.85, None, dict(r=0.6))],
    "velociraptor": [("bands", "stripe", 0.68, "upper", dict(count=11, distortion=6)), ("spots", "stripe", 0.4, "all", dict(size=0.018, r=0.3)), ("saddle", "stripe", 0.3, None, {}), ("head", "head", 0.8, None, dict(r=0.6))],
    "dilophosaurus": [("spots", "stripe", 0.75, "upper", dict(size=0.06, r=0.32))],
    "allosaurus": [("bands", "stripe", 0.55, "upper", dict(count=9, distortion=6)), ("saddle", "stripe", 0.3, None, {})],
    "tyrannosaurus": [("saddle", "stripe", 0.7, None, {}), ("blotch", "stripe", 0.4, "upper", dict(size=0.05, t=0.55))],
    "protoceratops": [("bands", "stripe", 0.96, "all", dict(count=16, distortion=4, sharp=1))],
    "triceratops": [("bands", "stripe", 0.55, "upper", dict(count=11, distortion=6)), ("saddle", "stripe", 0.2, None, {})],
    "brachiosaurus": [("reticulate", "stripe", 0.35, "upper", dict(size=0.03, w=0.06)), ("saddle", "stripe", 0.35, None, {})],
    "stegosaurus": [("blotch", "stripe", 0.6, "upper", dict(size=0.06, t=0.52)), ("saddle", "stripe", 0.3, None, {})],
    "ankylosaurus": [("spots", "stripe", 0.6, "upper", dict(size=0.04, r=0.3)), ("saddle", "stripe", 0.45, None, {})],
    "parasaurolophus": [("bands", "stripe", 0.45, "upper", dict(count=8, distortion=5)), ("blotch", "stripe", 0.25, "upper", dict(size=0.05, t=0.55))],
    "smilodon": [("grizzle", "stripe", 0.12, None, {}), ("saddle", "dorsal", 0.35, None, {}), ("head", "#8a6a44", 0.25, None, dict(r=0.5))],
    "tropicalSmilodon": [("bands", "stripe", 0.85, "upper", dict(count=12, distortion=7))],
    "direWolf": [("saddle", "stripe", 0.7, None, {}), ("grizzle", "#5a5248", 0.15, None, {}), ("socks", "#d8d0c0", 0.45, None, {})],
    "boar": [("grizzle", "#2a221c", 0.5, None, {}), ("socks", "stripe", 0.6, None, {})],
    "deer": [("saddle", "stripe", 0.3, None, {})],
    "mammoth": [("saddle", "stripe", 0.5, None, {}), ("grizzle", "#e0b07a", 0.18, None, {}), ("socks", "#3a2416", 0.45, None, {})],
    "elephant": [("blotch", "#7e6e60", 0.3, None, dict(size=0.1, t=0.55)), ("dust", "#c4b8a2", 0.45, None, {}), ("socks", "#6e5442", 0.5, None, {})],
    "crocodile": [("blotch", "stripe", 0.7, "upper", dict(size=0.05, t=0.5)), ("saddle", "stripe", 0.3, None, {})],
    "turtle": [("blotch", "stripe", 0.4, None, dict(size=0.08, t=0.5))],
    "dodo": [("grizzle", "stripe", 0.15, None, {}), ("saddle", "stripe", 0.25, None, {})],
}

# v2 (L4) mammal fur: opaque tapered clumps on the sculpt (zone, count, length, half-width), in
# body-length fractions. One skinned material, so the cards are thin solid wedges, not alpha.
# L4b: every clump is a soft lobe shell (flat, broad, rounded tip, lying close to the skin and
# overlapping like shingles) instead of a spiky 3-sided wedge; CLUMP_TRIS triangles each.
FUR = {
    # L4c: short-coated cats keep only a cheek ruff; the wolf keeps ruff, throat and brush tail
    # (the dorsal/haunch shells read as loose pebbles in game).
    # L4d: the short-coated cats lose the cheek/throat shells (pale rings at play zoom) and the wolf
    # its mane shells (scattered scales); the wolf keeps a small throat ruff and the brush tail.
    "direWolf": [("throat", 18, 0.05, 0.022), ("tail", 36, 0.065, 0.026)],
    "boar": [("crest", 54, 0.06, 0.016), ("cheek", 14, 0.04, 0.016), ("all", 40, 0.035, 0.016)],
    "deer": [("throat", 24, 0.045, 0.02), ("tail", 8, 0.035, 0.018)],
    "mammoth": [("skirt", 220, 0.16, 0.03), ("crest", 44, 0.07, 0.03), ("cheek", 26, 0.055, 0.026), ("tail", 10, 0.05, 0.02)],
    "dodo": [("dorsal", 40, 0.1, 0.05), ("haunch", 16, 0.09, 0.05), ("tailtip", 12, 0.14, 0.05)],
}
# L4b raptor plumage (feather shells in the plume material: dark base, pale tip):
# arm wing feathers, tail-tip fan, neck/head crest and a short back/thigh coat.
PLUME = {
    "compsognathus": [("arm", 16, 0.07, 0.03), ("tailtip", 14, 0.09, 0.035), ("crest_neck", 18, 0.06, 0.03), ("dorsal", 14, 0.05, 0.03)],
    "oviraptor": [("arm", 22, 0.1, 0.04), ("tailtip", 18, 0.12, 0.04), ("crest_neck", 16, 0.06, 0.03), ("dorsal", 14, 0.05, 0.03)],
    # L4d: gallimimus, utahraptor and velociraptor carry no plume shells (opaque shells read as
    # white paper shards in game); their plumage is painted into the colour map (PAINTED_PLUME).
}
CLUMP_TRIS = 14
# L4d painted plumage: (feather rows per body length, row contrast, wing/tail barring strength).
PAINTED_PLUME = {"gallimimus": (34.0, 0.3, 0.45), "utahraptor": (30.0, 0.32, 0.5), "velociraptor": (36.0, 0.28, 0.4)}
# Raptor lane: real feather volume for the three painted-plume species. Ordered, layered feather
# cards (closed ridged blades, CARD_TRIS each, their bases sunk into the skin) laid out on the
# skeleton instead of scattered shells. zone -> (cards per side / per row, length and width as
# body-length fractions, root colour, tip colour, bar strength).
# Raptor2: the folded wing is four stacked tiers, each one card-step further out from the flank,
# shorter and higher than the one under it (primaries under secondaries under two covert rows), so
# the wing shows stepped edges and shadowed roots instead of one painted plate; the tail is a
# rectrix fan under a shorter covert layer, clamped to the catalog length envelope; the neck carries
# a ruff of RUFF_ANGLES rows wrapped round it (not one thin midline mane).
#   primary   = long remiges off the hand (bottom tier, hanging back and down),
#   secondary = remiges along the forearm (tier 2),
#   covert    = greater (tier 3) and lesser (tier 4) coverts over the wing roots,
#   tail      = horizontal rectrix fan (Tail1-5), tailcov = shorter coverts laid over it,
#   ruff      = neck rows (Neck1/Neck2/Head), back = two shingled rows, thigh = trousers.
FEATHERS = {
    # R11-6: white body, dark slate neck and wings, white tail plume, red head.
    "gallimimus": dict(
        primary=(5, 0.15, 0.036, "#2c2f35", "#5a5e66", 0.35), secondary=(6, 0.12, 0.036, "#3e4148", "#6a6e76", 0.3),
        covert=(5, 0.065, 0.03, "#d2cec6", "#8e8a82", 0.2), tail=(8, 0.12, 0.04, "#d8d4cb", "#f0ede6", 0.25),
        tailcov=(6, 0.07, 0.034, "#bcb8ae", "#e8e5de", 0.2), ruff=(6, 0.055, 0.022, "#2e3136", "#4a4e55", 0.15),
        back=(5, 0.07, 0.032, "#c4bfb3", "#e2ded6", 0.2), thigh=(4, 0.075, 0.03, "#c8c4ba", "#ebe8e1", 0.15)),
    # Pale grey-beige with dark dorsal bands that carry into a barred tail fan, dark barred wings.
    "utahraptor": dict(
        primary=(5, 0.15, 0.036, "#3a342e", "#1e1a16", 0.5), secondary=(6, 0.12, 0.036, "#6e675e", "#2e2924", 0.5),
        covert=(5, 0.065, 0.03, "#c4beb1", "#7a7468", 0.25), tail=(8, 0.13, 0.04, "#bdb7aa", "#2e2924", 0.55),
        tailcov=(6, 0.075, 0.034, "#8a8478", "#d0cabe", 0.4), ruff=(5, 0.055, 0.024, "#5e5750", "#bdb7aa", 0.2),
        back=(5, 0.07, 0.034, "#5e574e", "#9a9488", 0.3), thigh=(4, 0.07, 0.03, "#a8a296", "#d6d0c4", 0.2)),
    # Sandy speckled coat, rufous-brown barred wings and tail, dark mane, red face.
    "velociraptor": dict(
        primary=(4, 0.16, 0.04, "#3a2a1e", "#6e4e34", 0.5), secondary=(5, 0.13, 0.04, "#8a6a4a", "#3a2a1e", 0.5),
        covert=(4, 0.07, 0.032, "#c4ae8e", "#6e5a44", 0.25), tail=(7, 0.14, 0.042, "#a08e76", "#2e241c", 0.55),
        tailcov=(5, 0.08, 0.036, "#7a6450", "#c8b498", 0.4), ruff=(4, 0.06, 0.026, "#4a3828", "#8a6e54", 0.2),
        back=(3, 0.075, 0.036, "#5e4c3c", "#9a8268", 0.3), thigh=(3, 0.075, 0.032, "#a08e76", "#cbb89c", 0.2)),
}
CARD_TRIS = 10  # feather_card: 6 roof triangles + 2 quads underneath (triangulated)
# Neck ruff rows: angle round the neck from the dorsal line (radians) and length factor.
RUFF_ANGLES = ((0.0, 1.15), (0.85, 1.0), (-0.85, 1.0), (1.65, 0.8), (-1.65, 0.8))
TAIL_PLUME = 3


def feather_cards(key):
    """Card count per species (both sides, every tier/row); drives the body triangle deduction."""
    spec = FEATHERS.get(key)
    if not spec:
        return 0
    per_side = spec["primary"][0] + spec["secondary"][0] + 2 * spec["covert"][0] + spec["tail"][0] + spec["tailcov"][0]
    per_side += 2 * spec["back"][0] + spec["thigh"][0]
    return 2 * per_side + spec["ruff"][0] * len(RUFF_ANGLES) + TAIL_PLUME


# B2a species keep their recorded seeds; B2b species seed from SEED + 100.
B2A_SPECIES = sorted(k for k, v in SPECIES.items() if v["plan"] in ("theropod", "ceratopsian", "sauropod"))
B2B_SPECIES = sorted(k for k in SPECIES if k not in B2A_SPECIES)


def lerp3(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


# ------------------------------------------------------------------ plan skeletons
# Each plan returns: chains {name: [(key, pos, ra, rb)]} parented to an existing key,
# bones [(name, head_key, tail_key, parent)], tips (claws), eye position.


def theropod(k):
    g, legs = k["girth"], k["legs"]
    dz = 1.06 * (legs - 1)

    def up(p):
        return (p[0], p[1], p[2] + dz)

    spine = [
        ("pelvis", up((0, 0.00, 1.16)), 0.24 * g, 0.29 * g),
        ("belly", up((0, -0.30, 1.13)), 0.26 * g, 0.33 * g),
        ("chest", up((0, -0.56, 1.19)), 0.23 * g, 0.31 * g),
    ]
    chest = Vector(spine[2][1])
    nf, hs, sn = k["neck"], k["head"], k["snout"]
    neck_a = chest + (Vector((0, -0.22, 0.17)) * nf)
    head_back = chest + (Vector((0, -0.45, 0.50)) * nf)
    neck_b = (neck_a + head_back) / 2 + Vector((0, 0.02, 0.0))
    hb = head_back
    head = hb + Vector((0, -0.14, -0.01)) * hs
    snout = hb + Vector((0, -0.14 - 0.20 * sn, -0.03)) * hs
    nose = hb + Vector((0, -0.14 - 0.35 * sn, -0.055)) * hs
    jaw_a = hb + Vector((0, -0.10, -0.10)) * hs
    jaw_tip = hb + Vector((0, -0.14 - 0.31 * sn, -0.135)) * hs
    # L4b: neckr/headw thin the neck and narrow the skull (lean raptors); bones do not move.
    nr, hw = k.get("neckr", 1.0), k.get("headw", 1.0)
    neck = [
        ("neck_a", tuple(neck_a), 0.14 * g * max(hs, 1) ** 0.5 * nr, 0.16 * g * max(hs, 1) ** 0.5 * nr),
        ("neck_b", tuple(neck_b), 0.11 * g * hs ** 0.6 * nr, 0.12 * g * hs ** 0.6 * nr),
        ("head_back", tuple(hb), 0.13 * hs * hw, 0.13 * hs),
        ("head", tuple(head), 0.115 * hs * hw, 0.11 * hs),
        ("snout", tuple(snout), 0.085 * hs * hw, 0.065 * hs),
        ("nose", tuple(nose), 0.05 * hs * hw, 0.042 * hs),
    ]
    jaw = [("jaw_a", tuple(jaw_a), 0.09 * hs, 0.055 * hs), ("jaw_tip", tuple(jaw_tip), 0.04 * hs, 0.026 * hs)]
    tl = k["tail"]
    pel = Vector(spine[0][1])
    tail = []
    for i, (dy, dzz, ra, rb) in enumerate([(0.40, -0.03, 0.20, 0.24), (0.82, -0.08, 0.14, 0.17), (1.25, -0.16, 0.09, 0.11), (1.65, -0.23, 0.05, 0.06), (2.05, -0.30, 0.022, 0.022)]):
        tail.append((f"tail{i + 1}", tuple(pel + Vector((0, dy * tl, dzz * tl))), ra * g, rb * g))
    chains = {"pelvis": [], "spine": spine, "neck": neck, "jaw": jaw, "tail": tail}
    leg_pts = [("hip", (0.18, 0.02, 1.06), 0.16, 0.20), ("knee", (0.25, -0.16, 0.66), 0.10, 0.11), ("ankle", (0.22, 0.14, 0.25), 0.055, 0.055), ("foot", (0.22, -0.04, 0.06), 0.05, 0.03)]
    toes = [(0.22, -0.27, 0.03), (0.14, -0.21, 0.03), (0.30, -0.21, 0.03)]
    am = k["arms"]
    tips = []
    limbs = []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = []
        for name, (x, y, z), ra, rb in leg_pts:
            zz = z * legs if name != "hip" else z + dz
            leg.append((f"{name}{sfx}", (x * side * g, y, zz), ra * g * (1 if name == "hip" else legs ** 0.3), rb * g))
        foot = Vector(leg[-1][1])
        toe_keys = []
        for i, (x, y, z) in enumerate(toes):
            p = (x * side * g, foot.y + (y + 0.04) * legs ** 0.5, z)
            toe_keys.append((f"toe{i}{sfx}", p, 0.028 * g, 0.02 * g))
            tips.append(("toe", Vector(p), "Toe" + sfx if i == 0 else "Foot" + sfx))
        sh = chest + Vector((0.16 * side * g, -0.04, -0.07))
        el = sh + Vector((0.07 * side, -0.07, -0.20)) * am
        wr = el + Vector((-0.02 * side, -0.15, -0.09)) * am
        arm = [(f"shoulder{sfx}", tuple(sh), 0.065 * g * am ** 0.5, 0.065 * g * am ** 0.5), (f"elbow{sfx}", tuple(el), 0.048 * am, 0.048 * am), (f"wrist{sfx}", tuple(wr), 0.032 * am, 0.03 * am)]
        fingers = []
        for i, dx in enumerate((-0.03, 0.03)):
            p = wr + Vector((dx * side, -0.09, -0.06)) * am
            fingers.append((f"finger{i}{sfx}", tuple(p), 0.014 * am, 0.012 * am))
            tips.append(("finger", p, "Arm" + sfx))
        limbs.append((sfx, leg, toe_keys, arm, fingers))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck1", "chest", "neck_a", "Chest"),
        ("Neck2", "neck_a", "head_back", "Neck1"),
        ("Head", "head_back", "nose", "Neck2"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
        ("Tail5", "tail4", "tail5", "Tail4"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"Toe{sfx}", f"foot{sfx}", f"toe0{sfx}", f"Foot{sfx}"),
            (f"Arm{sfx}", f"shoulder{sfx}", f"wrist{sfx}", "Chest"),
        ]
    eye = hb + Vector((0.10 * hs, -0.12 * hs, 0.045 * hs))
    nostril = nose + Vector((0.028 * hs, -0.02 * hs, 0.02 * hs))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis")


def ceratopsian(k):
    g, legs = k["girth"], k["legs"]
    spine = [
        ("pelvis", (0, 0.25, 1.15), 0.36 * g, 0.40 * g),
        ("belly", (0, -0.20, 1.12), 0.44 * g, 0.46 * g),
        ("chest", (0, -0.65, 1.06), 0.38 * g, 0.42 * g),
    ]
    neck = [
        ("neck_a", (0, -0.95, 1.00), 0.26 * g, 0.28 * g),
        ("head_back", (0, -1.15, 0.98), 0.25, 0.26),
        ("head", (0, -1.38, 0.90), 0.19, 0.20),
        ("snout", (0, -1.58, 0.82), 0.12, 0.12),
        ("nose", (0, -1.76, 0.74), 0.055, 0.065),
    ]
    jaw = [("jaw_a", (0, -1.34, 0.74), 0.15, 0.09), ("jaw_tip", (0, -1.66, 0.635), 0.05, 0.035)]
    tail = [
        ("tail1", (0, 0.65, 1.05), 0.24 * g, 0.27 * g),
        ("tail2", (0, 1.10, 0.92), 0.15 * g, 0.17 * g),
        ("tail3", (0, 1.55, 0.78), 0.08 * g, 0.09 * g),
        ("tail4", (0, 2.00, 0.65), 0.03, 0.03),
    ]
    tips, limbs = [], []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = [
            (f"hip{sfx}", (0.30 * side * g, 0.30, 0.95), 0.22 * g, 0.26 * g),
            (f"knee{sfx}", (0.34 * side * g, 0.15, 0.55 * legs), 0.14, 0.15),
            (f"ankle{sfx}", (0.33 * side * g, 0.30, 0.20 * legs), 0.10, 0.10),
            (f"foot{sfx}", (0.33 * side * g, 0.20, 0.05), 0.11, 0.06),
        ]
        toes = []
        for i, dx in enumerate((-0.07, 0.0, 0.07)):
            p = (0.33 * side * g + dx * side, 0.06, 0.03)
            toes.append((f"toe{i}{sfx}", p, 0.035, 0.025))
            tips.append(("hoof", Vector(p), "Foot" + sfx))
        arm = [
            (f"shoulder{sfx}", (0.30 * side * g, -0.62, 0.85), 0.17 * g, 0.18 * g),
            (f"elbow{sfx}", (0.37 * side * g, -0.58, 0.48 * legs), 0.12, 0.12),
            (f"wrist{sfx}", (0.35 * side * g, -0.64, 0.15 * legs), 0.09, 0.09),
            (f"hand{sfx}", (0.35 * side * g, -0.70, 0.04), 0.095, 0.05),
        ]
        fingers = []
        for i, dx in enumerate((-0.06, 0.0, 0.06)):
            p = (0.35 * side * g + dx * side, -0.80, 0.03)
            fingers.append((f"finger{i}{sfx}", p, 0.03, 0.022))
            tips.append(("hoof", Vector(p), "Forearm" + sfx))
        limbs.append((sfx, leg, toes, arm, fingers))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck", "chest", "head_back", "Chest"),
        ("Head", "head_back", "nose", "Neck"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    eye = Vector((0.17, -1.30, 1.02))
    nostril = Vector((0.04, -1.66, 0.84))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis")


def sauropod(k):
    g = k["girth"]
    spine = [
        ("pelvis", (0, 2.0, 8.6), 1.7 * g, 1.9 * g),
        ("belly", (0, 0.0, 8.8), 2.1 * g, 2.3 * g),
        ("chest", (0, -2.2, 9.6), 1.9 * g, 2.2 * g),
    ]
    neck = [
        ("n1", (0, -3.6, 11.4), 1.1, 1.2),
        ("n2", (0, -4.5, 13.6), 0.85, 0.9),
        ("n3", (0, -5.1, 15.8), 0.7, 0.7),
        ("n4", (0, -5.5, 18.0), 0.58, 0.58),
        ("n5", (0, -5.8, 20.0), 0.5, 0.5),
        ("n6", (0, -6.1, 21.6), 0.45, 0.45),
        ("head_back", (0, -6.4, 22.55), 0.52, 0.55),
        ("head", (0, -7.15, 22.6), 0.44, 0.42),
        ("nose", (0, -7.9, 22.45), 0.3, 0.27),
    ]
    jaw = [("jaw_a", (0, -7.0, 22.1), 0.36, 0.2), ("jaw_tip", (0, -7.8, 22.12), 0.22, 0.13)]
    tail = [
        ("tail1", (0, 3.2, 8.1), 1.25 * g, 1.4 * g),
        ("tail2", (0, 4.5, 7.4), 0.85 * g, 0.95 * g),
        ("tail3", (0, 5.9, 6.6), 0.55 * g, 0.6 * g),
        ("tail4", (0, 7.4, 5.8), 0.3, 0.3),
        ("tail5", (0, 9.0, 5.0), 0.12, 0.12),
    ]
    tips, limbs = [], []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = [
            (f"hip{sfx}", (1.4 * side, 2.2, 7.6), 1.0, 1.2),
            (f"knee{sfx}", (1.5 * side, 1.9, 4.4), 0.75, 0.75),
            (f"ankle{sfx}", (1.5 * side, 2.2, 1.3), 0.6, 0.6),
            (f"foot{sfx}", (1.5 * side, 1.9, 0.35), 0.72, 0.4),
        ]
        arm = [
            (f"shoulder{sfx}", (1.5 * side, -2.4, 8.6), 1.0, 1.05),
            (f"elbow{sfx}", (1.6 * side, -2.2, 5.0), 0.7, 0.7),
            (f"wrist{sfx}", (1.6 * side, -2.5, 1.6), 0.55, 0.55),
            (f"hand{sfx}", (1.6 * side, -2.6, 0.35), 0.62, 0.38),
        ]
        for i, dx in enumerate((-0.35, 0.0, 0.35)):
            tips.append(("nail", Vector((1.5 * side + dx, 1.3, 0.2)), "Foot" + sfx))
            tips.append(("nail", Vector((1.6 * side + dx, -3.05, 0.2)), "Forearm" + sfx))
        limbs.append((sfx, leg, [], arm, []))
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck1", "chest", "n1", "Chest"),
        ("Neck2", "n1", "n2", "Neck1"),
        ("Neck3", "n2", "n3", "Neck2"),
        ("Neck4", "n3", "n4", "Neck3"),
        ("Neck5", "n4", "n5", "Neck4"),
        ("Neck6", "n5", "head_back", "Neck5"),
        ("Head", "head_back", "nose", "Neck6"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
        ("Tail5", "tail4", "tail5", "Tail4"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    eye = Vector((0.38, -6.85, 22.85))
    nostril = Vector((0.12, -7.0, 23.25))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=nostril, root_key="pelvis", base_length=16.9)


PLANS = {"theropod": theropod, "ceratopsian": ceratopsian, "sauropod": sauropod}
PLAN_BONES = {"theropod": 22, "ceratopsian": 20, "sauropod": 26}


# ------------------------------------------------------------------ B2b plans
# Same contract as above plus optional: extras [(parent_key, chain)] (extra skin branches),
# extra_points {key: pos} (bone ends off the skin graph: ears, wing tips, tusk tips),
# eye_r (eye radius, unit space) and span (points included in the length fit).


def _v(*p):
    return Vector(p)


def _quad_bones(neck_bones, tail_n, hand=False, ear=False):
    bones = [("Root", "pelvis", "@up", None), ("Spine", "pelvis", "belly", "Root"), ("Chest", "belly", "chest", "Spine")]
    bones += neck_bones
    prev = "pelvis"
    for i in range(1, tail_n + 1):
        bones.append((f"Tail{i}", prev, f"tail{i}", "Root" if i == 1 else f"Tail{i - 1}"))
        prev = f"tail{i}"
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
        ]
        if hand:
            bones += [
                (f"Forearm{sfx}", f"elbow{sfx}", f"wrist{sfx}", f"UpperArm{sfx}"),
                (f"Hand{sfx}", f"wrist{sfx}", f"hand{sfx}", f"Forearm{sfx}"),
            ]
        else:
            bones.append((f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"))
        if ear:
            bones.append((f"Ear{sfx}", f"ear_base{sfx}", f"ear_tip{sfx}", "Head"))
    return bones


def _limbs(hind, fore, tips_kind, toes_per_foot, foot_bone="Foot", hand_bone="Forearm"):
    """hind/fore: [(name, (x, y, z), ra, rb)] for the +X side; mirrored for R."""
    limbs, tips = [], []
    for side, sfx in ((1, "L"), (-1, "R")):
        leg = [(f"{n}{sfx}", (x * side, y, z), ra, rb) for n, (x, y, z), ra, rb in hind]
        arm = [(f"{n}{sfx}", (x * side, y, z), ra, rb) for n, (x, y, z), ra, rb in fore]
        for chain, bone in ((leg, foot_bone), (arm, hand_bone)):
            end = Vector(chain[-1][1])
            spread = chain[-1][2] * 0.8
            for i in range(toes_per_foot):
                dx = 0 if toes_per_foot == 1 else -spread + 2 * spread * i / (toes_per_foot - 1)
                # Subsurf rounds the skin end up and in: sit the tip on that rounded front edge.
                r = chain[-1][2]
                tips.append((tips_kind, end + Vector((dx * side, -r * 0.55, r * 0.15)), bone + sfx))
        limbs.append((sfx, leg, [], arm, []))
    return limbs, tips


def armored(k):
    g, hind, fore, flat = k["girth"], k["hind"], k["fore"], k.get("flat", 1.0)
    hip, sh = 1.25 * hind, 0.95 * fore
    hw = 1.6 if flat < 1 else 1.0
    spine = [
        ("pelvis", (0, 0.3, hip), 0.38 * g, 0.42 * g * flat),
        ("belly", (0, -0.2, (hip + sh) / 2 + 0.05), 0.44 * g, 0.48 * g * flat),
        ("chest", (0, -0.65, sh + 0.1), 0.34 * g, 0.38 * g * flat),
    ]
    neck = [
        ("neck_a", (0, -0.95, sh - 0.05), 0.2 * hw, 0.22),
        ("head_back", (0, -1.15, sh - 0.16), 0.15 * hw, 0.15),
        ("head", (0, -1.28, sh - 0.2), 0.13 * hw, 0.12),
        ("snout", (0, -1.4, sh - 0.25), 0.09 * hw, 0.08),
        ("nose", (0, -1.5, sh - 0.29), 0.06 * hw, 0.05),
    ]
    jaw = [("jaw_a", (0, -1.25, sh - 0.28), 0.08 * hw, 0.05), ("jaw_tip", (0, -1.45, sh - 0.34), 0.04 * hw, 0.03)]
    droop = 1.0 if flat >= 1 else 0.35
    tail = [
        ("tail1", (0, 0.8, hip - 0.05 * droop), 0.28 * g, 0.3 * g * flat),
        ("tail2", (0, 1.3, hip - 0.25 * droop), 0.18 * g, 0.2 * g * flat),
        ("tail3", (0, 1.8, hip - 0.45 * droop), 0.1 * g, 0.11 * g),
        ("tail4", (0, 2.3, hip - 0.6 * droop), 0.045, 0.045),
    ]
    x = 0.3 * g
    hind_pts = [("hip", (x, 0.3, hip - 0.25), 0.2, 0.24), ("knee", (x * 1.1, 0.42, hip * 0.55), 0.14, 0.15), ("ankle", (x * 1.07, 0.3, hip * 0.18), 0.1, 0.1), ("foot", (x * 1.07, 0.2, 0.05), 0.12, 0.06)]
    fore_pts = [("shoulder", (x * 0.95, -0.62, sh - 0.15), 0.16, 0.18), ("elbow", (x * 1.1, -0.55, sh * 0.5), 0.11, 0.11), ("wrist", (x * 1.07, -0.62, sh * 0.15), 0.08, 0.08), ("hand", (x * 1.07, -0.7, 0.04), 0.09, 0.05)]
    limbs, tips = _limbs(hind_pts, fore_pts, "hoof", 3)
    bones = _quad_bones([("Neck", "chest", "head_back", "Chest"), ("Head", "head_back", "nose", "Neck"), ("Jaw", "head_back", "jaw_tip", "Head")], 4)
    eye = Vector((0.11 * hw, -1.24, sh - 0.13))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=eye, nostril=Vector((0.035 * hw, -1.5, sh - 0.25)), root_key="pelvis", eye_r=0.035)


def hadrosaur(k):
    g = k["girth"]
    spine = [("pelvis", (0, 0.2, 1.55), 0.3 * g, 0.36 * g), ("belly", (0, -0.25, 1.45), 0.34 * g, 0.4 * g), ("chest", (0, -0.7, 1.35), 0.28 * g, 0.33 * g)]
    neck = [
        ("neck_a", (0, -0.95, 1.55), 0.17, 0.2),
        ("head_back", (0, -1.12, 1.9), 0.12, 0.14),
        ("head", (0, -1.26, 1.88), 0.11, 0.12),
        ("snout", (0, -1.42, 1.79), 0.085, 0.08),
        ("nose", (0, -1.57, 1.72), 0.09, 0.05),
    ]
    jaw = [("jaw_a", (0, -1.22, 1.78), 0.08, 0.05), ("jaw_tip", (0, -1.52, 1.68), 0.06, 0.03)]
    tail = []
    for i, (dy, z, ra, rb) in enumerate([(0.6, 1.5, 0.24, 0.28), (1.05, 1.42, 0.17, 0.2), (1.5, 1.32, 0.11, 0.13), (1.95, 1.2, 0.06, 0.07), (2.35, 1.1, 0.025, 0.025)]):
        tail.append((f"tail{i + 1}", (0, 0.2 + dy, z), ra * g, rb * g))
    x = 0.22 * g
    hind_pts = [("hip", (x, 0.2, 1.35), 0.2, 0.26), ("knee", (x * 1.2, 0.0, 0.85), 0.14, 0.15), ("ankle", (x * 1.12, 0.32, 0.32), 0.08, 0.08), ("foot", (x * 1.12, 0.12, 0.05), 0.09, 0.05)]
    fore_pts = [("shoulder", (x * 0.9, -0.68, 1.2), 0.08, 0.09), ("elbow", (x * 1.1, -0.72, 0.72), 0.06, 0.06), ("wrist", (x * 1.05, -0.78, 0.25), 0.045, 0.045), ("hand", (x * 1.05, -0.84, 0.04), 0.05, 0.03)]
    limbs, tips = _limbs(hind_pts, fore_pts, "hoof", 3)
    neck_bones = [
        ("Neck1", "chest", "neck_a", "Chest"),
        ("Neck2", "neck_a", "head_back", "Neck1"),
        ("Head", "head_back", "nose", "Neck2"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
    ]
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=_quad_bones(neck_bones, 5), tips=tips, eye=Vector((0.1, -1.24, 1.93)), nostril=Vector((0.05, -1.52, 1.76)), root_key="pelvis", eye_r=0.028, extra_points={"crest_tip": Vector((0, -0.6, 2.45))})


def mammal(k):
    g, legs, nf, hs, sn = k["girth"], k["legs"], k["neck"], k["head"], k["snout"]
    up, lr, mr, cr = k.get("headup", 0.6), k.get("legr", 1.0), k.get("maner", 1.0), k.get("chestr", 1.0)
    hip, sh = 0.72 * legs, 0.74 * legs
    spine = [
        ("pelvis", (0, 0.32, hip + 0.04), 0.15 * g, 0.17 * g),
        ("belly", (0, 0.0, hip + 0.01), 0.17 * g, 0.19 * g),
        ("chest", (0, -0.3, sh + 0.03), 0.17 * g * cr * mr ** 0.5, 0.21 * g * cr * mr ** 0.5),
    ]
    ch = Vector(spine[2][1])
    na = ch + Vector((0, -0.16, 0.08 + 0.08 * up)) * nf
    hb = ch + Vector((0, -0.3, 0.16 + 0.22 * up)) * nf
    neck = [
        ("neck_a", tuple(na), 0.12 * g * mr, 0.14 * g * mr),
        ("head_back", tuple(hb), 0.095 * hs, 0.1 * hs),
        ("head", tuple(hb + Vector((0, -0.1, -0.01)) * hs), 0.09 * hs, 0.085 * hs),
        ("snout", tuple(hb + Vector((0, -0.1 - 0.1 * sn, -0.04)) * hs), 0.06 * hs, 0.055 * hs),
        ("nose", tuple(hb + Vector((0, -0.1 - 0.19 * sn, -0.06)) * hs), 0.04 * hs, 0.035 * hs),
    ]
    jaw = [("jaw_a", tuple(hb + Vector((0, -0.08, -0.08)) * hs), 0.06 * hs, 0.035 * hs), ("jaw_tip", tuple(hb + Vector((0, -0.1 - 0.16 * sn, -0.11)) * hs), 0.03 * hs, 0.02 * hs)]
    tl, tr, tu = k.get("tail", 1.0), k.get("tailr", 1.0), k.get("tailup", 0)
    pel = Vector(spine[0][1])
    tail = []
    for i, (dy, dz, r) in enumerate([(0.14, 0.0, 0.05), (0.32, -0.1 + 0.2 * tu, 0.045), (0.5, -0.26 + 0.35 * tu, 0.03)]):
        tail.append((f"tail{i + 1}", tuple(pel + Vector((0, dy * tl, dz * tl))), r * tr * g, r * tr * g))
    x = 0.11 * g
    # v2: digitigrade - stifle forward, hock high and back, long slanted metatarsal onto the toes.
    hind_pts = [("hip", (x, 0.3, hip - 0.06), 0.12 * g, 0.14 * g), ("knee", (x * 1.1, 0.14, hip * 0.62), 0.07 * lr, 0.075 * lr), ("ankle", (x, 0.42, hip * 0.33), 0.04 * lr, 0.045 * lr), ("foot", (x, 0.35, 0.035), 0.04 * lr, 0.03)]
    fore_pts = [("shoulder", (x, -0.28, sh - 0.08), 0.11 * g, 0.13 * g), ("elbow", (x * 1.1, -0.2, sh * 0.55), 0.062 * lr, 0.065 * lr), ("wrist", (x, -0.27, sh * 0.17), 0.038 * lr, 0.04 * lr), ("hand", (x, -0.3, 0.035), 0.04 * lr, 0.03)]
    kind = k.get("foot", "paw")
    limbs, tips = _limbs(hind_pts, fore_pts, kind, 2 if kind == "hoof" else 4, "Foot", "Hand")
    neck_bones = [
        ("Neck1", "chest", "neck_a", "Chest"),
        ("Neck2", "neck_a", "head_back", "Neck1"),
        ("Head", "head_back", "nose", "Neck2"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
    ]
    er = k.get("ear", 1.0)
    extra = {}
    for side, sfx in ((1, "L"), (-1, "R")):
        base = hb + Vector((0.055 * side, 0.01, 0.07)) * hs
        extra["ear_base" + sfx] = base
        extra["ear_tip" + sfx] = base + Vector((0.025 * side, 0.03, 0.1 * er)) * hs
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=_quad_bones(neck_bones, 3, hand=True, ear=True), tips=tips, eye=hb + Vector((0.062, -0.075, 0.03)) * hs, nostril=Vector(neck[4][1]) + Vector((0.018, -0.02, 0.012)) * hs, root_key="pelvis", eye_r=0.022 * hs, extra_points=extra)


def elephant(k):
    g, hump, ear = k["girth"], k["hump"], k["ear"]
    spine = [
        ("pelvis", (0, 0.55, 1.85), 0.55 * g, 0.6 * g),
        ("belly", (0, 0.0, 1.82), 0.66 * g, 0.72 * g),
        ("chest", (0, -0.62, 1.95 + 0.15 * hump), 0.6 * g, 0.7 * g),
    ]
    neck = [
        ("neck_a", (0, -0.98, 2.1 + 0.25 * hump), 0.44, 0.5),
        ("head_back", (0, -1.18, 2.25 + 0.2 * hump), 0.42, 0.48),
        ("head", (0, -1.38, 2.18 + 0.05 * hump), 0.38, 0.4),
        ("nose", (0, -1.55, 1.92), 0.24, 0.22),
    ]
    jaw = [("jaw_a", (0, -1.32, 1.78), 0.16, 0.1), ("jaw_tip", (0, -1.45, 1.7), 0.08, 0.06)]
    trunk = [("t1", (0, -1.66, 1.5), 0.16, 0.16), ("t2", (0, -1.7, 1.05), 0.12, 0.12), ("t3", (0, -1.68, 0.62), 0.09, 0.09), ("t4", (0, -1.6, 0.34), 0.065, 0.065)]
    tail = [("tail1", (0, 1.05, 1.65), 0.08, 0.08), ("tail2", (0, 1.2, 1.05), 0.045, 0.045)]
    x = 0.42 * g
    # v2: tapered pillar legs (fat upper leg, slim knee/ankle) ending on round flat pads.
    hind_pts = [("hip", (x, 0.55, 1.55), 0.3, 0.34), ("knee", (x, 0.52, 0.95), 0.2, 0.21), ("ankle", (x, 0.55, 0.36), 0.17, 0.17), ("foot", (x, 0.5, 0.12), 0.19, 0.1)]
    fore_pts = [("shoulder", (x * 1.05, -0.62, 1.6), 0.3, 0.34), ("elbow", (x * 1.07, -0.58, 1.0), 0.21, 0.22), ("wrist", (x * 1.07, -0.62, 0.36), 0.17, 0.17), ("hand", (x * 1.07, -0.64, 0.12), 0.19, 0.1)]
    limbs, tips = _limbs(hind_pts, fore_pts, "nailbig", 4)
    neck_bones = [
        ("Neck", "chest", "head_back", "Chest"),
        ("Head", "head_back", "nose", "Neck"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Trunk1", "nose", "t1", "Head"),
        ("Trunk2", "t1", "t2", "Trunk1"),
        ("Trunk3", "t2", "t3", "Trunk2"),
        ("Trunk4", "t3", "t4", "Trunk3"),
    ]
    extra = {}
    for side, sfx in ((1, "L"), (-1, "R")):
        extra["ear_base" + sfx] = Vector((0.36 * side, -1.1, 2.3 + 0.1 * hump))
        extra["ear_tip" + sfx] = Vector((0.36 * side + 0.26 * ear * side, -0.95, 2.3 - 0.55 * ear))
    tusk = k.get("tusk", 0.6)
    extra["tusk_tip"] = Vector((0, -1.55 - 0.75 * tusk, 1.5))
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, extras=[("nose", trunk)], limbs=limbs, bones=_quad_bones(neck_bones, 2, ear=True), tips=tips, eye=Vector((0.31, -1.34, 2.22)), nostril=Vector((0.03, -1.6, 0.27)), root_key="pelvis", eye_r=0.045, extra_points=extra)


def crocodilian(k):
    g = k["girth"]
    spine = [("pelvis", (0, 0.3, 0.3), 0.24 * g, 0.16 * g), ("belly", (0, -0.1, 0.29), 0.29 * g, 0.18 * g), ("chest", (0, -0.5, 0.29), 0.24 * g, 0.16 * g)]
    neck = [
        ("neck_a", (0, -0.75, 0.29), 0.17, 0.12),
        ("head_back", (0, -0.92, 0.29), 0.16, 0.11),
        ("head", (0, -1.1, 0.27), 0.12, 0.075),
        ("snout", (0, -1.35, 0.24), 0.085, 0.05),
        ("nose", (0, -1.6, 0.22), 0.06, 0.04),
    ]
    jaw = [("jaw_a", (0, -1.0, 0.2), 0.13, 0.05), ("jaw_tip", (0, -1.57, 0.17), 0.05, 0.025)]
    tail = [("tail1", (0, 0.75, 0.29), 0.2 * g, 0.15 * g), ("tail2", (0, 1.3, 0.26), 0.13 * g, 0.12 * g), ("tail3", (0, 1.85, 0.22), 0.07, 0.08), ("tail4", (0, 2.4, 0.19), 0.025, 0.03)]
    hind_pts = [("hip", (0.2, 0.3, 0.24), 0.1, 0.09), ("knee", (0.4, 0.33, 0.19), 0.06, 0.06), ("foot", (0.44, 0.2, 0.03), 0.06, 0.03)]
    fore_pts = [("shoulder", (0.17, -0.5, 0.24), 0.08, 0.07), ("elbow", (0.33, -0.47, 0.17), 0.05, 0.05), ("hand", (0.36, -0.6, 0.03), 0.05, 0.025)]
    limbs, tips = _limbs(hind_pts, fore_pts, "paw", 4, "Shin", "Forearm")
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "belly", "Root"),
        ("Chest", "belly", "chest", "Spine"),
        ("Neck", "chest", "head_back", "Chest"),
        ("Head", "head_back", "nose", "Neck"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail1", "pelvis", "tail1", "Root"),
        ("Tail2", "tail1", "tail2", "Tail1"),
        ("Tail3", "tail2", "tail3", "Tail2"),
        ("Tail4", "tail3", "tail4", "Tail3"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"foot{sfx}", f"Thigh{sfx}"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Chest"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=Vector((0.08, -1.0, 0.37)), nostril=Vector((0.03, -1.6, 0.25)), root_key="pelvis", eye_r=0.03)


def turtle(k):
    spine = [("pelvis", (0, 0.18, 0.3), 0.24, 0.16), ("belly", (0, 0.0, 0.3), 0.3, 0.18), ("chest", (0, -0.2, 0.3), 0.25, 0.16)]
    neck = [("neck_a", (0, -0.42, 0.27), 0.075, 0.07), ("head_back", (0, -0.56, 0.3), 0.07, 0.068), ("head", (0, -0.63, 0.3), 0.068, 0.062), ("nose", (0, -0.72, 0.28), 0.04, 0.035)]
    jaw = [("jaw_a", (0, -0.6, 0.26), 0.05, 0.03), ("jaw_tip", (0, -0.7, 0.25), 0.025, 0.02)]
    tail = [("tail1", (0, 0.5, 0.24), 0.03, 0.03)]
    hind_pts = [("hip", (0.18, 0.24, 0.22), 0.07, 0.06), ("foot", (0.32, 0.36, 0.03), 0.06, 0.03)]
    fore_pts = [("shoulder", (0.18, -0.22, 0.24), 0.07, 0.06), ("elbow", (0.32, -0.28, 0.14), 0.055, 0.05), ("hand", (0.38, -0.38, 0.03), 0.06, 0.025)]
    limbs, tips = _limbs(hind_pts, fore_pts, "paw", 3, "Thigh", "Forearm")
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Spine", "pelvis", "chest", "Root"),
        ("Neck", "chest", "head_back", "Spine"),
        ("Head", "head_back", "nose", "Neck"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail", "pelvis", "tail1", "Root"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"foot{sfx}", "Root"),
            (f"UpperArm{sfx}", f"shoulder{sfx}", f"elbow{sfx}", "Spine"),
            (f"Forearm{sfx}", f"elbow{sfx}", f"hand{sfx}", f"UpperArm{sfx}"),
        ]
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=Vector((0.05, -0.64, 0.33)), nostril=Vector((0.012, -0.73, 0.3)), root_key="pelvis", eye_r=0.014)


def bird(k):
    spine = [("pelvis", (0, 0.12, 0.55), 0.26, 0.26), ("belly", (0, -0.04, 0.55), 0.3, 0.3), ("chest", (0, -0.2, 0.6), 0.27, 0.27)]
    neck = [("neck_a", (0, -0.3, 0.8), 0.13, 0.13), ("head_back", (0, -0.33, 0.97), 0.12, 0.12), ("head", (0, -0.41, 0.98), 0.11, 0.11), ("nose", (0, -0.48, 0.95), 0.07, 0.07)]
    jaw = [("jaw_a", (0, -0.42, 0.92), 0.05, 0.04), ("jaw_tip", (0, -0.62, 0.86), 0.03, 0.02)]
    tail = [("tail1", (0, 0.42, 0.66), 0.08, 0.08)]
    hind_pts = [("hip", (0.13, 0.05, 0.42), 0.09, 0.1), ("knee", (0.15, 0.0, 0.28), 0.05, 0.05), ("ankle", (0.14, 0.05, 0.13), 0.035, 0.035), ("foot", (0.14, -0.03, 0.02), 0.035, 0.025)]
    fore_pts = [("shoulder", (0.24, -0.14, 0.66), 0.05, 0.05), ("wingtip", (0.29, 0.14, 0.56), 0.035, 0.035)]
    limbs, tips = _limbs(hind_pts, fore_pts, "toe", 3, "Foot", "Wing")
    tips = [t for t in tips if not t[2].startswith("Wing")]
    bones = [
        ("Root", "pelvis", "@up", None),
        ("Neck1", "chest", "neck_a", "Root"),
        ("Neck2", "neck_a", "head_back", "Neck1"),
        ("Head", "head_back", "nose", "Neck2"),
        ("Jaw", "head_back", "jaw_tip", "Head"),
        ("Tail", "pelvis", "tail1", "Root"),
    ]
    for sfx in ("L", "R"):
        bones += [
            (f"Thigh{sfx}", f"hip{sfx}", f"knee{sfx}", "Root"),
            (f"Shin{sfx}", f"knee{sfx}", f"ankle{sfx}", f"Thigh{sfx}"),
            (f"Foot{sfx}", f"ankle{sfx}", f"foot{sfx}", f"Shin{sfx}"),
            (f"Wing{sfx}", f"shoulder{sfx}", f"wingtip{sfx}", "Root"),
        ]
    return dict(spine=spine, neck=neck, jaw=jaw, tail=tail, limbs=limbs, bones=bones, tips=tips, eye=Vector((0.085, -0.4, 1.0)), nostril=Vector((0.03, -0.55, 0.95)), root_key="pelvis", eye_r=0.022)


PLANS.update(armored=armored, hadrosaur=hadrosaur, mammal=mammal, elephant=elephant, crocodilian=crocodilian, turtle=turtle, bird=bird)
PLAN_BONES.update(armored=20, hadrosaur=22, mammal=24, elephant=24, crocodilian=18, turtle=12, bird=14)


# ------------------------------------------------------------------ geometry


def scaled(sk, s):
    """Scale every position and radius of a skeleton dict by s (final stud scale)."""

    def chain(c):
        return [(n, tuple(Vector(p) * s), ra * s, rb * s) for n, p, ra, rb in c]

    out = dict(sk)
    for key in ("spine", "neck", "jaw", "tail"):
        out[key] = chain(sk[key])
    out["extras"] = [(parent, chain(c)) for parent, c in sk.get("extras", [])]
    out["extra_points"] = {n: Vector(p) * s for n, p in sk.get("extra_points", {}).items()}
    out["limbs"] = [(sfx, chain(l), chain(t), chain(a), chain(f)) for sfx, l, t, a, f in sk["limbs"]]
    out["tips"] = [(kind, p * s, bone) for kind, p, bone in sk["tips"]]
    out["eye"], out["nostril"] = sk["eye"] * s, sk["nostril"] * s
    return out


def build_body(name, sk, target):
    me = bpy.data.meshes.new(name)
    obj = C.link(bpy.data.objects.new(name, me))
    bm = bmesh.new()
    keys, radii, idx = [], [], {}

    def add(key, pos, ra, rb):
        v = bm.verts.new(Vector(pos))
        idx[key] = v
        keys.append(key)
        radii.append((ra, rb))
        return v

    def run(chain, start):
        prev = start
        for n, p, ra, rb in chain:
            v = add(n, p, ra, rb)
            if prev is not None:
                bm.edges.new((prev, v))
            prev = v
        return prev

    # Tail (reversed) -> pelvis -> belly -> chest -> neck -> head; jaw branches at head_back.
    tail_end = None
    for n, p, ra, rb in reversed(sk["tail"]):
        v = add(n, p, ra, rb)
        if tail_end is not None:
            bm.edges.new((tail_end, v))
        tail_end = v
    last = run(sk["spine"], tail_end)
    run(sk["neck"], last)
    run(sk["jaw"], idx["head_back"])
    for parent, chain in sk.get("extras", []):
        run(chain, idx[parent])
    for sfx, leg, toes, arm, fingers in sk["limbs"]:
        foot = run(leg, idx["pelvis"])
        for n, p, ra, rb in toes:
            v = add(n, p, ra, rb)
            bm.edges.new((foot, v))
        wrist = run(arm, idx["chest"])
        for n, p, ra, rb in fingers:
            v = add(n, p, ra, rb)
            bm.edges.new((wrist, v))
    bm.to_mesh(me)
    bm.free()
    obj.modifiers.new("skin", "SKIN")
    for i, r in enumerate(radii):
        me.skin_vertices[0].data[i].radius = r
        me.skin_vertices[0].data[i].use_root = keys[i] == sk["root_key"]
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = 2
    C.apply_modifiers(obj)
    tex = bpy.data.textures.new("lump", "CLOUDS")
    tex.noise_scale = 0.08 * sk["scale"]
    disp = obj.modifiers.new("disp", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.008 * sk["scale"]
    C.apply_modifiers(obj)
    C.decimate_to(obj, target)
    C.finish_mesh(obj)
    return obj, {k: Vector(v) for k, v in [(n, p) for c in ("spine", "neck", "jaw", "tail") for n, p, _a, _b in sk[c]]}


def detail_object(name, bm, bone):
    obj = C.mesh_object(name, bm)
    vg = obj.vertex_groups.new(name="detail:" + bone)
    vg.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    return obj


def cone(bm, base, direction, length, radius, segments=6):
    d = direction.normalized()
    rot = d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = Matrix.Translation(base) @ rot @ Matrix.Translation(Vector((0, 0, length / 2)))
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius, radius2=radius * 0.06, depth=length, matrix=m)


def plate(bm, center, normal, up, width, height, thick, segments=12, arc=math.pi):
    """Half-disc fan plate (frill, crest): its flat edge on `center`, bulging along `up`."""
    n = normal.normalized()
    u = up.normalized()
    side = u.cross(n).normalized()
    rim_f, rim_b = [], []
    for i in range(segments + 1):
        a = -arc / 2 + arc * i / segments
        p = center + side * math.sin(a) * width + u * math.cos(a) * height
        rim_f.append(bm.verts.new(p + n * thick / 2))
        rim_b.append(bm.verts.new(p - n * thick / 2))
    cf, cb = bm.verts.new(center + n * thick / 2), bm.verts.new(center - n * thick / 2)
    for i in range(segments):
        bm.faces.new((cf, rim_f[i], rim_f[i + 1]))
        bm.faces.new((cb, rim_b[i + 1], rim_b[i]))
        bm.faces.new((rim_f[i], rim_b[i], rim_b[i + 1], rim_f[i + 1]))


def build_details(sp, sk, points):
    """Claws, eyes and species features as separate objects, each tagged with its bone."""
    s = sk["scale"]
    feats = sp.get("features", [])
    out = {"claw": [], "eye": [], "accent": [], "ivory": []}
    bm = bmesh.new()
    for kind, p, bone in sk["tips"]:
        if kind == "toe":
            cone(bm, p, Vector((0, -1, -0.45)), 0.09 * s, 0.022 * s)
        elif kind == "finger":
            cone(bm, p, Vector((0, -1, -0.9)), 0.06 * s, 0.012 * s)
        elif kind == "hoof":
            cone(bm, p + Vector((0, -0.02 * s, 0)), Vector((0, -1, -0.6)), 0.06 * s, 0.03 * s)
        else:
            cone(bm, p, Vector((0, -1, -0.3)), 0.25 * s, 0.18 * s)
    # Tips are grouped by bone: one object per bone keeps the explicit weights exact.
    by_bone = {}
    for kind, p, bone in sk["tips"]:
        if sp["plan"] in B2B_PLANS and kind != "hoof":
            continue  # paws, nails and bird toes are built in build_details_b2b
        by_bone.setdefault(bone, []).append((kind, p))
    bm.free()
    for bone, items in by_bone.items():
        b = bmesh.new()
        for kind, p in items:
            if kind == "toe":
                cone(b, p, Vector((0, -1, -0.45)), 0.09 * s, 0.022 * s)
            elif kind == "finger":
                cone(b, p, Vector((0, -1, -0.9)), 0.06 * s, 0.012 * s)
            elif kind == "hoof":
                cone(b, p + Vector((0, -0.02 * s, 0)), Vector((0, -1, -0.6)), 0.06 * s, 0.035 * s)
            else:
                cone(b, p, Vector((0, -1, -0.3)), 0.012 * s, 0.012 * s)
        out["claw"].append(detail_object("claws_" + bone, b, bone))
    if "sickle" in feats:
        for sfx, side in (("L", 1), ("R", -1)):
            foot = points.get("foot" + sfx) or Vector()
            b = bmesh.new()
            # The raised second-toe sickle: a long curved-looking dark cone held up and forward.
            base = Vector((0.20 * side * s * sp["knobs"]["girth"], 0, 0))
            cone(b, base + Vector((0, sk["sickle_y"][sfx], 0.075 * s)), Vector((0, -0.6, 0.55)), 0.13 * s, 0.03 * s)
            out["claw"].append(detail_object("sickle" + sfx, b, "Foot" + sfx))
    b = bmesh.new()
    eye = sk["eye"]
    r = sk["eye_r_abs"]
    for side in (1, -1):
        bmesh.ops.create_uvsphere(b, u_segments=10, v_segments=8, radius=r, matrix=Matrix.Translation(Vector((eye.x * side, eye.y, eye.z))))
    eyes = detail_object("eyes", b, "Head")
    C.finish_mesh(eyes)
    out["eye"].append(eyes)
    hb, nose = points["head_back"], points["nose"]
    fwd = (nose - hb).normalized()
    if "crest" in feats:
        b = bmesh.new()
        plate(b, hb + Vector((0, -0.07 * s, 0.09 * s)), X, Vector((0, -0.25, 1)), 0.09 * s, 0.17 * s, 0.025 * s, 10)
        out["accent"].append(detail_object("crest", b, "Head"))
    if "twincrest" in feats:
        b = bmesh.new()
        for side in (1, -1):
            c = hb + fwd * 0.12 * s + Vector((0.045 * side * s, 0, 0.08 * s))
            plate(b, c, Vector((1, 0, -0.12 * side)), Vector((0, 0.15, 1)), 0.17 * s, 0.11 * s, 0.012 * s, 12)
        out["accent"].append(detail_object("twincrest", b, "Head"))
    if "brow" in feats:
        b = bmesh.new()
        hs = sp["knobs"]["head"]
        for side in (1, -1):
            c = hb + Vector((0.075 * side * s * hs, -0.10 * s * hs, 0.10 * s * hs))
            cone(b, c, Vector((0.25 * side, -0.4, 1)), 0.07 * s * hs, 0.03 * s * hs)
        out["accent"].append(detail_object("brow", b, "Head"))
    if "mane" in feats:
        # Feather mane: a row of short quill spikes down the back of the neck.
        n0, n1 = points["neck_a"], points["head_back"]
        b = bmesh.new()
        for i in range(7):
            t = i / 6
            p = n0.lerp(n1, t) + Vector((0, 0.06 * s, 0.11 * s * (1.2 - 0.4 * t)))
            cone(b, p, Vector((0, 0.9, 0.6)), 0.14 * s, 0.03 * s, 5)
        out["accent"].append(detail_object("mane_neck", b, "Neck2"))
    if "armfeathers" in feats:
        for sfx, side in (("L", 1), ("R", -1)):
            b = bmesh.new()
            sh = Vector(sk["arm_pts"][sfx][0])
            wr = Vector(sk["arm_pts"][sfx][2])
            for i in range(5):
                t = 0.25 + 0.75 * i / 4
                p = sh.lerp(wr, t) + Vector((0.01 * side * s, 0.02 * s, 0))
                cone(b, p, Vector((0.15 * side, 0.7, -0.5)), (0.10 + 0.03 * i) * s, 0.022 * s, 4)
            out["accent"].append(detail_object("armfeathers" + sfx, b, "Arm" + sfx))
    if "tailfan" in feats:
        tip = points["tail5"]
        b = bmesh.new()
        for i in range(7):
            a = -0.6 + 1.2 * i / 6
            cone(b, tip + Vector((0, -0.12 * s, 0)), Vector((math.sin(a), 1, 0.15)), 0.22 * s, 0.03 * s, 4)
        out["accent"].append(detail_object("tailfan", b, "Tail5"))
    if "frill" in feats:
        f = sp["knobs"]["frill"]
        b = bmesh.new()
        plate(b, hb + Vector((0, 0.02 * s, 0.10 * s)), Vector((0, -1, -0.55)), Vector((0, 0.55, 1)), 0.48 * s * f, 0.5 * s * f, 0.05 * s, 16, math.pi * 1.1)
        # Rim knobs (epoccipitals) along the frill edge.
        n = Vector((0, -1, -0.55)).normalized()
        u = Vector((0, 0.55, 1)).normalized()
        side = u.cross(n).normalized()
        for i in range(9):
            a = -math.pi * 0.55 + math.pi * 1.1 * i / 8
            p = hb + Vector((0, 0.02 * s, 0.10 * s)) + side * math.sin(a) * 0.48 * s * f + u * math.cos(a) * 0.5 * s * f
            bmesh.ops.create_icosphere(b, subdivisions=1, radius=0.045 * s * f, matrix=Matrix.Translation(p))
        out["accent"].append(detail_object("frill", b, "Head"))
    if "horns" in feats:
        h = sp["knobs"]["horns"]
        b = bmesh.new()
        for side in (1, -1):
            cone(b, hb + Vector((0.13 * side * s, -0.16 * s, 0.17 * s)), Vector((0.12 * side, -0.85, 0.55)), 0.48 * s * h, 0.055 * s, 8)
        cone(b, nose + Vector((0, 0.10 * s, 0.07 * s)), Vector((0, -0.3, 1)), 0.18 * s * h, 0.045 * s, 8)
        out["ivory"].append(detail_object("horns", b, "Head"))
    if sp["plan"] == "ceratopsian":
        b = bmesh.new()
        cone(b, nose + Vector((0, 0.02 * s, -0.015 * s)), Vector((0, -0.6, -0.8)), 0.09 * s, 0.05 * s, 8)
        out["ivory"].append(detail_object("beak", b, "Head"))
    if "nasalarch" in feats:
        b = bmesh.new()
        bmesh.ops.create_uvsphere(b, u_segments=12, v_segments=8, radius=0.34, matrix=Matrix.Translation(Vector((0, -6.85, 23.0))) @ Matrix.Diagonal((1.0, 1.4, 0.8, 1)))
        out["accent"].append(detail_object("nasalarch", b, "Head"))
    if sp["plan"] in B2B_PLANS:
        build_details_b2b(sp, sk, points, out)
    return out


B2B_PLANS = ("armored", "hadrosaur", "mammal", "elephant", "crocodilian", "turtle", "bird")


def cyl(bm, a, b, ra, rb, segments=6):
    """Tapered tube from a to b (closed ends)."""
    d = b - a
    rot = d.normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    m = Matrix.Translation((a + b) / 2) @ rot
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=ra, radius2=rb, depth=d.length, matrix=m)


def blob(bm, center, radii, segments=10, rings=6):
    m = Matrix.Translation(center) @ Matrix.Diagonal((radii[0], radii[1], radii[2], 1))
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=1.0, matrix=m)


def curved_tusk(bm, base, direction, curl, length, radius, steps=4):
    """A tusk/horn as a chain of tapered tubes bending by `curl` (vector added per step)."""
    p, d = Vector(base), Vector(direction).normalized()
    for i in range(steps):
        r0 = radius * (1 - i / steps)
        r1 = radius * (1 - (i + 1) / steps) + radius * 0.06
        q = p + d * (length / steps)
        cyl(bm, p, q, r0, r1, 7)
        p, d = q, (d + Vector(curl)).normalized()


def _spine_bone(sk, y):
    """Torso/tail bone owning world y (front -> back) for details placed along the back."""
    pts = {n: Vector(p) for c in ("spine", "tail") for n, p, _a, _b in sk[c]}
    names = [b[0] for b in sk["bones"]]
    if y < pts["belly"].y and "Chest" in names:
        return "Chest"
    if y < pts["pelvis"].y and "Spine" in names:
        return "Spine"
    best = "Root"
    for bname, h, _t, _p in sk["bones"]:
        if bname.startswith("Tail") and h in pts and pts[h].y <= y:
            best = bname
    return best


def _back_z(sk, y):
    """Top of the torso/tail skin at y (skin radius rb is the vertical one)."""
    chain = [(Vector(p), rb) for c in ("spine", "tail") for _n, p, _a, rb in sk[c]]
    chain.sort(key=lambda e: e[0].y)
    for (p0, r0), (p1, r1) in zip(chain, chain[1:]):
        if p0.y <= y <= p1.y:
            t = (y - p0.y) / max(p1.y - p0.y, 1e-6)
            return p0.z + (p1.z - p0.z) * t + (r0 + (r1 - r0) * t)
    p, r = chain[0] if y < chain[0][0].y else chain[-1]
    return p.z + r


def build_details_b2b(sp, sk, points, out):
    s = sk["scale"]
    feats = sp.get("features", [])
    hb, nose = points["head_back"], points["nose"]
    ep = sk.get("extra_points", {})
    pel, chest = points["pelvis"], points["chest"]
    # Claw / hoof / pad tips per bone (B2a only handles toe/finger/hoof sizing for its plans).
    by_bone = {}
    for kind, p, bone in sk["tips"]:
        by_bone.setdefault(bone, []).append((kind, p))
    for bone, items in by_bone.items():
        b = bmesh.new()
        for kind, p in items:
            if kind == "paw":
                cone(b, p + Vector((0, 0.01 * s, 0.01 * s)), Vector((0, -1, -0.5)), 0.035 * s, 0.009 * s, 5)
            elif kind == "nailbig":
                blob(b, p + Vector((0, 0.02 * s, 0.0)), (0.06 * s, 0.04 * s, 0.045 * s), 8, 4)
            elif kind == "toe":
                cone(b, p, Vector((0, -1, -0.3)), 0.07 * s, 0.012 * s, 5)
        if len(b.verts):
            out["claw"].append(detail_object("tips_" + bone, b, bone))
        else:
            b.free()
    # Ears (mammal cones, elephant fans) on their Ear bones.
    for sfx, side in (("L", 1), ("R", -1)):
        if "ear_base" + sfx not in ep:
            continue
        base, tip = ep["ear_base" + sfx], ep["ear_tip" + sfx]
        b = bmesh.new()
        if sp["plan"] == "elephant":
            d = tip - base
            plate(b, base + d * 0.15, Vector((0.35 * side, -1, 0.1)), d, abs(d.z) * 0.55, d.length * 0.8, 0.05 * s, 12, math.pi * 1.2)
        else:
            d = tip - base
            leaf(b, base - d * 0.12, tip, d.length * 0.36, d.length * 0.09, 0.8, Vector((0.35 * side, -1, 0.1)))
        ear = detail_object("ear" + sfx, b, "Ear" + sfx)
        C.finish_mesh(ear)
        # L4b: ears wear the hide (same fur, countershading and AO) instead of a flat accent fill.
        out.setdefault("skin", []).append(ear)
    if "plates" in feats:
        # Two staggered rows of tall rounded plates from the neck to mid-tail, tallest over the hips.
        b_by = {}
        y0, y1 = points["neck_a"].y, points["tail3"].y
        n = 13
        for i in range(n):
            t = i / (n - 1)
            y = y0 + (y1 - y0) * t
            h = (0.12 + 0.3 * math.sin(math.pi * min(1.0, t * 1.15)) ** 1.4) * s
            side = 1 if i % 2 == 0 else -1
            bone = _spine_bone(sk, y)
            bb = b_by.setdefault(bone, bmesh.new())
            c = Vector((0.035 * side * s, y, _back_z(sk, y) - 0.03 * s))
            plate(bb, c, Vector((1, 0, 0.12 * side)), Vector((0, 0.18, 1)), h * 0.55, h, 0.022 * s, 8, math.pi)
        for bone, bb in b_by.items():
            out["accent"].append(detail_object("plates_" + bone, bb, bone))
    if "thagomizer" in feats:
        b = bmesh.new()
        t4 = points["tail4"]
        for side in (1, -1):
            for j, dy in enumerate((-0.12, 0.05)):
                cone(b, t4 + Vector((0.02 * side * s, dy * s, 0.03 * s)), Vector((0.9 * side, 0.35, 0.35 + 0.2 * j)), 0.26 * s, 0.025 * s, 6)
        out["ivory"].append(detail_object("thagomizer", b, "Tail4"))
    if "osteoderms" in feats:
        b_by = {}
        y0, y1 = points["neck_a"].y, points["tail3"].y
        for i in range(11):
            y = y0 + (y1 - y0) * i / 10
            bone = _spine_bone(sk, y)
            bb = b_by.setdefault(bone, bmesh.new())
            top = _back_z(sk, y)
            for col in (-2, -1, 0, 1, 2):
                spread = 0.13 * col * s * (1.0 if y < y1 * 0.4 else 0.6)
                z = top - (0.02 + 0.03 * abs(col)) * s
                cone(bb, Vector((spread, y, z)), Vector((0.25 * col, 0, 1)), 0.07 * s, 0.03 * s, 5)
        for bone, bb in b_by.items():
            out["accent"].append(detail_object("osteoderms_" + bone, bb, bone))
    if "club" in feats:
        b = bmesh.new()
        t4 = points["tail4"]
        blob(b, t4 + Vector((0, 0.06 * s, 0)), (0.17 * s, 0.13 * s, 0.08 * s), 12, 6)
        out["ivory"].append(detail_object("club", b, "Tail4"))
    if "sidespikes" in feats:
        b_by = {}
        for y in (points["chest"].y, points["belly"].y, points["pelvis"].y):
            bone = _spine_bone(sk, y + 0.001)
            bb = b_by.setdefault(bone, bmesh.new())
            for side in (1, -1):
                cone(bb, Vector((0.42 * side * s, y, pel.z - 0.02 * s)), Vector((side, 0.15, -0.1)), 0.14 * s, 0.04 * s, 5)
        for bone, bb in b_by.items():
            out["accent"].append(detail_object("sidespikes_" + bone, bb, bone))
    if "tubecrest" in feats:
        b = bmesh.new()
        tip = ep["crest_tip"]
        start = hb + Vector((0, -0.06 * s, 0.05 * s))
        mid = start.lerp(tip, 0.5) + Vector((0, 0, 0.06 * s))
        cyl(b, start, mid, 0.055 * s, 0.05 * s, 8)
        cyl(b, mid, tip, 0.05 * s, 0.035 * s, 8)
        blob(b, tip, (0.036 * s, 0.036 * s, 0.036 * s), 8, 4)
        out["accent"].append(detail_object("tubecrest", b, "Head"))
    if "duckbill" in feats:
        b = bmesh.new()
        blob(b, nose + Vector((0, -0.02 * s, -0.01 * s)), (0.085 * s, 0.075 * s, 0.03 * s), 10, 5)
        out["ivory"].append(detail_object("duckbill", b, "Head"))
    if "saber" in feats:
        b = bmesh.new()
        sn = points["snout"]
        L = sp["saber"] * 0.4 * s
        for side in (1, -1):
            curved_tusk(b, sn + Vector((0.028 * side * s, 0.005 * s, -0.035 * s)), Vector((0, -0.12, -1)), Vector((0, 0.18, 0)), L, 0.016 * s, 3)
        out["ivory"].append(detail_object("sabers", b, "Head"))
    if "tusks" in feats or "longtusks" in feats:
        b = bmesh.new()
        if sp["plan"] == "elephant":
            long = "longtusks" in feats
            for side in (1, -1):
                base = Vector((0.13 * side * s, points["nose"].y + 0.08 * s, points["nose"].z - 0.12 * s))
                if long:
                    curved_tusk(b, base, Vector((0.25 * side, -0.55, -0.8)), Vector((0.06 * side, -0.05, 0.42)), 1.15 * s, 0.065 * s, 6)
                else:
                    curved_tusk(b, base, Vector((0.08 * side, -0.4, -0.9)), Vector((0, -0.1, 0.28)), 0.42 * s, 0.045 * s, 4)
        else:
            sn = points["snout"]
            for side in (1, -1):
                curved_tusk(b, sn + Vector((0.04 * side * s, 0, -0.02 * s)), Vector((0.5 * side, -0.4, 0.4)), Vector((0, 0.2, 0.25)), 0.09 * s, 0.014 * s, 3)
        out["ivory"].append(detail_object("tusks", b, "Head"))
    if "bristles" in feats:
        b_by = {}
        y0, y1 = points["neck_a"].y, pel.y
        for i in range(14):
            y = y0 + (y1 - y0) * i / 13
            bone = "Neck1" if y < chest.y else _spine_bone(sk, y)
            bb = b_by.setdefault(bone, bmesh.new())
            z = (_back_z(sk, y) if y >= chest.y else points["neck_a"].z + 0.13 * s) - 0.01 * s
            cone(bb, Vector((0, y, z)), Vector((0, 0.5, 1)), (0.07 - 0.03 * i / 13) * s, 0.018 * s, 4)
        for bone, bb in b_by.items():
            out["accent"].append(detail_object("bristles_" + bone, bb, bone))
    if "antlers" in feats:
        b = bmesh.new()
        for side in (1, -1):
            base = hb + Vector((0.035 * side * s, 0.01 * s, 0.07 * s))
            main_dir = Vector((0.45 * side, 0.35, 1))
            curved_tusk(b, base, main_dir, Vector((0.05 * side, 0.12, -0.05)), 0.42 * s, 0.018 * s, 4)
            d = main_dir.normalized()
            for j, (t, tine) in enumerate(((0.3, (0.1 * side, -0.9, 0.6)), (0.55, (0.3 * side, -0.4, 1)), (0.8, (0.6 * side, 0.1, 0.8)))):
                cone(b, base + d * 0.42 * s * t, Vector(tine), (0.11 - 0.02 * j) * s, 0.01 * s, 5)
        out["ivory"].append(detail_object("antlers", b, "Head"))
    if "scutes" in feats:
        b_by = {}
        y0, y1 = points["neck_a"].y, points["tail4"].y
        for i in range(22):
            y = y0 + (y1 - y0) * i / 21
            bone = "Neck" if y < chest.y else _spine_bone(sk, y)
            bb = b_by.setdefault(bone, bmesh.new())
            top = _back_z(sk, y) if y >= chest.y else points["neck_a"].z + 0.1 * s
            rows = (-1, 1) if y > points["tail2"].y else (-2, -1, 1, 2)
            for col in rows:
                cone(bb, Vector((0.045 * col * s, y, top - 0.015 * s * abs(col))), Vector((0.1 * col, 0, 1)), 0.045 * s, 0.022 * s, 4)
        for bone, bb in b_by.items():
            out["accent"].append(detail_object("scutes_" + bone, bb, bone))
    if "teeth" in feats:
        b = bmesh.new()
        bj = bmesh.new()
        ha, hn = points["head"], points["nose"]
        ja, jt = points["jaw_a"], points["jaw_tip"]
        for i in range(7):
            t = 0.1 + 0.85 * i / 6
            for side in (1, -1):
                p = ha.lerp(hn, t)
                w = (0.1 - 0.05 * t) * s
                cone(b, Vector((w * side, p.y, p.z - 0.045 * s)), Vector((0.2 * side, 0, -1)), 0.035 * s, 0.008 * s, 4)
                q = ja.lerp(jt, t)
                cone(bj, Vector((w * 0.95 * side, q.y + 0.03 * s, q.z + 0.03 * s)), Vector((0.2 * side, 0, 1)), 0.03 * s, 0.007 * s, 4)
        out["ivory"].append(detail_object("teeth_up", b, "Head"))
        out["ivory"].append(detail_object("teeth_low", bj, "Jaw"))
    if "shell" in feats:
        b = bmesh.new()
        c = points["belly"]
        blob(b, c + Vector((0, 0.01 * s, 0.03 * s)), (0.36 * s, 0.44 * s, 0.24 * s), 20, 10)
        # Flatten the dome's underside into the plastron line.
        for v in b.verts:
            if v.co.z < c.z - 0.02 * s:
                v.co.z = c.z - 0.02 * s - (v.co.z - c.z + 0.02 * s) * 0.15
        out.setdefault("shell", []).append(detail_object("shell", b, "Spine"))
    if "beak" in feats:
        b = bmesh.new()
        ha = points["head"]
        cyl(b, ha + Vector((0, -0.02 * s, -0.01 * s)), nose + Vector((0, -0.1 * s, -0.04 * s)), 0.06 * s, 0.045 * s, 10)
        cone(b, nose + Vector((0, -0.1 * s, -0.035 * s)), Vector((0, -0.4, -1)), 0.07 * s, 0.04 * s, 8)
        out["ivory"].append(detail_object("beak", b, "Head"))
    if "tuft" in feats:
        b = bmesh.new()
        t1 = points["tail1"]
        for i in range(5):
            a = -0.6 + 1.2 * i / 4
            cone(b, t1, Vector((math.sin(a) * 0.6, 0.4, 1)), 0.18 * s, 0.03 * s, 4)
        out["ivory"].append(detail_object("tuft", b, "Tail"))
    if sp["plan"] == "bird":
        for sfx, side in (("L", 1), ("R", -1)):
            b = bmesh.new()
            sh = points["shoulder" + sfx]
            for i in range(4):
                cone(b, sh + Vector((0.02 * side * s, 0.05 * s * i, -0.02 * s * i)), Vector((0.2 * side, 1, -0.5)), (0.22 - 0.03 * i) * s, 0.035 * s, 4)
            out["accent"].append(detail_object("wing" + sfx, b, "Wing" + sfx))
    return out


# ------------------------------------------------------------------ v2 sculpt (L4)
# The skin-modifier tube body is only the armature-shaped core. v2 unions it with ellipsoid
# masses (skull, jaw, cheek, brow, muscle bellies over hips and shoulders, skeletal landmarks,
# merged foot pads and toes), voxel-remeshes the union into one watertight sculpt, then bakes
# that high mesh onto the decimated low mesh (normal + albedo + roughness).

# Eye radius against the B2a/B2b value: real eyes are small next to the skull.
EYE_SCALE = dict(theropod=0.58, ceratopsian=0.6, sauropod=0.6, armored=0.7, hadrosaur=0.68, mammal=0.78, elephant=0.5, crocodilian=0.8, turtle=0.9, bird=0.8)
# L4d: eyes enlarged so they resolve at gameplay zoom (stylised, Durango-like proportion); small
# species gain the most because their eye is a few pixels on a phone.
EYE_GAIN = 1.25
EYE_GAIN_SMALL = 1.45
# Skull width/height against the head skin radius; m = limb muscle gain; lm = ilium/scapula bumps.
SCULPT = {
    "theropod": dict(sw=0.82, sh=1.22, m=1.0, lm=False, cheek=1.0),
    "ceratopsian": dict(sw=0.9, sh=1.0, m=1.0, lm=True, cheek=0.8),
    "sauropod": dict(sw=0.85, sh=0.95, m=0.9, lm=True, cheek=0.0),
    "armored": dict(sw=1.0, sh=0.85, m=0.85, lm=False, cheek=0.6),
    "hadrosaur": dict(sw=0.85, sh=1.05, m=1.0, lm=True, cheek=0.7),
    "mammal": dict(sw=0.95, sh=0.95, m=1.0, lm=True, cheek=1.0),
    "elephant": dict(sw=0.9, sh=1.05, m=0.9, lm=True, cheek=0.0),
    "crocodilian": dict(sw=1.05, sh=0.7, m=0.7, lm=False, cheek=0.8),
    "turtle": dict(sw=0.9, sh=0.9, m=0.0, lm=False, cheek=0.0),
    "bird": dict(sw=0.95, sh=1.0, m=0.8, lm=False, cheek=0.0),
}
Y = Vector((0, 1, 0))
Z = Vector((0, 0, 1))


def ell(bm, center, along, r_side, r_along, r_up, segments=14, rings=10):
    """Ellipsoid whose second axis follows `along` (its first axis stays as close to X as it can)."""
    yv = Vector(along).normalized()
    xv = X - yv * X.dot(yv)
    if xv.length < 1e-3:
        xv = Z - yv * Z.dot(yv)
    xv.normalize()
    zv = xv.cross(yv)
    m = Matrix.Identity(4)
    for i in range(3):
        m[i][0], m[i][1], m[i][2], m[i][3] = xv[i] * r_side, yv[i] * r_along, zv[i] * r_up, center[i]
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=1.0, matrix=m)


def eye_radius(sp, sk):
    s = sk["scale"]
    r = 0.034 * s * (sp["knobs"].get("head", 1.0) ** 0.5 if sp["plan"] == "theropod" else 1.0)
    if sp["plan"] == "sauropod":
        r = 0.16
    elif sp["plan"] == "ceratopsian":
        r = 0.045 * s
    elif "eye_r" in sk:
        r = sk["eye_r"] * s
    return r * EYE_SCALE[sp["plan"]] * (EYE_GAIN_SMALL if sp["length"] <= 4 else EYE_GAIN)


def sculpt_masses(sp, sk, P, R):
    """[(center, along, r_side, r_along, r_up)] in final studs."""
    plan = sp["plan"]
    cfg = SCULPT[plan]
    out = []

    def rm(key):
        return max(R[key]) if key in R else 0.0

    def add(c, along, a, b, c2):
        if a > 0 and b > 0 and c2 > 0:
            out.append((Vector(c), Vector(along), a, b, c2))

    hb, nose = P["head_back"], P["nose"]
    d = nose - hb
    hl = d.length
    fwd = d.normalized()
    hr = max(rm("head"), rm("head_back") * 0.9)
    hw = sp["knobs"].get("headw", 1.0)
    if plan == "mammal":
        # L4b: rounded cranium, a distinct stop, a tapering muzzle bridge, a nose pad and round
        # zygomatic cheeks instead of one long skull slab (the v2 heads read blocky).
        sn = sp["knobs"].get("snout", 1.0)
        cat = sp.get("foot") == "paw" and sn < 0.9
        add(hb.lerp(nose, 0.2) + Z * hr * 0.12, d, hr * 1.02, hl * 0.34, hr * 0.98)
        add(hb + Z * hr * 0.28 + fwd * hl * 0.06, d, hr * 1.05, hl * 0.3, hr * 0.95)
        add(hb.lerp(nose, 0.58) - Z * hr * 0.06, d, hr * (0.62 if cat else 0.5), hl * 0.3, hr * 0.6)
        add(hb.lerp(nose, 0.84) - Z * hr * 0.1, d, hr * (0.5 if cat else 0.36), hl * 0.2, hr * 0.44)
        add(nose - fwd * hl * 0.04 - Z * hr * 0.04, d, hr * 0.26, hl * 0.08, hr * 0.22)
        for side in (1, -1):
            add(hb.lerp(nose, 0.34) + X * side * hr * (0.6 if cat else 0.5) - Z * hr * 0.2, d, hr * (0.42 if cat else 0.32), hl * 0.2, hr * 0.36)
    else:
        # Skull: one mass from the occiput to the snout, then a narrower muzzle.
        add(hb.lerp(nose, 0.36) + Z * hr * 0.08, d, hr * cfg["sw"] * hw, hl * 0.5, hr * cfg["sh"])
    if plan in ("theropod", "hadrosaur", "crocodilian"):
        add(hb.lerp(nose, 0.74), d, hr * cfg["sw"] * 0.62 * hw, hl * 0.3, hr * cfg["sh"] * 0.72)
    if "jaw_a" in P and plan not in ("bird", "turtle", "elephant"):
        dj = P["jaw_tip"] - P["jaw_a"]
        add(P["jaw_a"].lerp(P["jaw_tip"], 0.4), dj, rm("jaw_a") * 0.95 * hw, dj.length * 0.52, rm("jaw_a") * 0.75)
    er, eye = sk["eye_r_abs"], sk["eye"]
    for side in (1, -1):
        sx = X * side
        if cfg["cheek"]:
            # Jaw adductor bulge behind and below the eye.
            c = hb + sx * hr * 0.55 * hw + fwd * hl * 0.1 - Z * hr * 0.28
            add(c, d, hr * 0.34 * cfg["cheek"] * hw, hl * 0.2, hr * 0.42 * cfg["cheek"])
        # Brow ridge over the eye.
        e = Vector((eye.x * side, eye.y, eye.z))
        add(e + Z * er * 1.05 + sx * er * 0.15, d, er * 1.0, er * 2.1, er * 0.7)
    neck_key = "neck_a" if "neck_a" in P else ("n1" if "n1" in P else None)
    if neck_key and plan not in ("turtle", "bird"):
        n0, n1 = P["chest"], P[neck_key]
        rn = rm(neck_key)
        add(n0.lerp(n1, 0.55) + Z * rn * 0.3, n1 - n0, rn * 0.95, (n1 - n0).length * 0.6, rn * 0.9)
    m = cfg["m"]
    if m:
        for side, sfx in ((1, "L"), (-1, "R")):
            sx = X * side

            def seg(a, b):
                return (P[a + sfx], P[b + sfx]) if a + sfx in P and b + sfx in P else None

            # Thigh: big muscle belly over the hip (caudofemoralis / quadriceps mass).
            thigh = seg("hip", "knee") or seg("hip", "foot")
            if thigh:
                a, b = thigh
                r0 = rm("hip" + sfx)
                add(a.lerp(b, 0.3) + sx * r0 * 0.14, b - a, r0 * 0.92 * m, (b - a).length * 0.44, r0 * 1.05 * m)
            shank = seg("knee", "ankle")
            if shank:
                a, b = shank
                r0 = rm("knee" + sfx)
                add(a.lerp(b, 0.26) + Y * r0 * 0.3, b - a, r0 * 0.8 * m, (b - a).length * 0.32, r0 * 0.95 * m)
            upper = seg("shoulder", "elbow")
            if upper:
                a, b = upper
                r0 = rm("shoulder" + sfx)
                add(a.lerp(b, 0.28) + sx * r0 * 0.1, b - a, r0 * 0.88 * m, (b - a).length * 0.42, r0 * 1.0 * m)
            fore = seg("elbow", "wrist") or seg("elbow", "hand")
            if fore and plan != "bird":
                a, b = fore
                r0 = rm("elbow" + sfx)
                add(a.lerp(b, 0.24) - Y * r0 * 0.15, b - a, r0 * 0.78 * m, (b - a).length * 0.3, r0 * 0.9 * m)
            if cfg["lm"]:
                rp, rc = rm("pelvis"), rm("chest")
                add(P["pelvis"] + sx * rp * 0.55 + Z * rp * 0.72, Y, rp * 0.26, rp * 0.42, rp * 0.2)
                add(P["chest"] + sx * rc * 0.62 + Z * rc * 0.5 + Y * rc * 0.1, Vector((0, 0.45, 1)), rc * 0.16, rc * 0.48, rc * 0.3)
    # Feet: pads with the toes merged in (mammals), round flat pads (elephants).
    kind = sp.get("foot", "paw")
    for side, sfx in ((1, "L"), (-1, "R")):
        for end in ("foot" + sfx, "hand" + sfx):
            if end not in P:
                continue
            f, r = P[end], R[end][0]
            if plan == "elephant":
                # L4b: overlapping, gently flaring masses (no ledge between pad and leg).
                for zz, rr, ru in ((0.42, 1.04, 0.5), (0.85, 0.99, 0.75), (1.45, 0.95, 0.95), (2.2, 0.92, 1.1)):
                    add(Vector((f.x, f.y - r * 0.06, r * zz)), Z, r * rr, r * ru, r * rr)
            elif plan == "mammal" and kind == "paw":
                add(f + Vector((0, -r * 0.5, r * 0.25)), Y, r * 1.15, r * 1.35, r * 0.8)
                for dx in (-0.78, -0.27, 0.27, 0.78):
                    c = Vector((f.x + dx * r * side, f.y - r * (1.35 - 0.35 * abs(dx)), r * 0.42))
                    add(c, -Y, r * 0.4, r * 0.55, r * 0.42)
            elif plan == "mammal":
                for dx in (-0.42, 0.42):
                    c = Vector((f.x + dx * r * side, f.y - r * 0.6, r * 0.55))
                    add(c, Vector((0, -1, -0.45)), r * 0.48, r * 0.95, r * 0.62)
    return out


def remesh_high(obj, voxel, s):
    r = obj.modifiers.new("vox", "REMESH")
    r.mode = "VOXEL"
    r.voxel_size = voxel
    r.adaptivity = 0.0
    sm = obj.modifiers.new("smooth", "SMOOTH")
    sm.factor = 0.7
    sm.iterations = 10
    C.apply_modifiers(obj)
    tex = bpy.data.textures.new("lump", "CLOUDS")
    tex.noise_scale = 0.08 * s
    disp = obj.modifiers.new("disp", "DISPLACE")
    disp.texture = tex
    disp.strength = 0.006 * s
    C.apply_modifiers(obj)
    for v in obj.data.vertices:
        if v.co.z < 0:
            v.co.z = 0.0  # flat soles: the feet stand on the floor plane
    obj.data.update()


def core_edges(sk):
    """The skin graph of build_body as (key_a, key_b) edges."""
    edges = []

    def run(chain, start):
        prev = start
        for n, _p, _a, _b in chain:
            if prev is not None:
                edges.append((prev, n))
            prev = n
        return prev

    tail_end = run(list(reversed(sk["tail"])), None)
    last = run(sk["spine"], tail_end)
    run(sk["neck"], last)
    run(sk["jaw"], "head_back")
    for parent, chain in sk.get("extras", []):
        run(chain, parent)
    for _sfx, leg, toes, arm, fingers in sk["limbs"]:
        foot = run(leg, "pelvis")
        for n, _p, _a, _b in toes:
            edges.append((foot, n))
        wrist = run(arm, "chest")
        for n, _p, _a, _b in fingers:
            edges.append((wrist, n))
    return edges


def core_masses(bm, sk, points, radii):
    """Closed ellipsoid chain along every skeleton edge (radius ra sideways, rb up): a manifold
    stand-in for the skin-modifier tube, which the voxel remesher cannot read reliably."""
    for a, b in core_edges(sk):
        pa, pb = points[a], points[b]
        (xa, za), (xb, zb) = radii[a], radii[b]
        d = pb - pa
        n = max(2, int(d.length / max(min(xa, za, xb, zb), 1e-3) * 1.6) + 1)
        for i in range(n + 1):
            t = i / n
            rx, rz = xa + (xb - xa) * t, za + (zb - za) * t
            ell(bm, pa.lerp(pb, t), d if d.length > 1e-6 else Y, rx, max(d.length / n * 0.9, min(rx, rz)), rz, 12, 8)


def build_body_v2(name, sk, sp, points, radii, target):
    """Voxel sculpt (high) + its decimated copy (low, the shipped body). Returns (low, high, bvh)."""
    bm = bmesh.new()
    core_masses(bm, sk, points, radii)
    core = C.mesh_object(name + "_core", bm)
    bm = bmesh.new()
    for c, along, a, b, c2 in sculpt_masses(sp, sk, points, radii):
        ell(bm, c, along, a, b, c2)
    masses = C.mesh_object(name + "_masses", bm)
    high = C.join([core, masses], name + "_high")
    remesh_high(high, sp["length"] / 230.0, sk["scale"])
    C.finish_mesh(high)
    low = high.copy()
    low.data = high.data.copy()
    low.name = name
    C.link(low)
    C.decimate_to(low, target)
    C.finish_mesh(low)
    hb = bmesh.new()
    hb.from_mesh(high.data)
    bvh = BVHTree.FromBMesh(hb)
    hb.free()
    return low, high, bvh


def snap_surface(sk, bvh):
    """Eyes and claw/hoof/nail tips onto the sculpt surface (no floating toenails)."""
    s = sk["scale"]
    er = sk["eye_r_abs"]
    loc, n, _i, _d = bvh.find_nearest(Vector((abs(sk["eye"].x), sk["eye"].y, sk["eye"].z)))
    if loc is not None:
        sk["eye"] = loc - n * er * 0.42
    tips = []
    for kind, p, bone in sk["tips"]:
        loc, n, _i, _d = bvh.find_nearest(p)
        if loc is None:
            tips.append((kind, p, bone))
            continue
        depth = {"nailbig": 0.03 * s, "hoof": 0.012 * s}.get(kind, 0.006 * s)
        tips.append((kind, loc - n * depth, bone))
    sk["tips"] = tips


def _seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (a + ab * t - p).length


def build_fur(sp, sk, P, R, high, table=None):
    """Soft fur / feather lobes grown from the sculpt surface per zone (opaque shells)."""
    import bisect
    import random

    spec = (FUR if table is None else table).get(sp["key"])
    if not spec:
        return None
    L = sp["length"]
    polys = list(high.data.polygons)
    areas, acc = [], 0.0
    for p in polys:
        acc += p.area
        areas.append(acc)

    def rm(k):
        return max(R[k]) if k in R else 0.0

    hb, chest, pel = P["head_back"], P["chest"], P["pelvis"]
    neck = P.get("neck_a", chest.lerp(hb, 0.5))
    rn, rc, rp = max(rm("neck_a"), rm("chest") * 0.6), rm("chest"), rm("pelvis")
    hr = max(rm("head"), rm("head_back"))
    eye = sk["eye"]
    tails = [P[k] for k in sorted(P) if k.startswith("tail")]
    floor = max(P["ankleL"].z if "ankleL" in P else 0.15 * L, 0.05 * L)
    mid_z = (chest.z + pel.z) / 2

    def zone_ok(z, p, n):
        if z == "mane":
            return _seg_dist(p, chest, hb) < rn * 1.7 and n.z > -0.35 and p.y > hb.y + hr * 0.2
        if z == "cheek":
            return (p - hb).length < hr * 1.6 and abs(n.x) > 0.45 and p.y > eye.y and p.z < eye.z + hr * 0.2
        if z == "dorsal":
            return n.z > 0.55 and chest.y - rc * 0.3 <= p.y <= pel.y + rp * 0.5
        if z == "throat":
            return _seg_dist(p, chest, hb) < rn * 1.6 and n.z < -0.2 and p.y > hb.y
        if z == "crest":
            return abs(p.x) < rc * 0.32 and n.z > 0.45 and neck.y - rn * 0.4 <= p.y <= pel.y
        if z == "tail":
            return bool(tails) and min(_seg_dist(p, a, b) for a, b in zip([pel] + tails, tails)) < rp * 0.6 and p.y > pel.y + rp * 0.6
        if z == "skirt":
            lower = n.z < 0.35 and floor * 1.4 < p.z < mid_z + rc * 0.2 and chest.y - rc * 1.1 <= p.y <= pel.y + rp * 0.9
            return lower or ((p - hb).length < hr * 1.4 and n.z < -0.2)
        if z == "all":
            return _seg_dist(p, chest, pel) < max(rc, rp) * 1.35 and n.z > -0.5
        if z == "haunch":
            return n.z > 0.0 and abs(n.x) > 0.35 and _seg_dist(p, pel, P.get("kneeL", pel)) < rp * 1.6 and p.y > pel.y - rp * 0.6
        if z == "arm":
            for f in "LR":
                a0 = P.get("shoulder" + f)
                a1 = P.get("wrist" + f, P.get("wingtip" + f))
                if a0 is not None and a1 is not None and _seg_dist(p, a0, a1) < max(rm("shoulder" + f), 1e-3) * 1.5 and n.x * (1 if f == "L" else -1) > -0.2:
                    return True
            return False
        if z == "tailtip":
            return len(tails) >= 1 and _seg_dist(p, tails[max(0, len(tails) - 3)], tails[-1]) < rp * 0.5 and n.z > -0.4
        if z == "crest_neck":
            return _seg_dist(p, chest.lerp(hb, 0.25), chest.lerp(hb, 0.92)) < rn * 1.6 and n.z > 0.45 and abs(n.x) < 0.6
        return False

    bm = bmesh.new()
    bases, tipness = [], []
    for zone, count, lf, wf in spec:
        made, tries = 0, 0
        while made < count and tries < count * 120:
            tries += 1
            i = bisect.bisect_left(areas, random.random() * acc)
            poly = polys[min(i, len(polys) - 1)]
            p, n = Vector(poly.center), Vector(poly.normal)
            if not zone_ok(zone, p, n):
                continue
            made += 1
            ln = lf * L * random.uniform(0.75, 1.25)
            w = wf * L * random.uniform(0.8, 1.2)
            lift = 0.28
            if zone == "skirt":
                g = -Z * 1.0 + Y * 0.15
                lift = 0.35
            elif zone == "crest":
                g = Y * 0.8 + Z * 0.5
                lift = 0.5
            elif zone in ("tail", "tailtip"):
                g = Y * 1.0 - Z * 0.2 + X * (1 if p.x > 0 else -1) * (0.5 if zone == "tailtip" else 0.0)
                lift = 0.2
            elif zone == "arm":
                f = "L" if p.x > 0 else "R"
                a1 = P.get("wrist" + f, P.get("wingtip" + f))
                g = (a1 - P["shoulder" + f]).normalized() * 0.6 + Y * 0.8 - Z * 0.4
                lift = 0.18
            elif zone == "crest_neck":
                g = Y * 0.9 + Z * 0.35
                lift = 0.45
            else:
                g = Y * 0.8 - Z * 0.45
                lift = 0.16
            # Lie the lobe along the skin (growth direction projected on the tangent plane).
            tg = g - n * g.dot(n)
            if tg.length < 1e-4:
                tg = Y - n * Y.dot(n)
            d = (tg.normalized() + n * lift).normalized()
            side = d.cross(n)
            if side.length < 1e-4:
                side = d.cross(X if abs(d.x) < 0.9 else Z)
            side.normalize()
            up = side.cross(d).normalized()
            if up.dot(n) < 0:
                up = -up
            th = w * 0.16
            base = p - n * th * 1.5
            mid = base + d * ln * 0.5 + up * th * 0.4
            tip = base + d * ln - up * th * 0.8
            tip.z = max(tip.z, floor)
            rings = []
            for c, r, t in ((base, w * 0.75, th), (mid, w, th * 0.8)):
                rings.append([bm.verts.new(c + side * r * cx + up * t * cz) for cx, cz in ((1, 0), (0, 1), (-1, 0), (0, -1))])
            tv = bm.verts.new(tip)
            bm.faces.new(list(reversed(rings[0])))
            for k in range(4):
                a0, a1 = rings[0][k], rings[0][(k + 1) % 4]
                b0, b1 = rings[1][k], rings[1][(k + 1) % 4]
                bm.faces.new((a0, a1, b1, b0))
                bm.faces.new((b0, b1, tv))
            bases += [base] * 9
            tipness += [0.0] * 4 + [0.55] * 4 + [1.0]
    if not bases:
        bm.free()
        return None
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    obj = C.mesh_object("fur", bm)
    me = obj.data
    a = me.attributes.new("fur_base", "FLOAT_VECTOR", "POINT")
    f = me.attributes.new("is_fur", "FLOAT", "POINT")
    tp = me.attributes.new("fur_tip", "FLOAT", "POINT")
    for i, b in enumerate(bases):
        a.data[i].vector = b
        f.data[i].value = 1.0
        tp.data[i].value = tipness[i]
    for poly in me.polygons:
        poly.use_smooth = True
    return obj


def feather_card(bm, base, d, flat, length, width, droop=0.12):
    """One closed feather blade: quill base, the widest vane at 40%, a pointed tip curling a little
    toward -flat (lies on the body). Raptor2: the rachis is a raised ridge (a shallow roof over the
    vane), so each card catches the key light on one half and shades the other, and every card edge
    casts a step onto the card under it. `flat` is the vane normal. CARD_TRIS triangles.
    Returns [(vert, t along, u across)] for the colour attributes."""
    d = d.normalized()
    f = (flat - d * flat.dot(d)).normalized()
    side = d.cross(f).normalized()
    th = width * 0.16
    c = base + d * length * 0.4 - f * length * droop * 0.16
    b0 = bm.verts.new(base)
    bl = bm.verts.new(c + side * width - f * th * 0.3)
    br = bm.verts.new(c - side * width - f * th * 0.3)
    top = bm.verts.new(c + f * th)
    und = bm.verts.new(c - f * th * 0.6)
    tl = bm.verts.new(base + d * length * 0.78 + side * width * 0.45 - f * length * droop * 0.6)
    tr = bm.verts.new(base + d * length * 0.78 - side * width * 0.45 - f * length * droop * 0.6)
    tip = bm.verts.new(base + d * length - f * length * droop)
    for face in ((b0, top, bl), (b0, br, top), (bl, top, tl), (top, tip, tl), (top, br, tr), (top, tr, tip),
                 (b0, bl, und), (b0, und, br), (bl, tl, tip, und), (und, tip, tr, br)):
        bm.faces.new(face)
    return [(b0, 0.0, 0.0), (bl, 0.4, 1.0), (br, 0.4, -1.0), (top, 0.4, 0.0), (und, 0.4, 0.0),
            (tl, 0.78, 0.6), (tr, 0.78, -0.6), (tip, 1.0, 0.0)]


def _polyline(pts, t):
    """Point and segment index at fraction t of a polyline's length."""
    segs = [(pts[i], pts[i + 1]) for i in range(len(pts) - 1)]
    total = sum((b - a).length for a, b in segs)
    acc = 0.0
    for i, (a, b) in enumerate(segs):
        ln = (b - a).length
        if acc + ln >= t * total or i == len(segs) - 1:
            u = 0.0 if ln < 1e-9 else max(0.0, min(1.0, (t * total - acc) / ln))
            return a.lerp(b, u), i, (b - a).normalized()
        acc += ln


def build_feathers(sp, sk, P, R, bvh, y_limit=None):
    """Raptor lane: ordered, layered feather cards per zone (FEATHERS), each card rigid on one bone.
    y_limit (raptor2): no card tip reaches past this Y (the catalog length envelope behind the
    nose); a card that would is shortened. Returns {"feather_<zone>": [objects]} (one object per
    bone, tagged detail:<bone>)."""
    spec = FEATHERS.get(sp["key"])
    if not spec:
        return {}
    import random

    L = sp["length"]

    def rm(k):
        return max(R[k]) if k in R else 0.0

    def surf(p, push=None):
        loc, n, _i, _dd = bvh.find_nearest(p if push is None else p + push)
        return (p, Z) if loc is None else (loc, n)

    groups = {}

    def card(zone, bone, base, d, flat, ln, w, droop=0.12):
        key = (zone, bone)
        if key not in groups:
            groups[key] = (bmesh.new(), [])
        bm, attrs = groups[key]
        ln *= random.uniform(0.92, 1.08)
        dn = d.normalized()
        if y_limit is not None:
            reach = dn.y + 0.05
            if reach > 1e-3 and base.y + ln * reach > y_limit:
                ln = max((y_limit - base.y) / reach, ln * 0.35)
        made = feather_card(bm, base, dn, flat, ln, w * random.uniform(0.92, 1.08), droop)
        if y_limit is not None:
            # Exact clamp: pull a card that still overshoots back toward its base.
            far = max(v.co.y for v, _t, _u in made)
            if far > y_limit and far - base.y > 1e-6:
                k = max((y_limit - base.y) / (far - base.y), 0.0)
                for v, _t, _u in made:
                    v.co = base + (v.co - base) * k
        attrs.extend(made)

    sides = ((1, "L"), (-1, "R"))
    step = 0.011 * L  # outward step between stacked wing tiers
    for side, sfx in sides:
        arm = [P["shoulder" + sfx], P["elbow" + sfx], P["wrist" + sfx], P["finger0" + sfx].lerp(P["finger1" + sfx], 0.5)]
        sx = X * side
        rs = rm("shoulder" + sfx)

        def wing_row(zone, n, t0, t1, ln_of, w, ang0, ang1, tier, lift, droop):
            for i in range(n):
                u = i / max(n - 1, 1)
                t = t0 + (t1 - t0) * u
                p, _seg, _dir = _polyline(arm, t)
                base, _nrm = surf(p + Z * lift, sx * rs)
                base = base + sx * step * tier
                ang = ang0 + (ang1 - ang0) * u
                d = Y * math.cos(ang) - Z * math.sin(ang) + sx * 0.08
                # Vane normal tilted up and out: each tier's lower edge tucks under the next.
                flat = sx + Z * (0.3 + 0.08 * tier) + Y * random.uniform(-0.12, 0.12)
                card(zone, "Arm" + sfx, base, d, flat, ln_of(u), w, droop)

        n, lf, wf = spec["primary"][:3]
        wing_row("primary", n, 0.62, 1.0, lambda u: lf * L * (0.85 + 0.3 * u), wf * L, 0.55, 0.85, 0, -0.01 * L, 0.06)
        n, lf, wf = spec["secondary"][:3]
        wing_row("secondary", n, 0.12, 0.72, lambda u: lf * L * (0.9 + 0.2 * u), wf * L, 0.18, 0.5, 1, 0.0, 0.06)
        n, lf, wf = spec["covert"][:3]
        wing_row("covert", n, 0.1, 0.78, lambda u: lf * L * (1.0 + 0.2 * u), wf * L, 0.2, 0.45, 2, 0.022 * L, 0.1)
        wing_row("covert", n, 0.0, 0.55, lambda u: lf * L * 0.62, wf * L * 0.9, 0.15, 0.35, 3, 0.04 * L, 0.12)
    # Tail: a horizontal rectrix fan with a shorter covert layer over its roots, then a plume.
    tails = [P["pelvis"]] + [P[f"tail{i}"] for i in range(1, 6) if f"tail{i}" in P]
    for zone, t0, t1, lift, outk in (("tail", 0.32, 0.97, 0.0, 0.62), ("tailcov", 0.26, 0.86, 0.012 * L, 0.38)):
        n, lf, wf = spec[zone][:3]
        for side, sfx in sides:
            sx = X * side
            for i in range(n):
                t = t0 + (t1 - t0) * i / max(n - 1, 1)
                p, seg, tdir = _polyline(tails, t)
                tr = max(rm(f"tail{seg + 1}"), 0.012 * L)
                base, nrm = surf(p + Z * lift, sx * tr)
                base = base - nrm * wf * L * 0.04 + Z * lift
                d = tdir + sx * (outk - 0.25 * t) - Z * 0.03
                flat = Z + sx * (0.25 if zone == "tail" else 0.1)
                card(zone, f"Tail{min(seg + 1, 5)}", base, d, flat, lf * L * (0.75 + 0.45 * t), wf * L * (1.0 + 0.4 * t), 0.04)
    p, seg, tdir = _polyline(tails, 0.86)
    for k, a in enumerate((-0.4, 0.0, 0.4)):
        card("tail", f"Tail{min(seg + 1, 5)}", p + Z * 0.008 * L, tdir + X * a, Z, spec["tail"][1] * L * (1.1 if k == 1 else 0.95), spec["tail"][2] * L, 0.05)
    # Ruff: RUFF_ANGLES rows wrapped round the neck, each card lying back toward the body.
    neck = [P["chest"].lerp(P["neck_a"], 0.3), P["neck_a"], P["neck_b"], P["head_back"]]
    n, lf, wf = spec["ruff"][:3]
    rn = max(rm("neck_a"), rm("neck_b"))
    for i in range(n):
        t = 0.04 + 0.86 * i / max(n - 1, 1)
        p, seg, ndir = _polyline(neck, t)
        upv = (Z - ndir * Z.dot(ndir)).normalized()
        bone = "Neck1" if seg == 0 else ("Head" if t > 0.86 else "Neck2")
        for ang, kl in RUFF_ANGLES:
            o = upv * math.cos(ang) + X * math.sin(ang)
            base, nrm = surf(p, o * rn * 1.4)
            base = base - nrm * wf * L * 0.08
            d = -ndir * 0.85 + o * 0.4
            card("ruff", bone, base, d, o, lf * L * kl * (1.2 - 0.4 * t), wf * L, 0.2)
    # Back: two shingled rows of contour feathers over the chest and hips.
    n, lf, wf = spec["back"][:3]
    spine = [P["chest"], P["belly"], P["pelvis"]]
    for side, sfx in sides:
        for row, (xo, zo) in enumerate(((0.35, 0.92), (0.72, 0.62))):
            for i in range(n):
                t = (i + 0.5 * row) / n
                p, seg, _sd = _polyline(spine, min(t, 1.0))
                r = max(rm("chest"), rm("belly"), rm("pelvis"))
                base, nrm = surf(p, X * side * r * xo + Z * r * zo)
                base = base - nrm * wf * L * 0.06
                d = (Y * 0.9 - Z * 0.3 + X * side * 0.25 * (1 + row))
                card("back", "Chest" if seg == 0 else "Spine", base, d, nrm, lf * L, wf * L, 0.15)
    # Thigh: feathered trousers hanging off the hip.
    n, lf, wf = spec["thigh"][:3]
    for side, sfx in sides:
        hip, knee = P["hip" + sfx], P["knee" + sfx]
        for i in range(n):
            t = 0.15 + 0.5 * i / max(n - 1, 1)
            a = -0.6 + 1.2 * ((i * 0.618) % 1.0)
            p = hip.lerp(knee, t)
            base, nrm = surf(p, X * side * rm("hip" + sfx) * 1.2 + Y * rm("hip" + sfx) * a)
            base = base - nrm * wf * L * 0.06
            d = (-Z * 0.85 + Y * 0.45 + X * side * 0.12)
            card("thigh", "Thigh" + sfx, base, d, nrm, lf * L, wf * L, 0.15)
    floor = 0.04 * L
    out = {}
    for (zone, bone), (bm, attrs) in groups.items():
        for v, _t, _u in attrs:
            v.co.z = max(v.co.z, floor)
        tv = {v: (t, u) for v, t, u in attrs}
        bm.verts.index_update()
        order = [tv[v] for v in bm.verts]
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        obj = detail_object(f"feathers_{zone}_{bone}", bm, bone)
        me = obj.data
        at = me.attributes.new("fthr_t", "FLOAT", "POINT")
        au = me.attributes.new("fthr_u", "FLOAT", "POINT")
        for i, (t, u) in enumerate(order):
            at.data[i].value = t
            au.data[i].value = u
        # Flat shading keeps the ridge: the two vane halves bake to different values.
        for poly in me.polygons:
            poly.use_smooth = False
        out.setdefault("feather_" + zone, []).append(obj)
    return out


def feather_tris(key):
    return feather_cards(key) * CARD_TRIS


def copy_fur_weights(body):
    """Each fur clump takes the bone weights of the body vertex under its base."""
    from mathutils.kdtree import KDTree

    me = body.data
    isf = me.attributes.get("is_fur")
    if isf is None:
        return 0
    flags = [d.value > 0.5 for d in isf.data]
    bases = [Vector(d.vector) for d in me.attributes["fur_base"].data]
    kd = KDTree(len(flags) - sum(flags))
    for v in me.vertices:
        if not flags[v.index]:
            kd.insert(v.co, v.index)
    kd.balance()
    groups = {g.index: g for g in body.vertex_groups}
    n = 0
    for v in me.vertices:
        if not flags[v.index]:
            continue
        _co, src, _d = kd.find(bases[v.index])
        ws = [(ge.group, ge.weight) for ge in me.vertices[src].groups if ge.weight > 1e-4]
        for g in groups.values():
            g.remove([v.index])
        for gi, w in ws:
            groups[gi].add([v.index], w, "REPLACE")
        n += 1
    me.attributes.remove(me.attributes["is_fur"])
    me.attributes.remove(me.attributes["fur_base"])
    me.attributes.remove(me.attributes["fur_tip"])
    return n


def leaf(bm, base, tip, width, thick, cup, facing, segments=10, rings=8):
    """Cupped ear: a deformed sphere, widest near the base, pointed at the tip, bowl toward `facing`."""
    u = tip - base
    length = u.length
    u.normalize()
    nrm = Vector(facing) - u * Vector(facing).dot(u)
    nrm.normalize()
    v = u.cross(nrm).normalized()
    tmp = bmesh.new()
    bmesh.ops.create_uvsphere(tmp, u_segments=segments, v_segments=rings, radius=1.0)
    for vert in tmp.verts:
        x, y, z = vert.co
        t = (z + 1) / 2
        prof = math.sin(math.pi * min(1.0, 0.12 + 0.88 * t)) ** 0.7 * (1.0 - 0.4 * t)
        yd = y * thick * (0.35 + 0.65 * prof) - cup * width * prof * (1 - x * x) * 0.45
        vert.co = base + u * length * t + v * (x * width * prof) + nrm * yd
    me = bpy.data.meshes.new("leaf_tmp")
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


# ------------------------------------------------------------------ materials


def make_hide_mat(sp, sk):
    s = sk["scale"]
    length = sp["length"]

    def hide_mat(nodes, links):
        coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
        geo = nodes.new("ShaderNodeNewGeometry")
        nz = nodes.new("ShaderNodeSeparateXYZ")
        links.new(geo.outputs["Normal"], nz.inputs["Vector"])
        # L4b countershading: light ventral -> body flank -> darker dorsal stripe (value contrast
        # the references carry), then darker extremities below.
        dorsal = C.hexlin(sp["dorsal"]) if "dorsal" in sp else lerp3(C.hexlin(sp["body"]), C.hexlin(sp["stripe"]), 0.55)
        shade = C.ramp(nodes, links, nz.outputs["Z"], [(-0.7, C.hexlin(sp["belly"])), (-0.4, lerp3(C.hexlin(sp["belly"]), C.hexlin(sp["body"]), 0.25)), (0.0, C.hexlin(sp["body"])), (0.4, C.hexlin(sp["body"])), (0.9, dorsal)])
        # v2: per-species pattern layers (PATTERNS) over the countershaded base, plus a soft
        # low-frequency mottle so no two flanks read as one flat fill.
        mot = C.noise(nodes, 2.2 / length, 3, 0.5, coord, links)
        mott = C.ramp(nodes, links, mot.outputs["Fac"], [(0.3, (0.88, 0.88, 0.88)), (0.7, (1.1, 1.1, 1.1))])
        base_m = nodes.new("ShaderNodeMix")
        base_m.data_type = "RGBA"
        base_m.blend_type = "MULTIPLY"
        base_m.inputs["Factor"].default_value = 1.0
        links.new(shade.outputs["Color"], base_m.inputs["A"])
        links.new(mott.outputs["Color"], base_m.inputs["B"])
        col = base_m.outputs["Result"]
        back = C.ramp(nodes, links, nz.outputs["Z"], [(-0.2, (0, 0, 0)), (0.25, (1, 1, 1))]).outputs["Color"]
        hip_z = sk["hip_z"]
        sz = nodes.new("ShaderNodeSeparateXYZ")
        links.new(coord, sz.inputs["Vector"])

        def scaled_coord(k):
            mp0 = nodes.new("ShaderNodeMapping")
            mp0.inputs["Scale"].default_value = (k, k, k)
            links.new(coord, mp0.inputs["Vector"])
            return mp0.outputs["Vector"]

        def voronoi(k, feature="F1"):
            v = nodes.new("ShaderNodeTexVoronoi")
            v.feature = feature
            v.inputs["Scale"].default_value = 1.0
            v.inputs["Randomness"].default_value = 0.9
            # warp the cells a little so spots are not perfect discs
            w = C.noise(nodes, k * 1.5, 2, 0.5, coord, links)
            off = nodes.new("ShaderNodeVectorMath")
            off.operation = "MULTIPLY_ADD"
            links.new(w.outputs["Color"], off.inputs[0])
            off.inputs[1].default_value = (0.35, 0.35, 0.35)
            links.new(scaled_coord(k), off.inputs[2])
            links.new(off.outputs["Vector"], v.inputs["Vector"])
            return v.outputs["Distance"]

        def pattern_mask(kind, q):
            if kind == "spots":
                k = 1.0 / (q["size"] * length)
                return C.ramp(nodes, links, voronoi(k), [(q["r"] * 0.75, (1, 1, 1)), (q["r"], (0, 0, 0))]).outputs["Color"]
            if kind == "rosette":
                k = 1.0 / (q["size"] * length)
                return C.ramp(nodes, links, voronoi(k), [(0.14, (0, 0, 0)), (0.2, (1, 1, 1)), (0.27, (1, 1, 1)), (0.33, (0, 0, 0))]).outputs["Color"]
            if kind == "reticulate":
                k = 1.0 / (q["size"] * length)
                return C.ramp(nodes, links, voronoi(k, "DISTANCE_TO_EDGE"), [(q["w"] * 0.5, (1, 1, 1)), (q["w"], (0, 0, 0))]).outputs["Color"]
            if kind == "blotch":
                n0 = C.noise(nodes, 1.0 / (q["size"] * length), 3, 0.55, coord, links)
                return C.ramp(nodes, links, n0.outputs["Fac"], [(q["t"], (0, 0, 0)), (q["t"] + 0.06, (1, 1, 1))]).outputs["Color"]
            if kind == "bands":
                wave = nodes.new("ShaderNodeTexWave")
                wave.wave_type = "BANDS"
                wave.bands_direction = "Y"
                wave.inputs["Scale"].default_value = 0.32 * q["count"] / length
                wave.inputs["Distortion"].default_value = q.get("distortion", 6)
                wave.inputs["Detail"].default_value = 3.0
                wave.inputs["Detail Scale"].default_value = 1.5
                links.new(coord, wave.inputs["Vector"])
                if q.get("sharp"):
                    return C.ramp(nodes, links, wave.outputs["Fac"], [(0.45, (0, 0, 0)), (0.6, (1, 1, 1))]).outputs["Color"]
                brk = C.noise(nodes, 3.5 * 3.55 / length, 4, 0.55, coord, links)
                sm = nodes.new("ShaderNodeMath")
                sm.operation = "MULTIPLY"
                links.new(wave.outputs["Fac"], sm.inputs[0])
                links.new(brk.outputs["Fac"], sm.inputs[1])
                return C.ramp(nodes, links, sm.outputs["Value"], [(0.3, (0, 0, 0)), (0.42, (1, 1, 1))]).outputs["Color"]
            if kind == "saddle":
                n0 = C.noise(nodes, 6.0 / length, 3, 0.6, coord, links)
                add = nodes.new("ShaderNodeMath")
                add.operation = "MULTIPLY_ADD"
                links.new(n0.outputs["Fac"], add.inputs[0])
                add.inputs[1].default_value = 0.5
                links.new(nz.outputs["Z"], add.inputs[2])
                return C.ramp(nodes, links, add.outputs["Value"], [(0.55, (0, 0, 0)), (0.95, (1, 1, 1))]).outputs["Color"]
            if kind == "socks":
                return C.ramp(nodes, links, sz.outputs["Z"], [(hip_z * 0.18, (1, 1, 1)), (hip_z * 0.45, (0, 0, 0))]).outputs["Color"]
            if kind == "head":
                vm = nodes.new("ShaderNodeVectorMath")
                vm.operation = "DISTANCE"
                links.new(coord, vm.inputs[0])
                vm.inputs[1].default_value = sk["head_c"]
                hl = sk["head_l"]
                n1 = C.noise(nodes, 6.0 / hl, 3, 0.6, coord, links)
                sm = nodes.new("ShaderNodeMath")
                sm.operation = "MULTIPLY_ADD"
                links.new(n1.outputs["Fac"], sm.inputs[0])
                sm.inputs[1].default_value = hl * 0.35
                links.new(vm.outputs["Value"], sm.inputs[2])
                return C.ramp(nodes, links, sm.outputs["Value"], [(hl * q["r"] * 0.7, (1, 1, 1)), (hl * q["r"] * 1.15, (0, 0, 0))]).outputs["Color"]
            if kind == "dust":
                n0 = C.noise(nodes, 4.0 / length, 3, 0.6, coord, links)
                add = nodes.new("ShaderNodeMath")
                add.operation = "MULTIPLY_ADD"
                links.new(n0.outputs["Fac"], add.inputs[0])
                add.inputs[1].default_value = 0.35
                links.new(nz.outputs["Z"], add.inputs[2])
                return C.ramp(nodes, links, add.outputs["Value"], [(0.6, (0, 0, 0)), (0.95, (1, 1, 1))]).outputs["Color"]
            if kind == "grizzle":
                n0 = C.noise(nodes, 60.0 / length, 2, 0.5, coord, links)
                return C.ramp(nodes, links, n0.outputs["Fac"], [(0.5, (0, 0, 0)), (0.62, (1, 1, 1))]).outputs["Color"]
            if kind == "neck":
                # Raptor lane: the neck tube (chest -> skull) in its own colour, soft at the ends.
                acc = None
                for pt, r in sk["neck_mask"]:
                    vm = nodes.new("ShaderNodeVectorMath")
                    vm.operation = "DISTANCE"
                    links.new(coord, vm.inputs[0])
                    vm.inputs[1].default_value = tuple(pt)
                    m = C.ramp(nodes, links, vm.outputs["Value"], [(r * 0.85, (1, 1, 1)), (r * 1.3, (0, 0, 0))]).outputs["Color"]
                    if acc is None:
                        acc = m
                    else:
                        lt = nodes.new("ShaderNodeMix")
                        lt.data_type = "RGBA"
                        lt.blend_type = "LIGHTEN"
                        lt.inputs["Factor"].default_value = 1.0
                        links.new(acc, lt.inputs["A"])
                        links.new(m, lt.inputs["B"])
                        acc = lt.outputs["Result"]
                return acc
            raise ValueError(kind)

        # Extremities: lower legs and feet, the tail tip and the muzzle tip run darker.
        ext_c = nodes.new("ShaderNodeRGB")
        ext_c.outputs[0].default_value = (*lerp3(C.hexlin(sp["stripe"]), (0.01, 0.008, 0.006), 0.25), 1)
        legs_m = C.ramp(nodes, links, sz.outputs["Z"], [(hip_z * 0.12, (0.7, 0.7, 0.7)), (hip_z * 0.5, (0, 0, 0))]).outputs["Color"]
        if sp["plan"] not in ("turtle", "crocodilian"):
            col = C.mix(nodes, links, legs_m, col, ext_c.outputs[0])
        ty0, ty1 = sk["tail_y"]
        tail_m = C.ramp(nodes, links, sz.outputs["Y"], [(ty0 + (ty1 - ty0) * 0.55, (0, 0, 0)), (ty1, (0.6, 0.6, 0.6))]).outputs["Color"]
        col = C.mix(nodes, links, tail_m, col, ext_c.outputs[0])
        for kind, colour, strength, region, q in PATTERNS[sp["key"]]:
            mask = pattern_mask(kind, q)
            k = nodes.new("ShaderNodeMath")
            k.operation = "MULTIPLY"
            links.new(mask, k.inputs[0])
            k.inputs[1].default_value = strength
            fac = k.outputs["Value"]
            if region == "upper":
                k2 = nodes.new("ShaderNodeMath")
                k2.operation = "MULTIPLY"
                links.new(fac, k2.inputs[0])
                links.new(back, k2.inputs[1])
                fac = k2.outputs["Value"]
            pc = nodes.new("ShaderNodeRGB")
            pc.outputs[0].default_value = (*C.hexlin(sp.get(colour, colour)), 1)
            col = C.mix(nodes, links, fac, col, pc.outputs[0])

        def dist_to(point, radius_in, radius_out):
            vm = nodes.new("ShaderNodeVectorMath")
            vm.operation = "DISTANCE"
            links.new(coord, vm.inputs[0])
            vm.inputs[1].default_value = point
            return C.ramp(nodes, links, vm.outputs["Value"], [(radius_in, (1, 1, 1)), (radius_out, (0, 0, 0))]).outputs["Color"]

        dark = nodes.new("ShaderNodeRGB")
        dark.outputs[0].default_value = (*C.hexlin("#1c1712"), 1)
        eye, nos = sk["eye"], sk["nostril"]
        es = sk["eye_r_abs"]
        for side in (1, -1):
            col = C.mix(nodes, links, dist_to((nos.x * side, nos.y, nos.z), es * 0.22, es * 0.4), col, dark.outputs[0])
            ring = dist_to((eye.x * side, eye.y + es * 0.9, eye.z), es, es * 2.2)
            k = nodes.new("ShaderNodeMath")
            k.operation = "MULTIPLY"
            k.inputs[1].default_value = 0.65
            links.new(ring, k.inputs[0])
            stripe2 = nodes.new("ShaderNodeRGB")
            stripe2.outputs[0].default_value = (*C.hexlin(sp["stripe"]), 1)
            col = C.mix(nodes, links, k.outputs["Value"], col, stripe2.outputs[0])
            # L4d: pale lid ring outside the socket (the eye reads as a framed spot, not a bead).
            e0 = Vector((eye.x * side, eye.y, eye.z))
            outer = dist_to(e0, es * 1.5, es * 2.1)
            inner = dist_to(e0, es * 1.05, es * 1.35)
            lid = nodes.new("ShaderNodeMath")
            lid.operation = "SUBTRACT"
            lid.use_clamp = True
            links.new(outer, lid.inputs[0])
            links.new(inner, lid.inputs[1])
            lk = nodes.new("ShaderNodeMath")
            lk.operation = "MULTIPLY"
            lk.inputs[1].default_value = 0.35
            links.new(lid.outputs["Value"], lk.inputs[0])
            pale = nodes.new("ShaderNodeRGB")
            pale.outputs[0].default_value = (*lerp3(C.hexlin(sp["belly"]), (1, 1, 1), 0.2), 1)
            col = C.mix(nodes, links, lk.outputs["Value"], col, pale.outputs[0])
            sock = dist_to(e0, es * 1.0, es * 1.3)
            sk2 = nodes.new("ShaderNodeMath")
            sk2.operation = "MULTIPLY"
            sk2.inputs[1].default_value = 0.85
            links.new(sock, sk2.inputs[0])
            col = C.mix(nodes, links, sk2.outputs["Value"], col, dark.outputs[0])
        # CC0 leather scan as micro-detail at a constant texel density per stud.
        mp = nodes.new("ShaderNodeMapping")
        density = 1.25 if length < 8 else 0.7
        mp.inputs["Scale"].default_value = (density, density, density)
        links.new(coord, mp.inputs["Vector"])
        la = nodes.new("ShaderNodeTexImage")
        la.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_albedo_1k.png"))
        la.projection = "BOX"
        la.projection_blend = 0.3
        links.new(mp.outputs["Vector"], la.inputs["Vector"])
        bw = nodes.new("ShaderNodeRGBToBW")
        links.new(la.outputs["Color"], bw.inputs["Color"])
        det = C.ramp(nodes, links, bw.outputs["Val"], [(0.05, (0.62, 0.62, 0.62)), (0.25, (1.2, 1.2, 1.2))])
        mul = nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        links.new(col, mul.inputs["A"])
        links.new(det.outputs["Color"], mul.inputs["B"])
        ln = nodes.new("ShaderNodeTexImage")
        ln.image = C.load_image(os.path.join(C.SRC_DIR, "brown_leather", "brown_leather_nor_gl_1k.png"), True)
        ln.projection = "BOX"
        ln.projection_blend = 0.3
        links.new(mp.outputs["Vector"], ln.inputs["Vector"])
        nmap = nodes.new("ShaderNodeNormalMap")
        nmap.inputs["Strength"].default_value = 1.5
        links.new(ln.outputs["Color"], nmap.inputs["Color"])
        vor = nodes.new("ShaderNodeTexVoronoi")
        vor.inputs["Scale"].default_value = min(23.0, 380.0 / length)
        links.new(coord, vor.inputs["Vector"])
        b = nodes.new("ShaderNodeBump")
        b.inputs["Strength"].default_value = 0.3
        links.new(vor.outputs["Distance"], b.inputs["Height"])
        links.new(nmap.outputs["Normal"], b.inputs["Normal"])
        col, height, hstr, rough_lo, rough_hi = skin_detail(nodes, links, coord, sp, mul.outputs["Result"])
        nb = nodes.new("ShaderNodeBump")
        nb.inputs["Strength"].default_value = hstr
        nb.inputs["Distance"].default_value = 0.02 * length
        links.new(height, nb.inputs["Height"])
        links.new(b.outputs["Normal"], nb.inputs["Normal"])
        # Fur shells: darker roots, sun-bleached tips (attributes from build_fur, 0 on the body).
        isf = nodes.new("ShaderNodeAttribute")
        isf.attribute_name = "is_fur"
        tip = nodes.new("ShaderNodeAttribute")
        tip.attribute_name = "fur_tip"
        root = 0.92 if sp.get("height_shade") else 0.78
        tipc = C.ramp(nodes, links, tip.outputs["Fac"], [(0.0, (root, root, root)), (1.0, (1.04, 1.03, 1.0))])
        col = multiply(nodes, links, col, C.mix(nodes, links, isf.outputs["Fac"], white(nodes), tipc.outputs["Color"]))
        if sp["key"] in PAINTED_PLUME:
            col = painted_plume(nodes, links, coord, sp, sk, col, nz)
        col = occlusion(nodes, links, col, length, sp)
        col = paint_light(nodes, links, col, nb.outputs["Normal"])
        col = rim_light(nodes, links, col, nb.outputs["Normal"], sp)
        rough = C.ramp(nodes, links, height, [(0.2, (rough_hi,) * 3), (0.8, (rough_lo,) * 3)])
        return col, rough.outputs["Color"], nb.outputs["Normal"]

    return hide_mat


def painted_plume(nodes, links, coord, sp, sk, col, nz):
    """L4d: plumage painted into the colour map instead of shells. Overlapping feather rows that
    run back along the body (stretched scallops: a soft dark lower edge under each row), darker
    barred wing and tail-tip feathering from the plume colours, and a soft darker underside of the
    feather mass so the coat reads as layered, not flat."""
    rows, contrast, bar = PAINTED_PLUME[sp["key"]]
    L = sp["length"]
    k = rows / L
    mp = nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (k * 1.3, k * 0.45, k * 1.6)
    links.new(coord, mp.inputs["Vector"])
    v = nodes.new("ShaderNodeTexVoronoi")
    v.feature = "F1"
    v.inputs["Randomness"].default_value = 0.6
    links.new(mp.outputs["Vector"], v.inputs["Vector"])
    edge = C.ramp(nodes, links, v.outputs["Distance"], [(0.0, (1.06, 1.05, 1.03)), (0.55, (1, 1, 1)), (0.85, (1 - contrast,) * 3)])
    col = multiply(nodes, links, col, edge.outputs["Color"])
    # Barring on the wing (arm) and the tail-tip fan, in the plume colours.
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord, sep.inputs["Vector"])
    ty0, ty1 = sk["tail_y"]
    tailm = C.ramp(nodes, links, sep.outputs["Y"], [(ty0 + (ty1 - ty0) * 0.6, (0, 0, 0)), (ty0 + (ty1 - ty0) * 0.8, (1, 1, 1))]).outputs["Color"]
    side = nodes.new("ShaderNodeMath")
    side.operation = "ABSOLUTE"
    links.new(sep.outputs["X"], side.inputs[0])
    arm_pts = [p for pts in sk["arm_pts"].values() for p in pts]
    if arm_pts:
        ay = sum(p[1] for p in arm_pts) / len(arm_pts)
        az = sum(p[2] for p in arm_pts) / len(arm_pts)
        vm = nodes.new("ShaderNodeVectorMath")
        vm.operation = "DISTANCE"
        cxyz = nodes.new("ShaderNodeCombineXYZ")
        links.new(side.outputs["Value"], cxyz.inputs["X"])
        links.new(sep.outputs["Y"], cxyz.inputs["Y"])
        links.new(sep.outputs["Z"], cxyz.inputs["Z"])
        links.new(cxyz.outputs["Vector"], vm.inputs[0])
        ax = max(abs(p[0]) for p in arm_pts)
        vm.inputs[1].default_value = (ax, ay, az)
        armm = C.ramp(nodes, links, vm.outputs["Value"], [(0.06 * L, (1, 1, 1)), (0.11 * L, (0, 0, 0))]).outputs["Color"]
        both = nodes.new("ShaderNodeMix")
        both.data_type = "RGBA"
        both.blend_type = "LIGHTEN"
        both.inputs["Factor"].default_value = 1.0
        links.new(tailm, both.inputs["A"])
        links.new(armm, both.inputs["B"])
        zone = both.outputs["Result"]
    else:
        zone = tailm
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "Y"
    wave.inputs["Scale"].default_value = 0.9 * rows / L
    wave.inputs["Distortion"].default_value = 2.0
    links.new(coord, wave.inputs["Vector"])
    barc = C.ramp(nodes, links, wave.outputs["Fac"], [(0.35, C.hexlin(sp["plume"])), (0.65, lerp3(C.hexlin(sp["plume"]), C.hexlin(sp["plume_tip"]), 0.55))])
    fac = nodes.new("ShaderNodeMath")
    fac.operation = "MULTIPLY"
    fac.inputs[1].default_value = bar
    bw = nodes.new("ShaderNodeRGBToBW")
    links.new(zone, bw.inputs["Color"])
    links.new(bw.outputs["Val"], fac.inputs[0])
    col = C.mix(nodes, links, fac.outputs["Value"], col, barc.outputs["Color"])
    # Underside of the feather mass a little darker (the flank under the folded wing).
    under = C.ramp(nodes, links, nz.outputs["Z"], [(-0.6, (0.88, 0.87, 0.86)), (-0.1, (1, 1, 1))])
    return multiply(nodes, links, col, under.outputs["Color"])


def white(nodes):
    w = nodes.new("ShaderNodeRGB")
    w.outputs[0].default_value = (1, 1, 1, 1)
    return w.outputs[0]


def multiply(nodes, links, a, b):
    m = nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    m.blend_type = "MULTIPLY"
    m.inputs["Factor"].default_value = 1.0
    links.new(a, m.inputs["A"])
    links.new(b, m.inputs["B"])
    return m.outputs["Result"]


# Per-skin tiling detail (L4b): cells per stud scale with body size so a 512/1024 bake still
# resolves them. (cells per body length, bump strength, edge darkening).
SKIN = {
    "scales": (46.0, 0.7, 0.42),
    "plates": (30.0, 0.8, 0.4),
    "wrinkle": (26.0, 0.65, 0.6),
    "fur": (90.0, 0.45, 0.7),
    "feathers": (40.0, 0.5, 0.6),
}


def skin_detail(nodes, links, coord, sp, col):
    """Height + albedo detail per skin: scales (voronoi cells, dark seams, per-cell tint), plates
    (bigger cells), wrinkle (crossing crease network), fur (stretched strands), feathers
    (overlapping scallops). Returns (col, height, bump strength, rough lo, rough hi)."""
    skin = sp.get("skin", "scales")
    cells, strength, edge_dark = SKIN[skin]
    k = cells / sp["length"]
    mp = nodes.new("ShaderNodeMapping")
    stretch = {"fur": (k * 1.4, k * 0.25, k * 1.4), "feathers": (k * 1.1, k * 0.7, k * 1.1), "wrinkle": (k * 0.6, k * 1.8, k * 0.6)}.get(skin, (k, k, k))
    mp.inputs["Scale"].default_value = stretch
    links.new(coord, mp.inputs["Vector"])
    if skin in ("scales", "plates", "feathers"):
        v = nodes.new("ShaderNodeTexVoronoi")
        v.feature = "DISTANCE_TO_EDGE"
        links.new(mp.outputs["Vector"], v.inputs["Vector"])
        v1 = nodes.new("ShaderNodeTexVoronoi")
        v1.feature = "F1"
        links.new(mp.outputs["Vector"], v1.inputs["Vector"])
        if skin == "feathers":
            # Scallop: edge distance shaped into a raised rounded lip with a dark under-edge.
            h = C.ramp(nodes, links, v1.outputs["Distance"], [(0.0, (1, 1, 1)), (0.55, (0.55, 0.55, 0.55)), (0.75, (0.1, 0.1, 0.1))])
        else:
            h = C.ramp(nodes, links, v.outputs["Distance"], [(0.0, (0, 0, 0)), (0.09, (0.55, 0.55, 0.55)), (0.3, (1, 1, 1))])
        height = h.outputs["Color"]
        seam = C.ramp(nodes, links, v.outputs["Distance"], [(0.02, (edge_dark,) * 3), (0.12, (1, 1, 1))])
        tint = C.ramp(nodes, links, v1.outputs["Color"], [(0.0, (0.86, 0.86, 0.86)), (1.0, (1.1, 1.08, 1.04))])
        col = multiply(nodes, links, multiply(nodes, links, col, seam.outputs["Color"]), tint.outputs["Color"])
        return col, height, strength, 0.62, 0.9
    if skin == "wrinkle":
        v = nodes.new("ShaderNodeTexVoronoi")
        v.feature = "DISTANCE_TO_EDGE"
        links.new(mp.outputs["Vector"], v.inputs["Vector"])
        n = C.noise(nodes, 1.0, 6, 0.7, mp.outputs["Vector"], links)
        add = nodes.new("ShaderNodeMath")
        add.operation = "MULTIPLY_ADD"
        links.new(v.outputs["Distance"], add.inputs[0])
        add.inputs[1].default_value = 2.2
        links.new(n.outputs["Fac"], add.inputs[2])
        h = C.ramp(nodes, links, add.outputs["Value"], [(0.35, (0, 0, 0)), (0.7, (1, 1, 1))])
        crease = C.ramp(nodes, links, v.outputs["Distance"], [(0.015, (edge_dark,) * 3), (0.08, (1, 1, 1))])
        col = multiply(nodes, links, col, crease.outputs["Color"])
        return col, h.outputs["Color"], strength, 0.8, 0.95
    # fur: long strands along the body axis, broken into tufts.
    n = C.noise(nodes, 1.0, 10, 0.75, mp.outputs["Vector"], links)
    w = nodes.new("ShaderNodeTexWave")
    w.wave_type = "BANDS"
    w.bands_direction = "X"
    w.inputs["Scale"].default_value = 1.0
    w.inputs["Distortion"].default_value = 9.0
    w.inputs["Detail"].default_value = 6.0
    links.new(mp.outputs["Vector"], w.inputs["Vector"])
    m = nodes.new("ShaderNodeMath")
    m.operation = "MULTIPLY"
    links.new(n.outputs["Fac"], m.inputs[0])
    links.new(w.outputs["Fac"], m.inputs[1])
    h = C.ramp(nodes, links, m.outputs["Value"], [(0.05, (0, 0, 0)), (0.45, (1, 1, 1))])
    if sp.get("height_shade"):
        edge_dark = 0.86
    tone = C.ramp(nodes, links, m.outputs["Value"], [(0.05, (edge_dark,) * 3), (0.5, (1.08, 1.07, 1.04))])
    col = multiply(nodes, links, col, tone.outputs["Color"])
    return col, h.outputs["Color"], strength, 0.85, 0.97


def occlusion(nodes, links, col, length, sp, fur_ok=True):
    """Baked ambient occlusion (local to the creature) + curvature dirt in the creases."""
    ao = nodes.new("ShaderNodeAmbientOcclusion")
    ao.only_local = True
    ao.samples = 16
    ao.inputs["Distance"].default_value = 0.08 * length
    aoc = C.ramp(nodes, links, ao.outputs["AO"], [(0.15, (0.42, 0.4, 0.38)), (0.85, (1, 1, 1))])
    # Shells sit on the skin, so their local AO is mostly self-shadow: keep a quarter of it.
    isf = nodes.new("ShaderNodeAttribute")
    isf.attribute_name = "is_fur"
    k = nodes.new("ShaderNodeMath")
    k.operation = "MULTIPLY"
    k.inputs[1].default_value = 0.75
    links.new(isf.outputs["Fac"], k.inputs[0])
    if fur_ok:
        aof = C.mix(nodes, links, k.outputs["Value"], aoc.outputs["Color"], white(nodes))
    else:
        aof = aoc.outputs["Color"]
    col = multiply(nodes, links, col, aof)
    geo = nodes.new("ShaderNodeNewGeometry")
    dirt = C.ramp(nodes, links, geo.outputs["Pointiness"], [(0.44, (0.62, 0.58, 0.54)), (0.5, (1, 1, 1)), (0.56, (1.08, 1.08, 1.06))])
    # L4c: shells skip the curvature dirt (thin shells read as dark scabs with it).
    dirt_c = C.mix(nodes, links, isf.outputs["Fac"], dirt.outputs["Color"], white(nodes)) if fur_ok else dirt.outputs["Color"]
    return multiply(nodes, links, col, dirt_c)


# L4c: Roblox clients only get the colour map (MeshPart.TextureContent via MeshTexture.bake;
# normal and roughness maps never reach the device), so the form and relief the normal map used
# to carry is painted into the albedo: a soft key from above-front (relief from the bumped
# normal), a sky/bounce gradient and a final contrast/saturation lift that survives the in-game
# grade (saturation -0.12) and haze.
PAINT_LIGHT = (0.35, -0.4, 0.85)


def paint_light(nodes, links, col, normal, key=0.42, sat=1.06):
    lv = Vector(PAINT_LIGHT).normalized()
    dot = nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    if normal is None:
        normal = nodes.new("ShaderNodeNewGeometry").outputs["Normal"]
    links.new(normal, dot.inputs[0])
    dot.inputs[1].default_value = tuple(lv)
    # Multiplicative only (linear-safe): shadow side ~0.75, lit side ~1.15, mean ~1.0.
    lo, hi = 1.0 - key * 0.6, 1.0 + key * 0.36
    shade = C.ramp(nodes, links, dot.outputs["Value"], [(-0.2, (lo * 0.98, lo * 0.97, lo * 1.03)), (0.3, (1.0, 1.0, 1.0)), (0.9, (hi, hi * 0.98, hi * 0.94))])
    col = multiply(nodes, links, col, shade.outputs["Color"])
    hs = nodes.new("ShaderNodeHueSaturation")
    hs.inputs["Saturation"].default_value = sat
    hs.inputs["Value"].default_value = 1.0
    links.new(col, hs.inputs["Color"])
    return hs.outputs["Color"]

def rim_light(nodes, links, col, normal, sp):
    """L4d: small dark species vanish against the olive ground at play zoom. A baked top rim
    (upward-facing surfaces pushed toward a warm pale `rim` colour) plus a value lift (`pop`) keeps
    the silhouette edge brighter than the ground; species without `pop` are unchanged."""
    pop = sp.get("pop", 0.0)
    if pop <= 0:
        return col
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(normal, sep.inputs["Vector"])
    up = C.ramp(nodes, links, sep.outputs["Z"], [(0.35, (0, 0, 0)), (0.95, (1, 1, 1))])
    k = nodes.new("ShaderNodeMath")
    k.operation = "MULTIPLY"
    k.inputs[1].default_value = pop * 0.55
    links.new(up.outputs["Color"], k.inputs[0])
    rc = nodes.new("ShaderNodeRGB")
    rc.outputs[0].default_value = (*C.hexlin(sp.get("rim", "#f0e6cc")), 1)
    scr = nodes.new("ShaderNodeMix")
    scr.data_type = "RGBA"
    scr.blend_type = "SCREEN"
    links.new(k.outputs["Value"], scr.inputs["Factor"])
    links.new(col, scr.inputs["A"])
    links.new(rc.outputs[0], scr.inputs["B"])
    lift = nodes.new("ShaderNodeHueSaturation")
    lift.inputs["Value"].default_value = 1.0 + pop * 0.25
    lift.inputs["Saturation"].default_value = 1.0 + pop * 0.15
    links.new(scr.outputs["Result"], lift.inputs["Color"])
    return lift.outputs["Color"]


def plume_mat(sp, length):
    """Feather shells: dark plume at the root, pale tip, barb streaks, a little AO."""

    def build(nodes, links):
        coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
        tip = nodes.new("ShaderNodeAttribute")
        tip.attribute_name = "fur_tip"
        c = C.ramp(nodes, links, tip.outputs["Fac"], [(0.0, C.hexlin(sp["plume"])), (0.55, C.hexlin(sp["plume"])), (1.0, C.hexlin(sp["plume_tip"]))])
        w = nodes.new("ShaderNodeTexWave")
        w.wave_type = "BANDS"
        w.inputs["Scale"].default_value = 160.0 / length
        w.inputs["Distortion"].default_value = 4.0
        links.new(coord, w.inputs["Vector"])
        barbs = C.ramp(nodes, links, w.outputs["Fac"], [(0.2, (0.78, 0.78, 0.78)), (0.8, (1.08, 1.08, 1.08))])
        col = multiply(nodes, links, c.outputs["Color"], barbs.outputs["Color"])
        col = occlusion(nodes, links, col, length, sp)
        bmp = nodes.new("ShaderNodeBump")
        bmp.inputs["Strength"].default_value = 0.35
        links.new(w.outputs["Fac"], bmp.inputs["Height"])
        col = paint_light(nodes, links, col, bmp.outputs["Normal"])
        col = rim_light(nodes, links, col, bmp.outputs["Normal"], sp)
        r = nodes.new("ShaderNodeValue")
        r.outputs[0].default_value = 0.8
        return col, r.outputs[0], bmp.outputs["Normal"]

    return build


def feather_mat(sp, zone):
    """Raptor lane feather cards: root colour -> tip colour along the card (fthr_t), crossed by
    soft bars (banded remiges and tail), a darker rachis line and darker vane edges (fthr_u), the
    shared AO/dirt, painted key light and rim, so the cards read as layered feathers, not plates."""
    _n, _l, _w, root, tip, bar = FEATHERS[sp["key"]][zone]

    def build(nodes, links):
        t = nodes.new("ShaderNodeAttribute")
        t.attribute_name = "fthr_t"
        u = nodes.new("ShaderNodeAttribute")
        u.attribute_name = "fthr_u"
        base = C.ramp(nodes, links, t.outputs["Fac"], [(0.0, lerp3(C.hexlin(root), (0, 0, 0), 0.45)), (0.35, C.hexlin(root)), (0.95, C.hexlin(tip))])
        # Raptor2: the root third is shadowed (it sits under the card above), so each tier reads as
        # a separate layer in the colour map the device gets.
        # Bars across the vane: a cosine of t, broken by world noise so neighbours do not line up.
        coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
        nz = C.noise(nodes, 3.0 / sp["length"], 2, 0.5, coord, links)
        k = nodes.new("ShaderNodeMath")
        k.operation = "MULTIPLY_ADD"
        links.new(t.outputs["Fac"], k.inputs[0])
        k.inputs[1].default_value = 4.0
        links.new(nz.outputs["Fac"], k.inputs[2])
        sn = nodes.new("ShaderNodeMath")
        sn.operation = "SINE"
        m6 = nodes.new("ShaderNodeMath")
        m6.operation = "MULTIPLY"
        m6.inputs[1].default_value = 2 * math.pi
        links.new(k.outputs["Value"], m6.inputs[0])
        links.new(m6.outputs["Value"], sn.inputs[0])
        bars = C.ramp(nodes, links, sn.outputs["Value"], [(-0.2, (1, 1, 1)), (0.5, (1 - bar,) * 3)])
        col = multiply(nodes, links, base.outputs["Color"], bars.outputs["Color"])
        au = nodes.new("ShaderNodeMath")
        au.operation = "ABSOLUTE"
        links.new(u.outputs["Fac"], au.inputs[0])
        edge = C.ramp(nodes, links, au.outputs["Value"], [(0.0, (0.8, 0.8, 0.8)), (0.12, (1.05, 1.05, 1.03)), (0.7, (1, 1, 1)), (1.0, (0.78, 0.78, 0.78))])
        col = multiply(nodes, links, col, edge.outputs["Color"])
        col = occlusion(nodes, links, col, sp["length"], sp, fur_ok=False)
        col = paint_light(nodes, links, col, None)
        col = rim_light(nodes, links, col, nodes.new("ShaderNodeNewGeometry").outputs["Normal"], sp)
        r = nodes.new("ShaderNodeValue")
        r.outputs[0].default_value = 0.85
        return col, r.outputs[0], None

    return build


def flat_mat(hexcol, rough):
    def build(nodes, links):
        c = nodes.new("ShaderNodeRGB")
        c.outputs[0].default_value = (*C.hexlin(hexcol), 1)
        r = nodes.new("ShaderNodeValue")
        r.outputs[0].default_value = rough
        # L4c: horn/claw/accent tips get the same painted key light as the hide.
        col = paint_light(nodes, links, c.outputs[0], None, key=0.35, sat=1.05)
        return col, r.outputs[0], None

    return build


def eye_mat(nodes, links, iris="eye"):
    geo = nodes.new("ShaderNodeNewGeometry")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geo.outputs["Normal"], sep.inputs["Vector"])
    ax = nodes.new("ShaderNodeMath")
    ax.operation = "ABSOLUTE"
    links.new(sep.outputs["X"], ax.inputs[0])
    # L4d: dark rim, a wide bright iris and a small pupil (the old 30-degree pupil plus a dim iris
    # read as a black bead at phone zoom).
    bright = lerp3(C.hexlin(iris), (1.0, 0.8, 0.35), 0.35)
    col = C.ramp(nodes, links, ax.outputs["Value"], [(0.42, C.hexlin("#120e0a")), (0.5, lerp3(bright, (0.02, 0.012, 0.004), 0.6)), (0.58, bright), (0.86, C.hexlin(iris)), (0.91, (0.003, 0.002, 0.002))])
    # L4c: a baked catchlight (the device never gets roughness/specular maps): a small pale spot
    # on the up-front side of each eyeball so the eye reads wet and alive at phone zoom.
    lv = Vector((0.0, -0.55, 0.85)).normalized()
    dl = nodes.new("ShaderNodeVectorMath")
    dl.operation = "DOT_PRODUCT"
    ny = nodes.new("ShaderNodeCombineXYZ")
    links.new(ax.outputs["Value"], ny.inputs["X"])
    links.new(sep.outputs["Y"], ny.inputs["Y"])
    links.new(sep.outputs["Z"], ny.inputs["Z"])
    links.new(ny.outputs["Vector"], dl.inputs[0])
    dl.inputs[1].default_value = tuple(Vector((0.55, lv.y, lv.z)).normalized())
    spot = C.ramp(nodes, links, dl.outputs["Value"], [(0.86, (0, 0, 0)), (0.92, (1, 1, 1))])
    hi = nodes.new("ShaderNodeRGB")
    hi.outputs[0].default_value = (0.85, 0.85, 0.8, 1)
    out = C.mix(nodes, links, spot.outputs["Color"], col.outputs["Color"], hi.outputs[0])
    r = nodes.new("ShaderNodeValue")
    r.outputs[0].default_value = 0.2
    return out, r.outputs[0], None


def shell_mat(sp):
    """Turtle carapace: dark-seamed scutes with growth-ring shading."""

    def build(nodes, links):
        coord = nodes.new("ShaderNodeTexCoord").outputs["Object"]
        vor = nodes.new("ShaderNodeTexVoronoi")
        vor.feature = "DISTANCE_TO_EDGE"
        vor.inputs["Scale"].default_value = 3.2
        links.new(coord, vor.inputs["Vector"])
        seam = C.ramp(nodes, links, vor.outputs["Distance"], [(0.02, C.hexlin("#1a150e")), (0.07, C.hexlin("#3a2c1c")), (0.12, C.hexlin(sp["accent"])), (0.24, C.hexlin("#5e4c30"))])
        n = C.noise(nodes, 18.0, 6, 0.6, coord, links)
        tone = C.ramp(nodes, links, n.outputs["Fac"], [(0.3, (0.8, 0.8, 0.8)), (0.7, (1.1, 1.1, 1.1))])
        mul = nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        links.new(seam.outputs["Color"], mul.inputs["A"])
        links.new(tone.outputs["Color"], mul.inputs["B"])
        shaded = occlusion(nodes, links, mul.outputs["Result"], sp["length"], sp)
        bmp = nodes.new("ShaderNodeBump")
        bmp.inputs["Strength"].default_value = 0.6
        links.new(vor.outputs["Distance"], bmp.inputs["Height"])
        shaded = paint_light(nodes, links, shaded, bmp.outputs["Normal"])
        r = nodes.new("ShaderNodeValue")
        r.outputs[0].default_value = 0.65
        return shaded, r.outputs[0], bmp.outputs["Normal"]

    return build


# ------------------------------------------------------------------ rig


def build_armature(name, sk, points):
    arm_data = bpy.data.armatures.new(name + "Rig")
    arm = C.link(bpy.data.objects.new(name + "Rig", arm_data))
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    made = {}
    for bname, h, t, parent in sk["bones"]:
        b = arm_data.edit_bones.new(bname)
        b.head = points[h]
        b.tail = points[h] + Vector((0, 0, 0.3 * sk["scale"])) if t == "@up" else points[t]
        # Local X = creature side axis (+X world): +X rotation lifts the tip, Z is yaw.
        y = (b.tail - b.head).normalized()
        z = X.cross(y)
        if z.length > 1e-4:
            b.align_roll(z.normalized())
        if parent:
            b.parent = made[parent]
            b.use_connect = (made[parent].tail - b.head).length < 1e-4
        made[bname] = b
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def weight(body, arm, smooth=False):
    """Heat weights for the body, explicit 1.0 weights for tagged details, nearest bone fallback.

    smooth (B2b): a body vertex heat weighting missed blends the bones within 1.6x its nearest
    distance by inverse square distance, so joints bend instead of shearing like rigid parts."""
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    bones = {b.name: (arm.matrix_world @ b.head_local, arm.matrix_world @ b.tail_local) for b in arm.data.bones}
    groups = {g.index: g.name for g in body.vertex_groups}
    bone_groups = {name: body.vertex_groups.get(name) or body.vertex_groups.new(name=name) for name in bones}
    detail = {}
    for v in body.data.vertices:
        for ge in v.groups:
            gname = groups.get(ge.group, "")
            if gname.startswith("detail:") and ge.weight > 0.5:
                detail[v.index] = gname[7:]
    fixed = 0
    for v in body.data.vertices:
        has = any(not groups.get(ge.group, "").startswith("detail:") and ge.weight > 1e-4 for ge in v.groups)
        target = detail.get(v.index)
        if target is None and has:
            continue
        blend = None
        if target is None:
            p = body.matrix_world @ v.co
            dists = {}
            for name, (h, t) in bones.items():
                seg = t - h
                u = max(0.0, min(1.0, (p - h).dot(seg) / max(seg.length_squared, 1e-9)))
                dists[name] = (h + seg * u - p).length
            target = min(dists, key=dists.get)
            if smooth and target != "Root":
                near = max(dists[target], 1e-4)
                blend = {n: 1.0 / max(d, 1e-4) ** 2 for n, d in dists.items() if d <= near * 1.6 and n != "Root"}
        for g in bone_groups.values():
            g.remove([v.index])
        if blend:
            total = sum(blend.values())
            for n, w in blend.items():
                bone_groups[n].add([v.index], w / total, "REPLACE")
        else:
            bone_groups[target].add([v.index], 1.0, "REPLACE")
        fixed += 1
    for g in list(body.vertex_groups):
        if g.name.startswith("detail:"):
            body.vertex_groups.remove(g)
    weighted = sum(1 for v in body.data.vertices if any(ge.weight > 1e-4 for ge in v.groups))
    return weighted, fixed


# ------------------------------------------------------------------ main


def build_geometry(sp, raw, s, name, body_tris):
    """Skin body + detail objects at scale s; returns (body, details, skeleton, points)."""
    sk = scaled(raw, s)
    sk["scale"] = s
    sk["arm_pts"] = {sfx: [a[1] for a in arm] for sfx, _l, _t, arm, _f in sk["limbs"]}
    sk["sickle_y"] = {sfx: leg[-1][1][1] - 0.02 * s for sfx, leg, _t, _a, _f in sk["limbs"]}
    points = {}
    for c in ("spine", "neck", "jaw", "tail"):
        for n, p, _a, _b in sk[c]:
            points[n] = Vector(p)
    for _parent, chain in sk.get("extras", []):
        for n, p, _a, _b in chain:
            points[n] = Vector(p)
    for sfx, leg, toes, arm, fingers in sk["limbs"]:
        for n, p, _a, _b in leg + toes + arm + fingers:
            points[n] = Vector(p)
    points.update(sk.get("extra_points", {}))
    radii = {}
    for c in ("spine", "neck", "jaw", "tail"):
        for n, _p, ra, rb in sk[c]:
            radii[n] = (ra, rb)
    for _parent, chain in sk.get("extras", []):
        for n, _p, ra, rb in chain:
            radii[n] = (ra, rb)
    for sfx, leg, toes, arm, fingers in sk["limbs"]:
        for n, _p, ra, rb in leg + toes + arm + fingers:
            radii[n] = (ra, rb)
    sk["eye_r_abs"] = eye_radius(sp, sk)
    sk["hip_z"] = points["pelvis"].z
    fur_tris = sum(c * CLUMP_TRIS for t in (FUR, PLUME) for _z, c, _l, _w in t.get(sp["key"], [])) + feather_tris(sp["key"])
    if "neck_a" in points:
        nk = [points["chest"].lerp(points["neck_a"], 0.5), points["neck_a"], points["neck_b"], points["head_back"]] if "neck_b" in points else [points["neck_a"], points["head_back"]]
        sk["neck_mask"] = [(nk[i].lerp(nk[i + 1], u), max(max(radii[k]) for k in ("neck_a", "head_back")) * 1.5) for i in range(len(nk) - 1) for u in (0.0, 0.5)] + [(nk[-1], max(radii["head_back"]) * 1.2)]
    sk["head_c"] = points["head_back"].lerp(points["nose"], 0.45)
    sk["head_l"] = (points["nose"] - points["head_back"]).length
    tail_pts = [points[k] for k in points if k.startswith("tail")]
    sk["tail_y"] = (points["pelvis"].y, max([t.y for t in tail_pts] + [points["pelvis"].y + 0.01]))
    body, high, bvh = build_body_v2(name, sk, sp, points, radii, body_tris - fur_tris)
    snap_surface(sk, bvh)
    det = build_details(sp, sk, points)
    fur = build_fur(sp, sk, points, radii, high)
    if fur is not None:
        det["fur"] = [fur]
    plume = build_fur(sp, sk, points, radii, high, PLUME)
    if plume is not None:
        det["plume"] = [plume]
    # Raptor2: feather tips stay inside the catalog length envelope measured from the nose.
    y_front = min(v.co.y for v in high.data.vertices)
    y_limit = y_front + sp["envelope"][2] if "envelope" in sp else None
    det.update(build_feathers(sp, sk, points, radii, bvh, y_limit))
    bpy.data.objects.remove(high)
    return body, det, sk, points


def bbox_size(body, det):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in [body] + [o for objs in det.values() for o in objs]:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return hi - lo


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    outdir = C.out_dir()
    key = argv[1]
    sp = dict(SPECIES[key], key=key)
    name = "Robango" + key[0].upper() + key[1:]
    b2b = sp["plan"] in B2B_PLANS
    # B2a seeds stay as recorded (index among the B2a species); B2b seeds start at SEED + 100.
    seed = SEED + 100 + B2B_SPECIES.index(key) if b2b else SEED + B2A_SPECIES.index(key)
    C.reset(seed)
    plan = PLANS[sp["plan"]]
    raw = plan(sp["knobs"])
    base = raw.get("base_length")
    if base is None:
        ys = [p[1] for c in ("spine", "neck", "tail") for _n, p, _a, _b in raw[c]]
        base = max(ys) - min(ys)
    s = sp["length"] / base
    if b2b:
        # Fit pass: build the bare geometry once, then scale so the whole creature (horns, ears,
        # plates, tusks included) sits inside the catalog render envelope (W x H x L studs).
        body, det, _sk, _pts = build_geometry(sp, raw, s, name, 2000)
        size = bbox_size(body, det)
        env = sp["envelope"]
        k = min(env[0] / size.x, env[1] / size.z, env[2] / size.y, 1.0) * 0.98
        s *= k
        C.reset(seed)
    detail_budget = 900 if sp["tris"] <= 4000 else 1400
    if b2b:
        detail_budget = 1300 if sp["tris"] <= 4000 else 2000
    body, det, sk, points = build_geometry(sp, raw, s, name, sp["tris"] - detail_budget)
    hide = C.material("hide", make_hide_mat(sp, sk))
    body.data.materials.append(hide)
    iris = sp.get("iris", "eye")
    mats = {
        "claw": C.material("claw", flat_mat("claw", 0.45)),
        "eye": C.material("eye", lambda n, l: eye_mat(n, l, iris)),
        "accent": C.material("accent", flat_mat(sp["accent"], 0.8)),
        "ivory": C.material("ivory", flat_mat(sp.get("ivory", "#b8ab88"), 0.6)),
        "shell": C.material("shell", shell_mat(sp)),
        "fur": hide,
        "skin": hide,
        "plume": C.material("plume", plume_mat(sp, sp["length"])) if "plume" in sp and key not in PAINTED_PLUME else hide,
    }
    for zone in FEATHERS.get(key, {}):
        mats["feather_" + zone] = C.material("feather_" + zone, feather_mat(sp, zone))
    parts = [body]
    for kind, objs in det.items():
        for o in objs:
            o.data.materials.append(mats[kind])
            parts.append(o)
    body = C.join(parts, name)
    C.unwrap(body, 0.006)
    sil = C.silhouette(name, outdir, [body])
    maps = C.bake(body, name, outdir, size=sp["tex"])
    arm = build_armature(name, sk, points)
    weighted, fixed = weight(body, arm, smooth=b2b)
    fur_vertices = copy_fur_weights(body)
    pv = C.preview(name, outdir, [body])
    fbx = C.export_fbx(name, outdir, [arm, body])
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for c in body.bound_box:
        w = body.matrix_world @ Vector(c)
        lo = Vector(map(min, lo, w))
        hi = Vector(map(max, hi, w))
    size = hi - lo
    assert len(arm.data.bones) == PLAN_BONES[sp["plan"]], (len(arm.data.bones), PLAN_BONES[sp["plan"]])
    C.report(
        name,
        [body],
        {"fbx": fbx, "preview": pv, "silhouettes": sil, **maps},
        {
            "species": key,
            "plan": sp["plan"],
            "seed": seed,
            "bones": len(arm.data.bones),
            "weighted_vertices": weighted,
            "fallback_or_detail_vertices": fixed,
            "fur_vertices": fur_vertices,
            "bone_names": [b.name for b in arm.data.bones],
            "vertices": len(body.data.vertices),
            "size_studs": [round(size.x, 2), round(size.z, 2), round(size.y, 2)],
            "envelope": sp["envelope"],
            "budget_tris": sp["tris"],
            "texture": sp["tex"],
            "root_height": round(points["pelvis"].z - lo.z, 3),
            "bbox_min_z": round(lo.z, 3),
        },
    )


main()
