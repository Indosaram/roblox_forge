--!strict
-- Catalog and published assets are injected; this module has no game-pack dependency.
local ItemIcons = {}

export type Catalog = {
	items: { any },
	materials: { any }?,
	recipes: { any },
}
export type Icon = { key: string?, image: string?, text: string }

function ItemIcons.new(catalog: Catalog, assets: { [string]: number | string })
	local items: { [string]: string } = {}
	local recipes: { [string]: boolean } = {}
	for _, item in catalog.items do
		items[item.id] = item.name or item.id
	end
	for _, material in (catalog.materials or {}) :: { any } do
		items[material.id] = items[material.item] or material.item
	end
	for _, recipe in catalog.recipes do
		recipes[recipe.id] = true
	end

	local function resolve(kind: string, id: string, label: string?): Icon
		local known = if kind == "item" then items[id] ~= nil else recipes[id] == true
		local key = if known then kind .. ".icon." .. id else nil
		local manifestKey = if key then string.gsub(key, "[.]", "-") else nil
		local asset = if manifestKey then assets[manifestKey] else nil
		local image = nil
		if type(asset) == "number" and asset > 0 then
			image = "rbxassetid://" .. tostring(asset)
		elseif type(asset) == "string" and string.match(asset, "^rbxassetid://[1-9][0-9]*$") then
			image = asset
		end
		return {
			key = key,
			image = image,
			text = label or (if kind == "item" then items[id] else nil) or id,
		}
	end

	return {
		item = function(id: string, label: string?): Icon
			return resolve("item", id, label)
		end,
		recipe = function(id: string, label: string?): Icon
			return resolve("recipe", id, label)
		end,
	}
end

return ItemIcons
