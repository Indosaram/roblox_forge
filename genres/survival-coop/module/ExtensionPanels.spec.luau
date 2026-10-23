--!strict
local Panels = require("./ExtensionPanels")
local Model = require("./SurvivalHUDModel")
local fs = require("@lune/fs")

local function signal(): any
	local callbacks: { () -> () } = {}
	return {
		Connect = function(_self, callback)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		fire = function()
			for _, callback in callbacks do
				callback()
			end
		end,
	}
end

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

-- Real ContractsPanel inside the real contextual dock, on a minimal fake engine.
local function contractsDock(locale: string, width: number, height: number, surveys: { number }?): any
	local nodes: { any } = {}
	local attributes: { [string]: any } = {}
	local heartbeat, stateEvent = signal(), { handlers = {} :: { any } }
	function stateEvent.OnClientEvent_Connect(callback)
		table.insert(stateEvent.handlers, callback)
	end
	local dimension = {
		new = function(xs, xo, ys, yo)
			return { xs or 0, xo or 0, ys or 0, yo or 0 }
		end,
		fromOffset = function(x, y)
			return { 0, x, 0, y }
		end,
		fromScale = function(x, y)
			return { x, 0, y, 0 }
		end,
	}
	local methods: any = {}
	methods.__index = methods
	function methods:IsA(kind)
		return kind == "GuiObject" or kind == "BasePart" or self.ClassName == kind
	end
	function methods:Destroy()
		self.Parent = nil
	end
	function methods:GetChildren()
		local out = {}
		for _, item in nodes do
			if item.Parent == self then
				table.insert(out, item)
			end
		end
		return out
	end
	function methods:FindFirstChild(name)
		for _, item in nodes do
			if item.Parent == self and item.Name == name then
				return item
			end
		end
		return nil
	end
	function methods:FindFirstChildOfClass(): any
		return nil
	end
	function methods:FindFirstAncestorWhichIsA(kind)
		local current = self.Parent
		while current and current.ClassName ~= kind do
			current = current.Parent
		end
		return current
	end
	function methods:SetAttribute(key, value)
		self.attributes[key] = value
	end
	function methods:GetAttribute(key)
		return self.attributes[key]
	end
	function methods:IsDescendantOf()
		return true
	end
	methods.GetPropertyChangedSignal = signal
	local function node(class: string?): any
		local item = setmetatable({
			ClassName = class or "Frame",
			Name = class or "Frame",
			Visible = true,
			DisplayOrder = 0,
			attributes = {},
			AbsoluteSize = { X = width, Y = height },
			AbsoluteContentSize = { X = 0, Y = 0 },
			Activated = signal(),
		}, methods)
		table.insert(nodes, item)
		return item
	end
	local function vec(x: number, y: number, z: number?): any
		local depth: number = z or 0
		return setmetatable({ X = x, Y = y, Z = depth, Magnitude = math.sqrt(x * x + y * y + depth * depth) }, {
			__sub = function(a: any, b: any)
				return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
			end,
		})
	end
	local root = node("Part")
	root.Name, root.Position = "HumanoidRootPart", vec(0, 0, 0)
	local character = node("Model")
	root.Parent = character
	local fern = node("Part")
	fern.Position = vec(6, 0, 0)
	fern.attributes = { ForgeNodeDepleted = false, ForgeNodeCount = 2, ForgeNodeItem = "fiber" }
	local targets = {}
	for _, distance in (surveys or {}) :: { number } do
		local target = node("Part")
		target.Position = vec(0, 0, distance)
		table.insert(targets, target)
	end
	local playerGui = node("PlayerGui")
	local player: any = { Character = character, PlayerGui = playerGui, UserId = 7 }
	function player:WaitForChild()
		return playerGui
	end
	function player:GetAttribute(key)
		return attributes[key]
	end
	function player:SetAttribute(key, value)
		attributes[key] = value
	end
	local services = {
		Players = { LocalPlayer = player },
		ReplicatedStorage = {
			WaitForChild = function(_self, name): any
				if name == "ForgeState" then
					return {
						OnClientEvent = {
							Connect = function(_s, callback)
								stateEvent.OnClientEvent_Connect(callback)
								return { Disconnect = function() end }
							end,
						},
					}
				end
				return {
					InvokeServer = function()
						return {
							ok = false,
							reason = "INSUFFICIENT_ITEMS",
							data = { item = "wood", need = 3, have = 0 },
							stateVersion = 1,
						}
					end,
				}
			end,
		},
		HttpService = {
			JSONEncode = function(_self, value)
				return tostring(value)
			end,
			GenerateGUID = function()
				return "request"
			end,
		},
		UserInputService = { TouchEnabled = width < 700 },
		RunService = { Heartbeat = heartbeat },
		ProximityPromptService = { PromptTriggered = signal() },
		CollectionService = {
			GetTagged = function(_self, tag)
				return if tag == "ForgeSurvey" then targets else { fern }
			end,
		},
		Workspace = {
			Raycast = function(): any
				return nil
			end,
			GetAttribute = function(): any
				return nil
			end,
		},
	}
	local enum: any = setmetatable({}, {
		__index = function(_self, key: string)
			return setmetatable({}, {
				__index = function(_group, value: string)
					return key .. "." .. value
				end,
			})
		end,
	})
	local environment: any = table.clone(getfenv())
	environment.game = {
		GetService = function(_self, name)
			return services[name]
		end,
	}
	environment.task = {
		spawn = function(callback, ...)
			callback(...)
		end,
	}
	environment.Instance, environment.Enum = { new = node }, enum
	environment.UDim, environment.UDim2 = dimension, dimension
	environment.Vector2 = { new = vec, zero = vec(0, 0, 0) }
	environment.Color3 = { fromRGB = function() end }
	environment.RaycastParams = { new = node }
	local function load(path: string): any
		local chunk = assert(loadstring(fs.readFile(path)))
		setfenv(chunk, environment)
		return chunk()
	end
	local contracts
	environment.require = function(path): any
		if path == "./SurvivalHUDModel" then
			return Model
		elseif path == "./SurvivalHUDLocale" then
			return require("./SurvivalHUDLocale")
		elseif path == "../../../core/ui-kit/Layout" then
			return require("../../../core/ui-kit/Layout")
		elseif path == "../../../core/infra/genre/CommandTransport" then
			return require("../../../core/infra/genre/CommandTransport")
		elseif path == "./ContractsPanel" then
			return contracts
		elseif path == "./CharacterText" then
			return require("./CharacterText")
		end
		return { factory = function() end, mount = function() end }
	end
	contracts = load("genres/survival-coop/module/ContractsPanel.luau")
	local clicks: { [string]: () -> () } = {}
	local function make(props: any): any
		local item = node("TextLabel")
		item.Text, item.Size, item.Position, item.Parent = props.text, props.size, props.position, props.parent
		return item
	end
	local components = {
		label = function(_theme, props)
			return make(props)
		end,
		button = function(_theme, props)
			local item = make(props)
			item.ClassName = "TextButton"
			clicks[item] = props.onClick
			return item
		end,
		modalSheet = function(_theme, props)
			local frame = node()
			frame.Name, frame.Visible = props.name, false
			local scroll = node("ScrollingFrame")
			scroll.Name, scroll.Parent = "Content", frame
			scroll.Position, scroll.Size = dimension.fromOffset(0, 44), dimension.new(1, 0, 1, -44)
			return { frame = frame, scroll = scroll, close = node("TextButton") }
		end,
	}
	load("genres/survival-coop/module/ExtensionPanels.luau").start({
		contextual = true,
		locale = locale,
		names = { wood = if locale == "en-us" then "Driftwood" else "쓰러진 통나무" },
		factories = { contracts.factory },
		ui = {
			components = components,
			theme = {
				default = {},
				merge = function()
					return {}
				end,
			},
		},
	})
	local function find(name: string): any
		for _, item in nodes do
			if item.Name == name and item.Parent then
				return item
			end
		end
		return nil
	end
	local function push(step: string)
		local offer = {
			id = "survey-driftwood",
			accepted = true,
			reward = {},
			trust = 10,
			deliver = { { item = "wood", quantity = 3 } },
		}
		for _, callback in stateEvent.handlers do
			callback({
				durable = {
					actions = { "survival-coop:contract-deliver" },
					epochs = { ["survival-coop:contract-deliver"] = 1 },
				},
				snapshots = {
					survivalExtensions = {
						contracts = {
							offers = { offer },
							trust = {},
							tutorial = { step = step, hint = "tutorial." .. step },
						},
					},
				},
			})
		end
	end
	local function shown(item: any): boolean
		while item and item ~= playerGui do
			if item.Visible == false then
				return false
			end
			item = item.Parent
		end
		return item == playerGui
	end
	return {
		find = find,
		targets = targets,
		push = push,
		shown = shown,
		tick = function()
			heartbeat:fire()
		end,
		click = function(item)
			clicks[item]()
		end,
	}
