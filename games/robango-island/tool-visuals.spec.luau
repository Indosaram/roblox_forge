--!strict
-- L7 tool meshes: every tool, weapon and worn bag in the content maps to a row that gen_tools.py
-- exports into the uploaded mesh-tools package; the genre hooks dress a Tool and a worn bag from
-- injected row templates (no SurfaceAppearance: plain Color + Material), and without templates
-- they return false/nil so the genre's primitive default stays.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local Content: any = require("./src/shared/SurvivalContent")
local Assets: any = require("./src/shared/Assets")
local Rules = require("../../genres/survival-coop/module/CharacterRules")

local function load(): any
	return luau.load(fs.readFile("games/robango-island/src/shared/ToolVisuals.luau"), {
		environment = {
			Instance = roblox.Instance,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
		},
	})()
end

-- Row keys the generator exports (gen_tools.py rows_for).
local function exported(): { [string]: boolean }
	local source = fs.readFile("games/robango-island/assets/blender/gen_tools.py")
	local rows = {}
	local work = assert(string.match(source, "WORK = (%b[])"))
	local hunt = assert(string.match(source, "HUNT = (%b[])"))
	for _, block in { work, hunt } do
		for family in string.gmatch(block, '%("(%a+)",') do
			for tier = 1, 3 do
				rows["tool." .. family .. ".t" .. tier] = true
			end
		end
	end
	for key in string.gmatch(source, '"(tool%.%a+)", None') do
		rows[key] = true
	end
	return rows
end

local function template(key: string, roles: { string }): any
	local model = roblox.Instance.new("Model")
	model.Name = key
	for i, role in roles do
		local part = roblox.Instance.new("MeshPart")
		part.Name = key .. role
		part.Size = roblox.Vector3.new(0.2, 2, 0.2)
		part.CFrame = roblox.CFrame.new(0, i * 0.5, 0)
		part.Parent = model
	end
	return model
end

local function character(): any
	local model = roblox.Instance.new("Model")
	local torso = roblox.Instance.new("Part")
	torso.Name, torso.Size, torso.CFrame = "UpperTorso", roblox.Vector3.new(2, 1.6, 1), roblox.CFrame.new(0, 4, 0)
	torso.Parent = model
	return model
end

return {
	["every tool, weapon and worn bag maps to an exported row in the uploaded package"] = function()
		local ToolVisuals = load()
		local rows = exported()
		assert(rows["tool.axe.t1"] and rows["tool.bow.t3"] and rows["tool.basket"] and rows["tool.bola"], "parsed rows")
		local count = 0
		for _, item in Content.items do
			local slot = Rules.slotOf(item.id)
			if slot == "weapon" or slot == "bag" or item.id == "capture-bola" then
				local key = ToolVisuals.row(item.id)
				assert(key, item.id .. " has no tool row")
				assert(rows[key], item.id .. " -> " .. key .. " is not exported by gen_tools.py")
				count += 1
			end
		end
		assert(count >= 40, "mapped " .. count)
		assert(type(Assets[ToolVisuals.PACKAGE]) == "string", "mesh-tools is in Assets.luau")
		assert(string.match(Assets[ToolVisuals.PACKAGE], "^rbxassetid://%d+$"), "mesh-tools is uploaded")
	end,
	["tier heads read stone, bone and copper; wood, lashing and ember keep their roles"] = function()
		local ToolVisuals = load()
		assert(ToolVisuals.look("tool.axe.t1", "tool.axe.t1__head").material == "Slate", "t1 stone")
		assert(ToolVisuals.look("tool.axe.t2", "tool.axe.t2__head").material == "SmoothPlastic", "t2 bone")
		assert(ToolVisuals.look("tool.axe.t3", "tool.axe.t3__head").material == "Metal", "t3 copper")
		assert(ToolVisuals.look("tool.axe.t3", "tool.axe.t3").material == "Wood", "haft wood")
		assert(ToolVisuals.look("tool.torch", "tool.torch__ember").material == "Neon", "ember")
		assert(ToolVisuals.look("tool.spear.t1", "tool.spear.t1__bind").material == "Fabric", "lashing")
	end,
	["without templates the hooks keep the genre default"] = function()
		local ToolVisuals = load()
		ToolVisuals.setTemplates({})
		local tool = roblox.Instance.new("Tool")
		assert(ToolVisuals.dressTool(tool, "stone-axe") == false and #tool:GetChildren() == 0, "tool default")
		local entry = { slot = "bag", catalogId = "cold-bag" }
		assert(ToolVisuals.dressGear(entry, character()) == nil, "gear default")
		assert(ToolVisuals.dressTool(roblox.Instance.new("Tool"), "fiber") == false, "unmapped item")
		ToolVisuals.setTemplates(nil)
	end,
	["dressTool builds a welded mesh Handle without SurfaceAppearance"] = function()
		local ToolVisuals = load()
		ToolVisuals.setTemplates({
			["tool.axe.t2"] = template("tool.axe.t2", { "", "__head", "__bind" }),
			["tool.basket"] = template("tool.basket", { "", "__bind" }),
		})
		local tool = roblox.Instance.new("Tool")
		assert(ToolVisuals.dressTool(tool, "axe-t1") == false, "axe-t1 maps to t1, not injected")
		assert(ToolVisuals.dressTool(tool, "axe-t2"), "axe-t2 dressed")
		local handle = assert(tool:FindFirstChild("Handle"), "Handle")
		assert(handle:IsA("MeshPart") and handle.Material == roblox.Enum.Material.Wood, "wood handle")
		local head = assert(tool:FindFirstChild("tool.axe.t2__head"), "head")
		assert(
			head.Material == roblox.Enum.Material.SmoothPlastic and not head.CanCollide and head.Massless,
			"bone head"
		)
		assert(head:FindFirstChildOfClass("WeldConstraint").Part0 == handle, "head welded to handle")
		assert(tool:GetAttribute("ForgeToolRow") == "tool.axe.t2", "row attribute")
		for _, part in tool:GetDescendants() do
			assert(not part:IsA("SurfaceAppearance"), "no SurfaceAppearance")
		end
		assert(ToolVisuals.dressTool(roblox.Instance.new("Tool"), "cold-bag") == false, "a bag is not a hand tool")
		local body = character()
		local worn = assert(ToolVisuals.dressGear({ slot = "bag", catalogId = "cold-bag" }, body), "basket worn")
		local main = assert(worn:FindFirstChild("tool.basket"), "basket main")
		assert(main:FindFirstChildOfClass("WeldConstraint").Part0 == body.UpperTorso, "welded to the torso")
		assert(main.CFrame.Position.Z > body.UpperTorso.CFrame.Position.Z, "on the back")
		assert(ToolVisuals.dressGear({ slot = "head", catalogId = "cold-head" }, body) == nil, "clothing stays default")
		ToolVisuals.setTemplates(nil)
	end,
}
