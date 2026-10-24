--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Deploy = require("./deploy")

local ROLES = {
	"onboarding",
	"home",
	"harbor",
	"archipelago",
	"explore10",
	"explore20",
	"frontier30",
	"frontier40",
	"frontier50",
	"frontier60",
	"brawl",
	"team-outpost",
}

local function fullRoles(start: any): { [string]: any }
	local roles: { [string]: any } = {}
	for index, role in ROLES do
		roles[role] = if role == "onboarding" then start else 1000 + index
	end
	return roles
end

local function withFixture(pack: string, deployYml: string, body: (directory: string) -> ())
	local directory = "games/" .. pack
	assert(not fs.isDir(directory) and not fs.isFile(directory), "fixture path already owned")
	local ok, reason = xpcall(function()
		fs.writeDir(directory)
		fs.writeFile(directory .. "/game.yml", "name: Role fixture\nmonetization: {}\n")
		fs.writeFile(directory .. "/deploy.yml", deployYml)
		body(directory)
	end, debug.traceback)
	if fs.isDir(directory) then
		fs.removeDir(directory)
	end
	assert(ok, tostring(reason))
end

return {
	["per role deploy refuses unknown missing duplicate and zero targets"] = function()
		local config: any =
			{ environments = { staging = { universeId = 1, placeId = 2, roles = { harbor = 3, home = 4 } } } }
		local selected =
			assert(Deploy.roleTarget(config, "staging", "home"), "deploy-role.spec.luau: routing invariant")
		assert(selected.environments.staging.placeId == 4, "deploy-role.spec.luau: routing invariant")
		assert(config.environments.staging.placeId == 2, "deploy-role.spec.luau: routing invariant")
		assert(Deploy.roleTarget(config, "staging", "invalid") == nil, "deploy-role.spec.luau: routing invariant")
		assert(Deploy.roleTarget(config, "staging", "brawl") == nil, "deploy-role.spec.luau: routing invariant")
		config.environments.staging.roles.home = 0
		assert(Deploy.roleTarget(config, "staging", "home") == nil, "deploy-role.spec.luau: routing invariant")
		config.environments.staging.roles.home = 3
		assert(Deploy.roleTarget(config, "staging", "home") == nil, "deploy-role.spec.luau: routing invariant")
		config.environments.staging.roles.home = "${HOME_PLACE}"
		local referenced = Deploy.roleTarget(config, "staging", "home", { HOME_PLACE = "9" } :: { [string]: string? })
		assert(referenced and referenced.environments.staging.placeId == 9, "role id references resolve")
		assert(Deploy.roleTarget(config, "staging", "home", {}) == nil, "unset role reference is unconfigured")
	end,
	["role plan orders the start place last and reports missing and conflicting ids"] = function()
		local deploy = {
			environments = { staging = { universeId = "${U}", placeId = "${P}", roles = fullRoles("${P}") } },
		}
		local plan = assert(Deploy.rolePlan(deploy, "staging", { U = "42", P = "7" }))
		assert(#plan.places == #ROLES and #plan.missing == 0 and #plan.errors == 0, "complete plan")
		assert(plan.places[#plan.places].role == "onboarding" and plan.places[#plan.places].placeId == 7, "start last")
		assert(plan.places[1].role == "archipelago", "sorted role order")
		assert(
			plan.places[1].url == "https://apis.roblox.com/universes/v1/42/places/1004/versions?versionType=Published",
			"publish url"
		)
		assert(plan.map.onboarding == 7 and plan.map.home == 1002, "runtime role map")
		local unresolved = assert(Deploy.rolePlan(deploy, "staging", {}))
		assert(unresolved.universeId == nil and table.find(unresolved.missing, "onboarding"), "unset start missing")
		deploy.environments.staging.roles.home = 0
		deploy.environments.staging.roles.brawl = 1003
		deploy.environments.staging.roles.onboarding = 8
		local broken = assert(Deploy.rolePlan(deploy, "staging", { U = "42", P = "7" }))
		assert(table.find(broken.missing, "home"), "zero id is missing")
		assert(table.find(broken.errors, "duplicate_place_id:brawl,harbor"), "duplicate id refused")
		assert(table.find(broken.errors, "onboarding_not_start_place"), "onboarding must be the start place")
		assert(
			Deploy.rolePlan({ environments = { staging = { universeId = 1, placeId = 2 } } }, "staging", {}) == nil,
			"no roles, no plan"
		)
		local text = Deploy.renderRolePlan(broken, "staging")
		assert(string.find(text, "| - | home | MISSING |", 1, true), "missing row rendered")
	end,
	["dry run lists every role place offline and all-roles refuses before network"] = function()
		local yml = "environments:\n  staging:\n    universeId: 42\n    placeId: 7\n    roles:\n"
		for index, role in ROLES do
			yml ..= string.format(
				"      %s: %d\n",
				role,
				if role == "onboarding" then 7 elseif role == "brawl" then 0 else 100 + index
			)
		end
		yml ..= "  production:\n    universeId: 0\n    placeId: 0\n    roles:\n      onboarding: 0\n"
		withFixture("fixture-deploy-role-plan", yml, function(directory)
			local output = directory .. "/plan.json"
			local pack = "fixture-deploy-role-plan"
			local calls = 0
			local ports = {
				env = {},
				request = function(): any
					calls += 1
					return nil
				end,
			}
			assert(
				Deploy.run(
					{ "deploy", "--env", "staging", "--pack", pack, "--development", "--dry-run", "--out", output },
					ports
				)
			)
			local plan = serde.decode("json", fs.readFile(output))
			assert(#plan.rolePlaces.places == #ROLES - 1, "eleven publishable role places")
			assert(plan.rolePlaces.missing[1] == "brawl" and #plan.rolePlaces.missing == 1, "brawl missing")
			assert(not fs.isFile("build/" .. pack .. ".rbxl"), "dry run must not build")
			assert(
				not Deploy.run({ "deploy", "--env", "staging", "--pack", pack, "--development", "--all-roles" }, ports),
				"all-roles refuses a missing role"
			)
			assert(
				not Deploy.run({ "deploy", "--env", "staging", "--pack", pack, "--all-roles", "--role", "home" }, ports),
				"all-roles and role are exclusive"
			)
			assert(calls == 0 and not fs.isFile("build/" .. pack .. ".rbxl"), "refusal precedes build and network")
			assert(
				Deploy.run({ "deploy", "roles", "--env", "staging", "--pack", pack, "--set", "brawl=555" }),
				"roles write-back"
			)
			local written = fs.readFile(directory .. "/deploy.yml")
			assert(string.find(written, "      brawl: 555\n", 1, true), "staging brawl written")
			assert(string.find(written, "  production:\n    universeId: 0", 1, true), "production untouched")
			assert(
				not Deploy.run({ "deploy", "roles", "--env", "staging", "--pack", pack, "--set", "home=7" }),
				"duplicate id refused"
			)
			assert(
				not Deploy.run({ "deploy", "roles", "--env", "staging", "--pack", pack, "--set", "nope=9" }),
				"unknown role refused"
			)
			assert(fs.readFile(directory .. "/deploy.yml") == written, "refused write leaves deploy.yml unchanged")
		end)
	end,
	["all-roles publish posts one attempt per place and stops at the first failure"] = function()
		local deploy = { environments = { staging = { universeId = 42, placeId = 7, roles = fullRoles(7) } } }
		local plan = assert(Deploy.rolePlan(deploy, "staging", {}))
		local urls: { string } = {}
		local ok = Deploy.publishRoles(plan, "bytes", "key", function(request: any): any
			assert(request.body == "bytes" and request.headers["x-api-key"] == "key", "same artifact and key")
			table.insert(urls, request.url)
			return { statusCode = 200, ok = true, body = '{"versionNumber":3}' }
		end, "build/x.rbxl", "staging")
		assert(ok and #urls == #ROLES, "every role published")
		assert(string.find(urls[#urls], "/places/7/", 1, true), "start place published last")
		table.clear(urls)
		local failed = Deploy.publishRoles(plan, "bytes", "key", function(request: any): any
			table.insert(urls, request.url)
			return { statusCode = if #urls == 2 then 403 else 200, ok = true, body = '{"versionNumber":3}' }
		end, "build/x.rbxl", "staging")
		assert(not failed and #urls == 2, "first failure stops before the start place")
	end,
}
