--!strict
-- Uploaded FBX packages carry SurfaceAppearances with no TexturePack (the Open Cloud importer
-- never bakes one), so clients cannot render them and log "Failed to load ...SurfaceAppearance"
-- (staging v47). Every package the pack loads at runtime must pass through MeshTexture.bake,
-- which moves the colour map onto MeshPart.TextureContent and drops the SurfaceAppearance.
local fs = require("@lune/fs")
local roblox: any = require("@lune/roblox")
local MeshTexture = require("./src/shared/MeshTexture")

-- The shape the importer produces: a Model with MeshParts, each holding a SurfaceAppearance
-- with colour/normal maps and an empty TexturePack.
local function imported(): any
	local model = roblox.Instance.new("Model")
	model.Name = "kit-jungle"
	local maps = {
		{ "veg.jungle.jungle-tall", "rbxassetid://97032835673268", roblox.Enum.AlphaMode.Transparency },
		{ "rock.jungle.red-bank", "rbxassetid://95388020143637", roblox.Enum.AlphaMode.Overlay },
	}
	for _, row in maps do
		local part = roblox.Instance.new("MeshPart")
		part.Name = row[1]
		local surface = roblox.Instance.new("SurfaceAppearance")
		surface.ColorMapContent = roblox.Content.fromUri(row[2])
		surface.NormalMapContent = roblox.Content.fromUri("rbxassetid://88104531490558")
		surface.AlphaMode = row[3]
		surface.Parent = part
		part.Parent = model
	end
	local plain = roblox.Instance.new("MeshPart")
	plain.Name = "untextured"
	plain.Parent = model
	return model
end

local cases = {}

cases["bake moves each colour map onto the MeshPart and drops every SurfaceAppearance"] = function()
	local model = imported()
	assert(MeshTexture.bake(model) == 2, "two textured parts baked")
	for _, d in model:GetDescendants() do
		assert(d.ClassName ~= "SurfaceAppearance", "SurfaceAppearance left on " .. d:GetFullName())
	end
	assert(
		model:FindFirstChild("veg.jungle.jungle-tall").TextureContent.Uri == "rbxassetid://97032835673268",
		"card keeps its colour map (alpha cutout comes from the texture alpha)"
	)
	assert(
		model:FindFirstChild("rock.jungle.red-bank").TextureContent.Uri == "rbxassetid://95388020143637",
		"opaque row keeps its colour map"
	)
	assert(model:FindFirstChild("untextured").TextureContent.Uri == nil, "untextured part stays untextured")
end

cases["bake accepts a single MeshPart (creature templates) and is idempotent"] = function()
	local part = imported():FindFirstChild("rock.jungle.red-bank")
	assert(MeshTexture.bake(part) == 1, "the root MeshPart itself is baked")
	assert(part:FindFirstChildOfClass("SurfaceAppearance") == nil, "root SurfaceAppearance dropped")
	assert(MeshTexture.bake(part) == 0, "a second bake changes nothing")
	assert(part.TextureContent.Uri == "rbxassetid://95388020143637", "texture survives a second bake")
end

-- L10: at Transparency 0 a baked MeshPart texture draws opaque, so alpha cutout cards (the
-- SurfaceAppearance's AlphaMode Transparency rows) take the cutout transparency and record it as
-- the base a show/hide toggle restores; Overlay rows (rocks, creatures, buildings) stay opaque.
cases["bake keeps cutout cards in the transparent pass and opaque rows at 0"] = function()
	local model = imported()
	MeshTexture.bake(model)
	local card = model:FindFirstChild("veg.jungle.jungle-tall")
	local rock = model:FindFirstChild("rock.jungle.red-bank")
	assert(card.Transparency > 0 and card.Transparency < 0.05, "cutout card is in the transparent pass")
	-- Transparency is stored as float32, the attribute as a double.
	assert(card:GetAttribute(MeshTexture.BASE_ATTRIBUTE) == MeshTexture.CUTOUT_TRANSPARENCY, "card records its base")
	assert(math.abs(MeshTexture.shown(card) - card.Transparency) < 1e-6, "a card is shown at its base")
	assert(rock.Transparency == 0 and rock:GetAttribute(MeshTexture.BASE_ATTRIBUTE) == nil, "opaque row")
	assert(MeshTexture.shown(rock) == 0, "an opaque row is shown at 0")
end

-- Static guard: every runtime InsertService:LoadAsset in the pack's server/shared code sits in a
-- file that bakes the loaded result. A new loader without MeshTexture.bake would ship untextured
-- meshes on device again.
cases["every package loader in the pack bakes its loaded templates"] = function()
	local loaders = 0
	local function scan(dir: string)
		for _, name in fs.readDir(dir) do
			local path = dir .. "/" .. name
			if fs.isDir(path) then
				scan(path)
			elseif string.match(name, "%.luau$") and not string.match(name, "%.spec%.luau$") then
				local source = fs.readFile(path)
				do
					local calls = 0
					for _ in string.gmatch(source, "[%.:]LoadAsset[%(,]") do
						calls += 1
					end
					if calls > 0 then
						loaders += 1
						assert(
							string.find(source, "MeshTexture.bake(", 1, true),
							path .. " loads packages through InsertService without MeshTexture.bake"
						)
					end
				end
			end
		end
	end
	scan("games/robango-island/src")
	assert(loaders >= 3, "expected the creature, biome-kit and structure loaders, found " .. loaders)
end

return cases
