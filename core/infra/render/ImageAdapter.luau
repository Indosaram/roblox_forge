--!strict
-- ImageAdapter: Roblox-side bridge that turns a pure-Luau Pixels canvas into
-- EditableImage content for ImageLabels and Decals.
--
-- EditableImage content is client-only and does not replicate, so every entry
-- point returns nil on the server (callers keep their hand-authored UI) and
-- wraps every engine call in pcall, returning nil if the editable APIs are
-- unavailable at runtime.

local ImageAdapter = {}

local RunService = game:GetService("RunService")

--- Builds a client-only Content (EditableImage) from a Pixels canvas, or nil on
--- the server / when the EditableImage API is unavailable.
function ImageAdapter.toContent(pixels: any): Content?
	if not RunService:IsClient() then
		return nil
	end
	local ok, result = pcall(function(): any
		local AssetService = game:GetService("AssetService")
		local size = Vector2.new(pixels.width, pixels.height)
		local editable = AssetService:CreateEditableImage({ Size = size })
		editable:WritePixelsBuffer(Vector2.zero, size, pixels:toBuffer())
		return Content.fromObject(editable)
	end)
	if ok and result ~= nil then
		return result :: Content
	end
	return nil
end

--- Sets `label.ImageContent` from a Pixels canvas. Returns false (leaving the
--- label untouched) when content could not be created or assigned.
function ImageAdapter.applyToImageLabel(label: ImageLabel, pixels: any): boolean
	local content = ImageAdapter.toContent(pixels)
	if content == nil then
		return false
	end
	local ok = pcall(function()
		label.ImageContent = content
	end)
	return ok
end

--- Parents a Decal carrying the canvas texture onto `parent` (a surface), or
--- returns nil on the server / when the Decal content path is unavailable.
function ImageAdapter.decal(parent: Instance, pixels: any, face: Enum.NormalId?): Decal?
	if not RunService:IsClient() then
		return nil
	end
	local content = ImageAdapter.toContent(pixels)
	if content == nil then
		return nil
	end
	local decal = Instance.new("Decal")
	decal.Name = "GeneratedDecal"
	decal.Face = face or Enum.NormalId.Front
	local ok = pcall(function()
		(decal :: any).TextureContent = content
	end)
	if not ok then
		decal:Destroy()
		return nil
	end
	decal.Parent = parent
	return decal
end

return ImageAdapter
