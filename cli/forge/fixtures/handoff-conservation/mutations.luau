--!strict
-- Execute the production specs with one deliberate in-memory mutation at a
-- time. No production file is modified and no concurrent worker sees a mutant.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Camp = require("../../../../genres/survival-coop/module/CampExtension")
local Memory = require("../../../../core/infra/data/MemoryBackend")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Market = require("../../../../genres/survival-coop/module/MarketExtension")
local Taming = require("../../../../genres/survival-coop/module/TamingExtension")
local Contracts = require("../../../../genres/survival-coop/module/ContractsExtension")
local Monetization = require("../../../../genres/survival-coop/module/MonetizationExtension")
local Session = require("../../../../core/infra/genre/Session")
local cases = {
	{
		id = "durable-ack",
		file = "core/infra/data/DataStoreBackend.spec.luau",
		test = "DataStoreBackend acknowledges only durable commits and surfaces flush failure",
		mutate = function(source: string): string
			return (
				string.gsub(
					source,
					"return dataStore:UpdateAsync%(key, transform%)",
					"local candidate; dataStore:UpdateAsync(key, function(old) candidate = transform(old); return if old == nil then candidate else old end); return candidate"
				)
			)
		end,
	},
	{
		id = "stale-fencing",
		file = "core/infra/data/DataStoreBackend.spec.luau",
		test = "DataStoreBackend stale lease cannot execute transform or overwrite destination",
		mutate = function(source: string): string
			return (
				string.gsub(
					source,
					"return dataStore:UpdateAsync%(key, transform%)",
					"local calls = 0; return dataStore:UpdateAsync(key, function(old) calls += 1; if old and old.generation == 2 then local candidate = table.clone(old); candidate.generation = 1; candidate.lease = {sessionId = 'origin', expiresAt = 99999}; transform(candidate) end return transform(old) end)"
				)
			)
		end,
	},
}
local count = 0
for _, case in cases do
	local realRead = fs.readFile
	local specifications = luau.load(realRead(case.file), {
		environment = {
			require = function(path: string): any
				if path == "@lune/fs" then
					local proxy = table.clone(fs)
					proxy.readFile = function(pathToRead: string): string
						local source = realRead(pathToRead)
						return if pathToRead == "core/infra/data/DataStoreBackend.luau"
							then case.mutate(source)
							else source
					end
					return proxy
				elseif path == "@lune/luau" then
					return luau
				elseif path == "./FencedStore" then
					return Fenced
				elseif path == "./MemoryBackend" then
					return Memory
				end
				error("unhandled spec import " .. path)
			end,
		},
	})()
	local ok, err = pcall(specifications[case.test])
	assert(not ok, "mutation survived: " .. case.id)
	print("KILLED " .. case.id .. " :: " .. tostring(err))
	count += 1
end
local savedImport = Camp.importLegacy
for _, status in { "IMPORTED", "QUARANTINED" } do
	Camp.importLegacy = function(destination, source, version, tribe)
		local result = savedImport(destination, source, version, tribe)
		if result.imports[version].status == status then
			result.imports[version].source = {}
		end
		return result
	end
	local tests = require("../../../../genres/survival-coop/module/CampExtension.spec")
	local name = if status == "IMPORTED"
		then "legacy camp import keeps source version receipt and lossless rollback snapshot"
		else "legacy ambiguous camp ownership is quarantined without deleting assets"
	local ok, err = pcall(tests[name])
	Camp.importLegacy = savedImport
	assert(not ok, "migration conservation mutation survived")
	print("KILLED migration-" .. status .. " :: " .. tostring(err))
	count += 1
end
local extensionCases: { any } = {
	{
		id = "market-drain",
		module = Market,
		callback = "drain",
		tests = require("../../../../genres/survival-coop/module/MarketExtension.spec"),
		name = "actor handoff settles ambiguous buyer payment and conserves seller buyer fee and escrow",
	},
	{
		id = "contract-drain",
		module = Contracts,
		callback = "drain",
		tests = require("../../../../genres/survival-coop/module/ContractsExtension.spec"),
		name = "actor handoff drains pending contract consumption and releases recovery ownership",
	},
	{
		id = "taming-release",
		module = Taming,
		callback = "releaseActor",
		tests = require("../../../../genres/survival-coop/module/TamingExtension.spec"),
		name = "actor handoff drains capture charge and departed sweeps cannot reload animals",
	},
	{
		id = "late-receipt",
		module = Monetization,
		callback = "releaseActor",
		tests = require("../../../../genres/survival-coop/module/MonetizationExtension.spec"),
		name = "actor release defers late receipts and explicit resume grants duplicate zero extra",
	},
}
for _, case in extensionCases do
	local savedFactory = case.module.factory
	case.module.factory = function(...)
		local extension = savedFactory(...)
		extension[case.callback] = function()
			return { ok = true }
		end
		return extension
	end
	local ok, err = pcall(case.tests[case.name])
	case.module.factory = savedFactory
	assert(not ok, "mutation survived: " .. case.id)
	print("KILLED " .. case.id .. " :: " .. tostring(err))
	count += 1
end
assert(count == 8, "every deliberate mutation executed")
local sessionCases: { any } = {
	{
		id = "session-drain-order",
		callback = "prepareHandoff",
		name = "handoff drains saves and releases every actor before travel and blocks old callbacks",
	},
	{
		id = "destination-fencing",
		callback = "resumeHandoff",
		name = "handoff destination failure reacquires origin but destination claim forbids rollback",
	},
}
for _, case in sessionCases do
	local savedNew = Session.new
	Session.new = function(...)
		local session = savedNew(...)
		session[case.callback] = function()
			return { ok = true }
		end
		return session
	end
	local tests = require("../../../../core/infra/genre/SessionExtensions.spec")
	local ok, err = pcall(tests[case.name])
	Session.new = savedNew
	assert(not ok, "mutation survived: " .. case.id)
	assert(
		not string.find(tostring(err), "unknown extension field", 1, true),
		"interface integration must precede Session mutation proof"
	)
	print("KILLED " .. case.id .. " :: " .. tostring(err))
	count += 1
end
print("mutation proofs: " .. count .. " killed")
process.exit(0)
