--!strict
local Contract = require("../../../core/domain/genre/Contract")
local Executor = require("../../../core/domain/genre/Executor")
local Schema = require("../../../core/infra/net/Schema")
local Validation = require("../../../core/domain/genre/Validation")
export type GenerateInput = {
	mode: "new" | "plan",
	slug: string,
	pascal: string,
	title: string,
	concept: string,
	seed: number,
	teams: { string },
	debugName: string,
	guiName: string,
}
export type Artifact = { path: string, content: string }
export type Control = {
	id: string,
	action: string,
	args: { any },
	label: string,
	kind: "button" | "prompt" | "player-button",
}
export type Generated = {
	config: Contract.ConfigData,
	artifacts: { Artifact },
	controls: { Control },
	assetKeys: { string },
	generation: { string },
}
export type Check = { name: string, ok: boolean, detail: string? }
export type SimMetrics = {
	balances: { [string]: number },
	sourceTotal: number,
	sinkTotal: number,
	acceptedActions: number,
	rejectedActions: number,
}
export type Driver = {
	run: (Executor.Executor, GenerateInput) -> { Check },
	simulate: (Executor.Executor, GenerateInput, number, number) -> SimMetrics,
}
export type Generator = {
	api: number,
	id: string,
	configVersion: number,
	runtime: Contract.RuntimeContract,
	generate: (GenerateInput) -> Generated,
	driver: Driver,
	recipes: {
		[string]: { normalize: ({ [string]: Contract.ConfigData }) -> { [string]: Contract.ConfigData }, driver: Driver },
	}?,
	qa: { scenarios: { string }, operations: { string }, targets: { string } },
	legacy: { generate: (GenerateInput) -> Generated, codegen: (string) -> string }?,
}
export type Manifest = {
	name: string,
	version: string,
	requires: { core: string },
	genre_contract: { api: number, generator: string, runtime: string, spec: string },
}
local M = {}
function M.id(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
end
function M.dense(value: any, limit: number): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > limit then
			return false
		end
		count += 1
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end
local function semver(value: any): { number }?
	if type(value) ~= "string" then
		return nil
	end
	local a, b, c = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
	if a == nil or b == nil or c == nil then
		return nil
	end
	local result = { tonumber(a) :: number, tonumber(b) :: number, tonumber(c) :: number }
	for _, n in result do
		if not Executor.finite(n) or n >= 2 ^ 53 then
			return nil
		end
	end
	return result
end
function M.coreCompatible(version: string, range: string): boolean
	if type(range) ~= "string" or string.sub(range, 1, 1) ~= "^" then
		return false
	end
	local current, base = semver(version), semver(string.sub(range, 2))
	if current == nil or base == nil then
		return false
	end
	local pivot = if base[1] > 0 then 1 elseif base[2] > 0 then 2 else 3
	for i = 1, pivot do
		if current[i] ~= base[i] then
			return false
		end
	end
	for i = pivot + 1, 3 do
		if current[i] > base[i] then
			return true
		end
		if current[i] < base[i] then
			return false
		end
	end
	return true
end
function M.validateManifest(raw: any, directoryId: string, coreVersion: string): { string }
	if type(raw) ~= "table" then
		return { "manifest: expected map" }
	end
	local errors: { string } = {}
	if not M.id(raw.name) or raw.name ~= directoryId then
		table.insert(errors, "name: must equal directory id")
	end
	if semver(raw.version) == nil then
		table.insert(errors, "version: expected major.minor.patch")
	end
	if type(raw.requires) ~= "table" or not M.coreCompatible(coreVersion, raw.requires.core) then
		table.insert(errors, "requires.core: unsupported or incompatible caret range")
	end
	local marker = raw.genre_contract
	if type(marker) ~= "table" or marker.api ~= 1 then
		table.insert(errors, "genre_contract: api 1 required")
	else
		if marker.generator ~= "generator.luau" then
			table.insert(errors, "genre_contract.generator: must be generator.luau")
		end
		if marker.runtime ~= "module/Contract.luau" then
			table.insert(errors, "genre_contract.runtime: must be module/Contract.luau")
		end
		-- The declarative spec lands beside the runtime descriptor it binds, and
		-- `genreregistry.discover` refuses a package that does not ship it.
		if marker.spec ~= "genre-spec.yml" then
			table.insert(errors, "genre_contract.spec: must be genre-spec.yml")
		end
	end
	table.sort(errors)
	return errors
end
M.validateRuntime = Validation.validateRuntime
M.validateValidator = Validation.validateValidator
function M.select(
	order: any,
	runtimes: { [string]: Contract.RuntimeContract },
	recipeId: string?
): ({ string }?, Contract.RuntimeContract?, { string })
	if not M.dense(order, 64) or #order == 0 then
		return nil, nil, { "order: expected nonempty dense list" }
	end
	local seen: { [string]: boolean } = {}
	local errors: { string } = {}
	for _, id in order do
		if not M.id(id) or seen[id] or runtimes[id] == nil then
			table.insert(errors, "order: invalid/duplicate/unknown " .. tostring(id))
		else
			seen[id] = true
		end
	end
	if #errors > 0 then
		table.sort(errors)
		return nil, nil, errors
	end
	if #order == 1 then
		if recipeId ~= nil then
			return nil, nil, { "recipe: unsupported single selection" }
		end
		return table.clone(order), nil, {}
	end
	local matches: { Contract.RuntimeContract } = {}
	for _, id in order do
		local runtime = runtimes[id]
		local r = runtime.recipe
		if r ~= nil and #r.partners == #order and (recipeId == nil or recipeId == r.id) then
			local exact = true
			for _, partner in r.partners do
				if not seen[partner] then
					exact = false
				end
			end
			if exact then
				table.insert(matches, runtime)
			end
		end
	end
	if #matches ~= 1 then
		return nil, nil, { "recipe: requires exactly one matching recipe" }
	end
	local owner = matches[1]
	assert(owner.recipe ~= nil, "contract assertion failed")
	return table.clone(owner.recipe.partners), owner, {}
end
function M.validatePack(pack: any, runtimes: { [string]: Contract.RuntimeContract }): { string }
	if type(pack) ~= "table" or not Executor.data(pack) or pack.api ~= 1 or type(pack.configs) ~= "table" then
		return { "pack: invalid data/api/configs" }
	end
	local order, owner, errors = M.select(pack.order, runtimes, pack.recipe)
	if order == nil then
		return errors
	end
	if owner ~= nil and pack.recipe == nil then
		table.insert(errors, "recipe: required in pack")
	end
	for i, id in order do
		if pack.order[i] ~= id then
			table.insert(errors, "order: not canonical")
		end
		local config = pack.configs[id]
		if type(config) ~= "table" then
			table.insert(errors, "configs: missing " .. id)
		else
			for _, err in runtimes[id].validateConfig(Executor.clone(config)) do
				table.insert(errors, id .. ": " .. err)
			end
		end
	end
	for id in pack.configs do
		if not table.find(order, id) then
			table.insert(errors, "configs: unknown " .. tostring(id))
		end
	end
	for key in pack do
		if key ~= "api" and key ~= "order" and key ~= "configs" and key ~= "recipe" then
			table.insert(errors, "pack: unknown " .. tostring(key))
		end
	end
	if #errors == 0 and owner ~= nil and owner.recipe ~= nil and owner.recipe.validateConfig ~= nil then
		for _, err in owner.recipe.validateConfig(Executor.clone(pack.configs)) do
			table.insert(errors, "recipe: " .. err)
		end
	end
	table.sort(errors)
	return errors
end
function M.validateGenerator(raw: any, runtime: Contract.RuntimeContract): { string }
	if type(raw) ~= "table" then
		return { "generator: expected descriptor" }
	end
	local errors: { string } = {}
	if raw.api ~= 1 or raw.configVersion ~= 1 or raw.id ~= runtime.id then
		table.insert(errors, "generator: metadata mismatch")
	end
	if type(raw.runtime) == "table" then
		for _, err in M.validateRuntime(raw.runtime) do
			table.insert(errors, "generator.runtime: " .. err)
		end
		for _, field in { "actions", "events", "hooks" } do
			if
				Executor.data(raw.runtime[field])
				and Executor.data(runtime[field])
				and M.serialize(raw.runtime[field]) ~= M.serialize(runtime[field])
			then
				table.insert(errors, "generator.runtime: " .. field .. " mismatch")
			end
		end
		local left, right = raw.runtime.recipe, runtime.recipe
		if
			(left == nil) ~= (right == nil)
			or (
				left ~= nil
				and right ~= nil
				and (
					left.id ~= right.id
					or M.serialize(left.partners) ~= M.serialize(right.partners)
					or (left.validateConfig == nil) ~= (right.validateConfig == nil)
				)
			)
		then
			table.insert(errors, "generator.runtime: recipe mismatch")
		end
	end
	if
		type(raw.runtime) ~= "table"
		or raw.runtime.id ~= runtime.id
		or raw.runtime.api ~= runtime.api
		or raw.runtime.configVersion ~= runtime.configVersion
		or raw.runtime.saveVersion ~= runtime.saveVersion
	then
		table.insert(errors, "generator.runtime: metadata mismatch")
	end
	if
		type(raw.generate) ~= "function"
		or type(raw.driver) ~= "table"
		or type(raw.driver.run) ~= "function"
		or type(raw.driver.simulate) ~= "function"
	then
		table.insert(errors, "generator: missing generation/driver")
	end
	if type(raw.qa) ~= "table" then
		table.insert(errors, "qa: missing descriptor")
	else
		for _, field in { "scenarios", "operations", "targets" } do
			local list = raw.qa[field]
			if not M.dense(list, 1024) or #list == 0 then
				table.insert(errors, "qa." .. field .. ": nonempty dense list required")
			else
				local seen: { [string]: boolean } = {}
				for _, name in list do
					if type(name) ~= "string" or #name > 128 or seen[name] then
						table.insert(errors, "qa." .. field .. ": invalid/duplicate name")
					else
						seen[name] = true
					end
				end
			end
		end
		if
			type(raw.qa.scenarios) == "table"
			and (
				not table.find(raw.qa.scenarios, "contract-loop") or not table.find(raw.qa.scenarios, "contract-rejoin")
			)
		then
			table.insert(errors, "qa: required contract scenarios missing")
		end
	end
	if
		raw.legacy ~= nil
		and (
			type(raw.legacy) ~= "table"
			or type(raw.legacy.generate) ~= "function"
			or type(raw.legacy.codegen) ~= "function"
		)
	then
		table.insert(errors, "legacy: invalid capability")
	end
	if raw.recipes ~= nil then
		if type(raw.recipes) ~= "table" then
			table.insert(errors, "recipes: expected capability map")
		else
			for id, recipe in raw.recipes do
				if
					runtime.recipe == nil
					or id ~= runtime.recipe.id
					or type(recipe) ~= "table"
					or type(recipe.normalize) ~= "function"
					or type(recipe.driver) ~= "table"
					or type(recipe.driver.run) ~= "function"
					or type(recipe.driver.simulate) ~= "function"
				then
					table.insert(errors, "recipes: invalid/undeclared capability " .. tostring(id))
				end
			end
			if runtime.recipe and raw.recipes[runtime.recipe.id] == nil then
				table.insert(errors, "recipes: missing declared capability")
			end
		end
	elseif runtime.recipe ~= nil then
		table.insert(errors, "recipes: missing declared capability")
	end
	table.sort(errors)
	return errors
end
function M.validateGenerated(generated: any, generator: Generator): { string }
	if type(generated) ~= "table" then
		return { "generated: invalid JSON data" }
	end
	local errors: { string } = {}
	if type(generated.config) ~= "table" or not Executor.data(generated.config) then
		table.insert(errors, "config: missing")
	else
		for _, err in generator.runtime.validateConfig(Executor.clone(generated.config)) do
			table.insert(errors, "config: " .. err)
		end
	end
	local paths: { [string]: boolean } = {}
	if not M.dense(generated.artifacts, 1024) then
		table.insert(errors, "artifacts: invalid list")
	else
		for _, artifact in generated.artifacts do
			local path = if type(artifact) == "table" then artifact.path else nil
			local safe = type(path) == "string"
				and #path > 0
				and not string.find(path, "\\", 1, true)
				and not string.find(path, ":", 1, true)
				and string.sub(path, 1, 1) ~= "/"
			if safe then
				for segment in string.gmatch(path, "[^/]+") do
					if segment == "." or segment == ".." then
						safe = false
					end
				end
			end
			if safe and generator.legacy == nil then
				safe = false
				for _, prefix in { "design/", "src/shared/", "assets/" } do
					if string.sub(path, 1, #prefix + #generator.id + 1) == prefix .. generator.id .. "/" then
						safe = true
					end
				end
			end
			if not safe or paths[path] or type(artifact.content) ~= "string" then
				table.insert(errors, "artifacts: unsafe/duplicate path")
			else
				paths[path] = true
			end
		end
	end
	local actions: { [string]: Contract.Action } = {}
	for _, action in generator.runtime.actions do
		actions[generator.id .. ":" .. action.id] = action
	end
	local controls: { [string]: boolean } = {}
	if not M.dense(generated.controls, 1024) then
		table.insert(errors, "controls: invalid list")
	else
		for _, control in generated.controls do
			if type(control) ~= "table" then
				table.insert(errors, "controls: invalid descriptor")
				continue
			end
			local action = actions[control.action]
			local namespace, localId = nil, nil
			if type(control.id) == "string" then
				namespace, localId = string.match(control.id, "^([^:]+):([^:]+)$")
			end
			local validId = M.id(control.id) or (namespace == generator.id and M.id(localId))
			if
				not validId
				or controls[control.id]
				or type(control.label) ~= "string"
				or (control.kind ~= "button" and control.kind ~= "prompt" and control.kind ~= "player-button")
				or action == nil
				or action.origin ~= "client"
				or not M.dense(control.args, 1024)
				or not Executor.data(control.args)
			then
				table.insert(errors, "controls: invalid/disallowed control")
			else
				controls[control.id] = true
				local args = table.clone(control.args)
				if control.kind == "player-button" then
					table.insert(args, 1, "selected-player")
				end
				local ok = #args == #action.args and Schema.check(Schema.tuple(action.args), args)
				if not ok then
					table.insert(errors, "controls: invalid action tuple")
				end
			end
		end
	end
	local keys: { [string]: boolean } = {}
	if not M.dense(generated.assetKeys, 1024) then
		table.insert(errors, "assetKeys: invalid list")
	else
		for _, key in generated.assetKeys do
			local validKey = if generator.legacy ~= nil
				then type(key) == "string" and #key <= 128 and string.match(key, "^[%a][%w_%-]*$") ~= nil
				else M.id(key)
			if
				not validKey
				or keys[key]
				or (generator.legacy == nil and string.sub(key, 1, #generator.id + 1) ~= generator.id .. "-")
			then
				table.insert(errors, "assetKeys: invalid/duplicate namespace")
			else
				keys[key] = true
			end
		end
	end
	local last = 0
	if not M.dense(generated.generation, 3) then
		table.insert(errors, "generation: invalid list")
	else
		for _, capability in generated.generation do
			local index = table.find({ "procedural", "launchart", "audio" }, capability)
			if index == nil or index <= last then
				table.insert(errors, "generation: invalid capability/order")
			else
				last = index
			end
		end
	end
	table.sort(errors)
	return errors
end
function M.serialize(value: any): string
	assert(Executor.data(value), "invalid JSON data")
	local function render(item: any): string
		if type(item) == "string" then
			return string.format("%q", item)
		end
		if type(item) ~= "table" then
			return tostring(item)
		end
		local keys = {}
		for key in item do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local fields = {}
		for _, key in keys do
			table.insert(fields, "[" .. render(key) .. "]=" .. render(item[key]))
		end
		return "{" .. table.concat(fields, ",") .. "}"
	end
	return render(value)
end
return M
