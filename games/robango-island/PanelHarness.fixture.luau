--!strict
-- Fake-engine harness for the shipped robango panel wiring (moved out of dock-close.spec so the
-- trading post sheet spec runs on the same engine): RobangoIslandClient's ExtensionPanels.start
-- section, every real panel module and the real ui-kit Components, optionally the real SurvivalHUD.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox: any = require("@lune/roblox")
local PackText = require("./PackText.fixture")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"

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
		elseif kind == "BasePart" then
			return self.ClassName == "Part" or self.ClassName == "BasePart"
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
	function methods.FindFirstChild(self, name, recursive)
		for _, child in rawget(getmetatable(self) :: any, "data").children do
			if child.Name == name then
				return child
			end
			if recursive then
				local found = methods.FindFirstChild(child, name, true)
				if found then
					return found
				end
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
	-- opts.invoke(remote, ...): a spec bridges ForgeAction (and other RemoteFunctions) to a real server.
	function methods.InvokeServer(self, ...)
		if opts.invoke then
			return opts.invoke(self, ...)
		end
		return { ok = false, reason = "COMMAND_UNAVAILABLE" }
	end
	function methods.FireServer() end
	-- BindableEvent:Fire -> its Event (SurvivalHUD's ForgeHUDResult / ForgeHUDRequested).
	function methods.Fire(self, ...)
		self.Event:Fire(...)
	end
	function methods.CaptureFocus() end
	function methods.ReleaseFocus() end
	function methods.GetServerTimeNow()
		return if opts.serverNow then opts.serverNow() else 0
	end
	function methods.AddTag() end
	function methods.Raycast()
		return nil
	end
	function methods.GetPartBoundsInBox()
		return {}
	end
	-- Camera: every world point projects off the right edge, in front (the waypoint arrow clamps).
	function methods.WorldToViewportPoint()
		return roblox.Vector3.new(100000, 100, 10), false
	end
	methods.WorldToScreenPoint = methods.WorldToViewportPoint
	function methods.PivotTo(self, cframe)
		rawget(getmetatable(self) :: any, "data").pivot = cframe
	end
	function methods.GetPivot(self)
		return rawget(getmetatable(self) :: any, "data").pivot or roblox.CFrame.new()
	end
	function methods.Play() end
	function methods.Stop() end

	local player = node("Player", "Player")
	player.UserId, player.DisplayName, player.LocaleId = opts.userId or 1, "Player", locale
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
	-- The minimap pin reads the camera heading (recursive FindFirstChild now finds the minimap frame).
	workspace.CurrentCamera.CFrame = roblox.CFrame.new()
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
		return if id == player.UserId then player else nil
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
	-- opts.guidPrefix: a fresh client per server (journey6h) must not reuse the last one's ids.
	local guid = 0
	function services.HttpService.GenerateGUID()
		guid += 1
		return (opts.guidPrefix or "guid-") .. guid
	end
	services.UserInputService.TouchEnabled = opts.touch ~= false
	services.UserInputService.KeyboardEnabled = opts.touch == false
	function services.UserInputService.GetFocusedTextBox()
		return nil
	end
	-- opts.tagged(tag) -> client instances (journey6h mirrors the server's station parts).
	function services.CollectionService.GetTagged(_, tag)
		return if opts.tagged then opts.tagged(tag) else {}
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
	-- opts.clock: os.clock on the spec's clock (journey6h); toasts and travel lines expire in sim time.
	if opts.clock then
		local fake = table.clone(os)
		fake.clock = opts.clock
		base.os = fake
	end
	base.RaycastParams = {
		new = function()
			return {}
		end,
	}
	base.OverlapParams = base.RaycastParams
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
		delay = function(seconds, fn, ...)
			-- opts.delayed: a spec queues delayed work and runs it on its own clock (journey6h).
			if opts.delayed and type(fn) == "function" then
				table.insert(opts.delayed, { seconds = seconds or 0, fn = fn, args = table.pack(...) })
			end
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
	if opts.multiplayer then
		-- game.yml play_mode.solo = false: the multiplayer surfaces these tests cover are all routed.
		local mode = table.clone(require("./src/shared/PlayMode"))
		mode.solo = false
		cache["games/robango-island/src/shared/PlayMode"] = mode
	end
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
	local section = string.sub(client, first, last - 1) .. "\nreturn {panels = panels, petRing = petRing}\n"
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
				-- The client passes PlayMode's chat / clan-tag switches (RobangoIslandClient shell).
				pet = {
					capturable = function()
						return env.petRing ~= nil and env.petRing.capturable()
					end,
					act = function(id)
						if env.petRing then
							env.petRing.act(id)
						end
					end,
				},
				chat = opts.chat,
				clanTag = opts.clanTag,
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
			settlementOrigin = opts.settlementOrigin or roblox.Vector3.new(0, 0, 0),
			bagBuild = opts.bagBuild,
			solo = opts.solo,
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
	local captureContext: any = nil
	local petModule = load("genres/survival-coop/module/PetRing")
	local petFactory = petModule.factory
	petModule.factory = function(ctx)
		captureContext = ctx
		return petFactory(ctx)
	end
	local handles = luau.load(section, { debugName = CLIENT, environment = env })()
	local panels = handles.panels
	env.petRing = handles.petRing
	local dock = assert(playerGui:FindFirstChild("ForgePanelDock"), "dock gui")
	local h: any = {
		errors = errors,
		heartbeat = heartbeat,
		attributes = attributes,
		playerGui = playerGui,
		hud = hud,
		panels = panels,
		petRing = handles.petRing,
		load = load,
		captureSend = function(action, args)
			return captureContext.send(action, args)
		end,
		player = player,
		workspace = workspace,
		game = game,
		new = node,
	}
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

return { harness = harness, signal = signal }
