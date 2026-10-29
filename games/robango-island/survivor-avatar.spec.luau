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
	-- L6: the presets dress the pack's own survivor meshes (mesh-survivors) on two body types.
	["L6 rig presets: two body types, every worn slot coloured, a stable figure per name"] = function()
		local bodies = {}
		for _, preset in Survivor.PRESETS do
			assert(preset.kind == "rig", preset.id .. " is a rig preset")
			assert(preset.rigBody and Survivor.BODIES[preset.rigBody], preset.id .. " body type")
			bodies[preset.rigBody :: string] = true
			local palette = assert(preset.palette, preset.id .. " palette")
			for _, slot in { "skin", "shirt", "boots", "hair" } do
				assert(palette[slot], preset.id .. " colours " .. slot)
			end
			local skin, material = Survivor.slotStyle(preset, "skin")
			assert(skin == palette.skin and material == "SmoothPlastic", "skin slot style")
			local _, boots = Survivor.slotStyle(preset, "trousers")
			assert(boots == "SmoothPlastic", "no patterned engine material on clothing")
			local eye = Survivor.slotStyle(preset, "eye")
			assert(eye.r < 80, "face details are dark")
		end
		assert(bodies.A and bodies.B, "both body types are used")
		assert(Survivor.figurePreset("npc.marit") == Survivor.figurePreset("npc.marit"), "stable figure")
		local seen = {}
		for _, name in { "npc.marit", "npc.tuck", "npc.hop", "npc.sella", "npc.bram", "npc.ines", "npc.pip" } do
			seen[Survivor.figurePreset(name).id] = true
		end
		local count = 0
		for _ in seen do
			count += 1
		end
		assert(count >= 3, "harbor townspeople wear several outfits")
		local part, slot, preset = Survivor.piece("LeftUpperArm__shirt__scout")
		assert(part == "LeftUpperArm" and slot == "shirt" and preset == "scout", "piece name split")
		assert(Survivor.piece("Anchor__anchor__ranger") == "Anchor", "anchor piece")
	end,
	["L6 joint layout: every R15 joint pivots at the end of its child part"] = function()
		local parts = 0
		for _, bodyId in { "A", "B" } do
			local layout = Survivor.layout(bodyId)
			parts = 0
			for _ in layout.rest do
				parts += 1
			end
			assert(parts == 16, "16 R15 parts incl. the root")
			local joints = 0
			for name, joint in layout.joints do
				joints += 1
				assert(layout.rest[joint.parent], name)
				local b = assert(layout.rest[joint.child], name)
				assert(
					math.abs(joint.at.y - b.y) <= 0.8 and math.abs(joint.at.x - b.x) <= 0.1,
					name .. " pivot at the child's end"
				)
			end
			assert(joints == 15, "15 R15 joints")
			-- Feet stand on the floor the humanoid's hip height puts under the root.
			local foot = layout.rest.LeftFoot
			assert(math.abs(foot.y - 0.15 + Survivor.ROOT_HEIGHT) < 1e-6, "foot on the floor")
			assert(
				math.abs(Survivor.ROOT_HEIGHT - (Survivor.HIP_HEIGHT + 2 / 2)) < 1e-6,
				"hip height + half the root = floor"
			)
		end
		assert(Survivor.layout("A").rest.LeftUpperArm.x < Survivor.layout("B").rest.LeftUpperArm.x, "body A is broader")
	end,
	["L6 dressRig leaves the character alone while the rig package is not loaded"] = function()
		local applied = false
		local character: any = {}
		function character.FindFirstChildOfClass(_, class)
			return if class == "Humanoid"
				then {
					ApplyDescriptionReset = function()
						applied = true
					end,
				}
				else nil
		end
		Survivor.setRigs(nil)
		local ok, why = Survivor.dressRig(character, assert(Survivor.find("scout")), {})
		assert(not ok and why == "RIG_NOT_LOADED" and not applied, "no package: nothing changes (catalog look follows)")
		assert(Survivor.figure("npc.pip", {} :: any) == nil, "no figure before the package loads")
	end,
	["L6 wiring: the wardrobe loads the rig package and NPCs and castaways reuse the figures"] = function()
		local fs = require("@lune/fs")
		local source = fs.readFile("games/robango-island/src/shared/SurvivorAvatar.luau")
		assert(string.find(source, "MeshTexture.bake", 1, true), "the package goes through MeshTexture")
		assert(string.find(source, "task.spawn(M.loadRigs)", 1, true), "wardrobe loads the rigs")
		local role = fs.readFile("games/robango-island/src/server/RoleWorld.luau")
		for _, needle in
			{
				"survivorFigure(facility.anchor, target)",
				'survivorFigure("castaway:" .. actor, npc)',
				'survivorFigure("town:" .. anchor.id, handle)',
			}
		do
			assert(string.find(role, needle, 1, true), "RoleWorld wires " .. needle)
		end
		local Assets = require("./src/shared/Assets")
		assert(string.match(Assets[Survivor.RIG_PACKAGE], "^rbxassetid://%d+$"), "mesh-survivors has an asset id")
	end,
}
