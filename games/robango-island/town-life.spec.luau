--!strict
-- Saltmeadow town life (R12/R13 lived-in town): the TownLife plan places only uploaded rows, keeps
-- every prop clear of the roads, plots, houses and set pieces, puts folk on open ground with a known
-- pose and label, lights the town at dusk, and RoleWorld wires it. Survivor poses bend real joints.
local Content = require("./src/shared/SurvivalContent")
local Life = require("./src/server/TownLife")
local Dressing = require("./src/server/WorldDressing")
local Meshes = require("./src/server/StructureMeshes")
local Plots = require("./src/shared/TownPlots")
local WorldText = require("./src/shared/WorldText")
local Survivor = require("./src/shared/SurvivorAvatar")
local fs = require("@lune/fs")
local roblox: any = require("@lune/roblox")
-- SurvivorAvatar's pose maths runs on the engine CFrame/Vector3 globals; Lune's roblox library
-- provides the same types.
local Vector3: any = roblox.Vector3
local engine: any = getfenv(Survivor.poseFrames)
engine.CFrame, engine.Vector3 = roblox.CFrame, roblox.Vector3

local function town(): any
	for _, layout in Content.layouts do
		if layout.id == "rw.town" then
			return layout
		end
	end
	error("rw.town missing")
end

-- Distance from (x, z) to the segment a-b.
local function segment(x: number, z: number, a: any, b: any): number
	local dx, dz = b.x - a.x, b.z - a.z
	local t = math.clamp(((x - a.x) * dx + (z - a.z) * dz) / math.max(dx * dx + dz * dz, 1e-9), 0, 1)
	return math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2)
end

-- Footprint radius of the fixed town pieces (L5 ROWS bounds, studs).
local FIXED = {
	house = 10,
	market = 4,
	workshop = 9,
	["quest-board"] = 3,
	dock = 6,
	["town.trading-post"] = 12,
	["bld.clan-hall"] = 22,
	["bld.well"] = 4,
	["town.rift-ring"] = 11,
	["town.npc-booth"] = 4,
	["town.chart-table"] = 4,
	["town.market-stall"] = 4,
	["town.notice-board"] = 3,
	["town.shipwright-yard"] = 15,
	["town.banner-pole"] = 1.5,
	["town.lamp-post"] = 1,
	["town.road-sign"] = 3,
	["town.flower-bed"] = 3.5,
	["town.barrel"] = 1.2,
	["town.crate-stack"] = 2.2,
	["town.post-box"] = 1,
	["town.dock"] = 6,
	["town.boat"] = 5,
}

local function fixedPieces(layout: any): { { x: number, z: number, r: number, id: string } }
	local out = {}
	for _, building in Dressing.town(layout) do
		local r = if building.lot == "large" then 16 else FIXED[building.kind]
		table.insert(out, { x = building.x, z = building.z, r = assert(r, building.kind), id = building.id })
	end
	for _, piece in Meshes.SET_PIECES do
		if piece.layout == "rw.town" and piece.row ~= "town.dock" and piece.row ~= "town.boat" then
			table.insert(out, { x = piece.x, z = piece.z, r = assert(FIXED[piece.row], piece.row), id = piece.row })
		end
	end
	return out
end

