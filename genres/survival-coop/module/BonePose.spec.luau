--!strict
-- B2a skinned creatures: BonePose keyframes, the DinosaurRig mesh-path option and herd layout.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local BonePose = require("./BonePose")
local Herd = require("./Herd")
local Rng = require("../../../core/domain/random/Rng")

local function loadRig(): any
	return luau.load(fs.readFile("genres/survival-coop/module/DinosaurRig.luau"), {
		environment = {
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
		},
	})()
end

local PLANS: { [string]: { string } } = BonePose.BONES :: any

-- A template shaped like the FBX import: one MeshPart with the plan's Bones under it.
local function template(plan: string, height: number): any
	local mesh = roblox.Instance.new("MeshPart")
	mesh.Name = "Template"
	mesh.Size = roblox.Vector3.new(1, height, 3)
	local made: { [string]: any } = {}
	for index, name in PLANS[plan] do
		local bone = roblox.Instance.new("Bone")
		bone.Name = name
		bone.CFrame = roblox.CFrame.new(0, 0, index * 0.01)
		bone.Parent = if name == "Root" then mesh else made.Root
		made[name] = bone
	end
	return mesh
end

local STATES = { "idle", "walk", "run", "attack", "hurt", "dead", "graze" }

return {
	["every body plan carries the catalog bone count"] = function()
		assert(#BonePose.BONES.theropod == 22, "theropod 22 bones")
		assert(#BonePose.BONES.ceratopsian == 20, "ceratopsian 20 bones")
		assert(#BonePose.BONES.sauropod == 26, "sauropod 26 bones")
	end,
	["each state samples a distinct, deterministic pose on every plan bone"] = function()
		for plan, bones in PLANS do
			local seen: { [string]: string } = {}
			for _, state in STATES do
				local frame = BonePose.sample(plan, state, 0.37, 12, "bite", 8)
				local again = BonePose.sample(plan, state, 0.37, 12, "bite", 8)
				local parts = {}
				for _, name in bones do
					local entry = assert(frame[name], plan .. " " .. state .. " lacks " .. name)
					local other = again[name]
					assert(
						entry.x == other.x and entry.y == other.y and entry.z == other.z and entry.lift == other.lift,
						"deterministic sample"
					)
					for _, value in { entry.x, entry.y, entry.z, entry.lift or 0, entry.forward or 0 } do
						assert(value == value and math.abs(value) < 3.2, "bounded angle " .. plan .. " " .. state)
					end
					table.insert(
						parts,
						string.format(
							"%.4f,%.4f,%.4f,%.4f,%.4f",
							entry.x,
							entry.y,
							entry.z,
							entry.lift or 0,
							entry.forward or 0
						)
					)
				end
				local key = table.concat(parts, ";")
				for other, previous in seen do
					assert(previous ~= key, plan .. ": " .. state .. " equals " .. other)
				end
				seen[state] = key
			end
		end
	end,
	["walk swings the legs in opposition and attack, hurt and death move the body"] = function()
		for plan in PLANS do
			local walk = BonePose.sample(plan, "walk", 0.3, 8)
			assert(walk.ThighL.x * walk.ThighR.x < 0, plan .. " legs alternate")
			if plan ~= "theropod" then
				assert(walk.UpperArmL.x * walk.ThighL.x < 0, plan .. " diagonal gait")
			end
			local idle = BonePose.sample(plan, "idle", 0.25, 0)
			local attack = BonePose.sample(plan, "attack", 0.25, 0, "bite")
			assert(attack.Jaw.x > idle.Jaw.x + 0.3, plan .. " bite opens the jaw")
			assert((attack.Root.forward or 0) > 0.1, plan .. " lunge")
			assert(math.abs(BonePose.sample(plan, "hurt", 0.15, 0).Root.z) > 0.1, plan .. " flinch")
			local dead = BonePose.sample(plan, "dead", 2, 0)
			assert(math.abs(dead.Root.z - math.pi / 2) < 1e-6 and (dead.Root.lift or 0) < -0.3, plan .. " lies down")
			local graze = BonePose.sample(plan, "graze", 6, 0, nil, 10)
			assert(graze.Head.x > idle.Head.x + 0.1, plan .. " grazing lowers the head")
		end
		local stomp = BonePose.sample("sauropod", "attack", 0.25, 0, "stomp")
		assert(stomp.Root.x < -0.25 and stomp.UpperArmL.x < -0.5, "sauropod rears for its stomp")
		assert(BonePose.clip("strike") == "attack" and BonePose.clip("unknown") == "idle", "clip map")
	end,
	["without the mesh option every pack keeps the part rig"] = function()
		local rig = loadRig()
		local world = roblox.Instance.new("Workspace")
		local model = rig.new("triceratops", "t", roblox.Vector3.zero, world)
		assert(model:FindFirstChild("Torso") and not model:FindFirstChild("Body"), "part rig")
		assert(model:GetAttribute("ForgeSkinned") == nil, "not skinned")
		assert(model.ModelStreamingMode == roblox.Enum.ModelStreamingMode.Atomic, "streams atomically")
		rig.pose(model, "walk", 0.1, 12)
		assert(model.PrimaryPart.Thigh1Joint.Transform ~= roblox.CFrame.identity, "Motor6D pose unchanged")
		-- A source that declines a species keeps that species on the part rig.
		rig.configureMeshes({
			source = function()
				return nil
			end,
		})
		assert(rig.new("dodo", "d", roblox.Vector3.zero, world):FindFirstChild("Torso"), "declined species")
		world:Destroy()
	end,
	["the mesh option builds a skinned atomic rig posed on Bone.Transform"] = function()
		local rig = loadRig()
		local world = roblox.Instance.new("Workspace")
		local templates: { [string]: any } = {
			triceratops = template("ceratopsian", 4.5),
			brachiosaurus = template("sauropod", 24),
			velociraptor = template("theropod", 2),
		}
		rig.configureMeshes({
			source = function(species: string): any
				return templates[species]
			end,
			sample = BonePose.sample,
		})
		for species: string, source: any in templates do
			local model = rig.new(species, species, roblox.Vector3.new(0, 10, 0), world)
			local root: any, body: any = model.PrimaryPart, model:FindFirstChild("Body")
			assert(body and body:IsA("MeshPart") and body ~= source, species .. " cloned skinned body")
			assert(model:GetAttribute("ForgeSkinned") == true and not model:FindFirstChild("Torso"), "no part anatomy")
			assert(model.ModelStreamingMode == roblox.Enum.ModelStreamingMode.Atomic, "atomic streaming")
			assert(body.Size == source.Size, "never scaled")
			assert(not body.CanCollide and body.Massless and root.CanCollide, "root keeps collision")
			local weld = root:FindFirstChild("BodyWeld")
			assert(weld and weld.Part0 == root and weld.Part1 == body, "welded to the root")
			local bottom = body.CFrame.Position.Y - body.Size.Y / 2
			assert(math.abs(bottom - (root.CFrame.Position.Y - root.Size.Y / 2)) < 1e-4, "feet on the envelope floor")
			local plan = model:GetAttribute("BodyPlan")
			for _, state in STATES do
				rig.pose(model, state, 0.3, 10)
				local frame = BonePose.sample(plan, state, 0.3, 10, model:GetAttribute("AttackStyle"), nil)
				local thigh = body:FindFirstChild("ThighL", true)
				local e = frame.ThighL
				local want = roblox.CFrame.Angles(-e.x, e.y, e.z)
				local got = thigh.Transform
				assert(
					(got.LookVector - want.LookVector).Magnitude < 1e-4
						and (got.UpVector - want.UpVector).Magnitude < 1e-4,
					species .. " " .. state .. " bone pose"
				)
			end
			model:Destroy()
		end
		world:Destroy()
	end,
	["herds lay out 3-5 seeded members around the spawn and move with the leader"] = function()
		local seed = 20261027
		for _, count in { 3, 4, 5 } do
			local function place()
				local stream = Rng.new(seed):fork("herd"):fork("rw.test." .. count)
				return Herd.place("rw.test." .. count, { x = 10, y = 4, z = -20 }, count, 8, function()
					return stream:nextNumber()
				end)
			end
			local members, again = place(), place()
			assert(#members == count, "herd size")
			assert(members[1].id == "rw.test." .. count .. ".1", "leader first")
			assert(members[1].position.x == 10 and members[1].position.z == -20, "leader on the spawn")
			for index, member in members do
				assert(member.position.x == again[index].position.x, "seeded, repeatable")
				local d = math.sqrt((member.position.x - 10) ^ 2 + (member.position.z + 20) ^ 2)
				assert(d <= 8 + 1e-9, "inside the spawn radius")
				if index > 1 then
					assert(d >= 8 * 0.55 - 1e-9, "spread around the leader")
				end
			end
		end
		local goal = Herd.follow({ x = 0, y = 0, z = 0 }, { x = 30, y = 2, z = 5 }, { x = -3, y = 0, z = 4 })
		assert(goal.x == 27 and goal.z == 9 and goal.y == 2, "keeps its offset from the leader")
	end,
	["content herd counts are 3-5 for herd species and every other spawn stays single"] = function()
		local content: any = require("../../../games/robango-island/src/shared/SurvivalContent")
		local grazers = { protoceratops = true, triceratops = true, gallimimus = true }
		-- C1 opening beat 5: a dodo trio and a parasaurolophus herd at the onboarding ford.
		local openingHerds = { dodo = true, parasaurolophus = true }
		local herds = 0
		for _, layout in content.layouts do
			local total = 0
			for _, spawn in layout.spawns do
				total += spawn.count
				if grazers[spawn.speciesId] then
					assert(spawn.count >= 3 and spawn.count <= 5, spawn.id .. " herd of 3-5")
					herds += 1
				elseif openingHerds[spawn.speciesId] and spawn.count > 1 then
					assert(layout.id == "rw.onboarding", spawn.id .. " opening herds stay on onboarding")
					assert(spawn.count >= 3 and spawn.count <= 5, spawn.id .. " herd of 3-5")
				else
					assert(spawn.count == 1, spawn.id .. " stays single")
				end
			end
			assert(total <= 32, layout.id .. " inside the wildlife budget")
		end
		assert(herds == 16, "every B2a grazer spawn is a herd")
	end,
}
