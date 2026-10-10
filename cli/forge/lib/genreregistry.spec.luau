--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Registry = require("./genreregistry")
local serial = 0
local function sandbox(body: (string) -> ())
	serial += 1
	local root = string.gsub(process.env.TEMP or process.env.TMP or process.cwd, "\\", "/")
		.. "/forge-contract-"
		.. tostring(math.floor(os.clock() * 1e6))
		.. "-"
		.. serial
	fs.writeDir(root)
	local ok, err = pcall(body :: any, root)
	fs.removeDir(root)
	assert(ok, tostring(err))
end
local function package(root: string, id: string)
	local path = root .. "/" .. id
	fs.writeDir(path .. "/module")
	fs.writeDir(path .. "/qa-scenarios")
	fs.writeFile(
		path .. "/forge-package.yml",
		serde.encode("yaml", {
			name = id,
			version = "0.1.0",
			requires = { core = "^1.0.0" },
			genre_contract = {
				api = 1,
				generator = "generator.luau",
				runtime = "module/Contract.luau",
				spec = "genre-spec.yml",
			},
		})
	)
	fs.writeFile(
		path .. "/genre-spec.yml",
		string.format(
			[[api: 1
version: 1.0.0
id: %s
runtime: %s
resources: []
entities: []
actions: []
loop: []
ui:
  resourceBar: {resources: [], order: 1}
  actionButtons: {from: actions, kinds: [button, prompt, player-button], order: 2}
  objective: {from: loop, order: 4}
  notifications: {kinds: [info, refuse, reward], order: 5}
locale:
  default: en
  strings:
    hud_menu: {ko: "메뉴"}
    hud_select_player: {ko: "플레이어를 먼저 선택하세요"}
]],
			id,
			id
		)
	)
	fs.writeFile(
		path .. "/module/Contract.luau",
		"return {api=1,id="
			.. string.format("%q", id)
			.. ",configVersion=1,saveVersion=1,actions={},events={},hooks={},validateConfig=function() return {} end,validateSave=function() return {} end,create=function() return {} end}"
	)
	fs.writeFile(
		path .. "/generator.luau",
		'local runtime=require("./module/Contract") return {api=1,id=runtime.id,configVersion=1,runtime=runtime,generate=function() return {} end,driver={run=function() return {} end,simulate=function() return {} end},qa={scenarios={"contract-loop","contract-rejoin"},operations={"dispatch"},targets={runtime.id..":state"}}}'
	)
	for _, name in { "contract-loop", "contract-rejoin" } do
		fs.writeFile(path .. "/qa-scenarios/" .. name .. ".yml", "contract_api: 1\n")
	end
end
return {
	["native Windows filesystem discovery loads six plus extension sorted"] = function()
		sandbox(function(root)
			for _, id in { "zeta", "epsilon", "delta", "gamma", "beta", "alpha", "additional" } do
				package(root, id)
			end
			fs.writeDir(root .. "/unrelated")
			local registry, errors = Registry.discover(root, "1.2.0")
			assert(registry and #errors == 0, table.concat(errors, "; "))
			assert(
				#registry.order == 7 and registry.order[1] == "additional" and registry.order[7] == "zeta",
				table.concat(errors, "; ")
			)
			assert(registry.packages.alpha.generator.runtime.id == "alpha", "contract assertion failed")
			assert(registry.packages.alpha.spec.id == "alpha", "spec not loaded beside the package")
			assert(Registry.select(registry, { "missing" }) == nil, "contract assertion failed")
		end)
	end,
	["manifest bearing incomplete packages fail even unselected with stable paths"] = function()
		sandbox(function(root)
			package(root, "valid")
			package(root, "broken")
			fs.removeFile(root .. "/broken/qa-scenarios/contract-rejoin.yml")
			local registry, errors = Registry.discover(root, "1.0.0")
			assert(
				registry == nil
					and #errors == 1
					and string.find(errors[1], "broken/qa-scenarios/contract-rejoin.yml", 1, true),
				table.concat(errors, "; ")
			)
			fs.writeDir(root .. "/legacy")
			fs.writeFile(
				root .. "/legacy/forge-package.yml",
				"name: valid\nversion: 0.1.0\nrequires:\n  core: '^1.0.0'\n"
			)
			local _, failures = Registry.discover(root, "1.0.0")
			local sorted = table.clone(failures)
			table.sort(sorted)
			assert(
				table.concat(sorted, "\n") == table.concat(failures, "\n") and #failures >= 4,
				"contract assertion failed"
			)
		end)
	end,
	["missing registry fails without filesystem writes"] = function()
		sandbox(function(root)
			local registry, errors = Registry.discover(root .. "/absent", "1.0.0")
			assert(registry == nil and #errors == 1 and not fs.isDir(root .. "/absent"), "contract assertion failed")
		end)
	end,
}
