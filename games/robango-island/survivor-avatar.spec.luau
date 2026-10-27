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
}
