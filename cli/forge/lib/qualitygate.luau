--!strict
-- Shared local gate. A declaration and a deployment exception never grant approval.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local qualityprofile = require("./qualityprofile")
local qualityreceipt = require("./qualityreceipt")
local M = {}

export type Options = {
	root: string?,
	pack: string,
	packDir: string,
	authority: qualityreceipt.Authority,
	target: qualityprofile.Tier?,
	receiptPath: string?,
	environment: string?,
	development: boolean?,
	buildPath: string?,
}
export type Result = {
	ok: boolean,
	code: string,
	errors: { string },
	declaredTier: qualityprofile.Tier?,
	releaseApproved: boolean,
}

function M.check(options: Options): Result
	local declaredTier: qualityprofile.Tier? = nil
	local ok, result = pcall(function(): Result
		local function status(code: string, approved: boolean?): Result
			return {
				ok = true,
				code = code,
				errors = {},
				declaredTier = declaredTier,
				releaseApproved = approved == true,
			}
		end
		assert(not options.development or options.environment == "staging", "development is staging-only")
		assert(
			options.environment == nil or options.environment == "staging" or options.environment == "production",
			"invalid deployment environment"
		)
		local root = options.root or "."
		local path = (if options.root then root .. "/" else "") .. options.packDir .. "/quality.yml"
		if not fs.isFile(path) then
			assert(options.environment ~= nil and options.target == nil, "missing quality profile")
			if options.development then
				return status("STAGING_DEVELOPMENT")
			end
			return {
				ok = false,
				code = "LEGACY_UNASSESSED",
				errors = { "deployment requires assessed release-candidate or explicit staging --development" },
				declaredTier = nil,
				releaseApproved = false,
			}
		end
		local profile, errors = qualityprofile.parse(serde.decode("yaml", fs.readFile(path)))
		assert(profile, table.concat(errors, "; "))
		assert(profile.pack == options.pack, "profile pack mismatch")
		declaredTier = profile.tier
		local target: qualityprofile.Tier = options.target or profile.tier
		assert(qualityprofile.tierWithin(profile.tier, target), "target cannot downgrade declared tier")
		if options.development then
			assert(target ~= "release-candidate", "release-candidate cannot bypass quality approval")
			return status("STAGING_DEVELOPMENT")
		end
		if options.environment ~= nil then
			assert(
				profile.tier == "release-candidate" and target == "release-candidate",
				"deployment requires release-candidate or explicit staging --development"
			)
		end
		if target == "starter" then
			return status("STARTER_NOT_RELEASE")
		end
		local receiptPath = options.receiptPath or profile.receiptPath
		assert(receiptPath, "missing receipt path")
		local receipt = serde.decode("json", fs.readFile((if options.root then root .. "/" else "") .. receiptPath))
		assert(type(receipt) == "table" and type(receipt.inputs) == "table", "missing attested receipt inputs")
		if options.buildPath then
			assert(receipt.inputs.buildPath == options.buildPath, "receipt does not bind deployment build path")
		end
		local input: qualityreceipt.Inputs = {
			root = root,
			packDir = options.packDir,
			receiptPath = receiptPath,
			buildPath = receipt.inputs.buildPath,
			evidenceDir = receipt.inputs.evidenceDir,
			evidence = receipt.inputs.evidence,
		}
		local checked = qualityreceipt.check(profile, input, receipt, options.authority, target)
		if checked.ok then
			local observationErrors = require("./qualityevaluate").validateObservations(profile, input, receipt)
			if #observationErrors > 0 then
				return {
					ok = false,
					code = "INVALID_OBSERVATIONS",
					errors = observationErrors,
					declaredTier = declaredTier,
					releaseApproved = false,
				}
			end
		end
		return {
			ok = checked.ok,
			code = checked.code,
			errors = checked.errors,
			declaredTier = declaredTier,
			releaseApproved = checked.ok and target == "release-candidate",
		}
	end)
	if not ok then
		return {
			ok = false,
			code = "QUALITY_GATE_FAILED",
			errors = { tostring(result) },
			declaredTier = declaredTier,
			releaseApproved = false,
		}
	end
	return result
end

return M
