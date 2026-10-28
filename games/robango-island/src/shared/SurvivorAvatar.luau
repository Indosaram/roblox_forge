--!strict
-- Robango survivors (plan G23 / A6): every player is a game-supplied adult survivor, never their
-- own Roblox avatar. Pure model (engine-free): the preset catalog, the HumanoidDescription values a
-- preset dresses, and the saved choice inside the actor's `robango-exp-v1` document.
--
-- Every catalog id below was checked on 2026-10-27 through
-- https://economy.roblox.com/v2/assets/<id>/details: creator Roblox (id 1), PriceInRobux 0 or part
-- of a free Roblox bundle (Man 238, Woman 239; catalog isFree = true). No paid or UGC item is used.
--
-- Swap point (A2 mesh survivors): a preset's `kind` selects how it dresses. "catalog" applies these
-- HumanoidDescription ids; a later "rig" kind can name a pack mesh rig while keeping the preset id,
-- so saved choices carry over unchanged.
local CosmeticVisual = require("../../../../genres/survival-coop/module/CosmeticVisual")
local M = {}

export type Rgb = { r: number, g: number, b: number }
export type Body = {
	torso: number,
	leftArm: number,
	rightArm: number,
	leftLeg: number,
	rightLeg: number,
	head: number,
	mood: number,
}
export type Preset = {
	id: string,
	kind: "catalog",
	body: Body,
	hair: number?,
	hat: number?,
	shirt: number,
	pants: number,
	skin: Rgb,
	scale: { height: number, width: number },
}

M.VERSION = 1

-- Verified catalog ids: id -> name and Roblox asset type id.
local CATALOG: { [number]: { name: string, assetType: number } } = {
	[86500008] = { name = "Man Torso", assetType = 27 },
	[86500036] = { name = "Man Right Arm", assetType = 28 },
	[86500054] = { name = "Man Left Arm", assetType = 29 },
	[86500064] = { name = "Man Left Leg", assetType = 30 },
	[86500078] = { name = "Man Right Leg", assetType = 31 },
	[10725826963] = { name = "Man Face - Head", assetType = 79 },
	[10725833199] = { name = "Man Face - Mood", assetType = 78 },
	[86499666] = { name = "Woman Torso", assetType = 27 },
	[86499698] = { name = "Woman Right Arm", assetType = 28 },
	[86499716] = { name = "Woman Left Arm", assetType = 29 },
	[86499753] = { name = "Woman Left Leg", assetType = 30 },
	[86499793] = { name = "Woman Right Leg", assetType = 31 },
	[10725626210] = { name = "Woman Face - Head", assetType = 79 },
	[10725638029] = { name = "Woman Face - Mood", assetType = 78 },
	[62234425] = { name = "Brown Hair", assetType = 41 },
	[62724852] = { name = "Chestnut Bun", assetType = 41 },
	[376548738] = { name = "Brown Charmer Hair", assetType = 41 },
	[1772336109] = { name = "Down to Earth Hair", assetType = 8 },
	[144076436] = { name = "Grey Striped Shirt with Denim Jacket", assetType = 11 },
	[398633584] = { name = "Denim Jacket with White Hoodie", assetType = 11 },
	[398635081] = { name = "Blue Plaid Shirt", assetType = 11 },
	[4047884046] = { name = "Guitar Tee with Black Jacket", assetType = 11 },
	[144076760] = { name = "Dark Green Jeans", assetType = 12 },
	[382537569] = { name = "Black Jeans", assetType = 12 },
	[398633812] = { name = "Black Jeans with White Shoes", assetType = 12 },
}
M.CATALOG = CATALOG

local MAN: Body = {
	torso = 86500008,
	rightArm = 86500036,
	leftArm = 86500054,
	leftLeg = 86500064,
	rightLeg = 86500078,
	head = 10725826963,
	mood = 10725833199,
}
local WOMAN: Body = {
	torso = 86499666,
	rightArm = 86499698,
	leftArm = 86499716,
	leftLeg = 86499753,
	rightLeg = 86499793,
	head = 10725626210,
	mood = 10725638029,
}

-- Original survivor outfits in muted work wear; ids are verified above. Order is the picker order.
M.PRESETS = {
	{
		id = "ranger",
		kind = "catalog",
		body = MAN,
		hair = 62234425,
		shirt = 144076436,
		pants = 144076760,
		skin = { r = 186, g = 142, b = 104 },
		scale = { height = 1.05, width = 1 },
	},
	{
		id = "scout",
		kind = "catalog",
		body = WOMAN,
		hair = 62724852,
		shirt = 398633584,
		pants = 382537569,
		skin = { r = 234, g = 196, b = 164 },
		scale = { height = 1, width = 0.92 },
	},
	{
		id = "forager",
		kind = "catalog",
		body = WOMAN,
		hat = 1772336109,
		shirt = 398635081,
		pants = 144076760,
		skin = { r = 124, g = 86, b = 62 },
		scale = { height = 0.98, width = 0.94 },
	},
	{
		id = "drifter",
		kind = "catalog",
		body = MAN,
		hair = 376548738,
		shirt = 4047884046,
		pants = 398633812,
		skin = { r = 160, g = 112, b = 80 },
		scale = { height = 1.02, width = 1.04 },
	},
} :: { Preset }

