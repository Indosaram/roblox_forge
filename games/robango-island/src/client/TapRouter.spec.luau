--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local TapRouter = require("./TapRouter")
local function probe(fields: { [string]: any }): any
	return fields
end
-- TapRouter with a stub `game` for installActions (ReplicatedStorage remotes, the local character).
local function loadWithGame(rootPosition: any): any
	local signal = {
		Connect = function()
			return { Disconnect = function() end }
		end,
	}
	local root = {
		Position = rootPosition,
		IsA = function(_, class)
			return class == "BasePart"
		end,
	}
	local character = {
		FindFirstChild = function(_, name)
			return if name == "HumanoidRootPart" then root else nil
		end,
	}
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name)
				return { Name = name, OnClientEvent = signal }
			end,
		},
		HttpService = {},
		Players = { LocalPlayer = { Character = character } },
	}
	return luau.load(fs.readFile("games/robango-island/src/client/TapRouter.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return assert(services[name], name)
				end,
			},
			Vector3 = roblox.Vector3,
		},
	})()
end
local function fakeTap(): any
	local tap: any = { handlers = {}, moves = {} }
	function tap.register(kind, fn)
		tap.handlers[kind] = fn
		return function() end
	end
	function tap.moveTo(goal, within, arrive)
		table.insert(tap.moves, { goal = goal, within = within, arrive = arrive })
	end
	return tap
end
local function nodePart(position: any, prompt: any?): any
	return {
		Parent = {},
		Position = position,
		FindFirstChild = function(_, name)
			return if name == "ForgeGather" then prompt else nil
		end,
	}
