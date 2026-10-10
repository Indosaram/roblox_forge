--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local lock = require("../forge/lib/lock")
local publication = require("../forge/lib/packpublication")
local contract = require("../forge/lib/genrecontract")
local packageModule = luau.load(fs.readFile("cli/release/package.luau"), {
	environment = {
		require = function(path: string): any
			if path == "../forge/lib/lock" then
				return lock
			elseif path == "../forge/lib/packpublication" then
				return publication
			elseif path == "../forge/lib/genrecontract" then
				return contract
			end
			return (require :: any)(path)
		end,
	},
})("module")

local function rejects(fn: () -> (), code: string)
	local ok, err = pcall(function()
		fn()
		return nil
	end)
	assert(not ok and string.find(tostring(err), code, 1, true), "expected " .. code .. ", got " .. tostring(err))
end

local function versionsFixture(): { any }
	return {
		{ path = "core/forge-package.yml", bytes = "name: core\nversion: 1.0.0\n" },
		{
			path = "genres/example/forge-package.yml",
			bytes = "name: example\nversion: 2.0.0\nrequires: {core: '^1.0.0'}\n",
		},
		{ path = "games/demo/game.yml", bytes = "name: demo\ngenres: [example]\n" },
		{ path = "games/demo/default.project.json", bytes = "{}" },
		{ path = "games/demo/forge-lock.yml", bytes = "core: 1.0.0\ngenres: {example: 2.0.0}\n" },
	}
end

