--!strict
-- A6 (plan G23): Robango players are game-supplied survivors. The chosen preset persists in the
-- actor's robango-exp-v1 document across a fresh store (rejoin), unknown ids change nothing, and
-- paid worn sets still dress on top of the survivor while mount skins never touch it.
local Survivor = require("./src/shared/SurvivorAvatar")
local Cosmetics = require("./src/shared/CosmeticConfig")
local Fixture = require("./PackText.fixture")
local Documents = require("../../core/infra/data/ActorDocumentStore")
local Memory = require("../../core/infra/data/MemoryBackend")

local function store(backend: any, session: string): any
	return Documents.new(backend, {
		sessionId = session,
		leaseSeconds = 30,
		now = function()
			return 0
		end,
	}, "robango-exp-v1")
end

return {
	["at least four presets mix body and face choices and use only verified catalog ids"] = function()
		assert(#Survivor.PRESETS >= 4, "four presets")
		local heads, ids = {}, {}
		for _, preset in Survivor.PRESETS do
			assert(not ids[preset.id], "duplicate preset " .. preset.id)
			ids[preset.id] = true
			heads[preset.body.head] = true
			local plan = Survivor.describe(preset)
			for _, key in
				{ "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Head", "MoodAnimation", "Shirt", "Pants" }
			do
				local id = plan.properties[key]
				assert(Survivor.CATALOG[id], preset.id .. "." .. key .. " uses unverified id " .. tostring(id))
			end
			for _, key in { "HairAccessory", "HatAccessory" } do
				local text = plan.properties[key]
				assert(text == "" or Survivor.CATALOG[tonumber(text)], preset.id .. "." .. key .. " unverified")
			end
		end
		local count = 0
		for _ in heads do
			count += 1
		end
		assert(count >= 2, "presets mix at least two body/face choices")
		assert(Survivor.find(Survivor.DEFAULT), "default preset exists")
	end,
	["a chosen preset persists across a fresh store (rejoin) and unknown ids are refused"] = function()
		local backend = Memory.new()
		local first = store(backend, "server-a")
		assert(Survivor.view(first.snapshot("101")).chosen == false, "fresh player has not chosen")
		assert(Survivor.choose(first, "101", "nope").reason == "UNKNOWN_SURVIVOR", "unknown id refused")
		local chosen = Survivor.choose(first, "101", "scout")
		assert(chosen.ok and chosen.data.preset == "scout", "choice saved")
		assert(first.close().ok, "release lease")
		local rejoin = store(backend, "server-b")
		local document = rejoin.snapshot("101")
		local view = Survivor.view(document)
		assert(view.preset == "scout" and view.chosen, "choice survives rejoin")
		assert(Survivor.presetOf(document).id == "scout", "worn preset is the saved one")
		assert(Survivor.choose(rejoin, "101", "drifter").ok, "choice can change")
		assert(Survivor.presetOf(rejoin.snapshot("101")).id == "drifter", "changed choice saved")
		-- Other document fields (expedition, development) are untouched by the survivor key.
		assert(rejoin.snapshot("101").archipelago == nil, "no expedition invented")
	end,
	["an unknown saved preset falls back to the default survivor"] = function()
		local document = { survivor = { version = 1, preset = "retired" } }
		assert(Survivor.presetOf(document).id == Survivor.DEFAULT and not Survivor.view(document).chosen, "fallback")
		assert(Survivor.presetOf(nil).id == Survivor.DEFAULT, "no document -> default")
	end,
	["owned worn sets dress on top of the survivor; mount skins never touch it"] = function()
		local document = { survivor = { version = 1, preset = "forager" } }
		local bare = Survivor.dress(document, nil, Cosmetics)
		assert(bare.preset.id == "forager" and #bare.wear == 0, "survivor alone")
		local worn = Survivor.dress(document, { ["route-guild-monthly"] = true }, Cosmetics)
		assert(worn.preset.id == "forager", "paid set does not replace the survivor body")
		assert(#worn.wear > 0 and worn.wear[1].set == "route-guild-monthly", "paid worn set on top")
		local skin = Survivor.dress(document, { ["ridge-strider-gold"] = true }, Cosmetics)
		assert(#skin.wear == 0 and skin.preset.id == "forager", "mount skin stays on the ride")
		assert(skin.description.properties.Shirt == bare.description.properties.Shirt, "outfit unchanged by skins")
	end,
	["apply resets the description, sets skin colour and drops stale worn pieces"] = function()
		local applied: any, removed = nil, false
		local character: any = {
			attributes = {},
			FindFirstChildOfClass = function(_, class)
				return if class == "Humanoid"
					then {
						ApplyDescriptionReset = function(_, description)
							applied = description
						end,
					}
					else nil
			end,
			FindFirstChild = function(_, name)
				return if name == "ForgeCosmetics"
					then {
						Destroy = function()
							removed = true
						end,
					}
					else nil
			end,
			SetAttribute = function(self, key, value)
				self.attributes[key] = value
			end,
		}
		local ok = Survivor.apply(character, assert(Survivor.find("ranger")), {
			description = function()
				return {}
			end,
			color = function(rgb)
				return rgb
			end,
		})
		assert(ok and applied and applied.Shirt == 144076436 and applied.HeadColor.r == 186, "described")
		-- The body itself is coloured as the outfit, so it never reads as a bare skin block.
		assert(applied.TorsoColor.r == 74 and applied.LeftLegColor.g == 74, "top and trousers coloured")
		assert(applied.Face == 0 and applied.GraphicTShirt == 0, "player's own items cleared")
		assert(removed and character.attributes.ForgeSurvivor == "ranger", "re-dress marker")
	end,
	["picker rows read the locale table in both languages and mark the worn preset"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local function text(key: string): string
				return assert(Fixture.packText(locale, "cli.survivor." .. key), locale .. " missing " .. key)
			end
			text("title")
			text("intro")
			local rows = Survivor.pickerRows(Survivor.PRESETS, { preset = "scout", chosen = true }, text)
			assert(#rows == #Survivor.PRESETS, "one row per preset")
			for _, row in rows do
				assert(not string.find(row[2], "survivor", 1, true) or locale == "en-us", "no raw key")
				assert((row[1] == "scout") == (string.find(row[2], text("current"), 1, true) ~= nil), "marks worn")
			end
		end
		assert(Survivor.pickerNeeded({ preset = "ranger", chosen = false }), "first join opens")
		assert(
			not Survivor.pickerNeeded({ preset = "ranger", chosen = true }) and not Survivor.pickerNeeded(nil),
			"otherwise closed"
		)
	end,
	-- p134 v46 (live server): the character spawned as a bare skin-coloured block, no shirt, pants
	-- or hair. ApplyDescriptionReset returned without error, but on the live server the clothing
	-- and accessory assets did not land on the character, and the old code neither checked nor
	-- retried: every body part was the skin colour, so nothing at all read as clothing.
	["a live apply whose clothing never loads still dresses the survivor in game-made pieces"] = function()
		local function fakeCharacter(loads: boolean)
			local children: { [string]: any } = {}
			local applied: any = nil
			local character: any = { attributes = {}, applies = 0 }
			local head = { Name = "Head", Size = { X = 2, Y = 1, Z = 1 } }
			function character.FindFirstChildOfClass(_, class)
				if class == "Humanoid" then
					return {
						ApplyDescriptionReset = function(_, description)
							character.applies += 1
							applied = description
							if loads then
								children.Shirt, children.Pants, children.Accessory = {}, {}, {}
							end
						end,
					}
				end
				return children[class]
			end
			function character.FindFirstChild(_, name)
				return if name == "Head" then head else children[name]
			end
			function character.SetAttribute(self, key, value)
				self.attributes[key] = value
			end
			character.described = function()
				return applied
			end
			character.children = children
			return character
		end
		local waits = {}
		local function ports(_character: any): any
			return {
				description = function()
					return {}
				end,
				color = function(rgb)
					return rgb
				end,
				wait = function(seconds)
					table.insert(waits, seconds)
				end,
				current = function()
					return true
				end,
				folder = function(name)
					local folder: any = { Name = name }
					function folder.Destroy() end
					return folder
				end,
				hairCap = function(_head, color)
					return { Name = "HairCap", Color = color }
				end,
			}
		end
		local preset = assert(Survivor.find("ranger"))
		local broken = fakeCharacter(false)
		local p = ports(broken)
		p.folder = function(name)
			local folder: any = { Name = name }
			broken.children[name] = folder
			return folder
		end
		local ok, missing = Survivor.dressCharacter(broken, preset, p)
		assert(ok, "the description itself applied")
		assert(broken.applies == Survivor.APPLY_ATTEMPTS and #waits == Survivor.APPLY_ATTEMPTS - 1, "retried")
		assert(#missing == 3, "shirt, pants and hair never loaded: " .. table.concat(missing, ","))
		local described = broken.described()
		assert(described.TorsoColor ~= described.HeadColor, "torso wears the top colour, not skin")
		assert(described.LeftLegColor ~= described.HeadColor, "legs wear the trouser colour, not skin")
		assert(broken.children[Survivor.FALLBACK], "a composed hair cap replaces the missing hair")
		table.clear(waits)
		local fine = fakeCharacter(true)
		local okFine, none = Survivor.dressCharacter(fine, preset, ports(fine))
		assert(okFine and #none == 0 and fine.applies == 1 and #waits == 0, "a loading outfit applies once")
		assert(fine.children[Survivor.FALLBACK] == nil, "no fallback when the real pieces loaded")
	end,
	["every preset colours its top and trousers unlike its skin"] = function()
		for _, preset in Survivor.PRESETS do
			local colors = Survivor.describe(preset).colors
			for _, key in { "TorsoColor", "LeftLegColor", "RightLegColor" } do
				local c = colors[key]
				assert(
					c and not (c.r == preset.skin.r and c.g == preset.skin.g and c.b == preset.skin.b),
					preset.id .. "." .. key
				)
			end
			assert(preset.hairColor, preset.id .. " hair colour")
		end
	end,
}