end

-- Offset rect of a {xs, xo, ys, yo} UDim2 pair inside a parent rect.
local function resolve(parent: any, position: any, size: any): any
	local w, h = size[1] * parent.width + size[2], size[3] * parent.height + size[4]
	return {
		x = position[1] * parent.width + position[2],
		y = position[3] * parent.height + position[4],
		width = w,
		height = h,
	}
end

return {
	["a short delivery refusal shows inside the open contracts sheet and survives gather hints"] = function()
		local cases: { { any } } = {
			{ "ko-kr", 360, 640, "가방에 쓰러진 통나무 3개를 들고 오세요 (현재 0개)." },
			{ "en-us", 1280, 720, "Carry Driftwood x3 in your bag (have 0)." },
		}
		for _, case in cases do
			local locale, width, height, expected =
				case[1] :: string, case[2] :: number, (case[3] :: number) - 56, case[4] :: string
			local dock = contractsDock(locale, width, height)
			dock.push("gather")
			local board = assert(dock.find("ContractBoard"), "contracts sheet")
			board.Visible = true
			dock.tick()
			local tracker = assert(dock.find("ObjectiveTracker"), "tracker")
			assert(not dock.shown(tracker), "open sheet hides the dock tracker")
			assert(string.find(tracker.Text, "fiber (6m)", 1, true), "gather hint active: " .. tracker.Text)
			dock.click(assert(dock.find("Deliver-survey-driftwood"), "deliver button"))
			local notice = dock.find("Notice")
			assert(notice and notice.Parent == board, "refusal lives in the sheet")
			assert(dock.shown(notice) and notice.Text == expected, tostring(notice.Text))
			dock.push("gather")
			dock.tick()
			assert(tracker.Text == expected, "gather hint kept the refusal: " .. tracker.Text)
			assert(dock.shown(notice) and notice.Text == expected, "equal snapshot keeps the notice")
			-- Fitted geometry: the notice sits inside the sheet and below the scrolling rows.
			local sheet = { x = 0, y = 0, width = board.Size[2], height = board.Size[4] }
			local rect = resolve(sheet, notice.Position, notice.Size)
			local scroll = dock.find("Content")
			local rows = resolve(sheet, scroll.Position, scroll.Size)
			assert(rect.x >= 0 and rect.y >= 0, "notice inside sheet")
			assert(rect.x + rect.width <= sheet.width and rect.y + rect.height <= sheet.height, "notice clipped")
			assert(rect.height >= 40 and rect.width >= 200, "notice readable")
			assert(not overlaps(rect, rows), "notice clears the Deliver row area")
			assert(rows.height >= 44 * 2, "Deliver row still visible")
		end
	end,
	["survey target distance shows outside the gather step and yields to contract notices"] = function()
		for _, case in { { "ko-kr", "조사: 50m" }, { "en-us", "Survey: 50m" } } do
			local dock = contractsDock(case[1], 1280, 664, { 80, 50 })
			dock.push("settle")
			dock.tick()
			local tracker = assert(dock.find("ObjectiveTracker"), "tracker")
			assert(tracker.Text == case[2], "survey hint: " .. tracker.Text)
			dock.targets[2]:SetAttribute("ForgeSurveyed7", true)
			dock.tick()
			assert(tracker.Text == string.gsub(case[2], "50", "80"), "completed target skipped: " .. tracker.Text)
			dock.click(assert(dock.find("Deliver-survey-driftwood"), "deliver button"))
			local notice = assert(dock.find("Notice"), "notice").Text
			dock.tick()
			assert(tracker.Text == notice and notice ~= "", "contract notice wins: " .. tracker.Text)
			local bare = contractsDock(case[1], 1280, 664)
			bare.push("settle")
			bare.tick()
			local text = assert(bare.find("ObjectiveTracker"), "tracker").Text
			assert(not string.find(text, "m$") and not string.find(text, "Survey", 1, true), "no hint: " .. text)
		end
	end,
	["biome entry toast fades after three seconds and reentry restarts it"] = function()
		local left, alpha = Model.biomeToast("landing", "forest", 0, 0)
		assert(left == 3 and alpha == 0, "entry starts visible")
		left, alpha = Model.biomeToast("forest", "forest", left, 2.5)
		assert(left == 0.5 and alpha == 0.5, "last second fades")
		left, alpha = Model.biomeToast("forest", "forest", left, 0.5)
		assert(left == 0 and alpha == 1, "three seconds expires")
		left, alpha = Model.biomeToast("forest", "forest", left, 10)
		assert(left == 0 and alpha == 1, "staying does not restart")
		left, alpha = Model.biomeToast("forest", "marsh", left, 0)
		assert(left == 3 and alpha == 0, "next biome restarts")
	end,
	["sheet close and build action surfaces stay separate at all target sizes"] = function()
		for _, size in { { 360, 640 }, { 360, 620 }, { 640, 360 }, { 1280, 720 }, { 1920, 1080 } } do
			local width, height = size[1], size[2] - 56
			local w, h, top, right = Model.contextSheetBounds(width, height, width < 700)
			local close = { x = width - right - 50, y = top, width = 44, height = 44 }
			local bar = { x = (width - 328) / 2, y = height - 72, width = 328, height = 48 }
			local toast = { x = 12, y = height - 184, width = width - 24, height = 52 }
			assert(w <= 720 and h >= 44 and top >= 0, "sheet bounded and header visible")
			assert(close.x >= 0 and close.x + close.width <= width, "44 pixel close within viewport")
			assert(not overlaps(close, bar) and not overlaps(close, toast), "close clears actions and toast")
			assert(not overlaps(bar, toast), "shortage toast clears bottom actions")
		end
	end,
	["every registered menu activation opens exactly its sheet at phone and desktop sizes"] = function()
		local registered = {}
		local sources = { "games/robango-island/src/client/RobangoIslandClient.client.luau" }
		for _, name in
			{
				"ContractsPanel",
				"TamingPanel",
				"CampPanel",
				"ShopPanel",
				"CrossServerMarketPanel",
				"DeathZonePanel",
				"BrawlPanel",
				"ScoreEditorPanel",
			}
		do
			table.insert(sources, "genres/survival-coop/module/" .. name .. ".luau")
		end
		for _, path in sources do
			for id in fs.readFile(path):gmatch('id = "([%w%-]+)",%s*label =') do
				registered[id] = true
			end
		end
		-- Clan.mount shares a dynamic ID with Outpost.factory.
		registered.clan, registered.outpost = true, true
		for _, viewport in { { 360, 640 }, { 1920, 1080 } } do
			local buttons, visibility, entries = {}, {}, {}
			local launchers = {}
			local function node(): any
				return {
					AbsoluteSize = { X = viewport[1], Y = viewport[2] },
					AbsoluteContentSize = { X = 0, Y = 0 },
					GetPropertyChangedSignal = signal,
					Destroy = function() end,
				}
			end
			local player: any = {
				WaitForChild = node,
				PlayerGui = {
					FindFirstChild = function()
						return nil
					end,
				},
			}
			local storage = {
				WaitForChild = function(_self, name)
					return if name == "ForgeState" then { OnClientEvent = signal() } else {}
				end,
			}
			local services = {
				ReplicatedStorage = storage,
				HttpService = {},
				Players = { LocalPlayer = player },
				UserInputService = { TouchEnabled = false },
				RunService = { Heartbeat = signal() },
				ProximityPromptService = { PromptTriggered = signal() },
			}
			local enum: any = setmetatable({}, {
				__index = function()
					return {}
				end,
			})
			local dimension = {
				new = function(...)
					return { ... }
				end,
				fromOffset = function(...)
					return { ... }
				end,
				fromScale = function(...)
					return { ... }
				end,
			}
			local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")))
			local environment: any = table.clone(getfenv())
			environment.game = {
				GetService = function(_self, name)
					return services[name]
				end,
			}
			environment.Instance, environment.Enum = { new = node }, enum
			environment.UDim, environment.UDim2, environment.Vector2 = dimension, dimension, dimension
			environment.require = function(path): any
				if path == "../../../core/ui-kit/Layout" then
					return require("../../../core/ui-kit/Layout")
				elseif path == "./SurvivalHUDModel" then
					return Model
				end
				return { factory = function() end }
			end
			setfenv(chunk, environment)
			local runtime = chunk()
			local factories = {}
			table.insert(factories, function(ctx: any)
				local owner: any = { DisplayOrder = 25 }
				ctx.fitSheet({
					FindFirstAncestorWhichIsA = function()
						return owner
					end,
				})
				assert(owner.DisplayOrder == 25, "membership input retains priority above clan and brawl sheets")
				assert(
					owner.ZIndexBehavior == enum.ZIndexBehavior.Sibling,
					"sheet controls render above their scroll parent"
				)
			end)
			for id in registered do
				if table.find({ "bag", "craft", "build", "skills", "explore" }, id) then
					visibility[id] = false
					table.insert(launchers, {
						id = id,
						label = id,
						open = function()
							for other in visibility do
								visibility[other] = other == id
							end
						end,
					})
					continue
				end
				table.insert(factories, function(ctx)
					visibility[id] = false
					local entry = {
						id = id,
						label = id,
						order = 1,
						setOpen = function(open)
							visibility[id] = open
						end,
						isOpen = function()
							return visibility[id]
						end,
					}
					entries[id] = entry
					ctx.dock(entry)
					return { destroy = function() end }
				end)
			end
			local started = runtime.start({
				locale = "ko-kr",
				factories = factories,
				launchers = launchers,
				onOpen = function()
					for _, launcher in launchers do
						visibility[launcher.id] = false
					end
				end,
				ui = {
					theme = {
						default = {},
						merge = function()
							return {}
						end,
					},
					components = {
						button = function(_theme, props)
							local button = node()
							buttons[props.text] = props.onClick
							return button
						end,
					},
				},
			})
			for id in registered do
				buttons[id]()
				buttons[id]()
				for other, visible in visibility do
					assert(visible == (other == id), "only activated panel visible: " .. id .. " / " .. other)
				end
			end
			-- Finish on a docked panel, since HUD-owned sheets close through hud.close.
			buttons.contracts()
			started.closeAll()
			for _, visible in visibility do
				assert(not visible, "close all")
			end
			started.destroy()
		end
	end,
	["context menu tiles and HUD clear topbar and mobile control zones at target viewports"] = function()
		for _, size in { { 360, 640 }, { 640, 360 }, { 1280, 720 }, { 1920, 1080 } } do
			-- ScreenGui consumes the topbar inset; model coordinates are in the remaining safe area.
			local width, height = size[1], size[2] - 56
			local menuWidth, columns, tileHeight, top = Panels.menuBounds(width, height)
			local menu = {
				x = (width - menuWidth) / 2,
				y = top,
				width = menuWidth,
				height = math.ceil(19 / columns) * (tileHeight + 6) - 6,
			}
			local stick = { x = 0, y = height - 128, width = 128, height = 128 }
			local jump = { x = width - 128, y = height - 128, width = 128, height = 128 }
			assert(menuWidth <= 720 and menu.x >= 0 and menu.y >= 0, "centered menu respects safe area")
			menu.height = math.min(menu.height, math.max(0, height - top - 128))
			assert(not overlaps(menu, stick) and not overlaps(menu, jump), "scroll viewport clears movement zones")
			local hud = Model.contextHudBounds(width, height)
			assert(not overlaps(menu, hud.menu), "card grid clears menu toggle")
			local chat = { x = 0, y = 0, width = 540, height = 320 }
			for _, key in { "vitals", "objective", "menu", "biome" } do
				for _, other in { "vitals", "objective", "menu", "biome" } do
					assert(key == other or not overlaps(hud[key], hud[other]), key .. " overlaps " .. other)
				end
				assert(width < 1000 or not overlaps(hud[key], chat), key .. " overlaps desktop chat")
			end
			assert(hud.objective.y >= hud.vitals.y + hud.vitals.height, "objective below vitals")
			assert(hud.objective.y >= hud.menu.y + hud.menu.height, "objective below menu")
			for _, rect in hud do
				assert(rect.y >= 0 and rect.x >= 0 and rect.x + rect.width <= width, "HUD within topbar safe area")
				assert(not overlaps(rect, stick) and not overlaps(rect, jump), "HUD clears joystick and jump")
			end
			-- Opening any sheet/photo mode hides vitals/objective; they are mutually exclusive surfaces.
			assert(hud.photo.y + hud.photo.height <= height - 128, "photo controls fit above movement zones")
		end
	end,
	["stage objective text lists the current stage objectives with progress"] = function()
		local content = {
			stages = {
				{
					layout = "rw.a1.s1",
					objectives = { { id = "g", action = "gather", target = "wood", quantity = 5 } },
				},
				{ layout = "rw.a1.s1", objectives = { { id = "s", action = "survey", target = "m", quantity = 1 } } },
				{
					layout = "rw.a1.s2",
					objectives = { { id = "c", action = "craft", target = "dry-twig", quantity = 1 } },
				},
			},
		}
		local state = { status = "active", templateId = "rw.a1", stage = 1, progress = { g = 2 }, completed = {} }
		local ko = Panels.stageObjectiveText(state, content, "ko-kr", { wood = "나무" })
		assert(ko == "나무 2/5 · 조사 0/1", tostring(ko))
		state.completed.s = true
		assert(Panels.stageObjectiveText(state, content, "en-us", { wood = "Wood" }) == "Wood 2/5 · Survey 1/1", "en")
		state.status = "complete"
		assert(Panels.stageObjectiveText(state, content, "en-us", nil) == nil, "no active stage")
	end,
	["dock travel result is always shown, refusals with a reason"] = function()
		assert(Panels.travelText("en-us", "mission_gate") == "Finish this island's objectives first", "gate")
		assert(Panels.travelText("ko-kr", "travelling") == "이동 중...", "travelling")
		assert(string.find(Panels.travelText("en-us", "studio_no_teleport"), "Studio", 1, true) ~= nil, "studio")
		assert(Panels.travelText("en-us", "weird") == "Cannot travel (weird)", "unknown reason still visible")
	end,
}
