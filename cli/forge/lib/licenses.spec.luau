--!strict
-- Specs for licenses: allow-list resolution, deny reasons, and unknown tool handling.

local licenses = require("./licenses")

local function contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

return {
	["allowed tool resolves to its license"] = function()
		local ok, license = licenses.resolve("trellis")
		assert(ok, "trellis is allowed")
		assert(license == "MIT", "expected MIT, got " .. license)
	end,

	["forge-procgen is allowed for first-party procedural assets"] = function()
		local ok, license = licenses.resolve("forge-procgen")
		assert(ok, "forge-procgen is allowed")
		assert(license == "first-party, commercial ok", "expected first-party license, got " .. license)
	end,

	["every allow-list entry resolves as allowed"] = function()
		for name, license in licenses.allowed do
			local ok, resolved = licenses.resolve(name)
			assert(ok, name .. " should be allowed")
			assert(resolved == license, name .. " license mismatch: " .. resolved)
		end
	end,

	["audiocraft is denied with its CC-BY-NC reason"] = function()
		local ok, reason = licenses.resolve("audiocraft")
		assert(not ok, "audiocraft must be denied")
		assert(contains(reason, "CC-BY-NC"), "reason must mention CC-BY-NC: " .. reason)
	end,

	["roblox-cube is denied with its research-only reason"] = function()
		local ok, reason = licenses.resolve("roblox-cube")
		assert(not ok, "roblox-cube must be denied")
		assert(contains(reason, "research only"), "reason must mention research only: " .. reason)
	end,

	["hunyuan3d-2 is denied with its region reason"] = function()
		local ok, reason = licenses.resolve("hunyuan3d-2")
		assert(not ok, "hunyuan3d-2 must be denied")
		assert(contains(reason, "KR/EU/UK"), "reason must mention excluded regions: " .. reason)
	end,

	["every denied entry rejects with a reason"] = function()
		for name, reason in licenses.denied do
			local ok, resolved = licenses.resolve(name)
			assert(not ok, name .. " must be denied")
			assert(resolved == reason, name .. " reason mismatch: " .. resolved)
		end
	end,

	["unknown tool is rejected and lists the allowed tools"] = function()
		local ok, reason = licenses.resolve("definitely-not-a-tool")
		assert(not ok, "unknown tools must be rejected")
		assert(contains(reason, "unknown tool"), "reason must say the tool is unknown: " .. reason)
		assert(contains(reason, "trellis"), "reason must list allowed tools: " .. reason)
	end,
}
