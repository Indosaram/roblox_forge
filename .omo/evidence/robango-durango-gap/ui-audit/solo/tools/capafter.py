"""capafter.py <outdir> - after captures: HUD, dock sheets, HUD sheets (skills/craft/build/bag), camp scroll probe."""
from pm import *
import sys
out = sys.argv[1]
P = 'local p=game.Players.LocalPlayer '
m = M()
for dev, short in (("D2_Phone_800","phone"),("D2_PC_1280","pc")):
    print(m.restart(dev), flush=True)
    m.enter(); time.sleep(2)
    print("hud", m.cap(f"{out}/{short}-hud.png"), flush=True)
    print("tokens", m.lua(P + 'local g=p.PlayerGui:FindFirstChild("ForgeSurvivalHUD") return tostring(g:FindFirstChild("Token-chat")).." emote="..tostring(g:FindFirstChild("Token-emote") ~= nil)'), flush=True)
    for s in ["camp","survival","navigator","party","players","clan","direct-trade","market","inbox","score-import","explore"]:
        m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1'); time.sleep(1.5)
        r = m.lua(P + 'p:SetAttribute("ForgeQAOpened",nil) p:SetAttribute("ForgeQAOpen","%s") task.wait(2.5) local o={} for _,g in p.PlayerGui:GetChildren() do if g:IsA("ScreenGui") and g.Enabled then for _,f in g:GetDescendants() do if f:IsA("Frame") and f.Visible and f:FindFirstChild("Header") then table.insert(o,g.Name) break end end end end return tostring(p:GetAttribute("ForgeQAOpened")).." sheets="..table.concat(o,",")' % s)
        time.sleep(1.5)
        print(s, r, m.cap(f"{out}/{short}-{s}.png"), flush=True)
        if s == "survival":
            # Scroll to the bottom, wait through several state pushes, read the position back.
            print("scroll", m.lua(P + 'local g=p.PlayerGui:FindFirstChild("Forge-survival") local sc=g:FindFirstChildWhichIsA("ScrollingFrame",true) sc.CanvasPosition=Vector2.new(0,10000) task.wait(0.5) local a=sc.CanvasPosition.Y task.wait(6) return "set="..a.." after6s="..sc.CanvasPosition.Y.." canvas="..sc.AbsoluteCanvasSize.Y'), flush=True)
            print("survival-bottom", m.cap(f"{out}/{short}-survival-bottom.png"), flush=True)
        if s == "navigator":
            print("navrows", m.lua(P + 'local o={} for _,b in p.PlayerGui:GetDescendants() do if b:IsA("TextButton") and b.Name:sub(1,4)=="Nav-" then table.insert(o,b.Name:sub(5)) end end return table.concat(o,",")'), flush=True)
    m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1'); time.sleep(1)
    for sec in ["skills","craft","build","bag"]:
        r = m.lua(P + 'local h=p.PlayerGui:FindFirstChild("ForgeSurvivalHUD") p:SetAttribute("ForgeQAOpen","") task.wait(0.5) return 1')
        print(sec, m.lua('local p=game.Players.LocalPlayer local ok=pcall(function() p:SetAttribute("ForgeQAOpen","%s") end) task.wait(2.5) return tostring(p:GetAttribute("ForgeQAOpened"))' % sec), flush=True)
        time.sleep(1.5)
        print(sec, m.cap(f"{out}/{short}-{sec}.png"), flush=True)
    m.lua(P + 'p:SetAttribute("ForgeQAOpen","") return 1')
m.play(False)
m.close()
