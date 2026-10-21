--!strict
local env: any = getfenv()
local Instance, UDim2, UDim, Color3 = env.Instance, env.UDim2, env.UDim, env.Color3
local M = {}
-- Shapes use normalized coordinates: x, y, width, height, rotation, round.
local shapes = {
	food = { { 0.26, 0.35, 0.48, 0.48, 0, 1 }, { 0.48, 0.16, 0.25, 0.14, -30, 1 } },
	fiber = { { 0.23, 0.2, 0.08, 0.6, -18 }, { 0.46, 0.2, 0.08, 0.6, 0 }, { 0.69, 0.2, 0.08, 0.6, 18 } },
	wood = { { 0.2, 0.3, 0.6, 0.4, -25, 1 }, { 0.22, 0.36, 0.18, 0.28, -25, 1 } },
	stone = { { 0.28, 0.25, 0.44, 0.5, 35 }, { 0.43, 0.3, 0.1, 0.35, 35 } },
	tool = { { 0.45, 0.2, 0.12, 0.65, 25 }, { 0.28, 0.2, 0.45, 0.25, 25 } },
	weapon = { { 0.45, 0.15, 0.1, 0.7, 35 }, { 0.32, 0.1, 0.3, 0.3, 35 } },
	armor = { { 0.25, 0.25, 0.5, 0.4 }, { 0.34, 0.5, 0.32, 0.28, 45 } },
	seed = { { 0.35, 0.42, 0.3, 0.4, 25, 1 }, { 0.48, 0.18, 0.25, 0.14, -35, 1 } },
	medicine = { { 0.4, 0.2, 0.2, 0.6 }, { 0.2, 0.4, 0.6, 0.2 } },
	building = { { 0.2, 0.44, 0.6, 0.36 }, { 0.25, 0.18, 0.5, 0.2, -25 } },
	creature = { { 0.3, 0.45, 0.4, 0.35, 0, 1 }, { 0.18, 0.2, 0.2, 0.2, 0, 1 }, { 0.6, 0.2, 0.2, 0.2, 0, 1 } },
	item = { { 0.27, 0.27, 0.46, 0.46, 45 } },
}
function M.category(item: any): string
	local id = item.id or ""
	local tags = item.tags or {}
	if shapes[item.category] then
		return item.category
	end
	if string.find(id, "seed") then
		return "seed"
	end
	if string.find(id, "medicine") or string.find(id, "bandage") then
		return "medicine"
	end
	if item.foodEffects then
		return "food"
	end
	if string.find(id, "spear") or string.find(id, "bow") or string.find(id, "sword") then
		return "weapon"
	end
	if table.find(tags, "tool") then
		return "tool"
	end
	if string.find(id, "armor") or string.find(id, "leather") or string.find(id, "hide") or string.find(id, "fur") then
		return "armor"
	end
	if table.find(tags, "building-part") or string.find(id, "kit") then
		return "building"
	end
	if string.find(id, "fiber") or string.find(id, "cord") or string.find(id, "reed") or string.find(id, "thatch") then
		return "fiber"
	end
	if
		string.find(id, "wood")
		or string.find(id, "plank")
		or string.find(id, "timber")
		or id == "branch"
		or string.find(id, "bark")
	then
		return "wood"
	end
	if
		string.find(id, "stone")
		or string.find(id, "flint")
		or string.find(id, "ore")
		or string.find(id, "basalt")
		or string.find(id, "clay")
	then
		return "stone"
	end
	return "item"
end
function M.mount(parent: any, category: string?, size: any, position: any, image: string?, name: string?): any
	local key = name or "IconFallback"
	local previous = parent:FindFirstChild(key)
	if previous then
		previous:Destroy()
	end
	local badge = Instance.new("Frame")
	badge.Name, badge.Size, badge.Position = key, size, position
	badge.BorderSizePixel, badge.BackgroundColor3 = 0, Color3.fromRGB(45, 76, 64)
	badge.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius, corner.Parent = UDim.new(0, 5), badge
	local glyph = Instance.new("Frame")
	glyph.Name, glyph.BackgroundTransparency, glyph.Size, glyph.Parent = "Glyph", 1, UDim2.fromScale(1, 1), badge
	for index, shape in shapes[category or "item"] or shapes.item do
		local part = Instance.new("Frame")
		part.Name, part.BorderSizePixel = "Shape" .. index, 0
		part.Size, part.Position = UDim2.fromScale(shape[3], shape[4]), UDim2.fromScale(shape[1], shape[2])
		part.Rotation, part.BackgroundColor3 = shape[5] or 0, Color3.fromRGB(220, 231, 176)
		part.Parent = glyph
		if shape[6] then
			local round = Instance.new("UICorner")
			round.CornerRadius, round.Parent = UDim.new(0.5, 0), part
		end
	end
	if image then
		local asset = Instance.new("ImageLabel")
		asset.Name, asset.BackgroundTransparency, asset.Size = "Asset", 1, UDim2.fromScale(1, 1)
		asset.Image, asset.Parent = image, badge
		local function loaded()
			glyph.Visible = not asset.IsLoaded
		end
		asset:GetPropertyChangedSignal("IsLoaded"):Connect(loaded)
		loaded()
	end
	return badge
end
return M
