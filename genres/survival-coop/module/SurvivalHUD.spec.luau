--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")

return {
	["sheet snapshots retain press identity and dispatch current enabled action"] = function()
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local hud = luau.load(source, {
			environment = {
				require = function(path)
					assert(
						path == "./SurvivalHUDModel"
							or path == "./SurvivalHUDLocale"
							or path == "../../../core/ui-kit/IconFallback",
						"HUD dependencies"
					)
					return {}
				end,
				UDim2 = {
					new = function(...)
						return { ... }
					end,
				},
			},
		})()
		local parent = {}
		local components = {
			button = function(_theme, props)
				local item: any = { Parent = props.parent, activate = props.onClick, destroyed = false }
				function item:Destroy()
					self.destroyed, self.Parent = true, nil
				end
				return item
			end,
		}
		local controls = hud.controls(components, {}, parent)
		local calls = {}
		controls.begin("build")
		local pressed = controls.button("place-one", "Place", function()
			table.insert(calls, 1)
		end, true)
		controls.finish()
		local handler = pressed.activate
		controls.begin("build")
		assert(controls.order() == 1, "labels participate in one ordered flow")
		local retained = controls.button("place-one", "Place updated", function()
			table.insert(calls, 2)
		end, true)
		controls.finish()
		assert(retained == pressed and retained.activate == handler and not pressed.destroyed, "press remains live")
		assert(retained.LayoutOrder == 2 and retained.Text == "Place updated", "current order and text")
		pressed.activate()
		assert(#calls == 1 and calls[1] == 2, "release dispatches current versioned closure")
		controls.begin("build")
		controls.button("place-one", "Pending", function()
			error("disabled action dispatched")
		end, false)
		controls.finish()
		pressed.activate()
		assert(not pressed.Interactable and not pressed.Active and not pressed.Selectable, "pending blocks input")
		assert(#calls == 1, "disabled activation is ignored")
		controls.begin("build")
		local replacement = controls.button("place-two", "Place", function()
			table.insert(calls, 3)
		end, true)
		controls.finish()
		assert(pressed.destroyed and replacement ~= pressed, "disappeared target is not retargeted")
		pressed.activate()
		assert(#calls == 1, "removed target cannot dispatch its old handler")
		replacement.activate()
		assert(calls[2] == 3, "new target has its own handler")
		controls.begin("craft")
		local other = controls.button("place-two", "Other section", function() end, true)
		controls.finish()
		assert(replacement.destroyed and other ~= replacement, "section change retires old controls")
	end,
}
