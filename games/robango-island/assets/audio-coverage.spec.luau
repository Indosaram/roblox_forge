--!strict
-- Every player-facing gameplay event resolves to a catalog slot, and every slot to a manifest
-- asset whose local file exists (uploaded or pending the local rbxasset fallback).
local Catalog = require("../src/shared/RobangoAudioCatalog")
local Audio = require("../src/client/RobangoAudio")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local ROOT = "games/robango-island/"
-- Gameplay event -> catalog event it must sound.
local REQUIRED: { [string]: string } = {
	["gather wood"] = "gather-wood",
	["gather stone"] = "gather-stone",
	["gather plant"] = "gather-plant",
	["gather shell"] = "gather-shell",
	["gather clay"] = "gather-clay",
	["gather meat"] = "gather-meat",
	["gather refusal/cooldown"] = "gather-refused",
	["craft start"] = "craft-start",
	["craft complete"] = "craft-complete",
	["build place"] = "build-place",
	["build complete"] = "build-complete",
	["repair"] = "repair",
	["market buy"] = "market-buy",
	["market sell"] = "market-sell",
	["market refusal"] = "ui-error",
	["shop purchase"] = "shop-purchase",
	["shop receipt"] = "shop-receipt",
	["tame success"] = "tame-success",
	["tame fail"] = "tame-fail",
	["mount"] = "mount",
	["dismount"] = "dismount",
	["creature telegraph"] = "creature-telegraph",
	["creature strike"] = "creature-strike",
	["player hit"] = "hit",
	["knockout"] = "knockout",
	["respawn"] = "respawn",
	["level up"] = "level-up",
	["contract complete"] = "contract-complete",
	["expedition depart"] = "travel-horn",
	["expedition arrive"] = "expedition-arrive",
	["expedition results"] = "expedition-results",
	["expedition claim"] = "reward",
	["hazard entry"] = "hazard-enter",
	["ui open"] = "ui-open",
	["ui close"] = "ui-close",
	["ui click"] = "ui-click",
	["toast success"] = "ui-confirm",
	["toast error"] = "ui-error",
}

local function manifest(): { [string]: any }
	local doc = serde.decode("yaml", fs.readFile(ROOT .. "assets/manifest.yml"))
	local byKey = {}
	for _, asset in doc.assets do
		byKey[asset.key] = asset
	end
	return byKey
end

local function routed(): { [string]: boolean }
	local values = {}
	for _, map in { Catalog.actions, Catalog.refusals, Catalog.gather, Catalog.wildlife, Catalog.signals } do
		for _, event in map do
			values[event] = true
		end
	end
	return values
end

local ok = { ok = true, stateVersion = 1 }
local function req(action: string, args: { any }?): any
	return { action = "survival-coop:" .. action, requestId = "r", args = args or {} }
end