return {
	["release changelog ships while root scratch remains excluded"] = function()
		assert(packageModule.included("CHANGELOG.md"))
		assert(not packageModule.included("scratch-notes.md"), 'not packageModule.included("scratch-notes.md")')
		assert(not packageModule.included(".omo/CHANGELOG.md"), 'not packageModule.included(".omo/CHANGELOG.md")')
	end,
	["inventory freeze uses explicit covered source and never hashes itself"] = function()
		local policy = {
			schemaVersion = 1,
			files = {},
			coveredSourcePaths = { "cli/a.luau" },
			sourceScopes = { { prefix = "cli/", kind = "first-party-tooling" } },
			sourceExtensions = { "luau" },
			sourceEvidence = "LICENSE.md owner scope",
			assetRecords = {},
		}
		local entries = {
			{ path = "cli/a.luau", bytes = "return 1" },
			{ path = "docs/release/shipped-licenses.json", bytes = "policy" },
		}
		local frozen, unknown = packageModule.freezeInventory(entries, policy)
		assert(
			#unknown == 0 and frozen.files[entries[2].path] == nil,
			"#unknown == 0 and frozen.files[entries[2].path] == nil"
		)
		assert(
			frozen.files[entries[1].path].sha256 == serde.hash("sha256", "return 1"),
			'frozen.files[entries[1].path].sha256 == serde.hash("sha256", "return 1")'
		)
		packageModule.validateRights(entries, frozen)
		table.insert(entries, { path = "cli/unreviewed.luau", bytes = "return 2" })
		local _, missing = packageModule.freezeInventory(entries, policy)
		assert(
			#missing == 1 and missing[1] == "cli/unreviewed.luau",
			'#missing == 1 and missing[1] == "cli/unreviewed.luau"'
		)
	end,
	["candidate capture is immutable and binds content independently of revision"] = function()
		local entries = { { path = "cli/a.luau", bytes = "first" } }
		local candidate = packageModule.captureCandidate(entries, string.rep("a", 40))
		entries[1].bytes = "second"
		assert(
			candidate.entries[1].bytes == "first" and table.isfrozen(candidate.entries[1]),
			'candidate.entries[1].bytes == "first" and table.isfrozen(candidate.entries[1])'
		)
		assert(
			candidate.contentDigest ~= packageModule.captureCandidate(entries, string.rep("a", 40)).contentDigest,
			'candidate.contentDigest ~= packageModule.captureCandidate(entries, string.rep("a", 40)).contentDigest'
		)
	end,
	["zip bytes are sorted and metadata fixed"] = function()
		local a = { path = "a.txt", bytes = "123456789" }
		local b = { path = "b.txt", bytes = "\000\255" }
		local zip = packageModule.zip({ b, a })
		assert(zip == packageModule.zip({ a, b }), "zip == packageModule.zip({ a, b })")
		assert(packageModule.crc32(a.bytes) == 0xCBF43926, "packageModule.crc32(a.bytes) == 0xCBF43926")
		local data = buffer.fromstring(zip)
		assert(buffer.readu32(data, 0) == 0x04034B50, "buffer.readu32(data, 0) == 0x04034B50")
		assert(
			buffer.readu16(data, 8) == 0 and buffer.readu16(data, 10) == 0,
			"buffer.readu16(data, 8) == 0 and buffer.readu16(data, 10) == 0"
		)
		assert(buffer.readu16(data, 12) == 33, "buffer.readu16(data, 12) == 33")
		assert(string.sub(zip, 31, 35) == "a.txt", 'string.sub(zip, 31, 35) == "a.txt"')
		assert(buffer.readu32(data, #zip - 22) == 0x06054B50, "buffer.readu32(data, #zip - 22) == 0x06054B50")
		assert(buffer.readu16(data, #zip - 12) == 2, "buffer.readu16(data, #zip - 12) == 2")
	end,
	["archive rejects traversal duplicate and case collisions"] = function()
		for _, path in { "../a", "/a", "a//b", "a/CON.txt", "a/LPT1", "a\\b" } do
			assert(not packageModule.safePath(path), "not packageModule.safePath(path)")
		end
		rejects(function()
			packageModule.zip({ { path = "a", bytes = "" }, { path = "A", bytes = "" } })
		end, "case-colliding")
	end,
	["only consumer trees ship and secret scratch output never ship"] = function()
		for _, path in
			{
				".git/config",
				".omo/evidence/a.json",
				"build/a.zip",
				"reports/a.json",
				"cli/a.luau.tmp.123",
				"games/a.forge-stage/journal.json",
				"games/a.forge-backup/x",
				"games/a/.env",
				"core/secrets.json",
				"cli/credentials.json",
				"docs/data/probe.json",
				"games/a/build/place.rbxl",
				"cli/scratch/test.luau",
				"cli/key.pem",
			}
		do
			assert(not packageModule.included(path), path)
		end
		for _, path in
			{
				"cli/forge/init.luau",
				"core/a.luau",
				"genres/a/generator.luau",
				"games/a/src/x.luau",
				"docs/release/install.md",
				"rokit.toml",
			}
		do
			assert(packageModule.included(path), path)
		end
	end,
	["whole source pins reject missing extra and mismatched package versions"] = function()
		assert(
			packageModule.versions(versionsFixture()).genres.example == "2.0.0",
			'packageModule.versions(versionsFixture()).genres.example == "2.0.0"'
		)
		for _, pins in
			{
				"core: 9.0.0\ngenres: {example: 2.0.0}",
				"core: 1.0.0\ngenres: {}",
				"core: 1.0.0\ngenres: {example: 2.0.0, other: 1.0.0}",
			}
		do
			local entries = versionsFixture()
			entries[5].bytes = pins
			rejects(function()
				packageModule.versions(entries)
			end, "FORGE_PACKAGE_PIN")
		end
	end,
	["rights require exact file digest and affirmative verified evidence"] = function()
		local entry = { path = "cli/a.luau", bytes = "return 1" }
		local record = {
			sha256 = serde.hash("sha256", entry.bytes),
			status = "verified",
			evidence = "authorship-record",
			verifiedBy = "fixture-owner",
			kind = "first-party-tooling",
			license = "LicenseRef-Forge-SUL-1.0",
		}
		local inventory = { schemaVersion = 1, files = { [entry.path] = record } }
		packageModule.validateRights({ entry }, inventory)
		entry.bytes = "return 2"
		rejects(function()
			packageModule.validateRights({ entry }, inventory)
		end, "FORGE_LICENSE_UNKNOWN")
		entry.bytes = "return 1"
		record.status = "unknown"
		rejects(function()
			packageModule.validateRights({ entry }, inventory)
		end, "FORGE_LICENSE_UNKNOWN")
	end,
	["third party cannot inherit first party exception"] = function()
		rejects(function()
			packageModule.validateRights({ { path = "core/a.luau", bytes = "a" } }, {
				schemaVersion = 1,
				files = {
					["core/a.luau"] = {
						sha256 = serde.hash("sha256", "a"),
						status = "verified",
						evidence = "upstream-tag",
						verifiedBy = "fixture",
						kind = "third-party",
						license = "LicenseRef-Forge-SUL-1.0-Runtime-Exception",
					},
				},
			})
		end, "FORGE_LICENSE_BOUNDARY")
	end,
	["pending sibling blocks even orphan completed malformed or backup markers"] = function()
		for _, marker in { "demo.forge-stage", "demo.forge-backup" } do
			for _, directory in { true, false } do
				local reader = {
					readDir = function(): { string }
						return { marker }
					end,
					isDir = function(path: string): boolean
						return path == "root/games" or (directory and path == "root/games/" .. marker)
					end,
					isFile = function(path: string): boolean
						return not directory and path == "root/games/" .. marker
					end,
				}
				rejects(function()
					packageModule.assertNoPublication("root", reader)
				end, "FORGE_PUBLICATION_PENDING")
			end
		end
	end,
}
