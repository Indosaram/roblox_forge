--!strict
-- Runtime texture path for the uploaded mesh packages (creatures, biome kits, node meshes,
-- building rows). The Open Cloud FBX importer (assets/blender/upload.mjs) gives every textured
-- MeshPart a SurfaceAppearance whose engine-managed TexturePack is empty: only a Studio publish
-- bakes that pack, and these models never pass through one (they arrive via
-- InsertService:LoadAsset). Clients render a SurfaceAppearance from its TexturePack, so on device
-- each one logs "Failed to load ...SurfaceAppearance. PBR textures may not be visible in game."
-- and draws untextured (staging v47, .omo/evidence/robango-durango-gap/tex/REPORT.md).
-- bake() moves the colour map onto MeshPart.TextureContent, which clients fetch as a plain Image
-- asset, and drops the SurfaceAppearance. Normal and roughness maps are lost; they never reached
-- the client anyway.
-- Alpha-cutout cards (SurfaceAppearance AlphaMode Transparency: grass, fern, shrub, leaf-litter
-- and every node row) keep their cutout only if the MeshPart itself is in the transparent pass:
-- at Transparency 0 the engine draws a MeshPart texture opaque, so every card read as a solid dark
-- slat (L10 Studio capture `closeup_grass.png`). bake() gives those parts CUTOUT_TRANSPARENCY
-- and records it as ForgeBaseTransparency, the value a show/hide toggle restores instead of 0.
local M = {}

M.CUTOUT_TRANSPARENCY = 0.02
M.BASE_ATTRIBUTE = "ForgeBaseTransparency"

--- The Transparency a shown baked part takes (0 for opaque rows, the cutout value for cards).
function M.shown(part: any): number
	local base = part:GetAttribute(M.BASE_ATTRIBUTE)
	return if type(base) == "number" then base else 0
end

--- Bakes every textured SurfaceAppearance under `root` (root included) into its MeshPart's
--- TextureContent and destroys it. Returns how many parts were baked. Call once per loaded
--- template, before cloning: clones then carry the texture and no SurfaceAppearance.
function M.bake(root: any): number
	local parts: { any } = root:GetDescendants()
	table.insert(parts, root)
	local baked = 0
	for _, part in parts do
		if not part:IsA("MeshPart") then
			continue
		end
		local surface = part:FindFirstChildOfClass("SurfaceAppearance")
		if not surface then
			continue
		end
		local color = surface.ColorMapContent
		if color.Uri ~= nil and color.Uri ~= "" then
			part.TextureContent = color
			if surface.AlphaMode.Name == "Transparency" and part.Transparency == 0 then
				part.Transparency = M.CUTOUT_TRANSPARENCY
				part:SetAttribute(M.BASE_ATTRIBUTE, M.CUTOUT_TRANSPARENCY)
			end
			baked += 1
		end
		surface:Destroy()
	end
	return baked
end

return M
