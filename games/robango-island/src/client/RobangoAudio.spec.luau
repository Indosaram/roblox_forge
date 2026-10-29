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

-- `opts.services` adds engine services, `opts.bank`/`opts.director`/`opts.assets`/`opts.config`
-- replace the stubs, `opts.enum` is the Enum global.
local function start(opts: any?)
	local o = opts or {}
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
	local stateEvent = { Name = "ForgeState", OnClientEvent = signal() }
	-- `opts.stateLate`: ForgeState is not there yet (a town join) and arrives through ChildAdded.
	-- WaitForChild errors so an unbounded wait (the v54 "Infinite yield possible") fails the spec.
	local storage: any = { ChildAdded = signal() }
	function storage.FindFirstChild(_, name)
		return if name == "ForgeState" and not o.stateLate then stateEvent else nil
	end
	function storage.WaitForChild()
		error("unbounded WaitForChild on ReplicatedStorage")
	end
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		ReplicatedStorage = storage,
		CollectionService = {
			GetTagged = function()
				return {}
			end,
		},
	}
	for name, service in o.services or {} do
		services[name] = service
	end
	local Audio = luau.load(fs.readFile("games/robango-island/src/client/RobangoAudio.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return assert(services[name], name)
				end,
			},
			workspace = workspace,
			Enum = o.enum,
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
	local config = o.config or { slots = {}, groups = {}, signals = {}, wildlife = {}, receiptLimit = 8 }
	local audio = Audio.start(o.bank or bank, o.director or director, o.assets or {}, config, {})
	return audio, playerGui, wildlife, stateEvent, storage
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
	-- p134 v53 (phone): the live universe refused robango-level-up 110021116520036 ("User is not
	-- authorized"). Every cue built a new Sound for the same id and the engine logged the failure
	-- again. Drives the real AudioDirector: after the engine reports the id failed, a level-up
	-- never builds or plays another Sound; a cue whose asset loads keeps playing.
	["a sound id the engine failed to load stays silent instead of retrying every cue"] = function()
		local LEVEL, CONFIRM = "rbxassetid://110021116520036", "rbxassetid://140071037166740"
		local Enum = { AssetFetchStatus = { Success = "Success", Failure = "Failure", Loading = "Loading" } }
		local status: { [string]: string } = { [LEVEL] = "Loading", [CONFIRM] = "Loading" }
		local fetched: { [string]: number } = {}
		local content = {}
		function content.GetAssetFetchStatus(self, id: string)
			assert(self == content, "method call")
			fetched[id] = (fetched[id] or 0) + 1
			return status[id] or "None"
		end
		local made: { [string]: number } = {}
		local cues: { [string]: string } = {}
		local bank = {
			new = function()
				return {
					define = function(_, name, cue)
						cues[name] = cue.soundId
					end,
					play = function(_, name)
						made[cues[name]] = (made[cues[name]] or 0) + 1
						return { Destroy = function() end }
					end,
					setGroupVolume = function() end,
					destroy = function() end,
				}
			end,
		}
		local slots = {
			["level-up"] = { asset = "robango-level-up", group = "UI", looped = false },
			["ui-confirm"] = { asset = "robango-ui-confirm", group = "UI", looped = false },
		}
		local config = {
			slots = slots,
			groups = { UI = 1 },
			events = { ["level-up"] = "level-up", ["ui-confirm"] = "ui-confirm" },
			regions = {},
			signals = { levelUp = "level-up", uiClick = "ui-confirm" },
			wildlife = {},
			receiptLimit = 8,
		}
		local audio = start({
			services = { ContentProvider = content },
			enum = Enum,
			bank = bank,
			director = require("../../../../genres/survival-coop/module/AudioDirector"),
			assets = { ["robango-level-up"] = LEVEL, ["robango-ui-confirm"] = CONFIRM },
			config = config,
		})
		audio.signal("levelUp")
		assert(made[LEVEL] == 1, "the first level-up requests the sound")
		status[LEVEL], status[CONFIRM] = "Failure", "Success"
		for _ = 1, 10 do
			audio.signal("levelUp")
			audio.signal("uiClick")
		end
		assert(made[LEVEL] == 1, "a refused id is never re-created, got " .. tostring(made[LEVEL]))
		assert(made[CONFIRM] == 10, "a loaded id keeps playing")
		local checks = fetched[LEVEL]
		audio.signal("levelUp")
		assert(fetched[LEVEL] == checks, "a refused id is remembered, not re-queried")
		audio.destroy()
	end,
	-- p134 v54 (town join): `WaitForChild("ForgeState")` logged "Infinite yield possible" at
	-- RobangoAudio:279. Start must not wait on it: it attaches once the remote arrives.
	["audio starts without waiting for ForgeState and attaches when it arrives"] = function()
		local audio, _, _, stateEvent, storage = start({ stateLate = true })
		assert(stateEvent.OnClientEvent.live == 0, "nothing attached before the remote exists")
		storage.ChildAdded.fire({ Name = "Other" })
		storage.ChildAdded.fire(stateEvent)
		assert(stateEvent.OnClientEvent.live == 1, "attached once ForgeState arrives")
		storage.ChildAdded.fire(stateEvent)
		assert(stateEvent.OnClientEvent.live == 1, "attached only once")
		stateEvent.OnClientEvent.fire({ snapshots = {} })
		audio.destroy()
		assert(stateEvent.OnClientEvent.live == 0, "destroy disconnects")
	end,
}