M.DEFAULT = "ranger"

function M.find(id: any): Preset?
	for _, preset in M.PRESETS do
		if preset.id == id then
			return preset
		end
	end
	return nil
end

--- The saved preset id in an actor document, or nil when the player never chose one.
function M.chosen(document: any): string?
	local saved = if type(document) == "table" then document.survivor else nil
	local id = if type(saved) == "table" then saved.preset else nil
	return if M.find(id) then id else nil
end

--- The preset the actor wears: the saved choice, else the default survivor.
function M.presetOf(document: any): Preset
	return M.find(M.chosen(document) or M.DEFAULT) :: Preset
end

--- Records `id` in the document (a transaction transform result). Unknown ids change nothing.
function M.select(document: any, id: any): { ok: boolean, reason: string?, data: any? }
	if not M.find(id) then
		return { ok = false, reason = "UNKNOWN_SURVIVOR" }
	end
	document.survivor = { version = M.VERSION, preset = id }
	return { ok = true, data = { preset = id } }
end

--- The client snapshot: the worn preset and whether the first-join picker is done.
function M.view(document: any): { preset: string, chosen: boolean }
	return { preset = M.presetOf(document).id, chosen = M.chosen(document) ~= nil }
end

--- HumanoidDescription property values for a catalog preset. Every property the description
--- does not set stays at its blank default, so nothing from the player's own avatar remains.
function M.describe(preset: Preset): { properties: { [string]: any }, skin: Rgb }
	assert(preset.kind == "catalog", "SURVIVOR_KIND_UNSUPPORTED")
	return {
		properties = {
			Torso = preset.body.torso,
			LeftArm = preset.body.leftArm,
			RightArm = preset.body.rightArm,
			LeftLeg = preset.body.leftLeg,
			RightLeg = preset.body.rightLeg,
			Head = preset.body.head,
			MoodAnimation = preset.body.mood,
			Face = 0,
			Shirt = preset.shirt,
			Pants = preset.pants,
			GraphicTShirt = 0,
			HairAccessory = if preset.hair then tostring(preset.hair) else "",
			HatAccessory = if preset.hat then tostring(preset.hat) else "",
			HeightScale = preset.scale.height,
			WidthScale = preset.scale.width,
			DepthScale = preset.scale.width,
			HeadScale = 1,
			BodyTypeScale = 0,
			ProportionScale = 0,
		},
		skin = preset.skin,
	}
end

--- Persists `id` as the actor's survivor through an ActorDocumentStore (`robango-exp-v1`).
function M.choose(store: any, actor: string, id: any): any
	return store.transaction(actor, function(document)
		return M.select(document, id)
	end)
end

--- What a character wears, bottom to top: the survivor preset is the base body and outfit, and the
--- paid worn sets the actor selected (MonetizationExtension appearance) dress on top of it. Mount
--- skins never touch the survivor; they render on the ride.
function M.dress(document: any, appearance: { [string]: boolean }?, cosmetics: CosmeticVisual.Config): any
	local preset = M.presetOf(document)
	return { preset = preset, description = M.describe(preset), wear = CosmeticVisual.wear(cosmetics, appearance) }
end

