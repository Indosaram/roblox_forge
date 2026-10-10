--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local genrecontract = require("./genrecontract")
local genrespec = require("./genrespec")
local Contract = require("../../../core/domain/genre/Contract")
export type Package = {
	id: string,
	path: string,
	manifest: genrecontract.Manifest,
	generator: genrecontract.Generator,
	runtime: Contract.RuntimeContract,
	-- The declarative genre spec, validated against the runtime descriptor above.
	spec: any,
}
export type Registry = {
	root: string,
	order: { string },
	packages: { [string]: Package },
	runtimes: { [string]: Contract.RuntimeContract },
}
local M = {}
local dynamicRequire = require :: any
local function modulePath(target: string): string
	local source = string.gsub(process.cwd, "\\", "/") .. "/cli/forge/lib"
	local from, to = {}, {}
	for part in string.gmatch(source, "[^/]+") do
		table.insert(from, part)
	end
	for part in string.gmatch(target, "[^/]+") do
		if part == ".." then
			table.remove(to)
		elseif part ~= "." then
			table.insert(to, part)
		end
	end
	assert(string.lower(from[1]) == string.lower(to[1]), "registry modules must be on the repository drive")
	local shared = 0
	while from[shared + 1] and to[shared + 1] and string.lower(from[shared + 1]) == string.lower(to[shared + 1]) do
		shared += 1
	end
	local parts = {}
	for _ = shared + 1, #from do
		table.insert(parts, "..")
	end
	for i = shared + 1, #to do
		table.insert(parts, to[i])
	end
	return "./" .. table.concat(parts, "/")
end
local function absolute(path: string): string
	local normalized = string.gsub(path, "\\", "/")
	if string.match(normalized, "^%a:/") or string.sub(normalized, 1, 1) == "/" then
		return normalized
	end
	return string.gsub(process.cwd, "\\", "/") .. "/" .. normalized
end
function M.discover(root: string?, coreVersion: string?): (Registry?, { string })
	local resolved = absolute(root or "genres")
	if not fs.isDir(resolved) then
		return nil, { resolved .. ": registry directory missing" }
	end
	local version = coreVersion
	if version == nil then
		local ok, decoded = pcall(function()
			return serde.decode("yaml", fs.readFile("core/forge-package.yml"))
		end)
		if not ok or type(decoded) ~= "table" or type(decoded.version) ~= "string" then
			return nil, { "core/forge-package.yml: invalid manifest" }
		end
		version = decoded.version
	end
	local registry: Registry = { root = resolved, order = {}, packages = {}, runtimes = {} }
	local errors: { string } = {}
	local ids = fs.readDir(resolved)
	table.sort(ids)
	local names: { [string]: string } = {}
	for _, id in ids do
		local path = resolved .. "/" .. id
		local manifestPath = path .. "/forge-package.yml"
		if not fs.isDir(path) or not fs.isFile(manifestPath) then
			continue
		end
		local ok, raw = pcall(function()
			return serde.decode("yaml", fs.readFile(manifestPath))
		end)
		if not ok then
			table.insert(errors, manifestPath .. ": " .. tostring(raw))
			continue
		end
		local manifestErrors = genrecontract.validateManifest(raw, id, version :: string)
		if type(raw) == "table" and type(raw.name) == "string" then
			if names[raw.name] then
				table.insert(errors, manifestPath .. ": duplicate manifest name " .. raw.name)
			else
				names[raw.name] = manifestPath
			end
		end
		for _, err in manifestErrors do
			table.insert(errors, manifestPath .. ": " .. err)
		end
		if #manifestErrors > 0 then
			continue
		end
		local missing = false
		for _, file in
			{
				"generator.luau",
				"module/Contract.luau",
				genrespec.FILE,
				"qa-scenarios/contract-loop.yml",
				"qa-scenarios/contract-rejoin.yml",
			}
		do
			if not fs.isFile(path .. "/" .. file) then
				table.insert(errors, path .. "/" .. file .. ": missing")
				missing = true
			end
		end
		if missing then
			continue
		end
		local runtimeOk, runtime = pcall(dynamicRequire, modulePath(path .. "/module/Contract"))
		if not runtimeOk then
			table.insert(errors, path .. "/module/Contract.luau: " .. tostring(runtime))
			continue
		end
		local runtimeErrors = genrecontract.validateRuntime(runtime)
		if type(runtime) == "table" and runtime.id ~= id then
			table.insert(runtimeErrors, "id: manifest mismatch")
		end
		for _, err in runtimeErrors do
			table.insert(errors, path .. "/module/Contract.luau: " .. err)
		end
		if #runtimeErrors > 0 then
			continue
		end
		local generatorOk, generator = pcall(dynamicRequire, modulePath(path .. "/generator"))
		if not generatorOk then
			table.insert(errors, path .. "/generator.luau: " .. tostring(generator))
			continue
		end
		local generatorErrors = genrecontract.validateGenerator(generator, runtime)
		for _, err in generatorErrors do
			table.insert(errors, path .. "/generator.luau: " .. err)
		end
		if #generatorErrors > 0 then
			continue
		end
		for _, scenario in generator.qa.scenarios do
			if not genrecontract.id(scenario) then
				table.insert(errors, path .. "/qa-scenarios: unsafe scenario id")
			elseif not fs.isFile(path .. "/qa-scenarios/" .. scenario .. ".yml") then
				table.insert(errors, path .. "/qa-scenarios/" .. scenario .. ".yml: missing")
			end
		end
		-- The spec is loaded and validated beside the runtime descriptor, so a
		-- malformed spec fails the whole catalog exactly as a malformed generator
		-- does, and a stale spec can never be generated against.
		local specPath = path .. "/" .. genrespec.FILE
		local rawSpec, specLoadErrors = genrespec.load(specPath)
		if rawSpec == nil then
			for _, err in specLoadErrors do
				table.insert(errors, err)
			end
			continue
		end
		local specErrors = genrespec.validate(rawSpec, runtime, { id = id, path = path })
		if #specErrors > 0 then
			for _, err in specErrors do
				table.insert(errors, specPath .. ": " .. err)
			end
			continue
		end
		table.insert(registry.order, id)
		registry.packages[id] =
			{ id = id, path = path, manifest = raw, generator = generator, runtime = runtime, spec = rawSpec }
		registry.runtimes[id] = runtime
	end
	table.sort(errors)
	if #errors > 0 then
		return nil, errors
	end
	return registry, {}
end
function M.select(
	registry: Registry,
	order: any,
	recipeId: string?
): ({ string }?, Contract.RuntimeContract?, { string })
	return genrecontract.select(order, registry.runtimes, recipeId)
end
return M
