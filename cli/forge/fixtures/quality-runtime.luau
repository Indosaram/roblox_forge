--!strict
-- Synthetic admission fixture only; never a Studio proof or release receipt.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local receipt = require("../lib/qualityreceipt")
local identity = require("../lib/buildidentity")
local Png = require("../lib/png")
local Pixels = require("../../../core/domain/procgen/Pixels")
local roblox = require("@lune/roblox")
return function(profile: any, input: any, review: any, ownedQaToken: string?): any
	local root = input.root
	fs.writeFile(
		root .. "/" .. input.packDir .. "/default.project.json",
		serde.encode("json", { name = "fixture", tree = { ["$className"] = "DataModel" } })
	)
	local current = identity.snapshot(
		root .. "/" .. input.packDir .. "/default.project.json",
		root .. "/" .. input.packDir,
		root .. "/" .. input.buildPath
	)
	local serverSource, clientSource = identity.runtime(current)
	local place = roblox.Instance.new("DataModel")
	if ownedQaToken ~= nil then
		local storage = roblox.Instance.new("ReplicatedStorage")
		storage:SetAttribute("ForgeQAOwner", ownedQaToken)
		storage.Parent = place
	end
	local service = roblox.Instance.new("ServerScriptService")
	service.Parent = place
	local starter = roblox.Instance.new("StarterPlayer")
	starter.Parent = place
	local scripts = roblox.Instance.new("StarterPlayerScripts")
	scripts.Parent = starter
	local server, client = roblox.Instance.new("Script"), roblox.Instance.new("LocalScript")
	server.Name, server.Source, server.Parent = "ForgeBuildIdentity", serverSource, service
	client.Name, client.Source, client.Parent = "ForgeBuildIdentity", clientSource, scripts
	fs.writeFile(root .. "/" .. input.buildPath, roblox.serializePlace(place))
	fs.writeFile(
		root .. "/" .. input.buildPath .. ".identity.json",
		serde.encode("json", {
			schemaVersion = 1,
			identity = current,
			ownedQaToken = ownedQaToken,
			build = "sha256:" .. serde.hash("sha256", fs.readFile(root .. "/" .. input.buildPath)),
		})
	)
	local runtime = {
		server = {
			schemaVersion = 1,
			role = "server",
			buildIdentity = current.id,
			sessionId = "fixture-session",
			studio_id = "server",
			ownedQaToken = ownedQaToken,
			placeId = if ownedQaToken then 0 else nil,
		},
		clients = {},
	}
	local outcome: any = {
		ok = true,
		kind = "studio",
		blockers = {},
		runtime = runtime,
		clients = {},
		steps = {
			{
				index = 1,
				op = "capture",
				actor = "1",
				studio_id = "client1",
				sessionId = "fixture-session",
				shortcut = false,
				startedSeconds = 0,
				elapsedSeconds = 60,
				revisionBefore = 0,
				revisionAfter = 1,
			},
		},
		captures = {},
		firstPlay = { goals = {} },
		actionEvidence = input.evidence.actions[1],
	}
	local bytes = buffer.tostring(Png.encode(Pixels.new(8, 6)))
	review.surfaces = {}
	for index = 1, 2 do
		local actor, studio = tostring(index), "client" .. index
		table.insert(runtime.clients, {
			schemaVersion = 1,
			role = "client",
			buildIdentity = current.id,
			serverBuildIdentity = current.id,
			sessionId = "fixture-session",
			actorId = actor,
			studio_id = studio,
			ownedQaToken = ownedQaToken,
			placeId = if ownedQaToken then 0 else nil,
		})
		table.insert(outcome.clients, { actor = actor, studio_id = studio })
		local path = input.evidence.captures[1]
		fs.writeFile(root .. "/" .. path, bytes)
		table.insert(outcome.captures, {
			schemaVersion = 2,
			actor = actor,
			studio_id = studio,
			sessionId = "fixture-session",
			buildIdentity = current.id,
			path = path,
			sha256 = serde.hash("sha256", bytes),
			step = 1,
			elapsedSeconds = 60,
			device = {
				id = "desktop",
				surface = "desktop",
				width = 1280,
				height = 720,
				form = "Desktop",
				orientation = "LandscapeLeft",
				scaling = "ActualResolution",
			},
			logical = {
				full = { x = 0, y = 0, width = 1280, height = 720 },
				viewport = { x = 0, y = 0, width = 1280, height = 720 },
				safeArea = { x = 0, y = 0, width = 1280, height = 720 },
				insets = { left = 0, top = 0, right = 0, bottom = 0 },
			},
			raster = { format = "png", width = 8, height = 6 },
			logicalToRaster = { origin = "full-screen", scaleX = 8 / 1280, scaleY = 6 / 720, offsetX = 0, offsetY = 0 },
			criticalUI = { { id = "button", x = 10, y = 10, width = 100, height = 50 } },
		})
	end
	for _, capture in outcome.captures do
		table.insert(review.surfaces, {
			scenario = input.evidence.scenarios[1],
			capture = capture.path,
			actor = capture.actor,
			studio_id = capture.studio_id,
			surface = capture.device.surface,
			captureSchemaVersion = 2,
			geometryDigest = receipt.digest({
				device = capture.device,
				logical = capture.logical,
				raster = capture.raster,
				logicalToRaster = capture.logicalToRaster,
				criticalUI = capture.criticalUI,
			}),
		})
	end
	for _, goal in profile.firstPlayGoals do
		local recorded = {
			goalDigest = receipt.digest(goal),
			actors = { "1", "2" },
			step = 1,
			elapsedSeconds = 60,
			observation = "synthetic unit fixture",
			unprompted = true,
			shortcut = false,
		}
		outcome.firstPlay.goals[goal.id] = recorded
		local observed = table.clone(recorded)
		observed.completed, observed.minutes, observed.players, observed.evidence =
			true, 1, 2, input.evidence.scenarios[1]
		review.goals[goal.id] = observed
	end
	fs.writeFile(
		root .. "/" .. input.evidence.actions[1],
		serde.encode("json", { runtime = runtime, clients = outcome.clients, steps = outcome.steps })
	)
	fs.writeFile(
		root .. "/" .. input.evidence.scenarios[1],
		serde.encode("json", { mode = "studio", outcome = outcome })
	)
	return current
end
