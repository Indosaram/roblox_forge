--!strict
-- Regression guard for the `forge new` templates: every genre (and the shipped
-- composition and crafting mode) must generate a pack that is already clean for
-- `forge check` - stylua-stable, codegen-stable, free of orphan server sources,
-- shipped with a smoke suite and free of selene warnings. A template regression
-- therefore fails the specs stage instead of the first pack an agent creates.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local tempdir = require("./tempdir")
local new = require("../commands/new")
local codegen = require("./codegen")
local registryLib = require("./genreregistry")

-- Each pack sits two levels below the repository root (like games/<slug>), so its
-- generated "../../core" project paths resolve; build/ is git-ignored.
local function scratchRoot(): string
	return "build/" .. (string.match(tempdir.path("newpack-fixture"), "[^/]+$") :: string)
end

local function exec(tool: string, args: { string }): (boolean, string)
	local result = process.exec(tool, args)
	return result.ok, result.stdout .. result.stderr
end

local function collectPaths(node: any, into: { string })
	if type(node) ~= "table" then
		return
	end
	for key, value in node do
		if key == "$path" and type(value) == "string" then
			table.insert(into, (string.gsub(value, "\\", "/")))
		elseif type(value) == "table" then
			collectPaths(value, into)
		end
	end
end

local function listFiles(dir: string, prefix: string, into: { string })
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			listFiles(path, prefix .. name .. "/", into)
		else
			table.insert(into, prefix .. name)
		end
	end
end

local function isMapped(path: string, mapped: { string }): boolean
	for _, root in mapped do
		if path == root or string.sub(path, 1, #root + 1) == root .. "/" then
			return true
		end
	end
	return false
end

-- A server file is reachable when the project maps it (directly or through a
-- mapped folder), or when it is a ModuleScript that a mapped source requires.
local function orphans(dir: string): { string }
	local mapped = {}
	collectPaths(serde.decode("json", fs.readFile(dir .. "/default.project.json")).tree, mapped)
	local sources = {}
	listFiles(dir .. "/src", "src/", sources)
	local mappedText = {}
	for _, path in sources do
		if isMapped(path, mapped) and string.sub(path, -5) == ".luau" then
			table.insert(mappedText, fs.readFile(dir .. "/" .. path))
		end
	end
	local found = {}
	for _, path in sources do
		if string.sub(path, 1, 11) == "src/server/" and not isMapped(path, mapped) then
			local module = string.match(path, "([^/]+)%.luau$")
			local required = false
			if module and not string.find(module, "%.") then
				for _, text in mappedText do
					for line in string.gmatch(text, "[^\n]+") do
						if string.find(line, "require", 1, true) and string.find(line, module, 1, true) then
							required = true
						end
					end
				end
			end
			if not required then
				table.insert(found, path)
			end
		end
	end
	return found
end

local function verify(slug: string, genre: string, mode: string?)
	local root = scratchRoot()
	local ok, reason = xpcall(function()
		local args = { "new", slug, "--genre", genre }
		if mode then
			table.insert(args, "--mode")
			table.insert(args, mode)
		end
		assert(new.run(args, { packsDir = root }), "forge new " .. genre .. " failed")
		local dir = root .. "/" .. slug

		local styled, styleOut = exec("stylua", { "--check", "--config-path", "stylua.toml", dir })
		assert(styled, "generated pack is not stylua-clean:\n" .. styleOut)

		local econ = fs.readFile(dir .. "/econ.yml")
		local registry = assert(registryLib.discover())
		local name, source = codegen.generateDocument(econ, registry)
		local shipped = dir .. "/src/shared/" .. name
		assert(fs.isFile(shipped), "generated pack lacks " .. name)
		assert(fs.readFile(shipped) == source, name .. " differs from a fresh forge codegen")

		local stray = orphans(dir)
		assert(#stray == 0, "server sources neither mapped nor required: " .. table.concat(stray, ", "))

		assert(fs.isFile(dir .. "/smoke/smoke.luau"), "generated pack lacks smoke/smoke.luau")

		-- selene.toml excludes build/**, so the scratch pack is linted with --no-exclude.
		local linted, lintOut = exec("selene", { "--no-exclude", dir })
		assert(
			linted and string.find(lintOut, "0 warnings", 1, true) ~= nil,
			"generated pack has selene findings:\n" .. lintOut
		)
	end, debug.traceback)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	assert(ok, reason)
end

return {
	["a new collect-raid pack is check-clean"] = function()
		verify("np-collect-raid", "collect-raid")
	end,
	["a new grow-harvest pack is check-clean"] = function()
		verify("np-grow-harvest", "grow-harvest")
	end,
	["a new survival-coop pack is check-clean"] = function()
		verify("np-survival-coop", "survival-coop")
	end,
	["a new rpg-progression pack is check-clean"] = function()
		verify("np-rpg-progression", "rpg-progression")
	end,
	["a new social-rp-fashion pack is check-clean"] = function()
		verify("np-social-rp-fashion", "social-rp-fashion")
	end,
	["a new pvp-arena pack is check-clean"] = function()
		verify("np-pvp-arena", "pvp-arena")
	end,
	["a new grow-harvest+survival-coop pack is check-clean"] = function()
		verify("np-gh-sc", "grow-harvest,survival-coop")
	end,
	["a new survival-coop crafting pack is check-clean"] = function()
		verify("np-craft", "survival-coop", "crafting")
	end,
}