--- Engine adapter: dresses `character` as `preset`. `ports.description()` returns a new
--- HumanoidDescription and `ports.color(rgb)` a Color3. Worn paid pieces are welded to the body
--- parts this replaces, so their folder is dropped and the world re-dresses them on the new body.
function M.apply(character: any, preset: Preset, ports: any): (boolean, string?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "NO_HUMANOID"
	end
	local plan = M.describe(preset)
	local description = ports.description()
	for key, value in plan.properties do
		description[key] = value
	end
	local skin = ports.color(plan.skin)
	for _, key in { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" } do
		description[key] = skin
	end
	local ok, err = pcall(function()
		humanoid:ApplyDescriptionReset(description)
	end)
	if not ok then
		return false, tostring(err)
	end
	character:SetAttribute("ForgeSurvivor", preset.id)
	local worn = character:FindFirstChild(CosmeticVisual.FOLDER)
	if worn then
		worn:Destroy()
	end
	return true, nil
end

-- Server engine adapter (SurvivorWardrobe): dresses every character as its saved survivor on each
-- spawn and right after the picker saves a choice. The place loads no player avatar
-- (StarterPlayer.LoadCharacterAppearance = false). Paid worn sets are re-dressed on top by
-- SurvivalWorld's cosmetic sync after every apply.
-- ports: players, store (the robango-exp-v1 ActorDocumentStore), world (gains dressSurvivor).
function M.wardrobe(ports: any)
	local ApplyPorts = {
		description = function()
			return Instance.new("HumanoidDescription")
		end,
		color = function(rgb)
			return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
		end,
	}
	local function dress(player: Player)
		local character = player.Character
		if not character then
			return
		end
		-- The saved document can be briefly busy or not yet resumed on join: retry, then fall
		-- back to the default survivor so a player never keeps the blank starter body.
		local document: any = nil
		for _ = 1, 10 do
			local snapshot = ports.store.snapshot(tostring(player.UserId))
			if snapshot then
				document = snapshot
				break
			end
			task.wait(1)
			if player.Character ~= character then
				return
			end
		end
		-- ApplyDescription needs the character in the DataModel; CharacterAdded can fire before the
		-- spawn gate parents it.
		while not character:IsDescendantOf(workspace) do
			if player.Character ~= character or player.Parent == nil then
				return
			end
			character.AncestryChanged:Wait()
		end
		local ok, reason = M.apply(character, M.presetOf(document), ApplyPorts)
		if not ok then
			warn("SURVIVOR_APPLY:" .. tostring(reason))
		end
	end
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			task.spawn(dress, player)
		end)
		if player.Character then
			task.spawn(dress, player)
		end
	end
	ports.players.PlayerAdded:Connect(watch)
	for _, player in ports.players:GetPlayers() do
		watch(player)
	end
	ports.world.dressSurvivor = function(actor: string)
		local player = ports.players:GetPlayerByUserId(tonumber(actor) or 0)
		if player then
			task.spawn(dress, player)
		end
	end
end

-- First-join survivor picker. Shown once, when the saved document has no choice yet; a pick
-- persists through `survival-coop:mission-action { "survivor", <presetId> }` (the pack's archipelago
-- extension stores it in the robango-exp-v1 actor document) and the server re-dresses the character.
-- Copy comes from the cli.survivor.* rows of locale/strings.csv.
M.PICK_ACTION = "survival-coop:mission-action"

--- Picker rows: { id, text } per preset, the worn one marked. `text(key)` resolves cli.survivor.*.
function M.pickerRows(presets: { any }, view: any, text: (string) -> string): { { string } }
	local rows = {}
	local current = if type(view) == "table" then view.preset else nil
	for _, preset in presets do
		local label = text(preset.id) .. " - " .. text(preset.id .. "_note")
		if preset.id == current then
			label = label .. " (" .. text("current") .. ")"
		end
		table.insert(rows, { preset.id, label })
	end
	return rows
end

--- True when the picker must open: the server says no survivor was chosen yet.
function M.pickerNeeded(view: any): boolean
	return type(view) == "table" and view.chosen == false
end

--- Panel factory (ExtensionPanels context plus `presets` and `text`).
function M.picker(ctx: any): any
	local player = game:GetService("Players").LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.Enabled = "ForgeSurvivorPicker", false, 26, false
	gui.Parent = player:WaitForChild("PlayerGui")
	local sheet = ctx.ui.components.modalSheet(ctx.ui.theme.default, {
		name = "SurvivorPicker",
		title = ctx.text("title"),
		parent = gui,
	})
	assert(ctx.fitSheet, "SURVIVOR_SHEET_REQUIRED")(sheet.frame)
	sheet.frame.Visible = true
	local intro = ctx.ui.components.label(ctx.ui.theme.default, {
		text = ctx.text("intro"),
		size = UDim2.new(1, 0, 0, 40),
		parent = sheet.scroll,
	})
	intro.TextWrapped, intro.LayoutOrder = true, 0
	local view: any = nil
	local asked = false
	local connections = {}
	local buttons: { [string]: TextButton } = {}
	local function render()
		for _, row in M.pickerRows(ctx.presets, view, ctx.text) do
			local button = buttons[row[1]]
			if button then
				button.Text = row[2]
			end
		end
	end
	for index, row in M.pickerRows(ctx.presets, view, ctx.text) do
		local id = row[1]
		local button = ctx.ui.components.button(ctx.ui.theme.default, {
			text = row[2],
			size = UDim2.new(1, 0, 0, 48),
			parent = sheet.scroll,
		})
		button.Name, button.LayoutOrder, button.TextWrapped = "Survivor-" .. id, index, true
		buttons[id] = button
		table.insert(
			connections,
			button.Activated:Connect(function()
				local result = ctx.send(M.PICK_ACTION, { "survivor", id })
				if result and result.ok then
					view = { preset = id, chosen = true }
					render()
					gui.Enabled = false
				end
			end)
		)
	end
	table.insert(
		connections,
		sheet.close.Activated:Connect(function()
			gui.Enabled = false
		end)
	)
	local stop = ctx.onSnapshot(function(snapshot)
		local trip = if type(snapshot) == "table" then snapshot.archipelago else nil
		local next = if type(trip) == "table" then trip.survivor else nil
		if next then
			view = next
			render()
			if M.pickerNeeded(view) and not asked then
				asked = true
				gui.Enabled = true
			end
		end
	end)
	return {
		destroy = function()
			stop()
			for _, connection in connections do
				connection:Disconnect()
			end
			gui:Destroy()
		end,
	}
end

return M
