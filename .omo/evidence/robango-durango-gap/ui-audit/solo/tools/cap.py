"""cap.py <device> <tag> <outdir> <ids,...>  - restart play on device, open each sheet with ForgeQAOpen, capture."""
from pm import *
import sys
dev, tag, out, ids = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
m = M()
print(m.restart(dev), flush=True)
m.enter()
P = 'local p=game.Players.LocalPlayer '
for s in ids:
    m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1'); time.sleep(1.5)
    r = m.lua(P + 'p:SetAttribute("ForgeQAOpen","%s") task.wait(2.5) return tostring(p:GetAttribute("ForgeQAOpened"))' % s)
    time.sleep(1.5)
    print(s, r, m.cap(f"{out}/{tag}-{s}.png"), flush=True)
m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1')
m.play(False)
m.close()
