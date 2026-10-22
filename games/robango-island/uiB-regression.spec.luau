--!strict
local fs = require("@lune/fs")
local Text = require("./src/shared/WorldText")
local Content = require("./src/shared/SurvivalContent")
local Home = require("../../core/domain/home/HomeState")
local HomeContent = require("../../core/domain/home/HomeContent")
local HomeWorld = require("./src/server/HomeWorld")
local Permissions = require("../../genres/survival-coop/module/HomePermissionsPanel")
local Social = require("../../genres/survival-coop/module/SocialLocale")
local Taming = require("../../genres/survival-coop/module/TamingPanel")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
return {
	["role prompt construction uses locale keys rather than English literals or raw ids"] = function()
		for _, path in
			{
				"src/server/RoleWorld.luau",
				"src/server/SurvivalWorldBootstrap.luau",
				"src/client/RobangoIslandClient.client.luau",
			}
		do
			local source = fs.readFile("games/robango-island/" .. path)
			for assignment in string.gmatch(source, "[%w_]+%.[AO][bc][jt][ei][co][tn]Text[^\n]*") do
				assert(not string.find(assignment, '= "'), "literal prompt copy: " .. assignment)
				assert(not string.find(assignment, "= if korean", 1, true), "inline prompt translation: " .. assignment)
			end
		end
		local engine = Engine.new()
		for _, layout in { "rw.harbor", "rw.home", "rw.a1.s1" } do
			local world = engine.role.build(
				Content,
				require("./src/shared/SurvivalWorldConfig"),
				require("./src/shared/WildlifePolicy"),
				function()
					return 0
				end,
				layout,
				1776
			)
			for _, prompt in engine.game:GetService("Workspace"):GetDescendants() do
				if prompt:IsA("ProximityPrompt") then
					local action = prompt:GetAttribute("ForgeActionKey")
					if action then
						assert(Text.strings[action], "missing action key " .. action)
						local object = prompt:GetAttribute("ForgeObjectKey")
						assert(not object or Text.strings[object], "missing object key " .. tostring(object))
						Text.localize(prompt, "ko-kr")
						assert(not string.find(prompt.ActionText, "%a"), "English action in KO")
						assert(not string.find(prompt.ObjectText or "", "%a"), "English object in KO")
					end
				end
			end
			world.destroy()
		end
	end,
	["default home owns one usable starter plot rendered with a localized farm prompt"] = function()
		local rules = HomeContent.rules(Content)
		local home = Home.new("11734795308", rules, 1776)
		local count = 0
		for _, structure in home.structures do
			if structure.kind == "farm-plot" then
				count += 1
			end
		end
		assert(count == 1, "new home must own exactly one starter farm plot")
		local engine = Engine.new(nil, true)
		local world = engine.role.build(
			Content,
			require("./src/shared/SurvivalWorldConfig"),
			require("./src/shared/WildlifePolicy"),
			function()
				return 0
			end,
			"rw.home",
			1776
		)
		world.renderHome(HomeWorld.plan(Content, home, rules))
		local plot = engine.game
			:GetService("Workspace")
			:FindFirstChild("ForgeRoleWorld")
			:FindFirstChild("HomeStructures")
			:FindFirstChild("starter-farm")
		local prompt = assert(plot:FindFirstChild("ProximityPrompt"), "starter farm prompt missing")
		local position = plot.Position
		local vector = require("@lune/roblox").Vector3
		local ground = engine.game
			:GetService("Workspace")
			:Raycast(position + vector.new(0, 64, 0), vector.new(0, -128, 0), { IgnoreWater = true })
		assert(
			ground and position.Y - plot.Size.Y / 2 >= ground.Position.Y,
			"starter plot must not be buried in home terrain"
		)
		assert(prompt:GetAttribute("ForgePanel") == "farm", "farm sheet route")
		Text.localize(prompt, "ko-kr")
		assert(prompt.ObjectText == Text.text("ko-kr", "farm-plot"), "farm localized")
		world.destroy()
	end,
	["home access labels self without exposing a numeric owner id"] = function()
		local home = Home.new("11734795308", HomeContent.rules(Content), 1776)
		for _, locale in { "ko-kr", "en-us" } do
			local rows = Permissions.rows(locale, { home = home, actorId = home.owner }, {})
			assert(not string.find(rows[1].text, home.owner, 1, true), "numeric owner id exposed")
			assert(string.find(rows[1].text, Social.text(locale, "perm.me"), 1, true), "localized self label")
		end
	end,
	["all production wildlife have localized Korean nameplates"] = function()
		for _, species in Content.wildlife do
			local name = Taming.species("ko-kr", species.id)
			assert(not string.find(name, "%a"), "untranslated wildlife " .. species.id)
			assert(Taming.species("en-us", species.id) ~= species.id, "raw wildlife id " .. species.id)
		end
	end,
}
