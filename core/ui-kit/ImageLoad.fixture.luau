--!strict
-- Spec fixture: Lune's ImageLabel reflects IsLoaded without a default and has no
-- GetPropertyChangedSignal. `instance` wraps Instance.new so every new ImageLabel starts unloaded,
-- and `load` decides when (or whether) an image finishes loading and fires its IsLoaded listeners,
-- as the engine does for a published image the experience may or may not use.
local roblox: any = require("@lune/roblox")

local M = {}
local listeners: { [any]: { [string]: { any } } } = {}

-- Registered once per process; another spec in the same worker may own it already.
pcall(roblox.implementMethod, "GuiObject", "GetPropertyChangedSignal", function(instance: any, property: string)
	return {
		Connect = function(_, fn: () -> ())
			local byProperty = listeners[instance] or {}
			listeners[instance] = byProperty
			local list = byProperty[property] or {}
			byProperty[property] = list
			table.insert(list, fn)
			return {
				Disconnect = function()
					local at = table.find(list, fn)
					if at then
						table.remove(list, at)
					end
				end,
			}
		end,
	}
end)

--- Instance table for a module environment: Instance.new with unloaded ImageLabels; `extra` runs on
--- every new instance (for example to give GuiObjects an AbsoluteSize).
function M.instance(extra: ((any) -> ())?): any
	return {
		new = function(class: string): any
			local made = roblox.Instance.new(class)
			if class == "ImageLabel" then
				made.IsLoaded = false
			end
			if extra then
				extra(made)
			end
			return made
		end,
	}
end

--- Marks `image` loaded (or not) and fires its IsLoaded listeners.
function M.load(image: any, loaded: boolean)
	image.IsLoaded = loaded
	for key, byProperty in listeners do
		if key == image then
			for _, fn in table.clone(byProperty.IsLoaded or {}) do
				(fn :: () -> ())()
			end
		end
	end
end

return M
