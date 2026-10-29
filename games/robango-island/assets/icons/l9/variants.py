"""L9 variants: recipe and material-profile icons reuse the restyled item art (one style per item).

Usage (repo root): python games/robango-island/assets/icons/l9/variants.py
Reads l9/variants.json ({recipe: [[recipeId, outputItem]], profile: [[materialId, item]]}),
copies item.icon.<item>.png to recipe.icon.<recipeId>.png / item.icon.<materialId>.png, and records
each copy in l9/verify.json with the item's atlas cell and a variantOf field.
"""
import hashlib, json, shutil

D = "games/robango-island/assets/icons"
verify = json.load(open(D + "/l9/verify.json"))
variants = json.load(open(D + "/l9/variants.json"))
pairs = [(f"recipe.icon.{r}", f"item.icon.{o}") for r, o in variants["recipe"]]
pairs += [(f"item.icon.{m}", f"item.icon.{i}") for m, i in variants["profile"]]
for target, source in pairs:
    base = verify[source]
    shutil.copyfile(f"{D}/{source}.png", f"{D}/{target}.png")
    verify[target] = {
        "atlas": base["atlas"],
        "cell": base["cell"],
        "clear": base["clear"],
        "visible": base["visible"],
        "sha256": base["sha256"],
        "variantOf": source,
        "inputVersion": hashlib.sha256(json.dumps({"variantOf": source, "of": base["inputVersion"]}).encode()).hexdigest(),
    }
    print("VARIANT", target, "<-", source)
json.dump(verify, open(D + "/l9/verify.json", "w"), indent=1, sort_keys=True)
