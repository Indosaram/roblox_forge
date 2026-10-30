--!strict
-- L13 game-feel feedback: drives the shipped FeedbackFx runtime on a stub engine (pure helpers plus
-- the budget, pooling and reduced-effects rules). The live-server edges (a real gather result, a
-- real committed craft) are driven in GatherLiveWiring.spec and CraftLiveWiring.spec.
local Stub = require("./FeedbackFx.fixture")
local Audio = require("../shared/RobangoAudioCatalog")

local ITEMS = { "stone", "branch", "fiber", "cord" }
local NAMES = { stone = "Stone", branch = "Branch", fiber = "Fiber", cord = "Cord" }

local function start(overrides: any?): (any, () -> (), any)
	local stub = Stub.new()
	local o = overrides or {}
	local toasts: { string } = {}
	local toastGui = stub.instance("ScreenGui", "ForgeGatherFan")
	local options = {
		assets = { ["fx-chip"] = "rbxassetid://1", ["fx-spark"] = "rbxassetid://2", ["fx-puff"] = "rbxassetid://3" },
		audio = Audio,
		profile = function()
			return o.profile or "low"
		end,
		reduced = function()
			return o.reduced == true
		end,
		hidden = function()
			return false
		end,
		icon = function(item: string)
			return "rbxassetid://icon-" .. item
		end,
		itemName = function(item: string)
			return NAMES[item] or item
		end,
		toastFormat = "+%d %s",
		toast = function(line: string)
			table.insert(toasts, line)
		end,
		toastGui = toastGui,
		names = NAMES,
		itemIds = ITEMS,
		defaultOutput = function()
			return "stone"
		end,
		bagPoint = function()
			return { X = 40, Y = 680 }
		end,
	}
	local stop = stub.Fx.start(options)
	stub.toasts, stub.toastGui = toasts, toastGui
	return stub, stop, options
end

-- A character with a Humanoid the runtime reads (MoveDirection, FloorMaterial, state).
local function character(stub: any, floor: string, moving: boolean, swimming: boolean?): any
	local model = stub.instance("Model", "Character")
	local humanoid = stub.instance("Humanoid", "Humanoid")
	humanoid.MoveDirection = Stub.vector(if moving then 1 else 0, 0, 0)
	humanoid.FloorMaterial = { Name = floor }
	humanoid.HipHeight = 2
	function humanoid.GetState()
		return if humanoid.swimming then "Swimming" else "Running"
	end
	humanoid.swimming = swimming == true
	humanoid.Parent = model
	local root = stub.instance("Part", "HumanoidRootPart")
	root.Position, root.Size = Stub.vector(0, 3, 0), Stub.vector(2, 2, 1)
	root.Parent = model
	stub.player.Character = model
	return humanoid
end

