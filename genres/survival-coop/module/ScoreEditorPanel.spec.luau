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
		assert(string.find(objects.Note_0_0.Text, "[x]", 1, true), "grid reflects selected note")
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
		objects.ImportText.Text = "{"
		objects.Import.Activated.fire()
		assert(not panel.controller.toggle(-1, 60, 480, 100), "invalid grid update refused")
		panel.destroy()
		assert(destroyed, "destroy GUI")
	end,
}
