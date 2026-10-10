--!strict
-- Specs for the evidence receipt: it must restate every column, bind the
-- declared profile, and fail closed on any attempt to claim human approval.

local serde = require("@lune/serde")
local qualityevidence = require("./qualityevidence")
local qualityscaffold = require("./qualityscaffold")
local qualityprofile = require("./qualityprofile")

local function profile(): qualityprofile.Profile
	local parsed = qualityprofile.parse(serde.decode("yaml", qualityscaffold.profile("evidence-pack", nil)))
	assert(parsed ~= nil, "the fixture profile must validate")
	return parsed :: qualityprofile.Profile
end

local function columns(overrides: { [string]: boolean }?): { [string]: any }
	local out: { [string]: any } = {}
	for _, name in qualityevidence.REQUIRED_COLUMNS do
		local ok = if overrides ~= nil and overrides[name] ~= nil then overrides[name] else true
		out[name] = { ok = ok, error = if ok then nil else name .. " failed" }
	end
	return out
end

local function receipt(subject: qualityprofile.Profile, overrides: { [string]: boolean }?): any
	return qualityevidence.build({
		pack = subject.pack,
		tier = subject.tier,
		profileDigest = qualityevidence.profileDigest(subject),
		columns = columns(overrides),
		captures = { present = false, reason = "headless sweep" },
		av = { present = false, reason = "headless sweep" },
		nativeQa = { ran = 1, passed = 1, skipped = false },
		load = { ok = true, actors = 8, actions = 12 },
	})
end

return {
	["a receipt of green columns is valid for the declared tier"] = function()
		local subject = profile()
		assert(#qualityevidence.validate(receipt(subject), subject) == 0, "a complete receipt must validate")
	end,

	["a failing column is reported by name"] = function()
		local subject = profile()
		local errors = qualityevidence.validate(receipt(subject, { build = false }), subject)
		assert(#errors == 1 and string.find(errors[1], "columns.build", 1, true) ~= nil, tostring(errors[1]))
	end,

	["a receipt never approves fun or visual quality"] = function()
		local subject = profile()
		local document = receipt(subject)
		assert(document.fun.verdict == qualityevidence.PENDING, "fun stays pending")
		assert(document.visual.verdict == qualityevidence.PENDING, "visual stays pending")
		assert(document.releaseApproved == false, "an evidence receipt never approves a release")
		document.fun.verdict = "approved"
		local errors = qualityevidence.validate(document, subject)
		assert(#errors == 1 and string.find(errors[1], "fun.verdict", 1, true) ~= nil, tostring(errors[1]))
	end,

	["a receipt cannot approve its own release"] = function()
		local subject = profile()
		local document = receipt(subject)
		document.releaseApproved = true
		local errors = qualityevidence.validate(document, subject)
		assert(#errors == 1 and string.find(errors[1], "releaseApproved", 1, true) ~= nil, tostring(errors[1]))
	end,

	["a receipt bound to another declaration or tier is refused"] = function()
		local subject = profile()
		local document = receipt(subject)
		document.profileDigest = "sha256:deadbeef"
		assert(#qualityevidence.validate(document, subject) == 1, "a stale profile binding must fail")
		local other = receipt(subject)
		other.tier = "release-candidate"
		local errors = qualityevidence.validate(other, subject)
		assert(#errors == 1 and string.find(errors[1], "tier", 1, true) ~= nil, tostring(#errors))
	end,

	["an absent evidence record has to say why"] = function()
		local subject = profile()
		local document = receipt(subject)
		document.captures = { present = false }
		local errors = qualityevidence.validate(document, subject)
		assert(#errors == 1 and string.find(errors[1], "captures.reason", 1, true) ~= nil, tostring(errors[1]))
	end,
}
