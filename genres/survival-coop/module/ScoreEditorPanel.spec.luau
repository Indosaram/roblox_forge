--!strict
local Editor = require("./ScoreEditorPanel")
local Transport = require("./ScoreTransport")
local Rules = require("../../../core/domain/music/TestCatalog")
local serde = require("@lune/serde")
local function signal(): any
	local callbacks = {}
	return {
		Connect = function(_self: any, callback: () -> ())
			table.insert(callbacks, callback)
			return {
				Disconnect = function()
					table.clear(callbacks)
				end,
			}
		end,
		fire = function()
			for _, callback in callbacks do
				callback()
			end
		end,
	}
end
return {
	["score workspace is bounded on desktop and a full-width bottom sheet on phone"] = function()
		for _, viewport in { { 360, 640 }, { 1920, 1080 } } do
			local bounds = Editor.bounds(viewport[1], viewport[2])
			assert(bounds.width <= 720 and bounds.height <= 560, "bounded editor")
			assert(bounds.height <= viewport[2] * 0.75, "at most three quarters high")
			if viewport[1] < 700 then
				assert(bounds.width == viewport[1] and bounds.y + bounds.height == viewport[2], "bottom sheet")
			end
		end
	end,
	["GUI controls edit touch sized grid save share preview stop and preserve invalid draft"] = function()
		local objects: { [string]: any } = {}
		local created = {}
		local played, stopped, saves, shares = 0, 0, 0, 0
		local destroyed = false
		local receiver = Transport.new({
			rules = Rules,
			uploadTtl = 30,
			now = function()
				return 0
			end,
			decode = function(text)
				return serde.decode("json", text)
			end,
			repository = {
				save = function()
					saves += 1
					return { ok = true, data = { scoreId = "1:score:1", revision = saves } }
				end,
			},
		})
		local panel = Editor.factory({
			rules = Rules,
			playerGui = {},
			view = {
				new = function(class)
					local node: any = {
						class = class,
						Activated = signal(),
						FocusLost = signal(),
						Destroy = function()
							destroyed = true
						end,
					}
					table.insert(created, node)
					return node
				end,
				size = function(x, y, dx, dy)
					return { x = x, y = y, dx = dx, dy = dy }
				end,
				position = function(x, y, dx, dy)
					return { x = x, y = y, dx = dx, dy = dy }
				end,
			},
			decode = function(text)
				return serde.decode("json", text)
			end,
			encode = function(value)
				return serde.encode("json", value)
			end,
			requestId = function()
				return "request" .. tostring(saves + 1)
			end,
			serverNow = function()
				return 10
			end,
			confirmDiscard = function()
				return false
			end,
			stop = function()
				stopped += 1
			end,
			playAt = function(event)
				assert(event.at == 10, "server clock origin")
				played += 1
			end,
			send = function(action, args)
				if action == "survival-coop:score-share" then
					shares += 1
					return { ok = true }
				end
				return receiver.command("1", action, args, {}, {}, function()
					return { ok = true }
				end)
			end,
		})
		for _, node in created do
			objects[node.Name] = node
		end
		objects.Note_0_0.Activated.fire()
		assert(objects.Note_0_0.Text == Editor.noteLabel(60, true), "grid reflects selected note")
		assert(objects.Note_0_0.Size.dx == 48 and objects.Note_0_0.Size.dy == 48, "phone touch target")
		objects.Share.Activated.fire()
		assert(shares == 0, "unsaved share refused")
		objects.Tempo.Text = "999"
		objects.Tempo.FocusLost.fire()
		objects.Save.Activated.fire()
		assert(saves == 1, "invalid tempo preserved valid draft")
		objects.Recipient.Text = "2"
		objects.Share.Activated.fire()
		assert(shares == 1, "share saved revision")
		objects.Play.Activated.fire()
		assert(played == 1, "preview scheduled")
		objects.Stop.Activated.fire()
		assert(stopped == 2, "stop playback")
		objects.Note_0_0.Activated.fire()
		assert(not panel.controller.close(), "unsaved close refused")
		objects.Instrument.Activated.fire()
		objects.Part2.Activated.fire()
		objects.Close.Activated.fire()
		assert(panel.gui.Enabled == false, "persistent close button hides unsaved draft")
		objects.ImportText.Text = "{"
		objects.Import.Activated.fire()
		assert(not panel.controller.toggle(-1, 60, 480, 100), "invalid grid update refused")
		panel.destroy()
		assert(destroyed, "destroy GUI")
	end,
	["docked editor mounts the shared themed sheet with every label localized and fitted"] = function()
		local fs = require("@lune/fs")
		local Text = require("./MusicText")
		local HudFit = require("../../../core/ui-kit/genre/HudFit")
		local Model = require("./SurvivalHUDModel")
		for _, locale in { "en-us", "ko-kr" } do
			local nodes: { any } = {}
			local function node(class: string): any
				local item: any = { ClassName = class, Activated = signal(), FocusLost = signal(), Text = "" }
				function item.Destroy() end
				table.insert(nodes, item)
				return item
			end
			local dim = function(...)
				return { ... }
			end
			local sheets, fitted = {}, 0
			local ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(_theme, props)
						table.insert(sheets, props.title)
						return { frame = node("Frame"), scroll = node("ScrollingFrame"), close = node("TextButton") }
					end,
					button = function(_theme, props)
						local button = node("TextButton")
						button.Text = props.text
						return button
					end,
					label = function(_theme, props)
						local label = node("TextLabel")
						label.Text = props.text
						return label
					end,
				},
			}
			local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/ScoreEditorPanel.luau")))
			local scope: any = setmetatable({
				Instance = { new = node },
				UDim2 = { new = dim },
				Color3 = { fromRGB = dim },
				require = function(path: string): any
					local modules: { [string]: any } = {
						["../../../core/domain/music/Score"] = require("../../../core/domain/music/Score"),
						["./ScoreTransport"] = Transport,
						["./MusicSelection"] = require("./MusicSelection"),
						["./MusicText"] = Text,
					}
					return assert(modules[path], "unexpected require " .. path)
				end,
			}, { __index = getfenv() })
			setfenv(chunk, scope)
			local Module = chunk()
			local docked: any = nil
			Module.factory({
				rules = Rules,
				locale = locale,
				ui = ui,
				playerGui = {},
				fitSheet = function()
					fitted += 1
				end,
				dock = function(entry)
					docked = entry
					return { setAvailable = function() end }
				end,
				requestId = function()
					return "r"
				end,
				serverNow = function()
					return 0
				end,
				stop = function() end,
				playAt = function() end,
				send = function()
					return { ok = true }
				end,
			})
			assert(#sheets == 1 and sheets[1] == Text.text(locale, "editor_title"), "themed modal sheet mounted")
			-- The tempo box carries a visible label row directly above it, inside the phone sheet.
			local tempoLabel, tempoBox = nil, nil
			for _, item in nodes do
				if item.Name == "TempoLabel" then
					tempoLabel = item
				elseif item.Name == "Tempo" then
					tempoBox = item
				end
			end
			assert(tempoLabel and tempoLabel.ClassName == "TextLabel", "tempo label exists")
			assert(tempoLabel.Text == Text.text(locale, "editor_tempo_label"), "tempo label localized")
			assert(
				tempoLabel.Text == (if string.sub(locale, 1, 2) == "ko" then "템포" else "Tempo"),
				"tempo label copy"
			)
			assert(tempoBox and tempoLabel.LayoutOrder + 1 == tempoBox.LayoutOrder, "label sits right above the box")
			local _, _, phoneWidth = Model.contextSheet(360, 640, true)
			assert(phoneWidth <= 360, "sheet inside 360 wide")
			assert(math.ceil(HudFit.textWidth(tempoLabel.Text, 15)) <= phoneWidth - 16, "tempo label fits 360 wide")
			assert(fitted == 1, "sheet fitted by the shared ExtensionPanels fit")
			assert(docked.label == Text.text(locale, "nav_music"), "dock label localized")
			for _, item in nodes do
				local text = item.Text
				if type(text) == "string" and text ~= "" then
					if string.sub(locale, 1, 2) == "ko" then
						assert(not string.find(text, "Next instrument", 1, true), "untranslated instrument button")
						assert(not string.match(text, "^Part %d"), "untranslated part button: " .. text)
					end
					assert(not string.match(text, "^%[[ x]%] "), "raw note cell: " .. text)
					if
						string.sub(locale, 1, 2) == "ko"
						and item.ClassName == "TextButton"
						and not string.find(text, "%d")
					then
						assert(not string.find(text, "%a%a%a"), "English button in Korean: " .. text)
					end
					-- Buttons do not wrap: one line fits the fitted sheet at both phone viewports.
					if item.ClassName == "TextButton" then
						for _, viewport in { { 640, 339 }, { 360, 640 } } do
							local _, _, width = Model.contextSheet(viewport[1], viewport[2], true)
							local need = math.ceil(HudFit.textWidth(text, 15))
							assert(need <= width - 16 - 6, text .. " clipped at " .. viewport[1] .. "x" .. viewport[2])
						end
					end
				end
			end
		end
	end,
}