end
return {
	["a node tap opens the gather radial client-side before any server reply"] = function()
		-- p134 v36: tapping a bush or rock opened nothing. The node handler needed the ForgeGather prompt
		-- (returned false without it) and then only fired the prompt; the C2 radial was never asked.
		local Router = loadWithGame(roblox.Vector3.new(0, 0, 0))
		local opened = {}
		local accept = true
		local tap = fakeTap()
		Router.installActions(tap, {}, nil, function(part)
			table.insert(opened, part)
			return accept
		end)
		-- In reach, no prompt yet (GatheringClient adds it later; the server may be slow): opens at once.
		local near = nodePart(roblox.Vector3.new(3, 0, 4))
		assert(tap.handlers.node(near) == true, "node tap handled")
		assert(#opened == 1 and opened[1] == near and #tap.moves == 0, "radial opened without walking")
		-- Out of reach: walk up, then open on arrival.
		local far = nodePart(roblox.Vector3.new(40, 0, 0))
		assert(tap.handlers.node(far) == true and #opened == 1, "far node waits for the walk")
		assert(#tap.moves == 1 and tap.moves[1].within == Router.REACH, "walks to reach")
		tap.moves[1].arrive()
		assert(#opened == 2 and opened[2] == far, "radial opened on arrival")
		-- The picker declines (nothing offered): the node's prompt still gathers.
		accept = false
		local held = 0
		local prompt = {
			Parent = true,
			Enabled = true,
			IsA = function(_, class)
				return class == "ProximityPrompt"
			end,
			InputHoldBegin = function()
				held += 1
			end,
			InputHoldEnd = function() end,
		}
		assert(tap.handlers.node(nodePart(roblox.Vector3.new(1, 0, 0), prompt)) == true, "declined still handled")
		assert(held == 1, "prompt fallback fired")
	end,
	["a tap on scenery rock or tree gathers from a node beside it, else says where to gather"] = function()
		-- Staging v40: the boulders and trees on screen are BiomeKits scenery (ForgeKitFamily rock/tree,
		-- queryable), not gather nodes, so their taps fell through to a plain walk with no word.
		local V = roblox.Vector3
		local stone = { Position = V.new(-54, 2, 12) }
		local wood = { Position = V.new(-66, 2, 12) }
		assert(TapRouter.decorNode(V.new(-50, 0, 18), { stone, wood }, TapRouter.DECOR_RADIUS) == stone, "nearest node")
		assert(TapRouter.decorNode(V.new(-9, 0, 140), { stone, wood }, TapRouter.DECOR_RADIUS) == nil, "far scenery")
		local ranks = {}
		for index, kind in TapRouter.PRIORITY do
			ranks[kind] = index
		end
		assert(ranks.node < ranks.decor and ranks.decor < ranks.ground, "decor after node, before ground")
		local Router = loadWithGame(V.new(0, 0, 0))
		local router = Router.new()
		local said, walked = {}, 0
		router.register("ground", function()
			walked += 1
			return true
		end)
		Router.installActions(router, {}, nil, function()
			return true
		end, function(family)
			table.insert(said, family)
		end)
		assert(router.dispatch({ decor = "rock", ground = V.new(1, 0, 1) }) == "ground", "the walk still runs")
		assert(said[1] == "rock" and walked == 1, "the player is told where stone comes from")
	end,
	["node kit pieces map back to their gather node id"] = function()
		-- The visible bush or rock is the node's decorative kit (CanQuery=false), not the small tagged part.
		assert(TapRouter.kitOwner("rw.explore10.berry.kit.leaf3") == "rw.explore10.berry", "kit part")
		assert(TapRouter.kitOwner("rw.explore10.stone.kit") == "rw.explore10.stone", "kit mesh model")
		assert(TapRouter.kitOwner("rw.explore10.stone") == nil, "node part itself")
		assert(TapRouter.kitOwner("biome.12.leaf1") == nil and TapRouter.kitOwner(".kit") == nil, "plain decor")
	end,
	["tap priority is ui then creature then node then ground and handlers can pass"] = function()
		local router = TapRouter.new()
		local seen = {}
		for _, kind in { "ground", "node", "creature" } do
			router.register(kind :: any, function(target)
				table.insert(seen, kind .. ":" .. tostring(target))
				return true
			end)
		end
		local all = { creature = "rex", node = "flint", ground = "dirt" }
		assert(
			router.dispatch(probe({ overUi = true, creature = "rex", node = "flint", ground = "dirt" })) == "ui",
			"ui first"
		)
		assert(#seen == 0, "ui tap reaches no world handler")
		assert(router.dispatch(probe(all)) == "creature" and seen[1] == "creature:rex", "creature over node")
		assert(
			router.dispatch(probe({ node = "flint", ground = "dirt" })) == "node" and seen[2] == "node:flint",
			"node over ground"
		)
		assert(router.dispatch(probe({ ground = "dirt" })) == "ground" and seen[3] == "ground:dirt", "ground last")
		assert(router.dispatch(probe({})) == nil, "empty tap routes nowhere")
		-- A newer handler (C2/C3) runs first; returning false passes to older ones, then lower kinds.
		local remove = router.register("creature", function()
			table.insert(seen, "combat")
			return false
		end)
		assert(router.dispatch(probe(all)) == "creature" and seen[4] == "combat" and seen[5] == "creature:rex", "pass")
		remove()
		local unregisterNode = router.register("node", function()
			return false
		end)
		local fallthrough = TapRouter.new()
		fallthrough.register("node", function()
			return false
		end)
		fallthrough.register("ground", function()
			return true
		end)
		assert(
			fallthrough.dispatch(probe({ node = "flint", ground = "dirt" })) == "ground",
			"declined node falls to ground"
		)
		unregisterNode()
		assert(router.dispatch(probe(all)) == "creature" and seen[6] == "creature:rex", "removed handler gone")
		assert(not pcall(router.register, "wall" :: any, function() end), "unknown kind rejected")
	end,
	["tap versus drag versus pinch gesture sessions"] = function()
		local g = TapRouter.gesture()
		g.began(1, 100, 100, false)
		assert(g.moved(1, 108, 104) == nil, "inside slop is still a tap")
		assert(g.ended(1, 108, 104) == "tap", "clean tap")
		g.began(1, 100, 100, false)
		assert(g.moved(1, 140, 100) == "steer" and g.steering(), "drag steers")
		local ox, oy = g.origin()
		assert(ox == 100 and oy == 100, "drag origin")
		assert(g.ended(1, 140, 100) == "release", "drag release")
		g.began(1, 100, 100, false)
		g.began(2, 300, 300, false)
		assert(g.moved(1, 200, 100) == nil, "pinch never steers")
		assert(g.ended(2, 300, 300) == nil and g.ended(1, 100, 100) == nil, "pinch is no tap")
		g.began(1, 100, 100, true)
		assert(g.moved(1, 200, 100) == nil and g.ended(1, 100, 100) == nil, "ui touches never reach the world")
		g.began(1, 100, 100, false)
		g.cancel()
		assert(g.ended(1, 100, 100) == nil and not g.steering(), "respawn cancels")
	end,
	-- p134 v51 (SM-N981N): three 5-17 min spells where taps and swipes did nothing while the server
	-- showed a free humanoid, after chat / dev console use. One touch whose end never reached the
	-- game left the old finger counter at 1, so every later touch counted as a pinch's second finger.
	["a touch whose end never arrives does not turn every later touch into a pinch"] = function()
		local ended: { [any]: boolean } = {}
		local g = TapRouter.gesture(function(id)
			return not ended[id]
		end)
		g.began("lost", 50, 50, false) -- the console / chat took this finger's InputEnded
		ended.lost = true
		g.began("tap", 300, 300, false)
		assert(g.ended("tap", 302, 301) == "tap", "the next tap walks")
		g.began("drag", 300, 300, false)
		assert(g.moved("drag", 380, 300) == "steer" and g.ended("drag", 380, 300) == "release", "swipes steer")
		-- A real second finger still makes a pinch.
		g.began("a", 100, 100, false)
		g.began("b", 200, 200, false)
		assert(g.ended("b", 200, 200) == nil and g.ended("a", 100, 100) == nil, "pinch is no tap")
		-- Without a liveness probe, cancel() (focus lost to chat or the console) also clears it.
		local plain = TapRouter.gesture()
		plain.began("lost", 50, 50, false)
		plain.cancel()
		plain.began("tap", 300, 300, false)
		assert(plain.ended("tap", 300, 300) == "tap", "cancel forgets the stranded finger")
		-- The runtime wires the cancel to focus changes and the probe to UserInputState.
		local source = fs.readFile("games/robango-island/src/client/TapRouter.luau")
		for _, needle in
			{
				"UserInputService.WindowFocusReleased, lost",
				"UserInputService.TextBoxFocused, lost",
				"UserInputService.TextBoxFocusReleased, lost",
				"MenuOpened, lost",
				"UserInputState.Begin",
			}
		do
			assert(string.find(source, needle, 1, true), needle .. " wired")
		end
	end,
	["picking prefers the closest visible candidate inside the radius"] = function()
		local list = {
			{ target = "behind", x = 101, y = 101, visible = false },
			{ target = "far", x = 180, y = 100, visible = true },
			{ target = "near", x = 120, y = 110, visible = true },
		}
		assert(TapRouter.nearest(100, 100, list, TapRouter.PICK_RADIUS) == "near", "nearest visible")
		assert(TapRouter.nearest(500, 500, list, TapRouter.PICK_RADIUS) == nil, "none in radius")
	end,
	["path route drops the start point and falls back to a straight line"] = function()
		local a, b, goal = { x = 0 }, { x = 5 }, { x = 9 }
		local route =
			TapRouter.route("Success", { { position = a, jump = false }, { position = b, jump = true } }, goal)
		assert(#route == 1 and route[1].position == b and route[1].jump, "computed path")
		for _, status in { "NoPath", "ClosestNoPath", "Error" } do
			local line = TapRouter.route(status, {}, goal)
			assert(#line == 1 and line[1].position == goal and not line[1].jump, status .. " straight line")
		end
		local short = TapRouter.route("Success", { { position = a, jump = false } }, goal)
		assert(#short == 1 and short[1].position == goal, "single-point path walks to the goal")
	end,
	["ground taps stop at the last land point and refuse a tap straight into the sea"] = function()
		-- Land is x < 20; the sea starts at x = 20.
		local function isLand(x: number, _z: number): boolean
			return x < 20
		end
		local x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 10, Y = 0, Z = 5 }, isLand)
		assert(x == 10 and z == 5, "an all-land tap keeps its exact goal")
		x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, isLand)
		assert(x and z == 0 and x < 20 and x >= 20 - TapRouter.SHORE_STEP, "stops on the last land sample")
		x, z = TapRouter.shore({ X = 0, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, function(px)
			return px < 20 or px > 30
		end)
		assert(x and x < 20, "a far island behind open water is not reached by walking through it")
		x = TapRouter.shore({ X = 19, Y = 0, Z = 0 }, { X = 60, Y = 0, Z = 0 }, isLand)
		assert(x == nil, "standing on the shore, a sea tap is refused")
		x = TapRouter.shore({ X = 25, Y = 0, Z = 0 }, { X = 40, Y = 0, Z = 0 }, isLand)
		assert(x == nil, "a tap further out to sea is refused")
		x, z = TapRouter.shore({ X = 25, Y = 0, Z = 0 }, { X = 5, Y = 0, Z = 0 }, isLand)
		assert(x == 5 and z == 0, "a wading player can walk back ashore")
	end,
	["drag steers along the camera's flattened axes"] = function()
		-- Camera looking north (-Z): right is +X.
		local right, forward = { x = 1, z = 0 }, { x = 0, z = -1 }
		local x, z = TapRouter.steer(0, -50, right, forward)
		assert(x == 0 and z == -1, "drag up walks away from the camera")
		x, z = TapRouter.steer(50, 0, right, forward)
		assert(x == 1 and z == 0, "drag right walks screen-right")
		x, z = TapRouter.steer(5, 5, right, forward)
		assert(x == nil and z == nil, "inside slop no steer")
	end,
	-- p134 v50: tapping a fern and a palm only walked the character. Palms are BiomeKits "tree" rows
	-- (queryable scenery: a tree tap gathers from a node beside it or says where wood comes from).
	-- Ferns and bushes are scenery too ("fern"/"shrub" rows), but were CanQuery=false, so the tap ray
	-- went through them to the ground. The real gather ferns are fiber nodes (tagged, mesh queryable).
	["fern, bush, palm and rock scenery are tappable and each says where to gather"] = function()
		local Kits = require("../shared/BiomeKits")
		local strings = fs.readFile("games/robango-island/locale/strings.csv")
		local Fixture = require("../../PackText.fixture")
		local looks = { "tree", "rock", "fern", "shrub" }
		for _, family in looks do
			assert(Kits.QUERYABLE[family] and TapRouter.DECOR_FAMILIES[family], family .. " scenery is tappable")
			local key = "cli.gather.decor_" .. family
			assert(string.find(strings, "\n" .. key .. ",", 1, true), key .. " row")
			assert(Fixture.packText("ko-kr", key) and Fixture.packText("en-us", key), key .. " both locales")
		end
		assert(not Kits.QUERYABLE.grass and not Kits.QUERYABLE.clutter, "grass and litter stay out of taps")
		local palms = 0
		for _, rows in Kits.kits do
			for _, row in rows do
				if string.find(row.key, "palm", 1, true) then
					palms += 1
					assert(row.family == "tree", row.key .. " is tree scenery")
				end
			end
		end
		assert(palms >= 3, "palm rows found")
		-- BiomeKits.place (the server's real placement path) applies it to every placed part.
		local environment: any = {
			require = function(path: string): any
				return if string.find(path, "Rng", 1, true)
					then require("../../../../core/domain/random/Rng")
					else require("../shared/BiomeKitsB1b")
			end,
		}
		for key, value in roblox do
			environment[key] = value
		end
		local Placer = luau.load(fs.readFile("games/robango-island/src/shared/BiomeKits.luau"), {
			environment = environment,
		})()
		local folder = roblox.Instance.new("Folder")
		local loaded, placements = {}, {}
		for index, family in { "tree", "rock", "fern", "shrub", "grass", "clutter" } do
			local template = roblox.Instance.new("Part")
			template.Size = roblox.Vector3.new(2, 2, 2)
			loaded["k." .. family] = template
			table.insert(
				placements,
				{ key = "k." .. family, family = family, x = index, y = 0, z = 0, yaw = 0, scale = 1 }
			)
		end
		assert(Placer.place(folder, placements, loaded, nil, 0) == 6, "all placed")
		for _, part in folder:GetChildren() do
			local family = part:GetAttribute("ForgeKitFamily")
			assert(part.CanQuery == (Kits.QUERYABLE[family] == true), family .. " CanQuery")
			assert(part.CanCollide == false, family .. " never collides")
		end
		-- A fern tap with no node beside it routes to decor and says where fiber comes from.
		local V = roblox.Vector3
		local Router = loadWithGame(V.new(0, 0, 0))
		local router = Router.new()
		local said = {}
		router.register("ground", function()
			return true
		end)
		Router.installActions(router, {}, nil, function()
			return true
		end, function(family)
			table.insert(said, family)
		end)
		assert(router.dispatch({ decor = "fern", ground = V.new(1, 0, 1) }) == "ground", "the walk still runs")
		assert(said[1] == "fern", "the player is told where fiber comes from")
	end,
}
