--!strict
-- p134 v51 (SM-N981N): client memory crept ~2 MB/min (846 -> 1017 MB over ~80 min). RobangoAudio
-- connected Activated on every GuiButton added to PlayerGui and kept the connection in its session
-- list forever, so each panel rebuild (rows rebuilt on every state packet) left a live connection
-- and its destroyed button behind; streamed creatures did the same. This drives RobangoAudio.start
-- with counted signals and checks a removed button or creature leaves no connection behind.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

type Signal = { live: number, fire: (...any) -> (), Connect: (any, (...any) -> ()) -> any }
local function signal(): Signal
	local handlers: { [number]: (...any) -> () } = {}
	local serial = 0
	local s: any = { live = 0 }
	function s.fire(...)
		for _, fn in table.clone(handlers) do
			fn(...)
		end
	end
	function s.Connect(_, fn)
		serial += 1
		local id = serial
		handlers[id] = fn
		s.live += 1
		return {
			Disconnect = function()
				if handlers[id] then
					handlers[id] = nil
					s.live -= 1
				end
			end,
		}
	end
	return s
end

local function instance(class: string, name: string): any
	local attributeSignals: { [string]: Signal } = {}
	local item: any = { Name = name, Activated = signal(), children = {} }
	function item.IsA(_, wanted)
		return wanted == class
	end
	function item.GetAttribute()
		return nil
	end
	function item.GetAttributeChangedSignal(_, key)
		attributeSignals[key] = attributeSignals[key] or signal()
		return attributeSignals[key]
	end
	function item.GetChildren(self)
		return self.children
	end
	function item.GetDescendants(self)
		return self.children
	end
	item.ChildAdded, item.ChildRemoved = signal(), signal()
	item.DescendantAdded, item.DescendantRemoving = signal(), signal()
	item.attributeSignals = attributeSignals
	return item
end

local function start()
	local playerGui = instance("PlayerGui", "PlayerGui")
	local player = instance("Player", "Player")
	function player.WaitForChild()
		return playerGui
	end
	local workspace = instance("Workspace", "Workspace")
	local wildlife = instance("Folder", "ForgeWildlife")
	function workspace.FindFirstChild(_, name)
		return if name == "ForgeWildlife" then wildlife else nil
	end
	local stateEvent = { OnClientEvent = signal() }
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		ReplicatedStorage = {
			WaitForChild = function()
				return stateEvent
			end,
		},
		CollectionService = {
			GetTagged = function()
				return {}
			end,
		},
	}
	local Audio = luau.load(fs.readFile("games/robango-island/src/client/RobangoAudio.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return assert(services[name], name)
				end,
			},
			workspace = workspace,
		},
	})()
	local bank = {
		new = function()
			return {
				define = function() end,
				play = function()
					return nil
				end,
				setGroupVolume = function() end,
				destroy = function() end,
			}
		end,
	}
	local director = {
		new = function()
			return {
				setMuted = function() end,
				region = function() end,
				event = function() end,
				result = function() end,
				setVolume = function() end,
				destroy = function() end,
			}
		end,
	}
	local config = { slots = {}, groups = {}, signals = {}, wildlife = {}, receiptLimit = 8 }
	local audio = Audio.start(bank, director, {}, config, {})
	return audio, playerGui, wildlife
end

return {
	["a button removed from PlayerGui leaves no click connection behind"] = function()
		local audio, playerGui = start()
		for round = 1, 50 do
			local rows = {}
			for index = 1, 10 do
				local button = instance("GuiButton", "Row" .. round .. "." .. index)
				table.insert(rows, button)
				playerGui.DescendantAdded.fire(button)
				assert(button.Activated.live == 1, "one click connection per live button")
			end
			for _, button in rows do
				playerGui.DescendantRemoving.fire(button)
				assert(button.Activated.live == 0, "a removed button is disconnected")
			end
		end
		local kept = instance("GuiButton", "Close")
		playerGui.DescendantAdded.fire(kept)
		playerGui.DescendantAdded.fire(kept)
		assert(kept.Activated.live == 1, "a button is never connected twice")
		audio.destroy()
		assert(kept.Activated.live == 0, "destroy drops the live ones")
	end,
	["a creature that streams out leaves no feedback connection behind"] = function()
		local audio, _, wildlife = start()
		for round = 1, 20 do
			local model = instance("Model", "Dodo" .. round)
			wildlife.ChildAdded.fire(model)
			local feedback = model.attributeSignals.ForgeWildlifeFeedback
			assert(feedback and feedback.live == 1, "the creature is watched")
			wildlife.ChildRemoved.fire(model)
			assert(feedback.live == 0, "a streamed-out creature is released")
			wildlife.ChildAdded.fire(model)
			assert(feedback.live == 1, "and watched again when it streams back in")
			wildlife.ChildRemoved.fire(model)
		end
		audio.destroy()
	end,
}
