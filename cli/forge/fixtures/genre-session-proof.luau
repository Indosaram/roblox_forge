--!strict
-- Headless proof of actual session/Executor/native adapter and module compilation.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local specs = require("./genre-session.spec")
local names: { string } = {}
for name in specs do
	table.insert(names, tostring(name))
end
table.sort(names)
for _, name in names do
	specs[name]()
	print("PASS " .. name)
end
for _, name in { "Options", "Session", "Clock", "Server", "Client" } do
	local path = "core/infra/genre/" .. name .. ".luau"
	luau.load(fs.readFile(path), { debugName = path })
	print("COMPILE " .. path)
end
print("Headless proof complete; Roblox/Studio surfaces not executed.")