return {
	["every listed gameplay event maps to a routed catalog slot"] = function()
		local wired = routed()
		for label, event in REQUIRED do
			local slot = Catalog.events[event]
			assert(slot, label .. ": no catalog event " .. event)
			assert(Catalog.slots[slot], label .. ": event " .. event .. " has no slot")
			assert(wired[event], label .. ": " .. event .. " is not routed from gameplay")
		end
		for _, map in { Catalog.actions, Catalog.refusals, Catalog.gather, Catalog.wildlife, Catalog.signals } do
			for key, event in map do
				assert(Catalog.events[event], tostring(key) .. " routes to unknown event " .. event)
			end
		end
	end,
	["every catalog slot maps to a manifest audio asset with a local file"] = function()
		local byKey = manifest()
		for name, slot in Catalog.slots do
			local asset = byKey[slot.asset]
			assert(asset, name .. ": manifest asset " .. slot.asset .. " missing")
			assert(asset.kind == "sfx" or asset.kind == "bgm", name .. ": not an audio asset")
			assert(type(asset.path) == "string" and fs.isFile(ROOT .. asset.path), name .. ": file missing")
			assert(
				(asset.assetId > 0) == (asset.moderation ~= "NotUploaded"),
				name .. ": upload id and moderation disagree"
			)
		end
		for _, instrument in { "bass", "clarinet", "drums", "flute", "guitar", "piano", "trumpet", "violin" } do
			local asset = byKey["audio-instrument-" .. instrument]
			assert(asset and fs.isFile(ROOT .. asset.path), instrument .. " instrument sample missing")
		end
	end,
	["every gather node kind has a material cue"] = function()
		local doc = serde.decode("yaml", fs.readFile(ROOT .. "content.yml"))
		for _, node in doc.nodes do
			assert(Catalog.gather[node.id], node.id .. " has no gather cue")
		end
	end,
	["every role-world gather node resolves a material cue"] = function()
		-- RoleWorld registers node kind gsub(id, "[._]", "-") (rw-a1-s1-material-wood) and publishes
		-- ForgeNodeItem; Studio p37 found every expedition gather silent.
		local doc = serde.decode("yaml", fs.readFile(ROOT .. "content.yml"))
		local confirmed = { ok = true, data = { status = "confirmed" } }
		local checked = 0
		for _, layout in doc.layouts do
			for _, node in layout.resourceNodes or {} do
				if not string.find(node.id, ".cargo.", 1, true) and not string.find(node.id, ".chapter.", 1, true) then
					local kind = string.gsub(node.id, "[._]", "-")
					local got = Audio.commandEvent(Catalog, req("gather"), confirmed, kind, node.item)
					assert(got and Catalog.events[got], node.id .. " (" .. node.item .. ") has no gather cue")
					checked += 1
				end
			end
		end
		assert(checked >= 200, "role-world nodes checked: " .. checked)
		local wood = Audio.commandEvent(Catalog, req("gather"), confirmed, "rw-a1-s1-material-wood", "wood")
		assert(wood == "gather-wood", "a1.s1 wood -> " .. tostring(wood))
	end,
	["command results route to the expected cues"] = function()
		local function E(_config: any, request: any, result: any, kind: string?, want: string?)
			local got = Audio.commandEvent(Catalog, request, result, kind)
			assert(got == want, request.action .. " -> " .. tostring(got) .. ", want " .. tostring(want))
		end
		E(Catalog, req("gather"), { ok = true, data = { status = "confirmed" } }, "marsh-clay-bank", "gather-clay")
		E(Catalog, req("gather"), { ok = false, reason = "NODE_COOLDOWN" }, nil, "gather-refused")
		E(Catalog, req("gather"), { ok = false, reason = "COMMAND_PENDING" }, nil, nil) -- retry is silent
		E(Catalog, req("craft-start"), ok, nil, "craft-start")
		E(Catalog, req("item-repair"), ok, nil, "repair")
		E(Catalog, req("market-buy"), ok, nil, "market-buy")
		E(Catalog, req("harbor-sell"), ok, nil, "market-sell")
		E(Catalog, req("market-buy"), { ok = false, reason = "INSUFFICIENT_FUNDS" }, nil, "ui-error")
		E(Catalog, req("shop-prompt"), ok, nil, "shop-purchase")
		E(Catalog, req("tame-capture"), { ok = true, data = { captured = true } }, nil, "tame-success")
		E(Catalog, req("tame-capture"), { ok = true, data = { captured = false } }, nil, "tame-fail")
		E(Catalog, req("tame-dismount"), ok, nil, "dismount")
		E(Catalog, req("contract-claim"), ok, nil, "contract-complete")
		E(Catalog, req("party-action", { "depart", "1" }), ok, nil, "travel-horn")
		E(Catalog, req("party-action", { "claim", "x" }), ok, nil, "reward")
		E(Catalog, req("party-action", { "invite", "x" }), ok, nil, nil) -- unmapped verb silent
	end,
	["snapshot edges sound vitals, level, expedition, hazard and receipts once"] = function()
		local function snap(health, level, ext)
			return {
				["survival-coop"] = { vitals = { healthMilli = health }, progression = { level = level } },
				survivalExtensions = ext,
			}
		end
		local edges, facts = Audio.snapshotEdges(nil, snap(1000, 1, {}))
		assert(#edges == 0, "first snapshot is a baseline")
		edges, facts = Audio.snapshotEdges(facts, snap(800, 2, { monetization = { grants = 0 } }))
		assert(table.concat(edges, ",") == "playerHit,levelUp", table.concat(edges, ","))
		edges, facts = Audio.snapshotEdges(facts, snap(0, 2, { monetization = { grants = 1 } }))
		assert(table.concat(edges, ",") == "knockout,shopReceipt", table.concat(edges, ","))
		local trip = {
			expedition = {
				arrival = { id = "t", stage = 1 },
				hazard = {},
				results = { id = "t", status = "done" },
			},
		}
		edges, facts = Audio.snapshotEdges(facts, snap(1000, 2, trip))
		assert(
			table.concat(edges, ",") == "respawn,expeditionArrive,expeditionResults,hazardEnter",
			table.concat(edges, ",")
		)
		edges = Audio.snapshotEdges(facts, snap(1000, 2, trip))
		assert(#edges == 0, "unchanged snapshot is silent")
		for _, name in { "playerHit", "levelUp", "knockout", "respawn", "shopReceipt" } do
			assert(Catalog.signals[name], name .. " signal unmapped")
		end
	end,
}
