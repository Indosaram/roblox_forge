--!strict
-- Wildlife readability: every robango species resolves an authored visual (content.yml
-- wildlifeDetails[].visual), the rig honours it within the part budget, and species of
-- different body plans differ in their side+front silhouette at gameplay distance. The
-- silhouette signature is a coarse occupancy grid normalised by the rig's largest
-- dimension, so size alone never counts as a difference.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Content = require("./src/shared/SurvivalContent")

local BUDGET = 48
local GX, GY = 16, 10
-- Minimum differing cells (of 2 * GX * GY) between species of different body plans.
local CROSS_FAMILY_MIN = 24

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

local function build(rig: any, world: any, detail: any): any
	local e = assert(detail.renderEnvelope, "render envelope: " .. detail.id)
	return rig.new(detail.id, detail.id, roblox.Vector3.zero, world, roblox.Vector3.new(e.x, e.y, e.z), detail.visual)
end

-- Side (Z by Y) and front (X by Y) occupancy of every visual part, in root space.
local function signature(model: any): string
	local root = model.PrimaryPart
	local s = root.Size
	local extent = math.max(s.X, s.Y, s.Z) * 1.3
	local cells: { [number]: boolean } = {}
	local function cell(v: number, n: number): number
		return math.clamp(math.floor((v / extent + 0.5) * n) + 1, 1, n)
	end
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p ~= root then
			local lo, hi = roblox.Vector3.one * math.huge, -roblox.Vector3.one * math.huge
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local v = root.CFrame:PointToObjectSpace(
							p.CFrame:PointToWorldSpace(p.Size / 2 * roblox.Vector3.new(sx, sy, sz))
						)
						lo, hi = lo:Min(v), hi:Max(v)
					end
				end
			end
			for view = 0, 1 do
				local a0, a1 = if view == 0 then lo.Z else lo.X, if view == 0 then hi.Z else hi.X
				for i = cell(a0, GX), cell(a1, GX) do
					for j = cell(lo.Y, GY), cell(hi.Y, GY) do
						cells[view * GX * GY + (j - 1) * GX + i] = true
					end
				end
			end
		end
	end
	local bits = table.create(2 * GX * GY, "0")
	for k in cells do
		bits[k] = "1"
	end
	return table.concat(bits)
end

local function distance(a: string, b: string): number
	local n = 0
	for i = 1, #a do
		if string.byte(a, i) ~= string.byte(b, i) then
			n += 1
		end
	end
	return n
end

local function survey(): { [string]: { family: string, signature: string, parts: number, model: any } }
	local rig = loadRig()
	local world = roblox.Instance.new("Workspace")
	local out = {}
	for _, detail in assert(Content.wildlifeDetails, "species catalog") do
		local model = build(rig, world, detail)
		local parts = 0
		for _, p in model:GetChildren() do
			if p:IsA("BasePart") then
				parts += 1
			end
		end
		out[detail.id] =
			{ family = model:GetAttribute("BodyPlan"), signature = signature(model), parts = parts, model = model }
	end
	return out
end

return {
	["every species resolves an authored visual the rig honours"] = function()
		local rig = loadRig()
		local world = roblox.Instance.new("Workspace")
		local count = 0
		for _, detail in assert(Content.wildlifeDetails, "species catalog") do
			local visual = (detail :: any).visual
			assert(type(visual) == "table", "authored visual: " .. detail.id)
			assert(
				type(visual.plan) == "string" and type(visual.feature) == "string",
				"plan and feature: " .. detail.id
			)
			local model = build(rig, world, detail)
			assert(model:GetAttribute("BodyPlan") == visual.plan, "rig body plan follows content: " .. detail.id)
			assert(model:GetAttribute("Silhouette") == visual.feature, "rig feature follows content: " .. detail.id)
			local body = visual.body
			local torso = model.Torso.Color
			assert(
				math.round(torso.R * 255) == body.r
					and math.round(torso.G * 255) == body.g
					and math.round(torso.B * 255) == body.b,
				"rig body colour follows content: " .. detail.id
			)
			for _, token in visual.parts or {} do
				local found = false
				for _, p in model:GetChildren() do
					if p:IsA("BasePart") and p:GetAttribute("VisualPart") == token then
						found = true
					end
				end
				assert(found, "authored silhouette part built: " .. detail.id .. "/" .. token)
			end
			assert(model.Torso.Material ~= roblox.Enum.Material.Fabric, "no near-black fabric skin: " .. detail.id)
			count += 1
			model:Destroy()
		end
		assert(count == 24, "all catalog species: " .. count)
	end,
	["species in different body plans differ in silhouette signature"] = function()
		local rigs = survey()
		local ids = {}
		for id in rigs do
			table.insert(ids, id)
		end
		table.sort(ids)
		local close = {}
		for i = 1, #ids do
			for j = i + 1, #ids do
				local a, b = rigs[ids[i]], rigs[ids[j]]
				assert(a.signature ~= b.signature, "identical silhouette: " .. ids[i] .. "/" .. ids[j])
				if a.family ~= b.family then
					local d = distance(a.signature, b.signature)
					if d < CROSS_FAMILY_MIN then
						table.insert(close, ids[i] .. "/" .. ids[j] .. "=" .. d)
					end
				end
			end
		end
		assert(#close == 0, "cross-family silhouettes too alike: " .. table.concat(close, ", "))
	end,
	["every species rig stays within the part budget"] = function()
		for id, rig in survey() do
			assert(rig.parts <= BUDGET, id .. " parts " .. rig.parts)
			assert(rig.parts == rig.model:GetAttribute("PartCount"), id .. " PartCount attribute")
			assert(rig.model:GetAttribute("PartBudget") == BUDGET, id .. " PartBudget attribute")
		end
	end,
}
