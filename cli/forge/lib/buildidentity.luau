--!strict
-- Local content identity, not signing. The final place hash belongs in the
-- sidecar, never in the scripts whose bytes contribute to that place hash.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local M = {}

local function absolute(path: string): string
	local normalized = string.gsub(path, "\\", "/")
	if not string.match(normalized, "^%a:/") and string.sub(normalized, 1, 1) ~= "/" then
		normalized = string.gsub(process.cwd, "\\", "/") .. "/" .. normalized
	end
	local prefix = string.match(normalized, "^%a:") or ""
	local parts = {}
	for part in string.gmatch(string.sub(normalized, #prefix + 1), "[^/]+") do
		if part == ".." then
			assert(#parts > 0, "IDENTITY_PATH_ESCAPE")
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return prefix .. "/" .. table.concat(parts, "/")
end

local function digest(entries: { [string]: string }): string
	local keys, parts = {}, {}
	for key in entries do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(parts, serde.encode("json", key) .. ":" .. serde.encode("json", entries[key]))
	end
	return "sha256:" .. serde.hash("sha256", table.concat(parts, "\n"))
end

function M.snapshot(projectPath: string, packDir: string?, outputPath: string): (any, any)
	local project = absolute(projectPath)
	local parent = string.match(project, "^(.*)/[^/]+$") :: string
	local output = absolute(outputPath)
	local root = absolute(".") .. "/"
	local pack = if packDir then absolute(packDir) elseif fs.isFile(parent .. "/game.yml") then parent else nil
	local source, config, assets = {}, {}, {}
	local visited: { [string]: boolean } = {}
	local function walk(path: string)
		path = absolute(path)
		if path == output or path == output .. ".identity.json" or path == output .. ".identity-project" then
			return
		end
		if visited[path] then
			return
		end
		visited[path] = true
		if fs.isDir(path) then
			for _, name in fs.readDir(path) do
				walk(path .. "/" .. name)
			end
		else
			assert(fs.isFile(path), "IDENTITY_MISSING_INPUT: " .. path)
			local key = if string.sub(path, 1, #root) == root then string.sub(path, #root + 1) else path
			local hash = "sha256:" .. serde.hash("sha256", fs.readFile(path))
			source[key] = hash
			if
				string.match(path, "%.ya?ml$")
				or string.match(path, "%.json$")
				or string.match(path, "%.toml$")
				or string.match(path, "%.lock$")
			then
				config[key] = hash
			end
			if pack and string.sub(path, 1, #pack + 8) == pack .. "/assets/" then
				assets[key] = hash
			end
		end
	end
	local document = serde.decode("json", fs.readFile(project))
	assert(type(document) == "table" and type(document.tree) == "table", "IDENTITY_INVALID_PROJECT")
	local function paths(node: any)
		if type(node) ~= "table" then
			return
		end
		if node["$path"] ~= nil then
			assert(type(node["$path"]) == "string", "IDENTITY_UNSUPPORTED_PATH")
			local value = node["$path"]
			node["$path"] = absolute(
				if string.match(value, "^%a:/") or string.sub(value, 1, 1) == "/" then value else parent .. "/" .. value
			)
			walk(node["$path"])
		end
		for key, child in node do
			if type(key) == "string" and string.sub(key, 1, 1) ~= "$" then
				paths(child)
			end
		end
	end
	paths(document.tree)
	walk(project)
	if pack then
		walk(pack)
		local manifestPath = pack .. "/assets/manifest.yml"
		if fs.isFile(manifestPath) then
			local manifest = serde.decode("yaml", fs.readFile(manifestPath))
			assert(type(manifest) == "table" and type(manifest.assets) == "table", "IDENTITY_INVALID_ASSETS")
			for _, asset in manifest.assets do
				if type(asset) == "table" and asset.path ~= nil then
					assert(type(asset.path) == "string", "IDENTITY_INVALID_ASSET_PATH")
					local path = absolute(pack .. "/" .. asset.path)
					assert(string.sub(path, 1, #pack + 1) == pack .. "/", "IDENTITY_ASSET_ESCAPE")
					walk(path)
					local key = if string.sub(path, 1, #root) == root then string.sub(path, #root + 1) else path
					assert(source[key], "IDENTITY_EXCLUDED_ASSET")
					assets[key] = source[key]
				end
			end
		end
	end
	-- The emitter and pinned tools are inputs even when not mounted in Rojo.
	for _, path in { "cli/forge/lib/buildidentity.luau", "cli/forge/lib/buildtargets.luau", "rokit.toml" } do
		walk(path)
	end
	local value: any = { schemaVersion = 1, source = digest(source), config = digest(config), asset = digest(assets) }
	value.id = digest({ source = value.source, config = value.config, asset = value.asset, schemaVersion = "1" })
	return value, document
end

function M.runtime(identity: any): (string, string)
	local literal = string.format("%q", identity.id)
	local server = [[--!strict
local id = ]] .. literal .. [[

local http = game:GetService("HttpService")
local storage = game:GetService("ReplicatedStorage")
local session = http:GenerateGUID(false)
assert(not storage:FindFirstChild("ForgeBuildHandshake"), "build handshake already exists")
local remote = Instance.new("RemoteFunction")
remote.Name = "ForgeBuildHandshake"
remote.OnServerInvoke = function(player)
	return {schemaVersion=1, role="server", buildIdentity=id, sessionId=session, actorId=tostring(player.UserId)}
end
remote.Parent = storage
local handshake = Instance.new("BindableFunction")
handshake.Name = "Handshake"
handshake.OnInvoke = function()
	return {schemaVersion=1, role="server", buildIdentity=id, sessionId=session}
end
handshake.Parent = script
]]
	local client = [[--!strict
local id = ]] .. literal .. [[

local player = game:GetService("Players").LocalPlayer
local remote = game:GetService("ReplicatedStorage"):WaitForChild("ForgeBuildHandshake", 30)
assert(remote and remote:IsA("RemoteFunction"), "build handshake unavailable")
local signal = Instance.new("BindableEvent")
local server, failure = nil, nil
local waiting = coroutine.running()
local connection = signal.Event:Connect(function()
	if coroutine.status(waiting) == "suspended" then task.spawn(waiting) end
end)
-- The join burst can delay the first response past one timeout; a single
-- dropped attempt must not kill identity registration forever, so retry
-- bounded before treating the failure as final.
for attempt = 1, 3 do
	local finished = false
	local worker = task.defer(function()
		local ok, result = pcall(function() return remote:InvokeServer() end)
		if finished then return end
		finished = true
		if ok then server = result else failure = tostring(result) end
		signal:Fire()
	end)
	local timeout = task.delay(10, function()
		if finished then return end
		finished = true
		failure = "BUILD_HANDSHAKE_TIMEOUT"
		task.cancel(worker)
		signal:Fire()
	end)
	if not finished then coroutine.yield() end
	if coroutine.status(timeout) == "suspended" then task.cancel(timeout) end
	if server then break end
	if attempt < 3 then task.wait(2) end
end
connection:Disconnect()
signal:Destroy()
assert(server, failure or "BUILD_HANDSHAKE_FAILED")
local handshake = Instance.new("BindableFunction")
handshake.Name = "Handshake"
handshake.OnInvoke = function()
	return {schemaVersion=1, role="client", buildIdentity=id, serverBuildIdentity=server.buildIdentity, sessionId=server.sessionId, actorId=tostring(player.UserId)}
end
handshake.Parent = script
]]
	return server, client
end

local function relativeMount(fromDir: string, target: string): string
	local from, to = {}, {}
	for part in string.gmatch(fromDir, "[^/]+") do
		table.insert(from, part)
	end
	for part in string.gmatch(target, "[^/]+") do
		table.insert(to, part)
	end
	if from[1] ~= to[1] then
		return target
	end
	local shared = 1
	while shared <= #from and shared <= #to and from[shared] == to[shared] do
		shared += 1
	end
	local parts = {}
	for _ = shared, #from do
		table.insert(parts, "..")
	end
	for i = shared, #to do
		table.insert(parts, to[i])
	end
	return #parts > 0 and table.concat(parts, "/") or "."
end

function M.prepare(projectPath: string, packDir: string?, outputPath: string, ownedQaToken: string?): any
	local identity, document = M.snapshot(projectPath, packDir, outputPath)
	local server, client = M.runtime(identity)
	local tree = document.tree
	if ownedQaToken ~= nil then
		assert(
			#ownedQaToken >= 16 and #ownedQaToken <= 128 and string.match(ownedQaToken, "^[%w%-]+$"),
			"INVALID_OWNED_QA_TOKEN"
		)
		tree.ReplicatedStorage = tree.ReplicatedStorage or { ["$className"] = "ReplicatedStorage" }
		local storage = tree.ReplicatedStorage
		storage["$attributes"] = storage["$attributes"] or {}
		assert(storage["$attributes"].ForgeQAOwner == nil, "OWNED_QA_MARKER_RESERVED")
		storage["$attributes"].ForgeQAOwner = ownedQaToken
	end
	tree.ServerScriptService = tree.ServerScriptService or { ["$className"] = "ServerScriptService" }
	tree.StarterPlayer = tree.StarterPlayer or { ["$className"] = "StarterPlayer" }
	tree.StarterPlayer.StarterPlayerScripts = tree.StarterPlayer.StarterPlayerScripts
		or { ["$className"] = "StarterPlayerScripts" }
	assert(
		not tree.ServerScriptService.ForgeBuildIdentity
			and not tree.StarterPlayer.StarterPlayerScripts.ForgeBuildIdentity,
		"IDENTITY_RESERVED_INSTANCE"
	)
	tree.ServerScriptService.ForgeBuildIdentity = { ["$className"] = "Script", ["$properties"] = { Source = server } }
	tree.StarterPlayer.StarterPlayerScripts.ForgeBuildIdentity =
		{ ["$className"] = "LocalScript", ["$properties"] = { Source = client } }
	local directory = outputPath .. ".identity-project"
	assert(not fs.isDir(directory) and not fs.isFile(directory), "IDENTITY_OVERLAY_IN_USE")
	fs.writeDir(directory)
	local path = directory .. "/default.project.json"
	do
		local base = absolute(directory)
		local function relativize(node: any)
			if type(node) ~= "table" then
				return
			end
			if type(node["$path"]) == "string" then
				node["$path"] = relativeMount(base, node["$path"])
			end
			for key, child in node do
				if type(key) == "string" and string.sub(key, 1, 1) ~= "$" then
					relativize(child)
				end
			end
		end
		relativize(tree)
	end
	local ok, err = pcall(fs.writeFile, path, serde.encode("json", document, true))
	if not ok then
		fs.removeDir(directory)
		error(err)
	end
	return { identity = identity, projectPath = path, directory = directory, ownedQaToken = ownedQaToken }
end

function M.inspectArtifact(bytes: string, identity: any, ownedQaToken: string?): boolean
	local place = roblox.deserializePlace(bytes)
	local storage = place:FindFirstChild("ReplicatedStorage")
	local marker = if storage then storage:GetAttribute("ForgeQAOwner") else nil
	if marker ~= ownedQaToken then
		return false
	end
	local server, client = M.runtime(identity)
	local service = place:FindFirstChild("ServerScriptService")
	local starter = place:FindFirstChild("StarterPlayer")
	local scripts = starter and starter:FindFirstChild("StarterPlayerScripts")
	-- platform=standard has no script class typings; ClassName guards below run
	-- before the engine-only Source property is read, so these stay untyped here.
	local emittedServer: any = service and service:FindFirstChild("ForgeBuildIdentity")
	local emittedClient: any = scripts and scripts:FindFirstChild("ForgeBuildIdentity")
	return emittedServer ~= nil
		and emittedServer.ClassName == "Script"
		and emittedServer.Source == server
		and emittedClient ~= nil
		and emittedClient.ClassName == "LocalScript"
		and emittedClient.Source == client
end

-- Capture and final evaluation must both call this with freshly read runtime
-- handshakes, and separately compare the sidecar to snapshot + artifact bytes.
function M.validateLoaded(identity: any, server: any, clients: any): boolean
	if
		type(identity) ~= "table"
		or type(identity.id) ~= "string"
		or not string.match(identity.id, "^sha256:%x+$")
		or #identity.id ~= 71
	then
		return false
	end
	if
		type(server) ~= "table"
		or server.schemaVersion ~= 1
		or server.role ~= "server"
		or server.buildIdentity ~= identity.id
		or type(server.sessionId) ~= "string"
		or server.sessionId == ""
	then
		return false
	end
	if type(clients) ~= "table" or #clients < 2 then
		return false
	end
	local actors: { [string]: boolean } = {}
	local count = 0
	for index, client in clients do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #clients or type(client) ~= "table" then
			return false
		end
		if
			client.schemaVersion ~= 1
			or client.role ~= "client"
			or client.buildIdentity ~= identity.id
			or client.serverBuildIdentity ~= identity.id
			or client.sessionId ~= server.sessionId
			or type(client.actorId) ~= "string"
			or client.actorId == ""
			or actors[client.actorId]
		then
			return false
		end
		actors[client.actorId] = true
		count += 1
	end
	return count == #clients
end

return M
