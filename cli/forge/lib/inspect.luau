--!strict
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local M = {}

type Instance = any

local function findPath(root: Instance, pathStr: string): Instance?
	local current: Instance? = root
	for seg in string.gmatch(pathStr, "[^%.]+") do
		if not current then
			return nil
		end
		current = current:FindFirstChild(seg)
	end
	return current
end

local function scanRequires(source: string): { string }
	local result: { string } = {}
	for reqPath in string.gmatch(source, "require%s*%(%s*[\"'](%.%./?[^\"']*)[\"']%s*%)") do
		table.insert(result, reqPath)
	end
	for reqPath in string.gmatch(source, "require%s*%(%s*[\"'](%./[^\"']*)[\"']%s*%)") do
		table.insert(result, reqPath)
	end
	return result
end

local function resolveRelativeRequire(startInstance: Instance, reqPath: string): (Instance?, string?)
	local segments: { string } = {}
	for seg in string.gmatch(reqPath, "[^/]+") do
		table.insert(segments, seg)
	end
	if #segments == 0 then
		return nil, "empty path"
	end

	local current: Instance? = nil
	local idx = 1
	if segments[1] == "." then
		current = startInstance.Parent
		idx = 2
	elseif segments[1] == ".." then
		current = startInstance.Parent
		while idx <= #segments and segments[idx] == ".." do
			if not current then
				return nil, "traversed above root"
			end
			current = current.Parent
			idx += 1
		end
	else
		return nil, "not a relative path starting with ./ or ../"
	end

	while idx <= #segments do
		local seg = segments[idx]
		if seg == ".." then
			if not current then
				return nil, "traversed above root"
			end
			current = current.Parent
		elseif seg ~= "." then
			if not current then
				return nil, "cannot find child '" .. seg .. "' of nil"
			end
			local child = current:FindFirstChild(seg)
			if not child then
				return nil, "child '" .. seg .. "' not found under '" .. current.Name .. "'"
			end
			current = child
		end
		idx += 1
	end

	return current, nil
end

local function getFullName(inst: Instance): string
	local parts: { string } = {}
	local cur: Instance? = inst
	while cur and cur.Parent ~= nil do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, ".")
end

export type InspectResult = {
	ok: boolean,
	resolvedRequiresCount: number,
	errors: { string },
}

function M.inspectPlaceFile(rbxlPath: string, expectedInstances: { { path: string, expected: string } }?): InspectResult
	local errors: { string } = {}
	local resolvedCount = 0

	if not fs.isFile(rbxlPath) then
		table.insert(errors, "place file does not exist: " .. rbxlPath)
		return {
			ok = false,
			resolvedRequiresCount = 0,
			errors = errors,
		}
	end

	local content = fs.readFile(rbxlPath)
	local place: Instance = roblox.deserializePlace(content)

	-- Required assertions
	local assertions: { { path: string, expected: string } } = expectedInstances
		or {
			{ path = "ServerScriptService.KaijuEggRaidersServer", expected = "Script" },
			{ path = "StarterPlayer.StarterPlayerScripts.KaijuEggRaidersClient", expected = "LocalScript" },
			{ path = "ReplicatedStorage.Remotes.BuyEgg", expected = "RemoteFunction" },
			{ path = "ReplicatedStorage.Remotes.HatchEgg", expected = "RemoteFunction" },
			{ path = "ReplicatedStorage.Remotes.StateChanged", expected = "RemoteEvent" },
			{ path = "ReplicatedStorage.Forge.core.domain.economy.Wallet", expected = "ModuleScript" },
		}

	for _, req in assertions do
		local inst = findPath(place, req.path)
		if not inst then
			table.insert(errors, "missing expected instance: " .. req.path .. " (" .. req.expected .. ")")
		elseif inst.ClassName ~= req.expected then
			table.insert(
				errors,
				"expected " .. req.path .. " to be " .. req.expected .. ", but found " .. inst.ClassName
			)
		end
	end

	-- Traverse tree and validate
	local function traverse(inst: Instance)
		if inst.Name == "README" or string.match(inst.Name, "^README%.") then
			table.insert(errors, "instance named README found in place: " .. getFullName(inst))
		end

		if inst.ClassName == "ModuleScript" and string.match(inst.Name, "%.spec$") then
			table.insert(errors, "spec module found in place: " .. getFullName(inst))
		end

		if inst.ClassName == "ModuleScript" or inst.ClassName == "Script" or inst.ClassName == "LocalScript" then
			local source = (inst :: any).Source or ""
			local requires = scanRequires(source)
			for _, reqPath in requires do
				local target, err = resolveRelativeRequire(inst, reqPath)
				if not target then
					table.insert(
						errors,
						"unresolved require '" .. reqPath .. "' in " .. getFullName(inst) .. ": " .. tostring(err)
					)
				else
					resolvedCount += 1
				end
			end
		end

		for _, child in inst:GetChildren() do
			traverse(child)
		end
	end

	for _, service in place:GetChildren() do
		traverse(service)
	end

	return {
		ok = (#errors == 0),
		resolvedRequiresCount = resolvedCount,
		errors = errors,
	}
end

return M
