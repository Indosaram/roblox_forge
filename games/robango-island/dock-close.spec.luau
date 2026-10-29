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

-- options: width, height, inset (top bar px a CoreUISafeInsets gui loses), touch, locale, realHud
-- (start the shipped SurvivalHUD instead of a stub, with GuiService.TopbarInset and computed
-- AbsolutePosition/AbsoluteSize for offset/scale GuiObjects).
local function harness(options: any?): any
	local opts = options or {}
	local locale = opts.locale or "ko-kr"
	-- Screen state a ScreenGui was last laid out at. D2 F4 (Studio, phone 799x359): the trading post's
	-- toggled-off ScreenGui kept the 1279x662 it had on PC, so only an enabled gui follows the screen.
	local screen = { width = opts.width or 360, height = opts.height or 582, inset = opts.inset or 0 }
	local errors: { string } = {}
	local nodes: { any } = {}
	local attributes: { [string]: any } = {}
	-- Gui-space rect of a GuiObject from Size/Position/AnchorPoint (offset and scale), its ScreenGui at 0,0.
	local function layoutRect(item: any): any
		local parent = item.Parent
		local base = if parent and parent.Size
			then layoutRect(parent)
			elseif parent and parent.ClassName == "ScreenGui" then {
				x = 0,
				y = 0,
				width = parent.AbsoluteSize.X,
				height = parent.AbsoluteSize.Y,
			}
			else { x = 0, y = 0, width = screen.width, height = screen.height }
		local size, position = item.Size, item.Position or roblox.UDim2.new()
		local width = size.X.Scale * base.width + size.X.Offset
		local height = size.Y.Scale * base.height + size.Y.Offset
		local anchor = item.AnchorPoint or roblox.Vector2.zero
		return {
			x = base.x + position.X.Scale * base.width + position.X.Offset - anchor.X * width,
			y = base.y + position.Y.Scale * base.height + position.Y.Offset - anchor.Y * height,
			width = width,
			height = height,
		}
	end
	local heartbeat = signal()
	local viewport = roblox.Vector2.new(screen.width, screen.height)
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
		if class == "ScreenGui" then
			data.laidOut = table.clone(screen)
		end
		-- Engine rule: a property wins over a same-named child (ImageLabel.Image is the image string,
		-- even with a child named "Image"; v49 DownPanel:311 indexed that string).
		if class == "ImageLabel" or class == "ImageButton" then
			data.Image = ""
		end
		local item = setmetatable({}, {
			__index = function(self, key)
				if key == "AbsoluteSize" and data.laidOut then
					local at = data.laidOut
					local safe = data.ScreenInsets == roblox.Enum.ScreenInsets.CoreUISafeInsets
					return roblox.Vector2.new(at.width, at.height - (if safe then at.inset else 0))
				end
				if opts.realHud and (key == "AbsolutePosition" or key == "AbsoluteSize") and data.Size then
					local r = layoutRect(self)
					return if key == "AbsolutePosition"
						then roblox.Vector2.new(r.x, r.y)
						else roblox.Vector2.new(r.width, r.height)
				end
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
						or (
							opts.realHud
							and (string.find(key, "Shown$") or string.find(key, "Hidden$") or string.find(key, "ing$"))
						)
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
					data[key] = value
					-- Like the engine: every new ancestor reports the moved item and its subtree.
					local moved = { self }
					for _, deep in methods.GetDescendants(self) do
						table.insert(moved, deep)
					end
					local ancestor = value
					while ancestor do
						local added = rawget(getmetatable(ancestor) :: any, "data").signals.DescendantAdded
						if added then
							for _, each in moved do
								added:Fire(each)
							end
						end
						ancestor = ancestor.Parent
					end
					return
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
	player.UserId, player.DisplayName, player.LocaleId = 1, "Player", locale
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
		-- Top bar band in screen px; a CoreUISafeInsets gui starts below it (AbsolutePosition y 0).
		GuiService = node("GuiService"),
	}
	services.GuiService.TopbarInset = {
		Min = roblox.Vector2.zero,
		Max = roblox.Vector2.new(screen.width, if opts.realHud then screen.inset else 0),
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
	services.UserInputService.TouchEnabled = opts.touch ~= false
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
	env.player, env.locale, env.korean = player, locale, locale == "ko-kr"
	env.names, env.authoredText = PackText.names(locale), PackText.authored
	env.clientText = PackText.packText -- client: PackText.lookup(packRows, "cli.") over full cli.* keys
	-- The client installs the Strings-table lookups before this section (see its PackText block).
	load("genres/survival-coop/module/PackLocale").use(PackText.packText)
	load("genres/survival-coop/module/ScreenText").use(PackText.screenText)
	-- The client builds one shared icon catalog before the panel section.
	env.itemIcons =
		load("genres/survival-coop/module/ItemIcons").new(env.content, load("games/robango-island/src/shared/Assets"))
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
	if opts.realHud then
		-- The client's SurvivalHUD.start call (contextual shell), on the real ui-kit.
		hud = load("genres/survival-coop/module/SurvivalHUD").start({
			icons = env.itemIcons,
			contextual = true,
			shell = {
				name = function(_kind, key)
					return env.names[key]
				end,
				open = function() end,
			},
			openPanel = function()
				return false
			end,
			content = env.content,
			ui = {
				components = load("core/ui-kit/Components"),
				grid = load("core/ui-kit/InventoryGrid"),
				theme = load("core/ui-kit/Theme"),
			},
			settlementOrigin = roblox.Vector3.new(0, 0, 0),
			locale = locale,
			names = env.names,
		})
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
	local h: any = { errors = errors, heartbeat = heartbeat, attributes = attributes, playerGui = playerGui, hud = hud }
	h.rect = layoutRect
	-- Device change: every enabled ScreenGui is laid out again and reports it; a disabled one is not.
	function h.setViewport(width: number, height: number, inset: number)
		screen.width, screen.height, screen.inset = width, height, inset
		services.GuiService.TopbarInset = {
			Min = roblox.Vector2.zero,
			Max = roblox.Vector2.new(width, if opts.realHud then inset else 0),
		}
		viewport = roblox.Vector2.new(width, height)
		DEFAULTS.AbsoluteSize, DEFAULTS.ViewportSize = viewport, viewport
		for _, item in nodes do
			local data = rawget(getmetatable(item) :: any, "data")
			if data.laidOut and item.Enabled ~= false then
				data.laidOut = table.clone(screen)
				item:GetPropertyChangedSignal("AbsoluteSize"):Fire()
			end
		end
	end
	-- One server state packet (ExtensionPanels reads packet.snapshots.survivalExtensions).
	function h.publish(extensions: any)
		game:GetService("ReplicatedStorage"):WaitForChild("ForgeState").OnClientEvent:Fire({
			snapshots = { survivalExtensions = extensions },
		})
		h.step()
	end
	-- A whole packet (survival-coop snapshot + durable policy), as the server pushes it.
	function h.packet(packet: any)
		game:GetService("ReplicatedStorage"):WaitForChild("ForgeState").OnClientEvent:Fire(packet)
		h.step()
	end
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

-- D2 F4: the trading post (C8 full-screen panel) at the three plan C8 screens.
local VIEWS = { { 800, 360, 0 }, { 850, 411, 58 }, { 1920, 1080, 0 } }
local MARKET: any = {
	balance = 120,
	items = { a = { catalogId = "antler", quantity = 5 } },
	catalogIds = { "antler", "apple" },
	listed = { { id = "L1", catalogId = "antler", quantity = 2, price = 20 } },
	listings = { { id = "S1", catalogId = "antler", quantity = 2, price = 21 } },
	filter = "antler",
	claims = { { id = "C1", value = { coins = 30 } } },
	page = 1,
	pages = 2,
	eligible = true,
}
-- Screen rect of a GuiObject inside its ScreenGui (offset layout, plus scale against the parent).
local function rect(item: any): { x: number, y: number, width: number, height: number }
	local parent = item.Parent
	local base = if parent and parent.ClassName ~= "ScreenGui"
		then rect(parent)
		else { x = 0, y = 0, width = parent.AbsoluteSize.X, height = parent.AbsoluteSize.Y }
	local size, position = item.Size, item.Position or roblox.UDim2.new()
	local width = size.X.Scale * base.width + size.X.Offset
	local height = size.Y.Scale * base.height + size.Y.Offset
	local anchor = item.AnchorPoint or roblox.Vector2.zero
	return {
		x = base.x + position.X.Scale * base.width + position.X.Offset - anchor.X * width,
		y = base.y + position.Y.Scale * base.height + position.Y.Offset - anchor.Y * height,
		width = width,
		height = height,
	}
end
local function inside(r: any, bounds: any): boolean
	return r.x >= bounds.x - 0.5
		and r.y >= bounds.y - 0.5
		and r.x + r.width <= bounds.x + bounds.width + 0.5
		and r.y + r.height <= bounds.y + bounds.height + 0.5
end
-- Checks the open market at screen `view` (safe area = the viewport below the top-bar inset).
local function checkMarket(h: any, view: { number }, locale: string)
	local where = string.format("%dx%d inset %d %s", view[1], view[2], view[3], locale)
	local open = h.sheets()
	assert(#open == 1 and open[1].frame.Name == "TradeSheet", "trading post open at " .. where)
	local frame, close = open[1].frame, open[1].close
	local safe = { x = 0, y = 0, width = view[1], height = view[2] - view[3] }
	local panel = rect(frame)
	assert(
		panel.width == safe.width and panel.height == safe.height and inside(panel, safe),
		string.format("panel %dx%d fills the %s safe area", panel.width, panel.height, where)
	)
	local x = rect(close)
	assert(inside(x, panel), "close inside the panel at " .. where)
	assert(x.width >= 44 and x.height >= 44, "close >= 44 px at " .. where)
	local Social = require("../../genres/survival-coop/module/SocialSheet")
	local buttons = 0
	local function walk(item: any)
		for _, child in item:GetChildren() do
			if child.Visible ~= false and child.Size then
				local r = rect(child)
				local isButton = child.ClassName == "TextButton"
				if isButton or child.ClassName == "TextLabel" or child.ClassName == "ScrollingFrame" then
					-- Scrolling lists may run past their pane; everything else stays on screen.
					if not item:IsA("ScrollingFrame") then
						assert(inside(r, panel), child.Name .. " overflows the panel at " .. where)
					end
				end
				if isButton then
					buttons += 1
					assert(r.height >= 44 and r.width >= 44, child.Name .. " under 44 px at " .. where)
				end
				if (isButton or child.ClassName == "TextLabel") and child.Text ~= "" and not child.TextScaled then
					assert(child.TextSize >= 13, child.Name .. " text under 13 px at " .. where)
					-- Unwrapped text is one line; wrapped text fits its rows.
					local width = Social.textWidth(child.Text, child.TextSize)
					local lines = if child.TextWrapped
						then math.max(1, math.floor(r.height / (child.TextSize * 1.2)))
						else 1
					assert(
						width <= (r.width - 4) * lines,
						string.format(
							"'%s' (%d px) does not fit %d px x %d at %s",
							child.Text,
							width,
							r.width,
							lines,
							where
						)
					)
				end
				walk(child)
			end
		end
	end
	walk(frame)
	assert(buttons >= 8, "tabs, grid and primary rendered at " .. where)
end

-- Scrolls the open menu grid as a player would until `tile` is a whole row inside it, then returns
-- whether the tile (and the grid) sit fully on screen. Mirrors UIGridLayout: cells in LayoutOrder,
-- a gap after each cell, the canvas starting MENU_GAP below the frame top (UIPadding).
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local function menuReach(h: any, tile: any, view: { any }): boolean
	local grid = assert(h.menu:FindFirstChildOfClass("UIGridLayout"), "menu grid layout")
	local cell, gap = grid.CellSize, Panels.MENU_GAP
	local frame = rect(h.menu)
	local columns = math.max(1, (frame.width - Panels.MENU_SCROLLBAR) // (cell.X.Offset + gap))
	local index = 0
	for _, other in h.tiles() do
		if other.Visible then
			if other == tile then
				break
			end
			index += 1
		end
	end
	local top = gap + (index // columns) * (cell.Y.Offset + gap)
	local bottom = top + cell.Y.Offset
	local canvas = h.menu.CanvasSize.Y.Offset
	local scroll = math.clamp(bottom - frame.height, 0, math.max(0, canvas - frame.height))
	h.menu.CanvasPosition = roblox.Vector2.new(0, scroll)
	local x = (index % columns) * (cell.X.Offset + gap)
	local screen = { x = 0, y = 0, width = view[1], height = view[2] }
	return bottom <= canvas
		and top - scroll >= 0
		and bottom - scroll <= frame.height
		and x + cell.X.Offset <= frame.width - Panels.MENU_SCROLLBAR
		and inside(frame, screen)
end

-- D2b fix 4: the SurvivalSheet (bag, craft, skills, build) on the shipped SurvivalHUD.
local function sheetParts(h: any): (any, any, any)
	local gui = assert(h.playerGui:FindFirstChild("ForgeSurvivalHUD"), "survival hud gui")
	local frame = assert(gui:FindFirstChild("SafeArea"):FindFirstChild("SurvivalSheet"), "survival sheet")
	return gui, frame, frame:FindFirstChild("Header"):FindFirstChild("Close")
end
local function overlap(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end
-- The notice lane (status line + MaterialToast) must sit on screen and off every content rect.
local function laneClear(h: any, content: { any }, where: string)
	local gui = h.playerGui:FindFirstChild("ForgeSurvivalHUD")
	for _, name in { "Status", "MaterialToast" } do
		local item = assert(gui:FindFirstChild(name), name)
		local r = h.rect(item)
		assert(r.width > 0 and r.height >= 28, string.format("%s lane %dx%d at %s", name, r.width, r.height, where))
		assert(r.y >= 0 and r.y + r.height <= gui.AbsoluteSize.Y, name .. " lane on screen at " .. where)
		for _, c in content do
			assert(
				not overlap(r, c.rect),
				string.format("%s (%d,%d %dx%d) covers %s at %s", name, r.x, r.y, r.width, r.height, c.name, where)
			)
		end
	end
end

return {
	["D2b 4: SurvivalSheet Close sits below the top-bar band, closes by click, and notices never cover its rows"] = function()
		-- PC 1280x720 (58 px top bar, the D2b capture) and the SM-N981N landscape phone.
		for _, view in { { 1280, 720, 58, false }, { 850, 411, 58, true } } do
			local where = string.format("%dx%d", view[1], view[2])
			local h = harness({ width = view[1], height = view[2], inset = view[3], touch = view[4], realHud = true })
			local _, frame, close = sheetParts(h)
			for _, section in { "bag", "craft", "skills", "build", "skills" } do
				h.hud.open(section)
				h.step()
				assert(frame.Visible, section .. " opens at " .. where)
				local x = h.rect(close)
				-- GuiService.TopbarInset.Max.Y in the gui's space: presses above it never reach the button.
				assert(
					x.y >= view[3] and x.width >= 44 and x.height >= 44,
					string.format("%s Close at y %d inside the %d px top bar band at %s", section, x.y, view[3], where)
				)
				local content: { any } = {}
				if section == "bag" or section == "craft" then
					for _, name in { "Categories", "CraftActions" } do
						table.insert(content, { name = name, rect = h.rect(frame:FindFirstChild(name)) })
					end
					local panes = frame:FindFirstChild("PanelPanes")
					for _, name in { "ItemList", "ItemDetails" } do
						table.insert(content, { name = name, rect = h.rect(panes:FindFirstChild(name)) })
					end
				else
					table.insert(content, { name = section .. " sheet", rect = h.rect(frame) })
				end
				laneClear(h, content, section .. " " .. where)
				h.click(close)
				assert(not frame.Visible, section .. " X closes the sheet at " .. where)
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["D2 F4: the trading post fills 800x360, 850x411 (58 px inset) and 1920x1080 after any device change; X closes it"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			-- Studio order: the panels start on a PC window, the device simulator then switches screens.
			local h = harness({ width = 1279, height = 662, touch = false, locale = locale })
			h.publish({
				market = MARKET,
				["harbor-buyback"] = { prices = { antler = 1 }, dailyUnits = 200, remaining = 7 },
			})
			for _, view in VIEWS do
				h.setViewport(view[1], view[2], view[3])
				h.step()
				assert(#h.sheets() == 0 and h.column.Visible, "dock idle before the market")
				h.click(h.toggle)
				h.click(h.tile("market"))
				checkMarket(h, view, locale)
				local close = h.sheets()[1].close
				h.click(close)
				assert(#h.sheets() == 0, "X closes the trading post at " .. view[1] .. "x" .. view[2])
				assert(h.column.Visible and h.attributes.ForgeExtensionSheetOpen == false, "X returns the menu")
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["D2 F4: an open trading post follows a device change and its X still closes it"] = function()
		local h = harness({ width = 1279, height = 662, touch = false })
		h.publish({ market = MARKET })
		h.step()
		h.click(h.toggle)
		h.click(h.tile("market"))
		for _, view in VIEWS do
			h.setViewport(view[1], view[2], view[3])
			h.step()
			checkMarket(h, view, "ko-kr")
		end
		h.click(h.sheets()[1].close)
		assert(#h.sheets() == 0 and h.column.Visible, "X closes after resizes")
		assert(#h.errors == 0, table.concat(h.errors, "\n"))
	end,
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
	-- D2b (08bc5d0, Studio PC 1280x720): market, shop, audio, music, brawl, home-move,
	-- home-permissions, direct-trade and organizations "opened nothing". 36 tiles with 7 rows on
	-- screen put 8 of them below the fold. Multiplayer is on hold, so the tiles that only act on
	-- other players are held off the grid. Every tile left is reachable in the scrolling grid (a whole
	-- row on screen after scrolling, never clipped) and opens its panel (a sheet, or the HUD sheet for
	-- the bag/craft/build/skills launchers), on the PC and on the 800x360 phone.
	["D2b: every visible menu tile is reachable by scrolling and opens a panel; multiplayer-only tiles are held"] = function()
		local HELD = {
			brawl = true,
			["direct-trade"] = true,
			outpost = true,
			party = true,
			clan = true,
			["clan-membership"] = true,
			["home-permissions"] = true,
			["death-zone"] = true,
		}
		local REQUIRED = { "market", "shop", "audio", "music", "home-move", "organizations" }
		for _, view in { { 1280, 720 - 58, false }, { 1280, 720, false }, { 800, 360, true }, { 799, 339, true } } do
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			-- The slices a Studio onboarding join publishes (D2b census: 36 tiles before this fix), so the
			-- context tiles (camp, death-zone, practice, routes, party) count against the fold too.
			h.publish({
				market = MARKET,
				camp = { role = "guest", hosts = { ["2"] = true } },
				["death-zone"] = { zone = "safe", alive = true },
				operations = {},
				expedition = {
					routes = {},
					party = { members = { "1" }, capacity = 4, invites = {} },
					now = 0,
					facts = {},
				},
			})
			for _, id in { "camp", "operations", "routes" } do
				assert(h.tile(id).Visible, id .. " context tile shown for the fold count")
			end
			local visible = {}
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				assert(not (HELD[id] and tile.Visible), id .. " (multiplayer only) is on the menu")
				if tile.Visible then
					table.insert(visible, tile)
				end
			end
			local at = view[1] .. "x" .. view[2]
			h.click(h.toggle)
			-- D2b fix 10: the phone grid showed 2 rows (108 px). The grid now runs the safe height:
			-- at least 5 whole rows on the 800x360 phone, and the PC shows every tile without scrolling.
			local cell = assert(h.menu:FindFirstChildOfClass("UIGridLayout"), "grid").CellSize.Y.Offset
			local rows = rect(h.menu).height // (cell + Panels.MENU_GAP)
			local columns = (rect(h.menu).width - Panels.MENU_SCROLLBAR)
				// (h.menu:FindFirstChildOfClass("UIGridLayout").CellSize.X.Offset + Panels.MENU_GAP)
			local need = if view[1] >= 1280 then math.ceil(#visible / columns) else 5
			assert(rows >= need, string.format("%d rows on screen, need %d at %s", rows, need, at))
			for _, tile in visible do
				assert(menuReach(h, tile, view), string.sub(tile.Name, 6) .. " not reachable at " .. at)
			end
			h.click(h.toggle)
			for _, id in REQUIRED do
				local tile = h.tile(id)
				assert(tile.Visible, id .. " tile on the menu at " .. at)
			end
			for _, tile in visible do
				local id = string.sub(tile.Name, 6)
				h.step()
				if not h.menu.Visible then
					h.click(h.toggle)
				end
				assert(h.menu.Visible, "menu opens before " .. id)
				assert(menuReach(h, tile, view), id .. " scrolled into view at " .. at)
				h.click(tile)
				if id == "explore" then
					-- Island view is the aerial camera (bound after this section): the menu just gives way.
					assert(not h.menu.Visible, "explore closes the menu")
				elseif LAUNCHERS[id] then
					assert(h.hud.shown, id .. " opens the HUD sheet at " .. at)
					h.hud.close()
				else
					local open = h.sheets()
					assert(#open == 1 and not h.column.Visible, id .. " opens no panel at " .. at)
					h.click(open[1].close)
					assert(#h.sheets() == 0 and h.column.Visible, id .. " X returns the menu at " .. at)
				end
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	-- D2b fix 3 (08bc5d0: ~15 panels were one black sheet of ~9 px centred text, score 2) and fix 10
	-- (phone menu: 6 of 36 tiles in a 108 px scroller, tiles unlabeled on PC). Every docked sheet
	-- opened from its tile is the shell sheet: parchment body, header with icon badge, left-aligned
	-- title and a 44 px close inside the screen, body text >= 14 px at 800x360 and >= 16 px at
	-- 1280x720, left-aligned row text; every menu tile carries a label at least MENU_LABEL_MIN.
	["D2b: docked sheets share the shell look with readable text and every menu tile is labelled"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local body = Theme.sheet.colors.body
		for _, view in { { 800, 360, true, 14 }, { 1280, 720, false, 16 } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			h.publish({ market = MARKET, operations = {} })
			local checked = 0
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				if not tile.Visible then
					continue
				end
				local label = tile:FindFirstChild("MenuLabel")
				assert(label and label.Text ~= "", id .. " tile has no label at " .. at)
				assert(label.TextSize >= Panels.MENU_LABEL_MIN, id .. " tile label under the minimum at " .. at)
				if LAUNCHERS[id] then
					continue
				end
				h.step()
				h.click(h.toggle)
				h.click(tile)
				local open = h.sheets()
				if #open == 1 and open[1].frame:GetAttribute("ForgeShellPanel") == nil then
					local frame, close = open[1].frame, open[1].close
					local header = frame:FindFirstChild("Header")
					-- Components.modalSheet sheets (Header + Content scroll); the sea chart draws its own map.
					if header and frame:FindFirstChild("Content") then
						checked += 1
						local function walk(item: any)
							for _, child in item:GetChildren() do
								local text = child.ClassName == "TextLabel" or child.ClassName == "TextButton"
								if text and child.Visible ~= false and child.Text ~= "" and not child.TextScaled then
									assert(
										child.TextSize >= view[4],
										string.format(
											"%s: %q is %d px (< %d) at %s",
											id,
											child.Text,
											child.TextSize,
											view[4],
											at
										)
									)
									if child.ClassName == "TextLabel" and item.Name == "Content" then
										assert(
											child.TextXAlignment == roblox.Enum.TextXAlignment.Left,
											string.format("%s: row %q is not left-aligned at %s", id, child.Text, at)
										)
									end
								end
								walk(child)
							end
						end
						walk(frame)
						local c = frame.BackgroundColor3
						assert(
							math.floor(c.R * 255 + 0.5) == body.r and math.floor(c.G * 255 + 0.5) == body.g,
							id .. " sheet body is not the shell parchment at " .. at
						)
						assert(header:FindFirstChild("ShellIcon"), id .. " header has no icon at " .. at)
						local title = assert(header:FindFirstChild("Title"), id .. " title")
						assert(title.TextXAlignment == roblox.Enum.TextXAlignment.Left, id .. " title centred")
						assert(title.TextSize >= view[4] + 2, id .. " title under " .. (view[4] + 2) .. " px at " .. at)
						local x = rect(close)
						assert(x.width >= 44 and x.height >= 44, id .. " close under 44 px at " .. at)
						assert(
							x.x >= 0 and x.y >= 0 and x.x + x.width <= view[1] and x.y + x.height <= view[2],
							id .. " close off screen at " .. at
						)
					end
				end
				for _, sheet in h.sheets() do
					h.click(sheet.close)
				end
				h.hud.close()
			end
			assert(checked >= 12, checked .. " shell sheets checked at " .. at)
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["U3b: every menu tile and sheet header shows a pack icon or a clean glyph, never an empty dark square"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local missing: { string } = {}
		-- An icon badge reads as an empty slot when its frame is filled and it shows no art: the glyph
		-- is hidden only by a published Asset image (IconFallback hides it once the image loads).
		local function clean(badge: any, where: string)
			assert(badge and badge.ClassName == "Frame", "icon badge at " .. where)
			assert(badge.BackgroundTransparency == 1, "filled (dark square) icon badge at " .. where)
			local asset, glyph = badge:FindFirstChild("Asset"), badge:FindFirstChild("Glyph")
			local image = asset ~= nil and asset.Image ~= nil and asset.Image ~= ""
			assert(image or (glyph and glyph:FindFirstChild("Shape1")), "no art and no glyph at " .. where)
			return image
		end
		for _, view in { { 800, 360, true }, { 1280, 720, false } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], touch = view[3] })
			h.publish({ market = MARKET, operations = {} })
			for _, tile in h.tiles() do
				local id = string.sub(tile.Name, 6)
				if tile.Visible then
					if not clean(tile:FindFirstChild("MenuIconFallback"), id .. " tile at " .. at) then
						table.insert(missing, id)
					end
				end
				if not tile.Visible or LAUNCHERS[id] then
					continue
				end
				h.step()
				h.click(h.toggle)
				h.click(tile)
				for _, sheet in h.sheets() do
					local header = sheet.frame:FindFirstChild("Header")
					if
						header
						and sheet.frame:FindFirstChild("Content")
						and sheet.frame:GetAttribute("ForgeShellPanel") == nil
					then
						clean(header:FindFirstChild("ShellIcon"), id .. " header at " .. at)
					end
				end
				for _, sheet in h.sheets() do
					h.click(sheet.close)
				end
				h.hud.close()
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
		-- Every visible dock id has published art (assets/icons + manifest), not just the glyph.
		assert(#missing == 0, "dock ids without a pack icon: " .. table.concat(missing, ", "))
		assert(Theme.sheet ~= nil, "sheet tokens")
	end,
	["U3b: bag, craft, skills and build sheets wear the shell tokens with 14/16 px text floors"] = function()
		local Theme = require("../../core/ui-kit/Theme")
		local C = Theme.sheet.colors
		local function same(c: any, token: any): boolean
			return math.floor(c.R * 255 + 0.5) == token.r
				and math.floor(c.G * 255 + 0.5) == token.g
				and math.floor(c.B * 255 + 0.5) == token.b
		end
		local actions = {}
		for _, verb in { "food", "gear-equip", "transfer-deposit", "craft-reserve", "recipe-mark", "skill-learn" } do
			table.insert(actions, "survival-coop:" .. verb)
		end
		local function stack(id: string, catalogId: string, quantity: number): any
			return {
				itemId = id,
				catalogId = catalogId,
				quantity = quantity,
				qualityMilli = 1000,
				durabilityMilli = 1000,
			}
		end
		local packet = {
			revision = 1,
			durable = { actions = actions, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					balance = 100,
					vitals = { healthMilli = 90000, hungerMilli = 70000, fatigueMilli = 20000 },
					progression = { level = 2, sp = 4, xp = 10, paid = {}, version = 1 },
					inventory = {
						{
							kind = "carried",
							items = { a = stack("a", "bone", 5), b = stack("b", "fiber", 12) },
							reservations = {},
							limits = { slots = 20, softWeightMilli = 40000, hardWeightMilli = 60000 },
							weightMilli = 2000,
						},
					},
				},
				survivalExtensions = {},
			},
		}
		-- 800x360 phone (floor 14) and 1280x720 PC (floor 16), plus U4's 58 px top bar on PC.
		for _, view in { { 800, 360, 0, true, 14 }, { 1280, 720, 58, false, 16 } } do
			local at = view[1] .. "x" .. view[2]
			local h = harness({ width = view[1], height = view[2], inset = view[3], touch = view[4], realHud = true })
			h.packet(packet)
			local _, frame, close = sheetParts(h)
			for _, section in { "bag", "craft", "skills", "build" } do
				local where = section .. " " .. at
				h.hud.open(section)
				h.step()
				assert(frame.Visible, section .. " open at " .. at)
				assert(same(frame.BackgroundColor3, C.body), where .. ": body is not the shell parchment")
				assert(same(frame:FindFirstChild("Header").BackgroundColor3, C.header), where .. ": header not leather")
				assert(same(close.BackgroundColor3, C.close), where .. ": close not the shell close")
				local x = h.rect(close)
				assert(x.width >= 44 and x.height >= 44 and x.y >= view[3], where .. ": close 44 px below the top bar")
				local rows, counts = 0, 0
				local function walk(item: any)
					for _, child in item:GetChildren() do
						if child.Visible == false then
							continue
						end
						local class = child.ClassName
						if (class == "TextLabel" or class == "TextButton") and child.Text ~= "" then
							assert(not child.TextScaled, string.format("%s: %q is TextScaled", where, child.Text))
							assert(
								child.TextSize >= view[5],
								string.format("%s: %q is %d px (< %d)", where, child.Text, child.TextSize, view[5])
							)
							if child.Name == "RowCount" or child.Name == "Quantity" then
								counts += 1
								assert(
									child.TextXAlignment == roblox.Enum.TextXAlignment.Right,
									where .. ": count " .. child.Text .. " not right-aligned"
								)
							elseif
								class == "TextLabel"
								and child.Parent.ClassName ~= "TextButton"
								and child.Name ~= "Currency"
							then
								rows += 1
								assert(
									child.TextXAlignment == roblox.Enum.TextXAlignment.Left,
									string.format("%s: row %q is not left-aligned", where, child.Text)
								)
							end
						end
						if class == "Frame" and child.Name == "IconFallback" then
							assert(
								child.BackgroundTransparency == 1,
								where .. ": dark icon square in " .. child.Parent.Name
							)
						end
						walk(child)
					end
				end
				walk(frame)
				assert(rows > 0, where .. ": no rows")
				if section == "bag" or section == "craft" then
					assert(counts > 0, where .. ": no item counts")
				end
				laneClear(h, { { name = section .. " close", rect = x } }, where)
				h.click(close)
				assert(not frame.Visible, where .. ": X closes")
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["U3b: character and guides show an empty state, not the failure line, before any record exists"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			local h = harness({ width = 800, height = 360, touch = true, locale = locale })
			h.publish({})
			for _, id in { "character", "guides" } do
				h.step()
				h.click(h.toggle)
				h.click(h.tile(id))
				local open = h.sheets()
				assert(#open == 1, id .. " opens")
				local texts = {}
				for _, item in open[1].frame:GetDescendants() do
					if (item.ClassName == "TextLabel" or item.ClassName == "TextButton") and item.Text ~= "" then
						table.insert(texts, item.Text)
					end
				end
				local all = table.concat(texts, "|")
				assert(
					not string.find(all, "실패", 1, true) and not string.find(all, "did not work", 1, true),
					id .. ": " .. all
				)
				local expected = if locale == "ko-kr" then "아직 없어요" else "Nothing here yet"
				assert(string.find(all, expected, 1, true), id .. " empty state missing: " .. all)
				h.click(open[1].close)
			end
			assert(#h.errors == 0, table.concat(h.errors, "\n"))
		end
	end,
	["L9: the down panel renders its cards with pack art and no script error"] = function()
		local h = harness({ width = 800, height = 360, touch = true })
		h.publish({ rescue = { down = true, options = { "rift", "camp", "rescue" }, flares = {} } })
		h.publish({ rescue = { down = true, options = { "rift", "camp", "rescue" }, flares = {} } })
		assert(#h.errors == 0, table.concat(h.errors, "; "))
		local gui = assert(h.playerGui:FindFirstChild("ForgeDownPanel"), "down panel gui")
		assert(gui.Enabled == true, "down panel shows while down")
		local shown = 0
		for _, card in gui:GetDescendants() do
			if card.Name == "DownCard" and card.Visible then
				local inner = card:FindFirstChild("Icon") and card.Icon:FindFirstChild("Image")
				assert(
					inner and string.match(inner.Image, "^rbxassetid://%d+$"),
					"card art for " .. tostring(card:GetAttribute("ForgeIcon"))
				)
				shown += 1
			end
		end
		assert(shown == 3, "three down cards, got " .. shown)
	end,
}
