--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local New = require("../../cli/forge/commands/new")
local Plan = require("../../cli/forge/commands/plan")
local Smoke = require("../../cli/forge/commands/smoke")
local QA = require("../../cli/forge/commands/qa")
local Generate = require("../../cli/forge/lib/genregenerate")
local root = Generate.absolute(
	(process.env.TEMP or ".omo/wip") .. "/collect-contract-" .. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
)
local context = { packsDir = root .. "/packs", reportsDir = root .. "/reports" }
local ok, reason = xpcall(function()
	for _, mode in { "new", "plan" } do
		local slug = "collect-command-" .. mode
		local result = if mode == "new"
			then New.run({ "new", slug, "--genre", "collect-raid" }, context)
			else Plan.run(
				{ "plan", "--concept", "Volcano egg keepers", "--genre", "collect-raid", "--pack", slug, "--seed", "7" },
				context
			)
		assert(result, "actual " .. mode .. " failed")
		assert(QA.run({ "qa", "plan", "--pack", slug }, context), "actual qa plan failed")
		assert(Smoke.run({ "smoke", "--local", "--pack", slug }, context), "actual generated smoke failed")
		print("PASS actual", mode, "qa and smoke", root .. "/packs/" .. slug)
	end
end, debug.traceback)
local cleaned, cleanupError = pcall(function()
	if fs.isDir(root) then
		fs.removeDir(root)
	end
end)
assert(cleaned, tostring(cleanupError))
print("REMOVED", root)
assert(ok, tostring(reason))
