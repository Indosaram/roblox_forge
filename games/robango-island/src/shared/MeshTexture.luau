--!strict
-- Runtime texture path for the uploaded mesh packages (creatures, biome kits, node meshes,
-- building rows). The Open Cloud FBX importer (assets/blender/upload.mjs) gives every textured
-- MeshPart a SurfaceAppearance whose engine-managed TexturePack is empty: only a Studio publish
-- bakes that pack, and these models never pass through one (they arrive via
-- InsertService:LoadAsset). Clients render a SurfaceAppearance from its TexturePack, so on device
-- each one logs "Failed to load ...SurfaceAppearance. PBR textures may not be visible in game."
-- and draws untextured (staging v47, .omo/evidence/robango-durango-gap/tex/REPORT.md).
-- bake() moves the colour map onto MeshPart.TextureContent, which clients fetch as a plain Image
-- asset, and drops the SurfaceAppearance. Alpha-cutout cards keep their cutout: a MeshPart
-- texture's alpha channel is drawn as transparency. Normal and roughness maps are lost; they
-- never reached the client anyway.
local M = {}

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
			baked += 1
		end
		surface:Destroy()
	end
	return baked
end

return M
