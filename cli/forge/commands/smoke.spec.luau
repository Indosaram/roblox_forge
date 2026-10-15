--!strict
-- Specs for `forge smoke --local` on a pack without a smoke script: skipped by
-- default, a failure under --strict, and a missing pack is always a failure.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local smoke = require("./smoke")

local function withPacksDir(test: (string) -> ())
	local root = (process.env.TMPDIR or process.env.TEMP or process.env.TMP or "/tmp")
		.. "/forge-smoke-strict-"
		.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
	local ok, reason = xpcall(function()
		fs.writeDir(root)
		fs.writeDir(root .. "/no-smoke-pack")
		test(root)
	end, debug.traceback)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	assert(ok, tostring(reason))
end

return {
	["a pack without a smoke script is skipped by default"] = function()
		withPacksDir(function(root)
			local ok = smoke.run({ "smoke", "--pack", "no-smoke-pack", "--local" }, { packsDir = root })
			assert(ok == true, "a missing smoke script is a skip, not a failure")
		end)
	end,

	["--strict fails a pack without a smoke script"] = function()
		withPacksDir(function(root)
			local ok = smoke.run({ "smoke", "--pack", "no-smoke-pack", "--local", "--strict" }, { packsDir = root })
			assert(ok == false, "--strict must fail when no smoke script exists")
		end)
	end,

	["--strict is accepted before the other flags"] = function()
		withPacksDir(function(root)
			local ok = smoke.run({ "smoke", "--strict", "--local", "--pack", "no-smoke-pack" }, { packsDir = root })
			assert(ok == false, "flag order must not matter")
		end)
	end,

	["a missing pack fails with or without --strict"] = function()
		withPacksDir(function(root)
			assert(smoke.run({ "smoke", "--pack", "absent", "--local" }, { packsDir = root }) == false, "missing pack")
			assert(
				smoke.run({ "smoke", "--pack", "absent", "--local", "--strict" }, { packsDir = root }) == false,
				"missing pack under --strict"
			)
		end)
	end,
}
