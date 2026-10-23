--!strict
-- p48 Studio 360x640: after the score editor's X, the 소리 (audio) tile hid the menu column with
-- no sheet on screen, so the menu could not be reopened. This runs the shipped robango panel
-- wiring (RobangoIslandClient's ExtensionPanels.start section, every real panel module and the
-- real ui-kit Components) on a small fake engine, opens each dock entry from its menu tile and
-- closes it by its header X: a hidden dock always has a visible sheet, and X brings it back.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox: any = require("@lune/roblox")
local PackText = require("./PackText.fixture")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"
-- Bag/craft/build/skills open SurvivalHUD's own sheet and island view the aerial camera.
local LAUNCHERS = { explore = true, bag = true, craft = true, build = true, skills = true }

local function signal(): any
	local handlers: { any } = {}
	local s: any = {}
	function s:Connect(fn)
		local entry = { fn = fn }
		table.insert(handlers, entry)
		return {
			Connected = true,
			Disconnect = function()
				entry.fn = nil
			end,
		}
	end
	s.Once = s.Connect
	function s:Wait() end
	function s:Fire(...)
		for _, entry in table.clone(handlers) do
			if entry.fn then
				entry.fn(...)
			end
		end
	end
	return s
end

local function harness(): any
	local errors: { string } = {}
	local nodes: { any } = {}
	local attributes: { [string]: any } = {}
	local heartbeat = signal()
	local viewport = roblox.Vector2.new(360, 582)
	local methods: any = {}
	local DEFAULTS: any = {
		Visible = true,
		Enabled = true,
		Text = "",
		AbsoluteSize = viewport,
		AbsolutePosition = roblox.Vector2.zero,
		AbsoluteContentSize = roblox.Vector2.zero,
		CanvasPosition = roblox.Vector2.zero,
		TextBounds = roblox.Vector2.zero,
		ViewportSize = viewport,
		DisplayOrder = 0,
		ZIndex = 1,
		TextSize = 8, -- the engine default an unstyled label renders at
		TextScaled = false,
	}
	local function node(class: string, name: string?): any
		local data: any = { ClassName = class, Name = name or class, children = {}, signals = {} }
		local item = setmetatable({}, {
			__index = function(self, key)
				local value = data[key]
				if value ~= nil then
					return value
				end
				if methods[key] then
					return methods[key]
				end
				if DEFAULTS[key] ~= nil then
					return DEFAULTS[key]
				end
				local first = string.sub(key, 1, 1)
				if first == string.upper(first) and first ~= string.lower(first) then
					local child = methods.FindFirstChild(self, key)
					if child then
						return child
					end
					-- Unset events (Activated, Destroying, OnClientEvent, ...) are signals.
					if string.find(key, "%u%l+ed$") or string.find(key, "Event$") or string.find(key, "^Mouse") then
						data.signals[key] = data.signals[key] or signal()
						data[key] = data.signals[key]
						return data[key]
					end
					if
						string.find(key, "Began$")
						or string.find(key, "Ended$")
						or string.find(key, "Destroying")
						or string.find(key, "Lost$")
						or string.find(key, "Stepped$")
					then
						data[key] = signal()
						return data[key]
					end
				end
				return nil
			end,
			__newindex = function(self, key, value)
				if key == "Parent" then
					local old = data.Parent
					if old then
						local list = rawget(getmetatable(old) :: any, "data").children
						local at = table.find(list, self)
						if at then
							table.remove(list, at)
						end
					end
					if value then
						table.insert(rawget(getmetatable(value) :: any, "data").children, self)
					end
				end
				data[key] = value
			end,
			data = data,
		})
		table.insert(nodes, item)
		return item
	end
	local function guiKind(item: any): boolean
		return item.ClassName ~= "ScreenGui" and item.ClassName ~= "Folder" and item.ClassName ~= "PlayerGui"
	end
	function methods.IsA(self, kind)
		if kind == "GuiObject" or kind == "GuiBase2d" then
			return string.find(self.ClassName, "^Text") ~= nil
				or string.find(self.ClassName, "^Image") ~= nil
				or self.ClassName == "Frame"
				or self.ClassName == "ScrollingFrame"
		elseif kind == "GuiButton" then
			return self.ClassName == "TextButton" or self.ClassName == "ImageButton"
		elseif kind == "LayerCollector" then
			return self.ClassName == "ScreenGui"
		end
		return self.ClassName == kind
	end
	function methods.GetChildren(self)
		return table.clone(rawget(getmetatable(self) :: any, "data").children)
	end
	function methods.GetDescendants(self)
		local out = {}
		for _, child in methods.GetChildren(self) do
			table.insert(out, child)
			for _, deep in methods.GetDescendants(child) do
				table.insert(out, deep)
			end
		end
		return out
	end
	function methods.FindFirstChild(self, name)
		for _, child in rawget(getmetatable(self) :: any, "data").children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function methods.WaitForChild(self, name)
		return methods.FindFirstChild(self, name)
			or (function()
				local made = node("Folder", name)
				made.Parent = self
				return made
			end)()
	end
	function methods.FindFirstChildOfClass(self, class)
		for _, child in methods.GetChildren(self) do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	function methods.FindFirstChildWhichIsA(self, class)
		for _, child in methods.GetChildren(self) do
			if child:IsA(class) then
				return child
			end
		end
		return nil
	end
	function methods.FindFirstAncestorWhichIsA(self, class)
		local current = self.Parent
		while current and not current:IsA(class) do
			current = current.Parent
		end
		return current
	end
	function methods.FindFirstAncestorOfClass(self, class)
		return methods.FindFirstAncestorWhichIsA(self, class)
	end
	function methods.IsDescendantOf(self, other)
		local current = self.Parent
		while current and current ~= other do
			current = current.Parent
		end
		return current ~= nil
	end
	function methods.Destroy(self)
		self.Parent = nil
	end
	methods.ClearAllChildren = function(self)
		for _, child in methods.GetChildren(self) do
			child.Parent = nil
		end
	end
	function methods.GetPropertyChangedSignal(self, property)
		local signals = rawget(getmetatable(self) :: any, "data").signals
		signals["@" .. property] = signals["@" .. property] or signal()
		return signals["@" .. property]
	end
	function methods.GetAttribute(self, key)
		return rawget(getmetatable(self) :: any, "data")["@" .. key]
	end
	function methods.SetAttribute(self, key, value)
		rawget(getmetatable(self) :: any, "data")["@" .. key] = value
	end
	function methods.GetAttributeChangedSignal(self, key)
		return methods.GetPropertyChangedSignal(self, "@" .. key)
	end
	function methods.GetAttributes()
		return {}
	end
	function methods.InvokeServer()
		return { ok = false, reason = "COMMAND_UNAVAILABLE" }
	end
	function methods.FireServer() end
	function methods.CaptureFocus() end
	function methods.ReleaseFocus() end
	function methods.GetServerTimeNow()
		return 0
	end
	function methods.Play() end
	function methods.Stop() end

	local player = node("Player", "Player")
	player.UserId, player.DisplayName, player.LocaleId = 1, "Player", "ko-kr"
	function player.GetAttribute(_self, key)
		return attributes[key]
	end
	function player.SetAttribute(_self, key, value)
		attributes[key] = value
	end
	local playerGui = node("PlayerGui", "PlayerGui")
	playerGui.Parent = player
	player.PlayerGui = playerGui
	local workspace = node("Workspace", "Workspace")
	workspace.CurrentCamera = node("Camera", "Camera")
	local services: any = {
		Players = node("Players"),
		RunService = node("RunService"),
		HttpService = node("HttpService"),
		UserInputService = node("UserInputService"),
		CollectionService = node("CollectionService"),
		TweenService = node("TweenService"),
		Workspace = workspace,
	}
	services.Players.LocalPlayer = player
	function services.Players.GetPlayers()
		return { player }
	end
	function services.Players.GetPlayerByUserId(_self, id)
		return if id == 1 then player else nil
	end
	services.RunService.Heartbeat = heartbeat
	function services.RunService.IsStudio()
		return false
	end
	function services.HttpService.JSONEncode(_self, value)
		return serde.encode("json", value)
	end
	function services.HttpService.JSONDecode(_self, text)
		return serde.decode("json", text)
	end
	local guid = 0
	function services.HttpService.GenerateGUID()
		guid += 1
		return "guid-" .. guid
	end
	services.UserInputService.TouchEnabled = true
	function services.UserInputService.GetFocusedTextBox()
		return nil
	end
	function services.CollectionService.GetTagged()
		return {}
	end
	function services.CollectionService.GetInstanceAddedSignal()
		return signal()
	end
	function services.CollectionService.GetInstanceRemovedSignal()
		return signal()
	end
	function services.TweenService.Create()
		return { Play = function() end, Cancel = function() end, Completed = signal() }
	end
	local game = node("DataModel", "game")
	function game.GetService(_self, name)
		services[name] = services[name] or node(name)
		return services[name]
	end
	local base: any = table.clone(getfenv())
	base.game, base.workspace = game, workspace
	base.Instance = {
		new = function(class, parent)
			local made = node(class)
			if parent then
				made.Parent = parent
			end
			return made
		end,
	}
	for _, name in { "UDim", "UDim2", "Vector2", "Vector3", "CFrame", "Color3", "ColorSequence", "Enum", "Font" } do
		base[name] = roblox[name]
	end
	for _, name in { "NumberSequence", "NumberRange", "ColorSequenceKeypoint", "NumberSequenceKeypoint" } do
		base[name] = roblox[name]
	end
	base.TweenInfo = { new = function() end }
	base.RaycastParams = {
		new = function()
			return {}
		end,
	}
	base.typeof = function(value)
		return if type(value) == "table"
				and getmetatable(value)
				and rawget(getmetatable(value) :: any, "data")
			then "Instance"
			else roblox.typeof and roblox.typeof(value) or type(value)
	end
	-- Spawned loops (`while ... task.wait()`) park instead of spinning on the fake clock.
	local spawned: { [thread]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function spawn(fn, ...)
		local thread = if type(fn) == "thread" then fn else coroutine.create(fn)
		spawned[thread] = true
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			table.insert(errors, tostring(err))
		end
		return thread
	end
	base.task = {
		spawn = spawn,
		defer = spawn,
		delay = function(_seconds, _fn)
			return coroutine.create(function() end)
		end,
		wait = function()
			if spawned[coroutine.running()] then
				coroutine.yield()
			end
			return 0
		end,
		cancel = function() end,
	}
	local cache: { [string]: any } = {}
	local load: (string) -> any
	local function proxy(path: string): any
		return setmetatable({}, {
			__index = function(_self, key)
				return proxy(if path == "" then key else path .. "/" .. key)
			end,
			path = path,
		})
	end
	local function resolve(from: string, relative: string): string
		local parts = string.split(from, "/")
		table.remove(parts)
		for _, segment in string.split(relative, "/") do
			if segment == ".." then
				table.remove(parts)
			elseif segment ~= "." then
				table.insert(parts, segment)
			end
		end
		return table.concat(parts, "/")
	end
	function load(path: string): any
		if cache[path] == nil then
			local file = path .. ".luau"
			local env = table.clone(base)
			env.require = function(target)
				if type(target) == "string" then
					return load(resolve(file, target))
				end
				return load((getmetatable(target) :: any).path)
			end
			env.getfenv = function()
				return env
			end
			local source = fs.readFile(file)
			cache[path] = luau.load(source, { debugName = file, environment = env })()
		end
		return cache[path]
	end
	-- The client's panel section: from ExtensionPanels require to the QuarterView camera.
	local client = fs.readFile(CLIENT)
	local first = assert(string.find(client, "local ExtensionPanels = require", 1, true), "panel section")
	local last = assert(string.find(client, "local QuarterView = require", first, true), "panel section end")
	local section = string.sub(client, first, last - 1) .. "\nreturn panels\n"
	local env = table.clone(base)
	local forge = proxy("")
	env.require = function(target)
		return load((getmetatable(target) :: any).path)
	end
	env.getfenv = function()
		return env
	end
	env.Forge, env.Shared = forge, forge.games["robango-island"].src.shared
	env.content = load("games/robango-island/src/shared/SurvivalContent")
	env.player, env.locale, env.korean = player, "ko-kr", true
	env.names, env.authoredText = PackText.names("ko-kr"), PackText.authored
	local hud: any = { opened = signal(), shown = false }
	function hud.open()
		hud.shown = true
	end
	function hud.close()
		hud.shown = false
	end
	function hud.isOpen()
		return hud.shown
	end
	env.hud = hud
	env.audio = {
		signal = function() end,
		panel = function()
			return { destroy = function() end }
		end,
	}
	env.gui, env.script = node("ScreenGui", "ForgeGenreUI"), node("LocalScript", "RobangoIslandClient")
	luau.load(section, { debugName = CLIENT, environment = env })()
	local dock = assert(playerGui:FindFirstChild("ForgePanelDock"), "dock gui")
	local h: any = { errors = errors, heartbeat = heartbeat, attributes = attributes }
	h.column = assert(dock:FindFirstChild("Dock"), "dock column")
	h.menu = assert(dock:FindFirstChild("Menu"), "menu grid")
	h.toggle = assert(h.column:FindFirstChild("MenuToggle"), "menu toggle")
	function h.tiles(): { any }
		local tiles = {}
		for _, item in h.menu:GetChildren() do
			if item.ClassName == "TextButton" and string.sub(item.Name, 1, 5) == "Dock-" then
				table.insert(tiles, item)
			end
		end
		table.sort(tiles, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		return tiles
	end
	function h.tile(id: string): any
		return assert(h.menu:FindFirstChild("Dock-" .. id), "tile " .. id)
	end
	local function shown(item: any): boolean
		local current = item
		while current and current ~= playerGui do
			if (guiKind(current) and current.Visible == false) or current.Enabled == false then
				return false
			end
			current = current.Parent
		end
		return current == playerGui
	end
	-- Every on-screen sheet with a close button: Components.modalSheet (Frame > Header > Close) or
	-- a panel root with its own Close (BrawlPanel). Returns { frame, close } pairs.
	function h.sheets(): { any }
		local open = {}
		for _, item in nodes do
			if item.ClassName == "Frame" and shown(item) then
				local header = item:FindFirstChild("Header")
				local close = (header and header:FindFirstChild("Close")) or item:FindFirstChild("Close")
				if close and close.ClassName == "TextButton" then
					table.insert(open, { frame = item, close = close })
				end
			end
		end
		-- Keep only outermost sheets (a sheet may nest a sub-panel with its own Close).
		local outer = {}
		for _, sheet in open do
			local nested = false
			for _, other in open do
				nested = nested or (other ~= sheet and sheet.frame:IsDescendantOf(other.frame))
			end
			if not nested then
				table.insert(outer, sheet)
			end
		end
		return outer
	end
	function h.step()
		heartbeat:Fire(1 / 60)
		heartbeat:Fire(1 / 60)
	end
	function h.click(button: any)
		button.Activated:Fire({}, 1)
		h.step()
	end
	return h
end

-- Opens `id` from the menu and closes it by X; returns whether a sheet opened.
local function cycle(h: any, id: string): boolean
	h.step()
	assert(#h.sheets() == 0 and h.column.Visible and h.toggle.Visible, "dock visible before " .. id)
	h.click(h.toggle)
	assert(h.menu.Visible, "menu opens before " .. id)
	h.click(h.tile(id))
	local open = h.sheets()
	if h.column.Visible then
		-- A locked entry (camp outside its site) may decline to open; the dock stays usable.
		assert(#open == 0, id .. " shows a sheet over a visible dock")
		return false
	end
	assert(#open == 1, string.format("%s hides the menu with %d sheets on screen (wedge)", id, #open))
	local function small(item: any)
		for _, child in item:GetChildren() do
			if (child.ClassName == "TextLabel" or child.ClassName == "TextButton") and child.Text ~= "" then
				assert(
					not child.Visible or child.TextScaled or child.TextSize >= 11,
					id .. " text under 11 px: " .. child.Text
				)
			end
			small(child)
		end
	end
	small(open[1].frame)
	h.click(open[1].close)
	assert(#h.sheets() == 0, id .. " sheet still on screen after its X")
	assert(h.column.Visible and h.toggle.Visible, id .. " X left the menu column hidden")
	return true
end

return {
	["p48: after the score editor's X the menu toggle returns and the audio tile opens its sheet"] = function()
		local h = harness()
		assert(cycle(h, "music"), "score editor opens")
		assert(h.attributes.ForgeExtensionSheetOpen == false, "no extension sheet flagged open")
		assert(cycle(h, "audio"), "audio settings sheet opens")
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	["p56: the menu reopens scrolled to the top with the guide tile first"] = function()
		local h = harness()
		h.step()
		assert(string.sub(h.tiles()[1].Name, 6) == "guides", "first tile: " .. h.tiles()[1].Name)
		h.click(h.toggle)
		assert(h.menu.Visible, "menu opens")
		h.menu.CanvasPosition = roblox.Vector2.new(0, 400)
		h.click(h.toggle)
		assert(not h.menu.Visible, "menu closes")
		h.click(h.toggle)
		assert(h.menu.Visible and h.menu.CanvasPosition.Y == 0, "menu reopens at canvas " .. h.menu.CanvasPosition.Y)
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
	["every dock entry opened from its tile closes by X and returns the menu column"] = function()
		local h = harness()
		local opened, ids = 0, {}
		for _, tile in h.tiles() do
			local id = string.sub(tile.Name, 6)
			if not LAUNCHERS[id] then
				table.insert(ids, id)
				if cycle(h, id) then
					opened += 1
				end
			end
		end
		assert(#ids >= 40 and opened >= #ids - 2, string.format("%d of %d dock entries opened", opened, #ids))
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
}
