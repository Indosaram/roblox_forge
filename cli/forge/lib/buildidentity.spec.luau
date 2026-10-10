--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local identity = require("./buildidentity")
local process = require("@lune/process")

local function fixture(callback: (string) -> ())
	local root = "build/spec-buildidentity"
	assert(not fs.isDir(root), "owned fixture already exists")
	if not fs.isDir("build") then
		fs.writeDir("build")
	end
	fs.writeDir(root)
	local ok, err = pcall(function()
		fs.writeDir(root .. "/assets")
		fs.writeFile(root .. "/assets/mesh.txt", "original asset")
		fs.writeFile(root .. "/game.yml", "name: identity\n")
		fs.writeFile(root .. "/Main.server.luau", "return nil\n")
		fs.writeFile(
			root .. "/default.project.json",
			serde.encode("json", {
				name = "identity",
				tree = {
					["$className"] = "DataModel",
					ServerScriptService = { Main = { ["$path"] = "Main.server.luau" } },
				},
			})
		)
		callback(root)
	end)
	fs.removeDir(root)
	assert(ok, tostring(err))
end

return {
	["owned QA overlay marks only temporary artifact project"] = function()
		fixture(function(root)
			local project, output = root .. "/default.project.json", root .. "/place.rbxl"
			local original = fs.readFile(project)
			local overlay = identity.prepare(project, root, output, "owned-test-marker-123")
			local document = serde.decode("json", fs.readFile(overlay.projectPath))
			assert(
				document.tree.ReplicatedStorage["$attributes"].ForgeQAOwner == "owned-test-marker-123",
				"marker exists before build"
			)
			assert(overlay.ownedQaToken == "owned-test-marker-123", "sidecar input binds marker")
			assert(fs.readFile(project) == original, "shared pack project unchanged")
			fs.removeDir(overlay.directory)
			local normal = identity.prepare(project, root, output)
			local unmarked = serde.decode("json", fs.readFile(normal.projectPath))
			assert(unmarked.tree.ReplicatedStorage == nil, "normal build does not provision QA owner")
			fs.removeDir(normal.directory)
		end)
	end,
	["built script classes cannot hide changed embedded identity source"] = function()
		local expected = { id = "sha256:" .. string.rep("a", 64) }
		local server, client = identity.runtime(expected)
		local place = roblox.Instance.new("DataModel")
		local service = roblox.Instance.new("ServerScriptService")
		service.Parent = place
		local starter = roblox.Instance.new("StarterPlayer")
		starter.Parent = place
		local scripts = roblox.Instance.new("StarterPlayerScripts")
		scripts.Parent = starter
		local a, b = roblox.Instance.new("Script"), roblox.Instance.new("LocalScript")
		a.Name, a.Source, a.Parent = "ForgeBuildIdentity", server, service
		b.Name, b.Source, b.Parent = "ForgeBuildIdentity", client, scripts
		assert(
			identity.inspectArtifact(roblox.serializePlace(place), expected),
			"unmarked artifact admits exact identity source"
		)
		assert(
			not identity.inspectArtifact(roblox.serializePlace(place), expected, "owned-test-marker-123"),
			"missing QA marker rejects"
		)
		local storage = roblox.Instance.new("ReplicatedStorage")
		storage.Parent = place
		storage:SetAttribute("ForgeQAOwner", "owned-test-marker-123")
		assert(
			identity.inspectArtifact(roblox.serializePlace(place), expected, "owned-test-marker-123"),
			"matching QA marker admits exact source"
		)
		assert(
			not identity.inspectArtifact(roblox.serializePlace(place), expected, "other-test-marker-123"),
			"wrong QA marker rejects"
		)
		assert(
			not identity.inspectArtifact(roblox.serializePlace(place), expected),
			"normal artifact cannot silently contain QA marker"
		)
		storage:SetAttribute("ForgeQAOwner", nil)
		b.Source = string.gsub(client, string.rep("a", 64), string.rep("b", 64))
		assert(
			not identity.inspectArtifact(roblox.serializePlace(place), expected),
			"right class with wrong literal rejects"
		)
	end,
	["identity changes with source config assets but not its artifact or sidecar"] = function()
		fixture(function(root)
			local project, output = root .. "/default.project.json", root .. "/place.rbxl"
			local first = identity.snapshot(project, root, output)
			fs.writeFile(output, "old artifact")
			fs.writeFile(output .. ".identity.json", "old identity")
			assert(identity.snapshot(project, root, output).id == first.id, "outputs cannot feed their own identity")
			for _, item in
				{
					{ "/Main.server.luau", "return true", "source" },
					{ "/game.yml", "name: changed", "config" },
					{ "/assets/mesh.txt", "changed asset", "asset" },
				}
			do
				local before = identity.snapshot(project, root, output)
				fs.writeFile(root .. item[1], item[2])
				local after = identity.snapshot(project, root, output)
				assert(
					after.id ~= before.id and after[item[3]] ~= before[item[3]],
					"changed input rejects stale identity"
				)
			end
			local original = fs.readFile(project)
			local overlay = identity.prepare(project, root, output)
			local document = serde.decode("json", fs.readFile(overlay.projectPath))
			assert(
				document.tree.ServerScriptService.ForgeBuildIdentity["$className"] == "Script",
				'document.tree.ServerScriptService.ForgeBuildIdentity["$className"] == "Script"'
			)
			assert(
				document.tree.StarterPlayer.StarterPlayerScripts.ForgeBuildIdentity["$className"] == "LocalScript",
				'document.tree.StarterPlayer.StarterPlayerScripts.ForgeBuildIdentity["$className"] == "LocalScript"'
			)
			assert(identity.snapshot(project, root, output).id == overlay.identity.id, "temporary overlay is excluded")
			assert(fs.readFile(project) == original, "pack project is never rewritten")
			fs.removeDir(overlay.directory)
		end)
	end,
	["overlay build preserves glob ignored spec exclusion like the authored mount"] = function()
		fixture(function(root)
			fs.writeDir(root .. "/src")
			fs.writeFile(root .. "/src/Runtime.luau", "return {}\n")
			fs.writeFile(root .. "/src/Logic.spec.luau", "return {}\n")
			fs.writeFile(
				root .. "/default.project.json",
				serde.encode("json", {
					name = "identity",
					globIgnorePaths = { "**/*.spec.luau" },
					tree = {
						["$className"] = "DataModel",
						ReplicatedStorage = { Assets = { ["$path"] = "src" } },
						ServerScriptService = { Main = { ["$path"] = "Main.server.luau" } },
					},
				})
			)
			local project, output = root .. "/default.project.json", root .. "/place.rbxl"
			local authored = process.exec("rojo", { "build", project, "-o", output .. ".authored.rbxl" })
			assert(authored.ok, authored.stderr)
			local overlay = identity.prepare(project, root, output)
			local built = process.exec("rojo", { "build", overlay.projectPath, "-o", output })
			assert(built.ok, built.stderr)
			local function selection(path: string): { [string]: boolean }
				local found: { [string]: boolean } = {}
				local function walk(inst: any)
					found[inst.Name] = true
					for _, child in inst:GetChildren() do
						walk(child)
					end
				end
				walk(roblox.deserializePlace(fs.readFile(path)))
				return found
			end
			local originalSelection = selection(output .. ".authored.rbxl")
			local overlaySelection = selection(output)
			for _, name in { "Runtime", "Main" } do
				assert(originalSelection[name], "authored mount keeps runtime module " .. name)
				assert(overlaySelection[name], "overlay build keeps runtime module " .. name)
			end
			assert(not originalSelection["Logic.spec"], "authored mount honors globIgnorePaths")
			assert(not overlaySelection["Logic.spec"], "overlay build honors globIgnorePaths")
			assert(overlaySelection.ForgeBuildIdentity, "overlay build keeps embedded identity")
			assert(
				identity.inspectArtifact(fs.readFile(output), overlay.identity),
				"embedded identity validates against prepared identity"
			)
		end)
	end,
	["actual emitted server and client handshakes reject stale and crossed identities"] = function()
		local expected = { id = "sha256:" .. string.rep("a", 64) }
		local serverSource, clientSource = identity.runtime(expected)
		local remote: any
		local function execute(source: string, actor: string?): any
			local scriptObject = {}
			local storage = {
				FindFirstChild = function()
					return nil
				end,
				WaitForChild = function()
					return remote
				end,
			}
			luau.load(source, {
				environment = {
					script = scriptObject,
					task = {
						defer = function(callback)
							callback()
							return coroutine.create(function() end)
						end,
						delay = function(_seconds, _callback)
							return coroutine.create(function() end)
						end,
						cancel = function(_thread) end,
						spawn = function(_thread)
							error("unexpected asynchronous fixture resume")
						end,
					},
					game = {
						GetService = function(_self: any, name: string): any
							if name == "ReplicatedStorage" then
								return storage
							end
							if name == "HttpService" then
								return {
									GenerateGUID = function()
										return "server-session"
									end,
								}
							end
							return { LocalPlayer = { UserId = actor } }
						end,
					},
					Instance = {
						new = function(kind: string): any
							local object: any = {}
							if kind == "BindableEvent" then
								object.Event = {
									Connect = function(_self, _callback)
										return { Disconnect = function() end }
									end,
								}
								object.Fire = function() end
								object.Destroy = function() end
							end
							if kind == "RemoteFunction" then
								remote = object
								object.IsA = function(_self: any, class: string)
									return class == kind
								end
								object.InvokeServer = function()
									return object.OnServerInvoke({ UserId = actor or "1" })
								end
							end
							return setmetatable(object, {
								__newindex = function(self: any, key: string, value: any)
									rawset(self, key, value)
									if key == "Parent" and value == scriptObject then
										(scriptObject :: any).Handshake = self
									end
								end,
							})
						end,
					},
				},
			})()
			return (scriptObject :: any).Handshake.OnInvoke()
		end
		local server = execute(serverSource)
		local clients = { execute(clientSource, "1"), execute(clientSource, "2") }
		assert(identity.validateLoaded(expected, server, clients), "actual emitted happy handshakes")
		local old = "sha256:" .. string.rep("b", 64)
		for _, field in { "buildIdentity", "serverBuildIdentity", "sessionId", "actorId" } do
			local saved = clients[2][field]
			clients[2][field] = if field == "actorId" then "1" else old
			assert(not identity.validateLoaded(expected, server, clients), "reject client mismatch: " .. field)
			clients[2][field] = saved
		end
		server.buildIdentity = old
		assert(not identity.validateLoaded(expected, server, clients), "reject old loaded server")
		server.buildIdentity = expected.id
		assert(
			not identity.validateLoaded({ id = old }, server, clients),
			"fresh local identity cannot attest old runtime"
		)
		assert(not identity.validateLoaded(expected, server, { clients[1] }), "both clients required")
	end,
	["actual emitted client retries a dropped handshake invoke before failing closed"] = function()
		local expected = { id = "sha256:" .. string.rep("a", 64) }
		local _serverSource, clientSource = identity.runtime(expected)
		local function runClient(invoke: (number) -> any): (any, { number }, number, any)
			local attempts = 0
			local waits: { number } = {}
			local scriptObject: any = {}
			local remote = {
				IsA = function(_self: any, className: string)
					return className == "RemoteFunction"
				end,
				InvokeServer = function()
					attempts += 1
					return invoke(attempts)
				end,
			}
			local storage = {
				WaitForChild = function()
					return remote
				end,
			}
			local loadOk, loadResult = pcall(function()
				luau.load(clientSource, {
					environment = {
						script = scriptObject,
						task = {
							defer = function(callback)
								callback()
								return coroutine.create(function() end)
							end,
							delay = function(_seconds, _callback)
								return coroutine.create(function() end)
							end,
							cancel = function(_thread) end,
							spawn = function(_thread)
								error("unexpected asynchronous fixture resume")
							end,
							wait = function(seconds: number)
								table.insert(waits, seconds)
							end,
						},
						game = {
							GetService = function(_self: any, name: string): any
								if name == "ReplicatedStorage" then
									return storage
								end
								return { LocalPlayer = { UserId = 7 } }
							end,
						},
						Instance = {
							new = function(kind: string): any
								local object: any = {}
								if kind == "BindableEvent" then
									object.Event = {
										Connect = function(_self, _callback)
											return { Disconnect = function() end }
										end,
									}
									object.Fire = function() end
									object.Destroy = function() end
								end
								return setmetatable(object, {
									__newindex = function(self: any, key: string, value: any)
										rawset(self, key, value)
										if key == "Parent" and value == scriptObject then
											scriptObject.Handshake = self
										end
									end,
								})
							end,
						},
					},
				})()
			end)
			return scriptObject, waits, attempts, if loadOk then nil else loadResult
		end

		local recovered, waits, attempts, err = runClient(function(attempt: number)
			if attempt == 1 then
				error("synthetic join-burst drop")
			end
			return { buildIdentity = expected.id, sessionId = "session-one" }
		end)
		assert(err == nil, "retrying client registers: " .. tostring(err))
		assert(recovered.Handshake, "handshake survives the dropped first invoke")
		assert(attempts == 2, "second attempt succeeds")
		assert(#waits == 1 and waits[1] == 2, "one bounded backoff between attempts")
		local payload = recovered.Handshake.OnInvoke()
		assert(payload.serverBuildIdentity == expected.id, "retried invoke returns the live server identity")
		assert(payload.sessionId == "session-one", "session retained after retry")
		assert(payload.actorId == "7", "actor identity retained after retry")

		local _dead, deadWaits, deadAttempts, deadErr = runClient(function(_attempt: number)
			error("synthetic handshake refusal")
		end)
		assert(
			deadErr ~= nil and string.find(tostring(deadErr), "synthetic handshake refusal", 1, true) ~= nil,
			"final failure surfaces the last server refusal"
		)
		assert(deadAttempts == 3, "exactly the bounded attempt count")
		assert(#deadWaits == 2, "backoff only between attempts")
	end,
}
