--!strict
-- Procedural-prop seating helpers for the client's remaining generated decor (the Studio
-- development island: ProcAssets keys in assets/procgen.yml, src/shared/ProcAssets.luau is
-- generated from it). Role worlds no longer get procedural props: their vegetation and rocks
-- are the B1 mesh biome kits (BiomeKits) and their camp props B3 rows (StructureMeshes), so the
-- old per-role ProcProps plan (low-fi Part blobs, asset-audit G10 item 5) is gone.
local M = {}

--- Lowest world Y of the visible geometry of a set of parts (anything with .CFrame and
--- .Size): each part's oriented box bottom. A Part is centred on its CFrame. A MeshAdapter
--- MeshPart is not: its CFrame is the mesh origin and its geometry spans the mesh-space
--- bounds recorded in ForgeMeshMin/ForgeMeshMax, scaled by Size / (max - min).
function M.bottom(parts: { any }): number
	local lowest = math.huge
	for _, part in parts do
		local cf, size = part.CFrame, part.Size
		local centreY = cf.Position.Y
		local lo = if part.GetAttribute then part:GetAttribute("ForgeMeshMin") else nil
		local hi = if part.GetAttribute then part:GetAttribute("ForgeMeshMax") else nil
		if lo and hi then
			local function offset(a: number, b: number, extent: number): number
				local span = b - a
				return if span > 0 then (a + b) / 2 * extent / span else 0
			end
			local dx = offset(lo.X, hi.X, size.X)
			local dy = offset(lo.Y, hi.Y, size.Y)
			local dz = offset(lo.Z, hi.Z, size.Z)
			centreY += cf.RightVector.Y * dx + cf.UpVector.Y * dy + cf.LookVector.Y * dz
		end
		local half = (
			math.abs(cf.RightVector.Y) * size.X
			+ math.abs(cf.UpVector.Y) * size.Y
			+ math.abs(cf.LookVector.Y) * size.Z
		) / 2
		lowest = math.min(lowest, centreY - half)
	end
	return lowest
end

--- Vertical offset that seats a prop whose bounding-box bottom is `bottom` on `ground`.
function M.seat(ground: number, bottom: number): number
	return ground - bottom
end

return M
