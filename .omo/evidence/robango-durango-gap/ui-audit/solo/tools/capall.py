"""capall.py <tag> <outdir> - for each device, capture the HUD then each sheet id."""
from pm import *
import sys
tag, out = sys.argv[1], sys.argv[2]
ids = sys.argv[3].split(",") if len(sys.argv) > 3 else ["camp","survival","navigator","party","players"]
P = 'local p=game.Players.LocalPlayer '
m = M()
for dev, short in (("D2_Phone_800","phone"),("D2_PC_1280","pc")):
    print(m.restart(dev), flush=True)
    m.enter(); time.sleep(2)
    print("hud", m.cap(f"{out}/{short}-hud.png"), flush=True)
    for s in ids:
        m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1'); time.sleep(1.5)
        r = m.lua(P + 'p:SetAttribute("ForgeQAOpen","%s") task.wait(2.5) return tostring(p:GetAttribute("ForgeQAOpened"))' % s)
        time.sleep(1.5)
        print(s, r, m.cap(f"{out}/{short}-{s}.png"), flush=True)
    m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1')
m.play(False)
m.close()
