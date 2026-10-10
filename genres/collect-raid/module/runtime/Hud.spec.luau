--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

return {
	["phone desktop transitions restore all parked controls and original order"] = function()
		local source = fs.readFile("genres/collect-raid/module/runtime/Hud.luau")
		if process.env.R12_HISTORICAL == "1" then
			local result = process.exec("git", { "show", "9b1d37b:genres/collect-raid/module/runtime/Hud.luau" })
			assert(result.ok, result.stderr)
			source = result.stdout
		end
		local block = string.match(source, "\tlocal desktopHome:.-\n\tapplyContentMode = setContentMode")
		assert(block ~= nil, "real HUD content binding found")
		local objects: { any } = {}
		local function panel(): any
			local parent: any = { Visible = true }
			function parent:GetChildren(): { any }
				local children = {}
				for _, item in objects do
					if item.Parent == self then
						table.insert(children, item)
					end
				end
				return children
			end
			return parent
		end
		local desktop, storePanel = panel(), panel()
		local function control(parent: any, order: number): any
			local item: any = { Parent = parent, LayoutOrder = order }
			function item:IsA(class: string): boolean
				return class == "GuiObject"
			end
			function item:Destroy()
				self.Parent = nil
			end
			table.insert(objects, item)
			return item
		end
		local env: any = {
			Config = { sourceOrder = { "egg" } },
			storePanel = storePanel,
			oddsPanel = panel(),
			closePhoneSheets = function() end,
		}
		for _, name in
			{
				"creaturesLabel",
				"creatureInventory",
				"vaultedLabel",
				"incubatorFrame",
				"oddsList",
				"siegeLabel",
				"vaultLabel",
				"raidButton",
				"questHeader",
				"questFrame",
				"inviteButton",
			}
		do
			env[name] = control(desktop, #objects * 7)
		end
		env.buyButtons = { egg = control(desktop, 45) }
		env.mergeButtons = { control(desktop, 65) }
		for _, name in { "buySheet", "mergeSheet", "raidSheet", "storeSheet" } do
			env[name] = { scroll = panel() }
		end
		local header = control(storePanel, -1)
		local product, pass, status = control(storePanel, 17), control(storePanel, 29), control(storePanel, 44)
		local destroyed = control(storePanel, 55)
		local homes: { [any]: any } = {}
		for _, item in objects do
			homes[item] = { parent = item.Parent, order = item.LayoutOrder }
		end
		local switch =
			luau.load("return function()\n" .. block .. "\nreturn setContentMode end", { environment = env })()()
		switch(false)
		for cycle = 1, 3 do
			switch(true)
			assert(header.Parent == storePanel and header.LayoutOrder == -1, "header stays desktop")
			for _, item in { product, pass, status } do
				assert(item.Parent == env.storeSheet.scroll, "store controls move to phone")
			end
			switch(true)
			if cycle == 1 then
				destroyed:Destroy()
			end
			switch(false)
			assert(
				product.Parent == storePanel and pass.Parent == storePanel and status.Parent == storePanel,
				"store controls restored from phone"
			)
			for item, home in homes do
				if item ~= destroyed then
					assert(item.Parent == home.parent, "parked control returned to desktop")
					assert(item.LayoutOrder == home.order, "desktop order restored")
				end
			end
			assert(destroyed.Parent == nil, "destroyed controls not resurrected")
		end
	end,
}
