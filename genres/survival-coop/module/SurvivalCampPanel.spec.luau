--!strict
-- text audit goal 3: the menu's 생존 (Survival) tile opened the bag. It now opens the survival camp
-- sheet: camp level and facilities, campfire and shelter status, shared storage use, structures
-- built and the next projects with have/need counts, in the sheets3 card style (FarmCraftSheet).
-- Host-only: needs the robango generated catalog; marker: require("@lune/task")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Panel = require("./SurvivalCampPanel")
local Panels = require("./FarmCraftPanels")
local Navigator = require("./NavigatorPanel")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local Fixture = require("../../../games/robango-island/PackText.fixture")

local function placement(id: string, structure: string): any
	return { id = id, definition = { id = structure, footprintX = 1, footprintZ = 1, cost = {} } }
end

local function stack(id: string, catalogId: string, quantity: number): any
	return { itemId = id, catalogId = catalogId, quantity = quantity, qualityMilli = 1000, durabilityMilli = 1000 }
end

local CAMP = {
	role = "member",
	version = 3,
	rung = 1,
	facilities = { ["camp-cache"] = true },
	completed = { windbreak = true },
	active = { ["drying-rack"] = { delivered = { berry = 5, branch = 30 } } },
	cooldowns = {},
	passes = {},
	ladder = Content.camp and {
		rungs = Content.camp.rungs,
		projects = Content.camp.projects,
		leagueRung = Content.camp.leagueRung,
	},
}

local function packet(structures: { any }, resting: boolean): any
	local placed = {}
	for _, entry in structures do
		placed[entry.id] = entry
	end
	return {
		snapshots = {
			["survival-coop"] = { vitals = { resting = resting, healthMilli = 90000 } },
			survivalSettlement = {
				settlement = { structures = placed, reservations = {}, roles = { ["1"] = "owner" } },
				warehouse = {
					items = { w = stack("w", "wood", 2), s = stack("s", "stone", 9) },
					reservations = {},
					limits = { slots = 40 },
				},
			},
		},
	}
end

local function names(locale: string): (string) -> string
	local table_ = Fixture.names(locale)
	return function(id: string): string
		return table_[id] or id
	end
end

-- Spec engine for FarmCraftSheet (ctx.instance): every row and its controls by name.
local function harness(locale: string): any
	local docks, opened = {}, {}
	local listener: any = nil
	local scroll: any = { children = {} }
	local function node(): any
		local raw: any = { children = {} }
		return setmetatable({}, {
			__index = raw,
			__newindex = function(self, key, value)
				if key == "Parent" and type(value) == "table" then
					value.children = value.children or {}
					table.insert(value.children, self)
				end
				raw[key] = value
			end,
		})
	end
	local function widget(_theme: any, props: any): any
		local value = node()
		value.Text, value.Size, value.Position, value.Parent = props.text, props.size, props.position, props.parent
		value.onClick = props.onClick
		value.Destroy = function(self)
			self.destroyed = true
		end
		return value
	end
	local ctx: any = {
		locale = locale,
		instance = {
			new = function(class: string): any
				local value = node()
				value.ClassName = class
				value.Destroy = function(self)
					self.destroyed = true
				end
				return value
			end,
		},
		enum = { ZIndexBehavior = { Sibling = "Sibling" } },
		udim2 = {
			new = function(...)
				return { ... }
			end,
			fromScale = function(...)
				return { ... }
			end,
		},
		game = {
			GetService = function()
				return { LocalPlayer = {
					WaitForChild = function()
						return {}
					end,
				} }
			end,
		},
		ui = {
			theme = { default = {} },
			components = {
				modalSheet = function(_theme: any, props: any): any
					if props.name == "survival" then
						return {
							frame = node(),
							scroll = scroll,
							close = {
								Activated = {
									Connect = function()
										return { Disconnect = function() end }
									end,
								},
							},
						}
					end
					return {
						frame = node(),
						scroll = node(),
						close = {
							Activated = {
								Connect = function()
									return { Disconnect = function() end }
								end,
							},
						},
					}
				end,
				label = widget,
				button = widget,
			},
		},
		dock = function(entry: any): any
			docks[entry.id] = entry
			return {
				open = function()
					entry.setOpen(true)
				end,
				setAvailable = function() end,
			}
		end,
		openPanel = function(id: string)
			table.insert(opened, id)
		end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		send = function(): any
			return { ok = false, reason = "COMMAND_UNAVAILABLE" }
		end,
	}
	local mounted = Panels.mount(ctx, {
		content = Content,
		name = names(locale),
		now = function(): number
			return 0
		end,
		actor = function(): string
			return "1"
		end,
		station = function(): string
			return "hand"
		end,
	})
	local api: any = { docks = docks, opened = opened, mounted = mounted }
	function api.push(extensions: any, whole: any)
		listener(extensions, whole)
	end
	function api.rows(): { any }
		local out = {}
		for _, row in scroll.children do
			if not row.destroyed then
				table.insert(out, row)
			end
		end
		return out
	end
	function api.texts(): { string }
		local out = {}
		local function walk(item: any)
			for _, child in item.children or {} do
				if not child.destroyed and type(child.Text) == "string" and child.Text ~= "" then
					table.insert(out, child.Text)
				end
				walk(child)
			end
		end
		for _, row in api.rows() do
			if type(row.Text) == "string" then
				table.insert(out, row.Text)
			end
			walk(row)
		end
		return out
	end
	function api.find(name: string): any
		local found = nil
		local function walk(item: any)
			for _, child in item.children or {} do
				if not child.destroyed and child.Name == name then
					found = found or child
				end
				walk(child)
			end
		end
		walk(scroll)
		return found
	end
	return api
