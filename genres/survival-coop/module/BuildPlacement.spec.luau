--!strict
-- p60 real-input Studio defects: touch never moved the ghost, no PC rotate key, the ghost stayed
-- green on wildlife, and every server refusal read "move closer".
local fs = require("@lune/fs")
local Build = require("./BuildPlacement")
local Locale = require("./SurvivalHUDLocale")

local HUD = "genres/survival-coop/module/SurvivalHUD.luau"

local function node(attribute: string?, parent: any?): any
	return {
		Parent = parent,
		GetAttribute = function(_, key)
			return if key == "ForgeWildlifeId" then attribute else nil
		end,
	}
end

local function floor(instance: any?): any
	return { Instance = instance or node(nil), Normal = { Y = 1 }, Position = { Y = 4 } }
end

return {
	["p61 touch drag and tap move the ghost even when the camera consumed the touch"] = function()
		assert(Build.pointerUse("Touch", true, false), "processed touch drag still moves the ghost")
		assert(not Build.pointerUse("Touch", true, true), "a touch on a HUD button never moves the ghost")
		assert(Build.pointerUse("MouseMovement", false, false), "mouse hover moves the ghost")
		assert(not Build.pointerUse("MouseMovement", true, false), "mouse over GUI does not")
		assert(not Build.pointerUse("MouseButton1", false, false), "clicks are not pointer moves")
		assert(Build.isTap(100, 100, 108, 106) and not Build.isTap(100, 100, 130, 100), "tap vs drag")
		local source = fs.readFile(HUD)
		assert(not string.find(source, 'if processed or section ~= "build"', 1, true), "touch not gated on processed")
		assert(string.find(source, "input.InputEnded:Connect", 1, true), "tap-to-cell handler")
		assert(string.find(source, "BuildPlacement.pointerUse(kind, processed, over)", 1, true), "drag uses the rule")
		assert(string.find(source, "GetGuiObjectsAtPosition", 1, true), "HUD buttons keep their taps")
	end,
	["p61 a free PC key rotates the ghost and the build hints name it"] = function()
		assert(Build.ROTATE_KEY == "Y", "rotate key")
		local taken = {}
		for _, file in fs.readDir("genres/survival-coop/module") do
			if string.sub(file, -5) == ".luau" and not string.find(file, "%.spec%.luau$") then
				local text = fs.readFile("genres/survival-coop/module/" .. file)
				for key in string.gmatch(text, "Enum%.KeyCode%.(%w+)") do
					taken[key] = true
				end
			end
		end
		assert(not taken[Build.ROTATE_KEY], "rotate key collides with another bind")
		local source = fs.readFile(HUD)
		assert(string.find(source, "Enum.KeyCode :: any)[BuildPlacement.ROTATE_KEY]", 1, true), "key wired")
		for _, locale in { "en-us", "ko-kr" } do
			for _, key in { "placementHint", "buildHint" } do
				assert(string.find(Locale.text(locale, key), "Y", 1, true), locale .. " " .. key .. " names Y")
			end
		end
	end,
	["p61 ghost validity mirrors server occupancy and refusals are distinct"] = function()
		local cells = { { x = 0, z = 0 }, { x = 0, z = 1 } }
		local function probe(map: { [number]: any })
			return function(cell)
				local row = map[cell.z] or {}
				return row.support, row.parts or {}
			end
		end
		assert(
			Build.occupancy(cells, probe({ [0] = { support = floor() }, [1] = { support = floor() } }), true) == nil,
			"free level plot is valid"
		)
		local dino = node("rw.protoceratops.01")
		local hip = node(nil, dino)
		local blocked = probe({ [0] = { support = floor() }, [1] = { support = floor(), parts = { hip } } })
		assert(Build.occupancy(cells, blocked, false) == "PLACEMENT_BLOCKED_CREATURE", "wildlife turns it red")
		local standing = probe({ [0] = { support = floor(hip) } })
		assert(Build.occupancy(cells, standing, false) == "PLACEMENT_BLOCKED_CREATURE", "ray hits a dinosaur")
		local rock = probe({ [0] = { support = floor(), parts = { node(nil) } } })
		assert(Build.occupancy(cells, rock, true) == "PLACEMENT_BLOCKED", "part in the way")
		local slope = probe({ [0] = { support = { Instance = node(nil), Normal = { Y = 0.5 } } } })
		assert(Build.occupancy(cells, slope, false) == "PLACEMENT_UNSUPPORTED", "slope")
		assert(Build.occupancy(cells, probe({}), true) == "PLACEMENT_UNSUPPORTED", "server needs ground")
		assert(Build.occupancy(cells, probe({}), false) == nil, "client: unstreamed ground is unknown")
		local source = fs.readFile(HUD)
		assert(string.find(source, "reason = BuildPlacement.occupancy(checked", 1, true), "ghost colour uses it")
		local seen = {}
		for _, reason in
			{ "PLACEMENT_UNREACHABLE", "PLACEMENT_UNSUPPORTED", "PLACEMENT_BLOCKED", "PLACEMENT_BLOCKED_CREATURE" }
		do
			for _, locale in { "en-us", "ko-kr" } do
				local text = Locale.refusal(locale, reason)
				assert(text ~= Locale.refusal(locale, "unknown") and not seen[text], locale .. " " .. reason)
				seen[text] = true
			end
		end
		assert(
			not string.find(Locale.refusal("ko-kr", "PLACEMENT_BLOCKED_CREATURE"), "가까이 가서", 1, true),
			"ko"
		)
	end,
}
