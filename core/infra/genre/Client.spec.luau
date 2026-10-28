--!strict
-- p134 v45: the core developer panel set `label.Text = id .. JSONEncode(snapshot)` for every
-- snapshot on every packet. A 256K-character snapshot raised "Unable to assign property Text"
-- once per second on the phone, and the panel was hidden by the pack's own HUD anyway.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Transport = require("./CommandTransport")

local MAX_TEXT = 200000

local function signal(): any
	local callbacks: { (...any) -> () } = {}
	return {
		Connect = function(_, callback)
			table.insert(callbacks, callback)
			return { Disconnect = function() end }
		end,
		Fire = function(_, ...)
			for _, callback in table.clone(callbacks) do
				callback(...)
			end
		end,
	}
end

-- Loads the real Client.luau into a minimal engine double; TextLabel.Text enforces the engine limit.
local function harness(hidden: boolean): any
	local labels: { any } = {}
	local encodes = 0
	local function instance(class: string): any
		local object: any = { ClassName = class, Activated = signal() }
		if class == "TextLabel" then
			local props: { [string]: any } = {}
			local label = setmetatable({ ClassName = class }, {
				__index = props,
				__newindex = function(_, key, value)
					if key == "Text" then
						assert(
							#value < MAX_TEXT,
							"Unable to assign property Text. Provided string length (" .. #value .. ")"
						)
					end
					props[key] = value
				end,
			})
			table.insert(labels, label)
			return label
		end
		return object
	end
	local state = { OnClientEvent = signal() }
	local remote = {}
	function remote:InvokeServer()
		return { ok = true, durable = { actions = {}, sessionEpoch = 0 } }
	end
	local player = {
		UserId = 1,
		WaitForChild = function()
			return {}
		end,
	}
	local services: { [string]: any } = {
		Players = { LocalPlayer = player },
		ReplicatedStorage = {
			WaitForChild = function(_, name)
				return if name == "ForgeAction" then remote else state
			end,
		},
		HttpService = {
			JSONEncode = function(_, value)
				encodes += 1
				return value.blob
			end,
		},
		ProximityPromptService = { PromptTriggered = signal() },
	}
	local new = function(...)
		return { ... }
	end
	local module = luau.load(fs.readFile("core/infra/genre/Client.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			Instance = { new = instance },
			Enum = { AutomaticSize = { Y = "Y" }, TextXAlignment = { Left = "Left" } },
			UDim2 = { new = new, fromOffset = new },
			UDim = { new = new },
			Color3 = { new = new, fromRGB = new },
			require = function(path: string): any
				if path == "./CommandTransport" then
					return Transport
				end
				return {}
			end,
		},
	})()
	local gui = module.start({ controls = {}, hidden = hidden })
	return {
		module = module,
		gui = gui,
		labels = labels,
		encodes = function()
			return encodes
		end,
		push = function(blob: string)
			state.OnClientEvent:Fire({
				snapshots = { ["survival-coop"] = { blob = blob } },
				roster = {},
				durable = { actions = {}, sessionEpoch = 0 },
			})
		end,
	}
end

local function snapshotLabels(labels: { any }): { any }
	local out = {}
	for _, label in labels do
		if label.Name == "survival-coop:snapshot" then
			table.insert(out, label)
		end
	end
	return out
end

return {
	["a hidden developer panel never builds the per-packet snapshot dump"] = function()
		local h = harness(true)
		assert(h.gui.Enabled == false, "hidden from creation")
		h.push(string.rep("x", 256156))
		h.push(string.rep("x", 281118))
		assert(h.encodes() == 0, "no JSONEncode per packet, got " .. h.encodes())
		assert(#snapshotLabels(h.labels) == 0, "no snapshot label")
	end,
	["a visible developer panel truncates a snapshot below the TextLabel limit"] = function()
		local h = harness(false)
		h.push(string.rep("x", 256156))
		local rows = snapshotLabels(h.labels)
		assert(#rows == 1, "one snapshot label")
		local text = rows[1].Text :: string
		assert(#text <= h.module.SNAPSHOT_TEXT_LIMIT and #text < MAX_TEXT, "bounded, got " .. #text)
		assert(string.find(text, "truncated", 1, true), "marks the cut")
		h.push("{}")
		assert(rows[1].Text == "survival-coop\n{}", "small snapshot shown whole: " .. tostring(rows[1].Text))
	end,
	["truncation never splits a UTF-8 character"] = function()
		local Client = luau.load(fs.readFile("core/infra/genre/Client.luau"), {
			environment = {
				game = {
					GetService = function()
						return {}
					end,
				},
				require = function()
					return {}
				end,
			},
		})()
		local text = Client.snapshotText("id", string.rep("가", 20000))
		assert(#text <= Client.SNAPSHOT_TEXT_LIMIT, "bounded")
		assert(utf8.len(text) ~= nil, "valid UTF-8")
	end,
}
