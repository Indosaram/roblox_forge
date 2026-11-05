--!strict
-- p134 v75/v76 fresh-account phone run (SM-N981N, ko-kr, touch, 914x411 under a 58 px top bar):
-- the LOW items left after the v75 batch (C1 timer pill over sheet titles, C3 campfire ghost always
-- 'blocked' and red, C4 empty survivor picker portraits).
local Harness = require("./PanelHarness.fixture")
local Settlement = require("../../core/domain/settlement/Settlement")
local Source = require("./src/shared/SurvivalWorldConfig")

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function find(root: any, name: string): any
	for _, item in root:GetDescendants() do
		if item.Name == name then
			return item
		end
	end
	return nil
end

return {
	-- C1: '표류섬 남은 시간' (SeaChart DriftTimer, its own gui above the HUD) sat on the title bar of
	-- every sheet opened on the isle (연습과 악기, 안내, 길들인 동물). The pill now yields to an open
	-- sheet like the hunger tip and the waypoint arrow (Waypoint.covered), and comes back after.
	-- Fails on 12df9def: the pill stayed visible over the sheet header.
	["v75 C1: the drift-isle timer pill never draws over an open sheet's title bar"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true })
		h.workspace:SetAttribute("ForgeWorldRole", "archipelago")
		h.publish({
			archipelago = { status = "active", templateId = "rw.a1", stage = 1, expiresAt = 1800 },
		})
		local pill = assert(find(h.playerGui, "DriftTimer"), "drift timer pill")
		assert(pill.Visible, "the pill shows on an active drift isle")
		-- The HUD's own sheet (craft) and a docked menu sheet (안내 / guides).
		local opened = {
			function()
				h.hud.open("craft")
			end,
			function()
				h.click(h.toggle)
				h.click(h.tile("guides"))
			end,
		}
		for index, open in opened do
			open()
			h.step()
			local sheets = h.sheets()
			assert(#sheets > 0, "a sheet is open (" .. index .. ")")
			for _, sheet in sheets do
				local header = sheet.frame:FindFirstChild("Header") or sheet.close
				local hit = pill.Visible and overlaps(h.rect(pill), h.rect(header))
				assert(not hit, string.format("pill over the '%s' title bar (%d)", sheet.frame.Name, index))
				assert(not pill.Visible, "the pill yields to the open sheet (" .. index .. ")")
			end
			for _, sheet in sheets do
				h.click(sheet.close)
			end
			h.hud.close()
			if h.menu.Visible then
				h.click(h.toggle)
			end
			h.step()
			assert(pill.Visible, "the pill comes back when the sheet closes (" .. index .. ")")
		end
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	-- C3: the campfire ghost read '바위·나무·건물 같은 장애물이 있어요' with a red footprint even on the
	-- beam spot, and 설치 still placed it. The ghost starts under the player and the opening's
	-- client-only Tumble rig (ForgeOpeningLocal; DinosaurRig Humanoid parts collide) follows 4 studs
	-- behind, so the HUD's box probe always found it; the server, which never sees that rig, did not.
	-- Fails on 12df9def: the companion turned the clear cell red with the obstacle line.
	["v75 C3: the build ghost is green on a clear cell next to the companion, red only on a real obstacle"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true })
		local tribe = Source.tribe
		local settlement = Settlement.new({
			tribeId = tribe.config.tribeId,
			width = tribe.config.width,
			depth = tribe.config.depth,
			cellStuds = tribe.config.cellStuds,
			maxMembers = tribe.config.maxMembers,
		}, "1")
		-- The opening's client-only stage with Tumble's collidable rig part in it.
		local stage = h.new("Folder", "ForgeOpeningLocal")
		stage:SetAttribute("ForgeLocalOnly", true)
		stage.Parent = h.workspace
		local rig = h.new("Model", "Opening-protoceratops")
		rig.Parent = stage
		local torso = h.new("Part", "Torso")
		torso.Parent = rig
		local rock = h.new("Part", "Rock")
		local rockHere = false
		h.workspace.GetPartBoundsInBox = function(_self, _cframe, _size, params)
			local found = {}
			if not table.find(params.FilterDescendantsInstances or {}, stage) then
				table.insert(found, torso)
			end
			if rockHere then
				table.insert(found, rock)
			end
			return found
		end
		local wood = { itemId = "w", catalogId = "wood", quantity = 6, qualityMilli = 1000, durabilityMilli = 0 }
		h.packet({
			revision = 1,
			durable = { actions = { "survival-coop:settlement-reserve" }, epochs = {} },
			snapshots = {
				["survival-coop"] = {
					progression = { level = 3, sp = 0, xp = 0, paid = {}, version = 1 },
					inventory = {},
				},
				survivalSettlement = {
					settlement = settlement,
					warehouse = { kind = "warehouse", items = { w = wood }, reservations = {}, version = 1 },
				},
				survivalExtensions = {},
			},
		})
		h.hud.open("build")
		h.step()
		local function build()
			h.click(assert(find(h.playerGui, "BuildTab-station"), "stations tab"))
			h.click(assert(find(h.playerGui, "Structure-campfire"), "campfire Build"))
		end
		build()
		local reason = assert(find(h.playerGui, "PlacementReason"), "placement reason line")
		local ghost = assert(h.workspace:FindFirstChild("ForgeBuildPreview"), "build ghost")
		local function footprints(): { any }
			local out = {}
			for _, part in ghost:GetChildren() do
				if part.Name == "Footprint" then
					table.insert(out, part)
				end
			end
			assert(#out > 0, "a footprint")
			return out
		end
		assert(reason.Text == "", "no obstacle line on a clear cell: " .. reason.Text)
		for _, part in footprints() do
			assert(part.Color.G > part.Color.R, "clear footprint is green, not red")
		end
		-- A real obstacle still turns it red with the obstacle line.
		rockHere = true
		h.click(assert(find(h.playerGui, "CancelPlacement"), "cancel"))
		build()
		assert(string.find(reason.Text, "장애물", 1, true), "a real obstacle names itself: " .. reason.Text)
		for _, part in footprints() do
			assert(part.Color.R > part.Color.G, "blocked footprint is red")
		end
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
	-- C4: the survivor picker's four portrait cards were empty squares (v74 portrait run, v75
	-- landscape). The portraits cloned each rig template as soon as its Model replicated, before its
	-- mesh pieces streamed in, kept that empty clone and never retried. A card now shows the survivor
	-- icon until the template's body piece is there, then the live portrait.
	-- Fails on 12df9def: no fallback image, and the early empty clone stayed for good.
	["v75 C4: survivor picker cards show the survivor icon, then the portrait once the rig streams in"] = function()
		local h = Harness.harness({ width = 914, height = 411, inset = 58, realHud = true })
		local picker = assert(h.playerGui:FindFirstChild("ForgeSurvivorPicker"), "picker gui")
		local card = assert(find(picker, "Survivor-ranger"), "ranger card")
		local art = assert(card:FindFirstChild("Portrait"), "portrait viewport")
		local function figure(): any
			for _, child in art:GetChildren() do
				if child.ClassName == "Model" then
					return child
				end
			end
			return nil
		end
		local function fallback(): any
			return art:FindFirstChild("PortraitFallback")
		end
		local shown = fallback()
		assert(shown and shown.Visible ~= false, "a fallback image while no rig is in")
		assert(string.match(shown.Image, "^rbxassetid://%d+$"), "the fallback is real art: " .. tostring(shown.Image))
		-- Engine-like replication: the rig Model arrives first (ChildAdded), its pieces after it.
		local function clone(item: any): any
			local copy = h.new(item.ClassName, item.Name)
			for _, child in item:GetChildren() do
				clone(child).Parent = copy
			end
			copy.Clone = clone
			return copy
		end
		local storage = h.game:GetService("ReplicatedStorage")
		local folder = h.new("Folder", "ForgeSurvivorRigs")
		folder.Parent = storage
		storage.ChildAdded:Fire(folder)
		local model = h.new("Model", "ranger")
		model.Clone = clone
		model.Parent = folder
		folder.ChildAdded:Fire(model)
		assert(fallback().Visible ~= false, "an empty rig keeps the fallback")
		local body = h.new("Part", "UpperTorso__body__ranger")
		body.Parent = model
		local portrait = figure()
		assert(portrait, "the portrait appears once the body piece is in")
		assert(portrait:FindFirstChild("UpperTorso__body__ranger"), "the portrait holds the painted body")
		assert(fallback().Visible == false, "the fallback hides under the portrait")
		assert(#h.errors == 0, tostring(h.errors[1]))
	end,
}
