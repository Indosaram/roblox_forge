"""Persistent StudioMCP client (one process per script run)."""
import asyncio, base64, glob, json, os, sys, time, subprocess, threading, queue
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
EXE = sorted(glob.glob(os.path.expandvars(r"%LOCALAPPDATA%\Roblox\Versions\*\StudioMCP.exe")), key=os.path.getmtime)[-1]
SID = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sid.txt")).read().strip()


class M:
    def __init__(self):
        self.p = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.n = 0
        self.q = queue.Queue()
        threading.Thread(target=self._rd, daemon=True).start()
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "capS", "version": "1"}})
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n").encode())
        for i in range(30):
            t = self.text(self.rpc("tools/call", {"name": "list_roblox_studios", "arguments": {}}))
            if SID in t:
                break
            time.sleep(3)

    def _rd(self):
        for line in self.p.stdout:
            try:
                self.q.put(json.loads(line))
            except Exception:
                pass

    def rpc(self, method, params, timeout=180):
        self.n += 1
        n = self.n
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params}) + "\n").encode())
        end = time.time() + timeout
        while time.time() < end:
            try:
                j = self.q.get(timeout=max(0.1, end - time.time()))
            except queue.Empty:
                break
            if j.get("id") == n:
                return j
        return {"error": {"message": "timeout"}}

    @staticmethod
    def text(j):
        if "error" in j:
            return "ERR " + json.dumps(j["error"])
        return "\n".join(c.get("text", "") for c in j.get("result", {}).get("content", []) if c.get("type") == "text")

    def call(self, tool, args, timeout=180):
        a = dict(args)
        a["studio_id"] = SID
        return self.rpc("tools/call", {"name": tool, "arguments": a}, timeout)

    def lua(self, code, dm="Client"):
        for i in range(5):
            r = self.text(self.call("execute_luau", {"code": code, "datamodel_type": dm}))
            if "not connected" not in r and "No Roblox Studio" not in r and "ERR" not in r[:4]:
                return r
            time.sleep(3)
        return r

    def cap(self, path):
        for i in range(4):
            j = self.call("screen_capture", {"capture_id": "ScreenCapture_1"})
            for c in j.get("result", {}).get("content", []):
                if c.get("type") == "image":
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    open(path, "wb").write(base64.b64decode(c["data"]))
                    return "ok " + os.path.basename(path)
            time.sleep(2)
        return "NOCAP " + self.text(j)[:200]

    def state(self):
        return self.text(self.call("get_studio_state", {}))

    def play(self, on):
        return self.text(self.call("start_stop_play", {"is_start": on}))

    def waitmode(self, mode, n=40):
        s = ""
        for i in range(n):
            s = self.state()
            if "Current Studio Mode: " + mode in s:
                return s
            time.sleep(3)
        return s

    def setdev(self, name):
        return self.lua('local S=game:GetService("StudioDeviceSimulatorService") for _,id in S:GetDeviceListAsync() do local i=S:GetDeviceInfoAsync(id) if i.Name=="%s" then S:SetDeviceAsync(id) break end end pcall(function() S:SetOrientationAsync(Enum.ScreenOrientation.LandscapeLeft) end) task.wait(0.5) return tostring(S:GetDeviceAsync())' % name, "Edit")

    def restart(self, dev, edit_lua=None):
        if "Mode: Play" in self.state():
            self.play(False)
        self.waitmode("Edit")
        print(self.setdev(dev), flush=True)
        self.lua('workspace:SetAttribute("ForgeQASkipTitle", true) return 1', "Edit")
        if edit_lua:
            print(self.lua(edit_lua, "Edit"), flush=True)
        self.play(True)
        self.waitmode("Play")
        for i in range(40):
            if self.lua('return tostring(game.Players.LocalPlayer:GetAttribute("ForgeHudReady"))') == "true":
                break
            time.sleep(3)
        time.sleep(5)
        self.enter()
        return self.lua('return tostring(workspace.CurrentCamera.ViewportSize)')

    def enter(self):
        return self.lua('local p=game.Players.LocalPlayer p:SetAttribute("ForgeTitleDone",true) local t=p.PlayerGui:FindFirstChild("ForgeTitle") if t then t:Destroy() end local k=p.PlayerGui:FindFirstChild("ForgeSurvivorPicker") if k then k.Enabled=false end return 1')

    def close(self):
        self.p.kill()