end

return {
	["the Survival menu row opens the camp sheet, not the bag"] = function()
		local row = Navigator.ROWS[1]
		assert(row[1] == "nav_survival" and row[2] == "survival", "nav_survival routes to " .. tostring(row[2]))
		local ui = harness("ko-kr")
		local entry = assert(ui.docks.survival, "survival dock entry")
		assert(entry.hidden == true, "no extra menu-grid tile (the navigator row and openPanel open it)")
	end,
	["the camp sheet shows level, fire, shelter, storage, built and next projects"] = function()
		for _, locale in { "ko-kr", "en-us" } do
			local ui = harness(locale)
			ui.docks.survival.setOpen(true)
			ui.push(
				{ camp = CAMP },
				packet({ placement("p1", "campfire"), placement("p2", "campfire"), placement("p3", "tent") }, true)
			)
			local all = table.concat(ui.texts(), "\n")
			local ko = locale == "ko-kr"
			local expected: { string } = if ko
				then {
					"캠프 레벨 1/2",
					"캠프 저장고",
					"불 피움: 모닥불 2개",
					"불 곁에서 쉬는 중",
					"쉼터: 천막",
					"공용 창고 2/40칸",
					"지은 건물",
					"모닥불 x2",
					"천막 x1",
					"다음 프로젝트",
					"건조대 35/75",
				}
				else { "Camp level 1/2", "Campfires lit: 2", "Shelter: Tent", "Shared storage 2/40 slots" }
			for _, expect in expected do
				assert(string.find(all, expect, 1, true), locale .. ": missing '" .. expect .. "' in\n" .. all)
			end
			-- The next unbuilt core structure shows the storage have/need, never a raw id.
			assert(ui.find("Next-build-storage") or ui.find("Next-build-workbench"), "next build project card")
			for _, text in ui.texts() do
				assert(not string.find(text, "%l%-%l"), locale .. ": raw id in " .. text)
				if ko then
					for word in string.gmatch(text, "%a%a%a+") do
						assert(false, "English '" .. word .. "' in " .. text)
					end
				end
			end
		end
	end,
	["an empty camp says so and its actions route to the camp, build and storage sheets"] = function()
		local ui = harness("ko-kr")
		ui.docks.survival.setOpen(true)
		ui.push({}, packet({}, false))
		local all = table.concat(ui.texts(), "\n")
		for _, expect in
			{ "아직 모닥불이 없어요", "아직 쉼터가 없어요", "아직 지은 건물이 없어요" }
		do
			assert(string.find(all, expect, 1, true), "missing " .. expect .. " in\n" .. all)
		end
		local view = Panel.model("ko-kr", Content, nil, packet({}, false), 0, names("ko-kr"))
		assert(#view.next == Panel.NEXT_LIMIT and view.next[1].id == "build-campfire", "campfire is the first project")
		assert(view.next[1].detail:find("나무") ~= nil, "campfire cost names wood: " .. view.next[1].detail)
		for _, name in { "BuildFire", "BuildShelter", "OpenStorage", "OpenCamp", "Go-build-campfire" } do
			assert(ui.find(name), name .. " button").onClick()
		end
		assert(
			table.concat(ui.opened, ",") == "build,build,storage,camp,build",
			"routes: " .. table.concat(ui.opened, ",")
		)
	end,
}
