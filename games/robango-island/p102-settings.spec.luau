--!strict
-- p102: settings language and text size, reduced effects applied, 14px vitals labels, the phone
-- island view framed above its controls, and the last five p97 strings moved to strings.csv.
local fs = require("@lune/fs")
local Fixture = require("./PackText.fixture")
local Settings = require("./src/shared/SettingsModel")
local Camera = require("./src/client/AerialCamera")
local Model = require("../../genres/survival-coop/module/SurvivalHUDModel")
local HudFit = require("../../core/ui-kit/genre/HudFit")
local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")

local function fake(class: string, props: { [string]: any }): any
	local attributes = {}
	props.IsA = function(_self, name)
		return name == class
	end
	props.GetAttribute = function(_self, name)
		return attributes[name]
	end
	props.SetAttribute = function(_self, name, value)
		attributes[name] = value
	end
	return props
end

local function hangul(source: string): boolean
	for _, code in utf8.codes(source) do
		if code >= 0xAC00 and code <= 0xD7A3 then
			return true
		end
	end
	return false
end

return {
	["settings carry language and text size, old saves load and the server keeps both"] = function()
		local old = Settings.normalize({ muted = true, volume = 0.5 })
		assert(old.language == "auto" and old.textSize == "normal", "old save defaults")
		assert(Settings.locale("ko-kr", old) == "ko-kr" and Settings.locale("en-us", old) == "en-us", "auto")
		assert(Settings.locale("en-us", { language = "ko" }) == "ko-kr", "ko chosen")
		assert(Settings.locale("ko-kr", { language = "en" }) == "en-us", "en chosen")
		assert(Settings.locale("ko-kr", { language = "fr" }) == "ko-kr", "unknown -> auto")
		local keys = {}
		for _, row in Settings.rows("ko-kr", { language = "en", textSize = "large" }) do
			keys[row[1]] = row[2]
		end
		assert(keys.language and keys.textSize, "language and text size rows")
		assert(keys.language ~= "language" and keys.textSize ~= "textSize", "rows read strings.csv")
		assert(
			Settings.next(old, "language") == "ko" and Settings.next({ language = "en" }, "language") == "auto",
			"language cycles"
		)
		assert(Settings.next(old, "textSize") == "large" and Settings.next(old, "muted") == false, "toggles")
		local args = Settings.args(old, "textSize", "large")
		assert(args[3].textSize == "large" and args[3].language == "auto", "args carry both")
		local back = Settings.fromArgs(args)
		assert(back.textSize == "large" and back.volume == 0.5 and back.muted, "round trip")
		assert(Settings.TEXT_SCALE.large >= 1.15 and Settings.TEXT_SCALE.normal == 1, "large scales up")
		local Contract = require("../../genres/survival-coop/module/Contract")
		local Schema = require("../../core/infra/net/Schema")
		local descriptor
		for _, action in Contract.actions do
			if action.id == "audio-settings" then
				descriptor = action
			end
		end
		local tuple = Schema.tuple(descriptor.args)
		assert(Schema.check(tuple, args), "contract accepts language and text size")
		assert(not Schema.check(tuple, { true, 1, { language = "xx" } }), "unknown language refused")
		local server = fs.readFile("games/robango-island/src/server/SurvivalFactory.luau")
		assert(string.find(server, "language = extra.language,", 1, true), "server persists language")
		assert(string.find(server, "textSize = extra.textSize,", 1, true), "server persists text size")
		assert(string.find(server, '"ForgeLanguage"', 1, true), "server publishes the saved language")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(
			string.find(
				client,
				'Settings.locale(player.LocaleId, { language = player:GetAttribute("ForgeLanguage") })',
				1,
				true
			),
			"client picks its pack locale from the saved language"
		)
		assert(string.find(client, "Settings.scaleText(", 1, true), "client applies text size")
		assert(not hangul(fs.readFile("games/robango-island/src/shared/SettingsModel.luau")), "labels in strings.csv")
		-- Text scale keeps the authored base size so normal restores it.
		local label = fake("TextLabel", { TextSize = 15 })
		Settings.scaleText(label, Settings.TEXT_SCALE.large)
		assert(label.TextSize == 18, "large label " .. label.TextSize)
		Settings.scaleText(label, 1)
		assert(label.TextSize == 15, "normal restores")
		local limit = fake("UITextSizeConstraint", { MaxTextSize = 15 })
		Settings.scaleText(limit, Settings.TEXT_SCALE.large)
		assert(limit.MaxTextSize == 18, "constraint cap scales")
	end,
	["reduced effects turns off decorative particles and thins haze, and restores them"] = function()
		local fire = fake("Fire", { Enabled = true })
		local off = fake("ParticleEmitter", { Enabled = false })
		local haze = fake("Atmosphere", { Density = 0.26, Haze = 1.1 })
		local telegraph = fake("Highlight", { Enabled = true })
		for _, object in { fire, off, haze, telegraph } do
			Settings.reduceEffect(object, true)
		end
		assert(not fire.Enabled and not off.Enabled, "decor particles off")
		assert(haze.Density <= Settings.REDUCED_DENSITY and haze.Haze == 0, "haze thinned")
		assert(telegraph.Enabled, "attack telegraph kept")
		for _, object in { fire, off, haze, telegraph } do
			Settings.reduceEffect(object, false)
		end
		assert(fire.Enabled and not off.Enabled, "authored state restored")
		assert(haze.Density == 0.26 and haze.Haze == 1.1, "haze restored")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, 'GetAttributeChangedSignal("ForgeReducedEffects")', 1, true), "client applies it")
		assert(string.find(client, "Settings.reduceEffect(", 1, true), "client reduces effects")
	end,
	["vitals labels and values are at least 14px and still fit the phone column"] = function()
		local v = Model.VITALS
		assert(v.textSize >= 14, "vitals label " .. v.textSize .. "px")
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(not string.find(hud, "textSize = 11,", 1, true), "11px vitals value left")
		for _, viewport in { { 360, 640 }, { 375, 667 }, { 390, 844 }, { 640, 339 }, { 1280, 720 } } do
			local vitals = Model.contextHudBounds(viewport[1], viewport[2]).vitals
			assert(vitals.width - v.trackX - v.trackRight >= 40, "track squeezed at " .. viewport[1])
			assert(v.labelX + v.labelWidth <= v.trackX, "label overlaps track")
			for _, locale in { "en-us", "ko-kr" } do
				for _, stat in { "health", "hunger", "fatigue" } do
					local text = Locale.text(locale, stat)
					assert(HudFit.textWidth(text, v.textSize) <= v.labelWidth, text .. " overflows")
				end
			end
		end
	end,
	["phone island view frames the whole island above the controls panel"] = function()
		local Content = require("./src/shared/SurvivalContent")
		local Aerial = require("../../genres/survival-coop/module/AerialView")
		local layout: any = nil
		for _, candidate in Content.layouts do
			if candidate.id == "rw.a1.s1" then
				layout = candidate
			end
		end
		for _, viewport in { { X = 360, Y = 640 }, { X = 390, Y = 844 } } do
			local toggle: any = nil
			local applied: any = nil
			local buttons = setmetatable({}, {
				__index = function(_, name)
					return {
						Activated = {
							Connect = function(_self, callback)
								if name == "Toggle" then
									toggle = callback
								end
								return { Disconnect = function() end }
							end,
						},
					}
				end,
			})
			local camera: any = { CameraType = "Custom", CFrame = "c", FieldOfView = 30, ViewportSize = viewport }
			Camera.new({
				aerial = Aerial,
				touch = true,
				workspace = { CurrentCamera = camera },
				guis = {},
				buttons = buttons,
				controls = { Visible = false },
				quarterView = { suspend = function() end },
				bounds = function()
					return layout.bounds.min, layout.bounds.max
				end,
				scriptable = "Scriptable",
				lookAt = function(position, target)
					applied = { position = position, target = target }
					return applied
				end,
				focusAt = function(point)
					return point
				end,
			})
			toggle()
			local p, t = applied.position, applied.target
			-- Camera basis: forward toward the aim point, world up projected.
			local f = { x = t.x - p.x, y = t.y - p.y, z = t.z - p.z }
			local fl = math.sqrt(f.x ^ 2 + f.y ^ 2 + f.z ^ 2)
			f = { x = f.x / fl, y = f.y / fl, z = f.z / fl }
			local r = { x = -f.z, y = 0, z = f.x }
			local rl = math.sqrt(r.x ^ 2 + r.z ^ 2)
			r = { x = r.x / rl, y = 0, z = r.z / rl }
			local u = { x = r.y * f.z - r.z * f.y, y = r.z * f.x - r.x * f.z, z = r.x * f.y - r.y * f.x }
			local tanV = math.tan(math.rad(camera.FieldOfView) / 2)
			local tanH = tanV * viewport.X / viewport.Y
			local panelTop = Camera.panelTop(viewport, true)
			local label = viewport.X .. "x" .. viewport.Y
			local b = layout.bounds
			for _, x in { b.min.x, b.max.x } do
				for _, y in { b.min.y, b.max.y } do
					for _, z in { b.min.z, b.max.z } do
						local d = { x = x - p.x, y = y - p.y, z = z - p.z }
						local depth = d.x * f.x + d.y * f.y + d.z * f.z
						local sx = (d.x * r.x + d.y * r.y + d.z * r.z) / depth / tanH
						local sy = (d.x * u.x + d.y * u.y + d.z * u.z) / depth / tanV
						local px, py = (sx + 1) / 2 * viewport.X, (1 - sy) / 2 * viewport.Y
						assert(px >= 0 and px <= viewport.X, label .. " corner off the side: " .. px)
						assert(
							py >= 0 and py <= panelTop,
							string.format("%s corner y %d under panel top %d", label, py, panelTop)
						)
					end
				end
			end
			-- Same measure as the p83 spec: camera to the aimed focus.
			local distance = math.sqrt((p.x - t.x) ^ 2 + (p.y - t.y) ^ 2 + (p.z - t.z) ^ 2)
			assert(distance <= Camera.MAX_DISTANCE + 0.01, label .. " camera " .. distance .. " studs out")
		end
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(
			string.find(client, 'touch = game:GetService("UserInputService").TouchEnabled,', 1, true),
			"client passes touch"
		)
	end,
	["the five p97 holdouts read strings.csv with no Hangul left in Luau"] = function()
		for _, path in { "FarmCraftText", "SurvivalHUDLocale", "WildlifeNames" } do
			local source = fs.readFile("genres/survival-coop/module/" .. path .. ".luau")
			assert(not hangul(source), path .. " still carries Korean text")
		end
		local FarmCraft = require("../../genres/survival-coop/module/FarmCraftText")
		local Wildlife = require("../../genres/survival-coop/module/WildlifeNames")
		local packText = Fixture.packText
		assert(FarmCraft.refusal("ko-kr", "OUT_OF_RANGE") == packText("ko-kr", "fct.OUT_OF_RANGE"), "fct")
		assert(packText("ko-kr", "fct.OUT_OF_RANGE") ~= nil, "fct row")
		for _, key in { "PLACEMENT_BLOCKED_CREATURE", "market.tutorial" } do
			local ko = packText("ko-kr", "hud." .. key)
			assert(ko and Locale.text("ko-kr", key) == ko, "hud." .. key)
		end
		for _, species in { "brachiosaurus", "parasaurolophus" } do
			local ko = packText("ko-kr", "wld.wildlife_" .. species)
			assert(ko and hangul(ko) and Wildlife.name("ko-kr", species) == ko, species)
		end
	end,
}