local function total(stub: any, prefix: string): number
	local sum = 0
	for name, emitter in stub.emitters() do
		if string.sub(name, 1, #prefix) == prefix then
			sum += emitter.emitted
		end
	end
	return sum
end

return {
	["material follows the audio catalog's gather events, so chips and sound agree"] = function()
		local Fx = Stub.new().Fx
		assert(Fx.material(Audio, "branch-pile", nil) == "wood", "branch pile is wood")
		assert(Fx.material(Audio, "flint-outcrop", nil) == "stone", "flint is stone")
		assert(Fx.material(Audio, "fiber-bush", nil) == "plant", "fiber bush is plant")
		assert(Fx.material(Audio, "rw-a1-s1-material-x", "clay") == "clay", "item fallback")
		assert(Fx.material(Audio, nil, "bone") == "shell", "bone heap chips like shell")
		assert(Fx.material(Audio, "unknown", nil) == "stone", "default")
		for kind: string, event: string in Audio.gather :: any do
			local material = Fx.material(Audio, kind, nil)
			assert(event == "gather-" .. material or not Fx.MATERIALS[string.sub(event, 8)], kind)
		end
	end,
	["the token bucket caps particles per second and refills over time"] = function()
		local Fx = Stub.new().Fx
		local bucket = Fx.bucket(60)
		assert(bucket.take(40, 0) == 40, "first burst fits")
		assert(bucket.take(40, 0) == 20, "the rest of the second's budget")
		assert(bucket.take(5, 0) == 0, "empty")
		assert(bucket.take(40, 0.5) == 30, "half a second refills half")
		assert(bucket.take(500, 100) == 60, "never more than one second's worth")
		-- Phone profile: the per-second budget is below the desktop one and every burst fits in it.
		local low, high = Fx.budget("low"), Fx.budget("high")
		assert(low.rate < high.rate and low.fires < high.fires, "low is cheaper")
		assert(low.chips + low.sparks + low.puffs <= low.rate / 4, "four gathers a second fit the low budget")
		assert(Fx.budget("nope") == low, "unknown profile is low")
	end,
	["a burst storm on the phone profile never exceeds the per-second particle cap"] = function()
		local stub, stop = start()
		local humanoid = character(stub, "Sand", false)
		local model = stub.instance("Model", "Dodo")
		local root = stub.instance("Part", "Root")
		root.Position = Stub.vector(3, 1, 0)
		root.Parent = model
		model.PrimaryPart = root
		model:SetAttribute("ForgeWildlifeHealthMilli", 100000)
		local folder = stub.instance("Folder", "ForgeWildlife")
		folder.Parent = stub.workspace
		model.Parent = folder
		stub.heartbeat:Fire()
		for hp = 99000, 1000, -1000 do
			model:SetAttribute("ForgeWildlifeHealthMilli", hp)
		end
		local emitted = 0
		for _, emitter in stub.emitters() do
			emitted += emitter.emitted
		end
		assert(emitted <= stub.Fx.budget("low").rate, "storm emitted " .. emitted)
		assert(emitted > 0, "the first hits still show")
		humanoid.Parent = nil
		stop()
	end,
	["a creature health drop flashes it with a pooled highlight and sparks at its root"] = function()
		local stub, stop = start()
		character(stub, "Grass", false)
		local folder = stub.instance("Folder", "ForgeWildlife")
		folder.Parent = stub.workspace
		local models = {}
		for index = 1, 3 do
			local model = stub.instance("Model", "Boar" .. index)
			local root = stub.instance("Part", "Root")
			root.Position = Stub.vector(index * 3, 1, 0)
			root.Parent = model
			model.PrimaryPart = root
			model:SetAttribute("ForgeWildlifeHealthMilli", 50000)
			model.Parent = folder
			models[index] = model
		end
		stub.heartbeat:Fire()
		local before = total(stub, "spark")
		models[1]:SetAttribute("ForgeWildlifeHealthMilli", 42000)
		assert(total(stub, "spark") > before, "sparks at the hit")
		local flashes = {}
		for _, item in stub.created do
			if item.ClassName == "Highlight" then
				table.insert(flashes, item)
			end
		end
		assert(#flashes == 2, "two pooled flash highlights, got " .. #flashes)
		local lit = flashes[1].Enabled and flashes[1] or flashes[2]
		assert(lit.Enabled and lit.Adornee == models[1], "the hit creature flashes")
		models[2]:SetAttribute("ForgeWildlifeHealthMilli", 1000)
		models[3]:SetAttribute("ForgeWildlifeHealthMilli", 1000)
		local count = 0
		for _, item in stub.created do
			count += if item.ClassName == "Highlight" then 1 else 0
		end
		assert(count == 2, "three hits reuse the two highlights")
		stub.flushDelays()
		assert(not flashes[1].Enabled and not flashes[2].Enabled, "flashes end")
		-- A heal, or a far creature, shows nothing.
		local sparks = total(stub, "spark")
		models[1]:SetAttribute("ForgeWildlifeHealthMilli", 50000)
		assert(total(stub, "spark") == sparks, "a heal is not a hit")
		-- The windup telegraph keeps its own highlight.
		local windup = stub.instance("Highlight", "AttackWindup")
		windup.Parent = models[1]
		models[1]:SetAttribute("ForgeWildlifeHealthMilli", 40000)
		assert(not flashes[1].Enabled and not flashes[2].Enabled, "no flash over the windup telegraph")
		stop()
	end,
	["footstep dust follows the floor material and stops under reduced effects"] = function()
		local reduced = false
		local stub = Stub.new()
		-- The runtime's clock: each heartbeat below advances it explicitly.
		local now = 0
		local stop = stub.Fx.start({
			clock = function()
				return now
			end,
			assets = {},
			audio = Audio,
			profile = function()
				return "low"
			end,
			reduced = function()
				return reduced
			end,
			hidden = function()
				return false
			end,
			icon = function()
				return nil
			end,
			itemName = tostring,
			toastFormat = "+%d %s",
			toast = function() end,
			toastGui = stub.instance("ScreenGui", "Fan"),
			names = {},
			itemIds = {},
			defaultOutput = function()
				return nil
			end,
			bagPoint = function()
				return nil
			end,
		})
		local humanoid = character(stub, "Sand", true)
		local emitters = stub.emitters()
		local steps = 0
		for _ = 1, 5 do
			now += stub.Fx.STEP_SECONDS + 0.01
			stub.heartbeat:Fire()
		end
		steps = emitters["puff-sand"].emitted
		assert(steps >= 5, "five steps on sand raise dust, got " .. steps)
		humanoid.FloorMaterial = { Name = "Water" }
		now += 1
		stub.heartbeat:Fire()
		assert(emitters["puff-sand"].emitted == steps, "no dust on water")
		humanoid.FloorMaterial = { Name = "Snow" }
		now += 1
		stub.heartbeat:Fire()
		assert(emitters["puff-snow"].emitted > 0, "snow dust is the snow tone")
		-- Entering water splashes once, then swimming drips at the swim interval.
		humanoid.swimming = true
		now += 1
		stub.heartbeat:Fire()
		local splash = emitters.drop.emitted
		assert(splash >= stub.Fx.budget("low").splash, "the entry splash, got " .. splash)
		now += 0.05
		stub.heartbeat:Fire()
		assert(emitters.drop.emitted == splash, "no second splash while still in the water")
		now += stub.Fx.SWIM_SECONDS
		stub.heartbeat:Fire()
		assert(emitters.drop.emitted > splash, "drops while swimming")
		humanoid.swimming = false
		reduced = true
		humanoid.FloorMaterial = { Name = "Sand" }
		local quiet = emitters["puff-sand"].emitted
		for _ = 1, 3 do
			now += 1
			stub.heartbeat:Fire()
		end
		assert(emitters["puff-sand"].emitted == quiet, "reduced effects: no dust")
		stop()
	end,
	["camp fires get smoke and embers on at most the profile's fire cap, rate-capped"] = function()
		local stub, stop = start()
		character(stub, "Grass", false)
		local stations = {}
		for index = 1, 5 do
			local part = stub.instance("Part", "Campfire" .. index)
			part.Position, part.Size = Stub.vector(index * 10, 0, 0), Stub.vector(3, 1, 3)
			part:SetAttribute("ForgeStationKind", if index == 5 then "workbench" else "campfire")
			part.Parent = stub.workspace
			table.insert(stations, part)
		end
		stub.tagged.ForgeSurvivalStation = stations
		stub.heartbeat:Fire()
		local smokes, embers = 0, 0
		for _, item in stub.created do
			if item.ClassName == "ParticleEmitter" and item.Name == "CampSmoke" and item.Enabled then
				smokes += 1
				assert(item.Rate <= stub.Fx.FIRE_SMOKE_RATE, "smoke rate capped")
			elseif item.ClassName == "ParticleEmitter" and item.Name == "CampEmbers" and item.Enabled then
				embers += 1
				assert(item.Rate <= stub.Fx.FIRE_EMBER_RATE, "ember rate capped")
			end
		end
		local cap = stub.Fx.budget("low").fires
		assert(smokes == cap and embers == cap, "low profile lights " .. smokes .. " of 4 fires")
		-- The nearest fires win.
		local fire1 = stub.workspace:FindFirstChild("ForgeFeedbackFx"):FindFirstChild("FireHost1")
		assert(fire1.CFrame.X == 10, "nearest fire first")
		stop()
		assert(stub.workspace:FindFirstChild("ForgeFeedbackFx") == nil, "destroy removes the fx folder")
	end,
	["reduced effects turns the camp fires off; gather and level feedback stay"] = function()
		local stub, stop = start({ reduced = true })
		character(stub, "Grass", false)
		local part = stub.instance("Part", "Campfire")
		part.Position, part.Size = Stub.vector(5, 0, 0), Stub.vector(3, 1, 3)
		part:SetAttribute("ForgeStationKind", "campfire")
		part.Parent = stub.workspace
		stub.tagged.ForgeSurvivalStation = { part }
		stub.heartbeat:Fire()
		for _, item in stub.created do
			assert(not (item.ClassName == "ParticleEmitter" and item.Enabled and item.Rate > 0), item.Name .. " on")
		end
		stub.state.OnClientEvent:Fire({
			snapshots = { ["survival-coop"] = { progression = { level = 1, mastery = {} } } },
		})
		stub.state.OnClientEvent:Fire({
			snapshots = { ["survival-coop"] = { progression = { level = 2, mastery = {} } } },
		})
		assert(stub.emitters().gold.emitted > 0, "the level-up burst still shows")
		stop()
	end,
	["leveled and crafted read authoritative snapshot edges only"] = function()
		local Fx = Stub.new().Fx
		local a = { progression = { level = 3, mastery = { gathering = { level = 2 } } } }
		assert(not Fx.leveled(nil, a), "first snapshot is a baseline")
		assert(not Fx.leveled(a, a), "no change")
		assert(Fx.leveled(a, { progression = { level = 4, mastery = a.progression.mastery } }), "character level")
		assert(Fx.leveled(a, { progression = { level = 3, mastery = { gathering = { level = 3 } } } }), "mastery")
		local function ws(state: string?): any
			return {
				workshop = {
					actorId = "7",
					entries = if state
						then {
							j = { job = { state = state, outputs = { { catalogId = "cord", quantity = 2 } } } },
						}
						else {},
				},
			}
		end
		assert(#Fx.crafted(nil, ws("Committed"), "7") == 0, "baseline")
		assert(#Fx.crafted(ws(nil), ws("Committed"), "7") == 0, "a job first seen committed (rejoin) is old")
		local made = Fx.crafted(ws("Ready"), ws("Committed"), "7")
		assert(#made == 1 and made[1].item == "cord" and made[1].quantity == 2, "ready -> committed")
		assert(#Fx.crafted(ws("Committed"), ws("Committed"), "7") == 0, "once")
		assert(#Fx.crafted(ws("Ready"), ws("Committed"), "8") == 0, "another actor's workshop")
		assert(#Fx.crafted(ws("Running"), ws("Cancelled"), "7") == 0, "cancel is not a craft")
	end,
	["picker toasts carry the item icon; other toasts do not"] = function()
		local stub, stop = start()
		local pattern = stub.Fx.toastPattern("+%d %s")
		assert(stub.Fx.toastItem("+3 Stone", pattern, { Stone = "stone" }) == "stone", "parsed")
		assert(stub.Fx.toastItem("Gather here", pattern, { Stone = "stone" }) == nil, "not an item line")
		local ko = stub.Fx.toastPattern("%s +%d")
		assert(stub.Fx.toastItem("돌 +2", ko, { ["돌"] = "stone" }) == "stone", "either order")
		local labels = {}
		for index = 1, 3 do
			local label = stub.instance("TextLabel", "Toast" .. index)
			label.Visible, label.Text = true, "Find stones by the shore"
			label.Parent = stub.toastGui
			labels[index] = label
		end
		labels[1].Text = "+2 Fiber"
		stub.heartbeat:Fire()
		local badge = labels[1]:FindFirstChild("ForgeToastIcon")
		assert(badge and badge.Visible and badge.Image == "rbxassetid://icon-fiber", "item toast gets its icon")
		assert(labels[2]:FindFirstChild("ForgeToastIcon") == nil, "a hint toast gets none")
		labels[1].Text = "Too far"
		stub.heartbeat:Fire()
		assert(not badge.Visible, "the badge hides when the slot shows another line")
		stop()
	end,
	["destroy disconnects every runtime connection"] = function()
		local stub, stop = start()
		character(stub, "Grass", false)
		local folder = stub.instance("Folder", "ForgeWildlife")
		folder.Parent = stub.workspace
		local model = stub.instance("Model", "Dodo")
		model:SetAttribute("ForgeWildlifeHealthMilli", 1000)
		model.Parent = folder
		stub.heartbeat:Fire()
		local health = model:GetAttributeChangedSignal("ForgeWildlifeHealthMilli")
		assert(health.live == 1 and stub.heartbeat.live == 1, "watching")
		stop()
		assert(health.live == 0, "creature watch dropped")
		assert(stub.heartbeat.live == 0 and stub.state.OnClientEvent.live == 0, "heartbeat and state dropped")
		assert(folder.ChildAdded.live == 0, "folder watch dropped")
	end,
}
