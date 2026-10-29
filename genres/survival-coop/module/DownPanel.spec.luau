--!strict
-- p134 v49 (phone): while down, the client logged "DownPanel:311: attempt to index string with
-- 'Image'" about once a second. U3b made the card icon an ImageLabel pebble badge with an inner
-- "Image" label, and render wrote `item.icon.Image.Image`: on an ImageLabel `.Image` is the
-- string property, not the child. This drives the real DownPanel factory through two snapshots.
local roblox: any = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local _packText = (require :: any)("../../../games/robango-island/PackText.fixture")
local ImageLoad = require("../../../core/ui-kit/ImageLoad.fixture")

local function signal(list: { any }?)
	return {
		Connect = function(_, fn)
			if list then
				table.insert(list, fn)
			end
			return { Disconnect = function() end }
		end,
	}
end

local function mount(): (any, (any) -> (), any, any, any)
	local I = roblox.Instance
	local playerGui = I.new("PlayerGui")
	-- Attributes fire their changed signals like the engine's, so the pack's backpack binding
	-- (TitleFlow.bindBackpack) can run against this same player.
	local attributes: { [string]: any } = {}
	local watchers: { [string]: { () -> () } } = {}
	local player = {
		PlayerGui = playerGui,
		WaitForChild = function()
			return playerGui
		end,
		GetAttribute = function(_, name: string)
			return attributes[name]
		end,
		SetAttribute = function(_, name: string, value: any)
			if attributes[name] ~= value then
				attributes[name] = value
				for _, fn in watchers[name] or ({} :: { () -> () }) do
					fn()
				end
			end
		end,
		GetAttributeChangedSignal = function(_, name: string)
			return {
				Connect = function(_, fn)
					watchers[name] = watchers[name] or {}
					table.insert(watchers[name], fn)
					return { Disconnect = function() end }
				end,
			}
		end,
	}
	local lighting = I.new("Lighting")
	local services: { [string]: any } = {
		Players = {
			LocalPlayer = player,
			GetPlayerByUserId = function()
				return nil
			end,
		},
		Lighting = lighting,
		RunService = { Heartbeat = signal() },
		TextChatService = {
			FindFirstChild = function()
				return nil
			end,
		},
	}
	local environment: any = {
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		task = { spawn = function() end },
	}
	for key, value in roblox do
		environment[key] = value
	end
	local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
		environment = environment,
	})()
	environment.require = function(path: string)
		return if path == "./HudShell" then shell else require("./PackLocale")
	end
	-- Registered once per process; another spec in the run may have done it already.
	pcall(roblox.implementProperty, "TextButton", "Activated", function()
		return signal()
	end)
	-- Lune GUI objects have no layout: the pebble rim reads a card badge's size.
	environment.Instance = ImageLoad.instance(function(made)
		if made:IsA("GuiObject") then
			made.AbsoluteSize = roblox.Vector2.new(48, 48)
		end
	end)
	local panel = luau.load(fs.readFile("genres/survival-coop/module/DownPanel.luau"), {
		chunkName = "DownPanel",
		environment = environment,
	})()
	local listener: ((any) -> ())? = nil
	local started = panel.factory({
		locale = "en-us",
		icons = {
			item = function(id: string)
				return { image = "rbxassetid://" .. #id }
			end,
		},
		send = function()
			return { ok = true }
		end,
		onSnapshot = function(fn)
			listener = fn
			return function() end
		end,
	})
	assert(started and listener, "factory subscribed")
	return playerGui, listener :: (any) -> (), player, started, panel
end

return {
	["the down panel renders twice across snapshots and puts item art on each card badge"] = function()
		local playerGui, render = mount()
		render({ rescue = { down = true, options = { "rift", "camp", "rescue" } } })
		-- The second snapshot reuses the cards built by the first.
		render({ rescue = { down = true, options = { "rift", "camp" }, choice = "camp" } })
		local gui = playerGui:FindFirstChild("ForgeDownPanel")
		assert(gui and gui.Enabled, "panel shown while down")
		local row = gui:FindFirstChild("DownCards")
		local visible = 0
		for _, button in row:GetChildren() do
			if button:IsA("TextButton") then
				local inner = button:FindFirstChild("Icon"):FindFirstChild("Image")
				if button.Visible then
					visible += 1
					assert(string.match(inner.Image, "^rbxassetid://%d+$"), "badge art on the inner label")
				end
			end
		end
		assert(visible == 2, "two cards on the second snapshot, got " .. visible)
		render({ rescue = { down = false, options = {} } })
		assert(not gui.Enabled, "panel hides once up")
	end,
	-- p134 v53 (phone): the CoreGui Backpack hotbar (bone knife / bola tiles) drew over the middle
	-- down card. The panel flags the player while shown; Robango's backpack binding hides the hotbar
	-- under that flag and brings it back after the respawn.
	["the backpack hotbar hides while the down panel shows and returns once up"] = function()
		local playerGui, render, player, started, panel = mount()
		local Flow = (require :: any)("../../../games/robango-island/src/first/TitleFlow")
		assert(table.find(Flow.SHEET_ATTRIBUTES, panel.OPEN_ATTRIBUTE), "the binding reads the down flag")
		player:SetAttribute("ForgeTitleDone", true)
		local applied: { boolean } = {}
		Flow.bindBackpack(player, function(shown: boolean)
			table.insert(applied, shown)
		end)
		assert(applied[#applied] == true, "hotbar shown in play")
		render({ rescue = { down = true, options = { "rift", "camp", "rescue" } } })
		assert(playerGui:FindFirstChild("ForgeDownPanel").Enabled, "panel shown while down")
		assert(applied[#applied] == false, "hotbar hidden under the down panel")
		local count = #applied
		render({ rescue = { down = true, options = { "rift", "camp" }, choice = "camp" } })
		assert(#applied == count, "a second down snapshot changes nothing")
		render({ rescue = { down = false, options = {} } })
		assert(applied[#applied] == true, "hotbar back after the respawn")
		render({ rescue = { down = true, options = { "camp" } } })
		started.destroy()
		assert(applied[#applied] == true, "destroying the panel never leaves the hotbar hidden")
	end,
}