return {
	["town life: only uploaded rows, clear of roads, plots, buildings and each other"] = function()
		local layout = town()
		local plan = Life.plan(layout)
		assert(#Life.plan({ id = "rw.harbor" }).props == 0, "only Saltmeadow has a plan")
		-- Every row the plan places is exported by gen_buildings.py (uploaded packages).
		local rows = fs.readFile("games/robango-island/assets/blender/gen_buildings.py")
		local items: { any } = table.clone(plan.props)
		for _, fire in plan.fires do
			table.insert(items, fire)
		end
		for _, item in items do
			assert(string.find(rows, '("' .. item.row .. '",', 1, true), item.id .. " row is not exported")
		end
		assert(#plan.props >= 50, "a dense town: " .. #plan.props .. " props")
		assert(#plan.fires >= 4 and #plan.lamps >= 20, "fires and lamps")
		local fixed = fixedPieces(layout)
		local placed: { any } = {}
		local plots = Plots.layout(1)
		local problems: { string } = {}
		local check = assert
		local function assert(ok: any, message: string)
			if not ok then
				table.insert(problems, message)
			end
		end
		for _, item in items do
			for _, path in layout.paths do
				for index = 2, #path.points do
					local d = segment(item.x, item.z, path.points[index - 1], path.points[index])
					assert(d >= path.width / 2 + item.r - 0.5, item.id .. " stands on road " .. path.id)
				end
			end
			for _, plot in plots.plots do
				local inside = item.x > plot.min.x - item.r
					and item.x < plot.max.x + item.r
					and item.z > plot.min.z - item.r
					and item.z < plot.max.z + item.r
				assert(not inside, item.id .. " inside plot " .. plot.id)
			end
			for _, other in fixed do
				local d = math.sqrt((item.x - other.x) ^ 2 + (item.z - other.z) ^ 2)
				assert(d >= item.r + other.r, item.id .. " overlaps " .. other.id)
			end
			for _, other in placed do
				local d = math.sqrt((item.x - other.x) ^ 2 + (item.z - other.z) ^ 2)
				assert(d >= item.r + other.r - 0.5, item.id .. " overlaps " .. other.id)
			end
			table.insert(placed, item)
			-- Land props stay on the town island; rowboats lie on the bay beach above the waterline.
			if item.row == "town.rowboat" then
				assert(math.abs(item.x) > Life.LANDING, item.id .. " on the landing")
				assert(item.z < Life.shore(item.x) and item.z > Life.shore(item.x) - 24, item.id .. " on the beach")
			else
				assert(
					item.z < Life.shore(item.x) - 24 - item.r or math.abs(item.x) <= Life.LANDING,
					item.id .. " in the bay"
				)
			end
		end
		-- The town's own houses stay off the roads, plots and each other.
		local houses: { any } = {}
		for _, item in fixed do
			if string.sub(item.id, 1, 11) == "town.house." then
				for _, path in layout.paths do
					for index = 2, #path.points do
						local d = segment(item.x, item.z, path.points[index - 1], path.points[index])
						assert(d >= path.width / 2 + item.r - 2, item.id .. " stands on road " .. path.id)
					end
				end
				for _, other in fixed do
					if
						other ~= item and string.sub(other.id, 1, 11) ~= "town.house."
						or (houses[other] and other ~= item)
					then
						local d = math.sqrt((item.x - other.x) ^ 2 + (item.z - other.z) ^ 2)
						assert(d >= item.r + other.r - 2, item.id .. " overlaps " .. other.id)
					end
				end
				houses[item] = true
				assert(item.z < Life.shore(item.x) - 24 - item.r, item.id .. " in the bay")
			end
		end
		for _, lamp in plan.lamps do
			for _, other in placed do
				assert((lamp.x - other.x) ^ 2 + (lamp.z - other.z) ^ 2 >= (other.r + 1) ^ 2, "lamp on " .. other.id)
			end
		end
		check(#problems == 0, table.concat(problems, "; "))
	end,
	["dense core: narrow ragged foot paths, fenced yards holding the props, cover off roads and yards"] = function()
		local layout = town()
		-- R12 foot paths, not the old 10-46 stud bands that rendered as dark rectangles.
		for _, lane in Life.GROUND.lanes do
			assert(lane.width <= 4 and #lane.points >= 2, "lane width " .. lane.width)
		end
		for _, disc in Life.GROUND.discs do
			assert(disc.r <= 12, "worn patch radius " .. disc.r)
		end
		-- Props cluster: most land props stand inside a yard, the square or the harbor front.
		local plan = Life.plan(layout)
		local inside, land = 0, 0
		for _, prop in plan.props do
			if prop.row == "town.rowboat" or string.sub(prop.id, 1, 5) == "fire." then
				continue
			end
			land += 1
			local clustered = math.abs(prop.x) <= 40 and prop.z >= 330 and prop.z <= 395 or prop.z >= 530
			for _, yard in Life.YARDS do
				clustered = clustered or prop.x > yard.x0 and prop.x < yard.x1 and prop.z > yard.z0 and prop.z < yard.z1
			end
			inside += if clustered then 1 else 0
		end
		assert(inside >= land * 0.75, inside .. " of " .. land .. " props in yards, square or harbor")
		for _, yard in Life.YARDS do
			assert(yard.gate > yard.z0 + Life.GATE and yard.gate < yard.z1 - Life.GATE, "gate inside the side")
			assert((yard.x1 - yard.x0) % Life.FENCE == 0, "fence tiles the yard width")
		end
		-- Cover never lands on a road, lane or yard, and covers the core densely.
		local cover = Life.cover(layout, Life.blockers(layout, Dressing.town(layout), Meshes.SET_PIECES))
		assert(#cover >= 200 and #cover <= 600, "cover cards " .. #cover)
		for _, card in cover do
			for _, path in layout.paths do
				for index = 2, #path.points do
					assert(
						segment(card.x, card.z, path.points[index - 1], path.points[index]) > path.width / 2,
						"cover on road"
					)
				end
			end
			for _, yard in Life.YARDS do
				assert(
					not (card.x > yard.x0 and card.x < yard.x1 and card.z > yard.z0 and card.z < yard.z1),
					"cover in yard"
				)
			end
		end
		local again = Life.cover(layout, Life.blockers(layout, Dressing.town(layout), Meshes.SET_PIECES))
		assert(#again == #cover and again[1].x == cover[1].x, "deterministic cover")
	end,
	["town folk: posed survivors on open ground with a localized label, readable at the play camera"] = function()
		local layout = town()
		local plan = Life.plan(layout)
		assert(#plan.folk >= 30, "a busy town: " .. #plan.folk .. " folk")
		local poses: { [string]: number } = {}
		local fixed = fixedPieces(layout)
		for _, folk in plan.folk do
			assert(Survivor.POSES[folk.pose], folk.id .. " pose " .. folk.pose)
			poses[folk.pose] = (poses[folk.pose] or 0) + 1
			local en, ko = WorldText.text("en-us", folk.label), WorldText.text("ko-kr", folk.label)
			assert(en ~= folk.label and ko ~= en, folk.id .. " label " .. folk.label)
			assert((folk.face.x - folk.x) ^ 2 + (folk.face.z - folk.z) ^ 2 > 1, folk.id .. " faces somewhere")
			for _, other in fixed do
				local d = math.sqrt((folk.x - other.x) ^ 2 + (folk.z - other.z) ^ 2)
				assert(d >= other.r * 0.8, folk.id .. " inside " .. other.id)
			end
			if folk.pose == "sit" then
				assert(folk.seat == Life.SEAT, folk.id .. " sits on a bench seat")
			end
		end
		for _, pose in { "sit", "carry", "work", "vend", "stand" } do
			assert((poses[pose] or 0) >= 3, "at least 3 folk " .. pose)
		end
		-- Scale: a 1.35x figure is ~7.4 studs, so at the play camera share (0.06 for 5.5 studs) it
		-- fills ~8% of the screen height, ~29 px on a 360 px phone view (1x was the ~20 px speck).
		assert(Life.FOLK_SCALE >= 1.3, "folk read at the play camera")
	end,
	["survivor poses bend the limbs about their joints and seat the hips on the bench"] = function()
		local layout = Survivor.layout("A")
		local frames = Survivor.poseFrames("A", "sit")
		local knee = layout.joints.LeftKnee.at
		local hip = layout.joints.LeftHip.at
		-- The thigh swings forward (-Z) to horizontal; the knee joint ends level with the hip, in front.
		local kneeAt = frames.LeftUpperLeg * Vector3.new(knee.x, knee.y, knee.z)
		assert(math.abs(kneeAt.Y - hip.y) < 0.05 and kneeAt.Z < -0.6, "thigh horizontal, knee forward")
		-- The shin hangs back down from the knee.
		local ankle = layout.joints.LeftAnkle.at
		local ankleAt = frames.LeftLowerLeg * Vector3.new(ankle.x, ankle.y, ankle.z)
		assert(math.abs(ankleAt.Z - kneeAt.Z) < 0.05 and ankleAt.Y < kneeAt.Y - 0.8, "shin hangs down")
		assert(frames.LeftFoot and frames.LeftFoot == frames.LeftLowerLeg, "the foot follows the shin")
		assert(frames.Head == nil and frames.UpperTorso == nil, "the trunk stays upright")
		-- Seated: the hip joint sits seat + clearance above the floor.
		local lift = Survivor.rootLift("sit", 1, Life.SEAT)
		assert(math.abs(lift + hip.y - (Life.SEAT + Survivor.SEAT_CLEARANCE)) < 1e-6, "hips on the seat")
		assert(Survivor.rootLift("stand", 1.35) == Survivor.ROOT_HEIGHT * 1.35, "standing scales the root")
		local carry = Survivor.poseFrames("B", "carry")
		local wrist = Survivor.layout("B").joints.RightWrist.at
		local hand = carry.RightLowerArm * Vector3.new(wrist.x, wrist.y, wrist.z)
		assert(hand.Z < -0.5 and hand.Y > wrist.y + 0.4, "carry: hands forward and up")
	end,
	["RoleWorld wires town life: props, fires, lamps, folk figures and labels; the package loads"] = function()
		local role = fs.readFile("games/robango-island/src/server/RoleWorld.luau")
		for _, needle in
			{
				"if layoutId == TownLife.LAYOUT then",
				"Meshes.place(prop.row, at, life, prop.id)",
				"torch(Vector3.new(lamp.x, y, lamp.z)",
				"{ pose = folk.pose, scale = TownLife.FOLK_SCALE, seat = folk.seat }",
				'text:SetAttribute("ForgeTextKey", folk.label)',
			}
		do
			assert(string.find(role, needle, 1, true), "RoleWorld: " .. needle)
		end
		assert(table.find(Meshes.PACKAGES, "mesh-town-life"), "StructureMeshes loads the town-life package")
		local Assets = require("./src/shared/Assets")
		assert(string.match(Assets["mesh-town-life"], "^rbxassetid://%d+$"), "mesh-town-life has an asset id")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, 'object:GetAttribute("ForgeTextKey")', 1, true), "client localizes folk labels")
	end,
}
