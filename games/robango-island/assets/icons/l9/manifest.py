"""L9: point every restyled icon row at its l9 source and reset it to NotUploaded.

Usage (repo root): python games/robango-island/assets/icons/l9/manifest.py
Reads l9/verify.json (written by slice.py). Adds item-icon-bone-knife after item-icon-bone.
"""
import json, re

M = "games/robango-island/assets/manifest.yml"
verify = json.load(open("games/robango-island/assets/icons/l9/verify.json"))
text = open(M, encoding="utf8").read()
rows = re.split(r"(?m)^(?=  - key: )", text)
RIGHTS = """      rights:
        source: "OpenAI Services Agreement s4.1: customer owns Output; OpenAI assigns all right, title and interest in Output"
        ownership: licensed
        evidence:
          document: "https://openai.com/policies/services-agreement/"
          version: "2026-01-01"
          verifiedBy: "agent:omo (lead, 2026-10-21; access via mahoquot proxy - owner to confirm proxy terms)"
"""


def row(icon, v):
    key = icon.replace(".", "-")
    return f"""  - key: {key}
    kind: image
    tool: gpt-image
    source: "gpt-image l9/atlas-{v['atlas'][-5]}.png cell {v['cell']}{' (same art as ' + v['variantOf'] + ')' if 'variantOf' in v else ''}"
    path: assets/icons/{icon}.png
    assetId: 0
    moderation: NotUploaded
    provenance:
      digest: sha256:{v['sha256']}
      recipe:
        id: robango-icon-l9
        version: 1
        input: "assets/icons/l9/jobs.json#{icon}"
        inputVersion: sha256:{v['inputVersion']}
      provider:
        name: gpt-image
        version: Responses-API
{RIGHTS}      author: agent:omo/hephaestus
      created: 2026-10-29
"""


index = {}
for i, r in enumerate(rows):
    m = re.match(r"  - key: (\S+)", r)
    if m:
        index[m.group(1)] = i
changed = added = 0
for icon, v in verify.items():
    key = icon.replace(".", "-")
    if key in index:
        if f"digest: sha256:{v['sha256']}" in rows[index[key]] and "robango-icon-l9" in rows[index[key]]:
            continue  # already applied (keeps the uploaded assetId)
        rows[index[key]] = row(icon, v)
        changed += 1
    else:
        anchor = index["item-icon-bone"]
        rows[anchor] = rows[anchor] + row(icon, v)
        added += 1
open(M, "w", encoding="utf8", newline="\n").write("".join(rows))
print(f"changed={changed} added={added}")
