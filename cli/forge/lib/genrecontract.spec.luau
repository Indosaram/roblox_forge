--!strict
local C = require("./genrecontract")
local function manifest(): any
	return {
		name = "counter",
		version = "0.1.0",
		requires = { core = "^1.0.0" },
		genre_contract = {
			api = 1,
			generator = "generator.luau",
			runtime = "module/Contract.luau",
			spec = "genre-spec.yml",
		},
	}
end
local function runtime(id: string): any
	return {
		api = 1,
		id = id,
		configVersion = 1,
		saveVersion = 1,
		actions = {},
		events = {},
		hooks = {},
		validateConfig = function(_c)
			return {}
		end,
		validateSave = function(_s)
			return {}
		end,
		create = function(_c, _s)
			return {}
		end,
	}
end
return {
	["generated controls accept only local or matching canonical namespaces"] = function()
		local descriptor = runtime("counter")
		descriptor.actions = { { id = "increment", origin = "client", args = {} } }
		local generator: any = { id = "counter", runtime = descriptor }
		local generated: any = {
			config = {},
			artifacts = {},
			assetKeys = {},
			generation = {},
			controls = {
				{
					id = "counter:increment",
					action = "counter:increment",
					args = {},
					label = "Increment",
					kind = "button",
				},
			},
		}
		assert(#C.validateGenerated(generated, generator) == 0, "matching namespace rejected")
		generated.controls[1].id = "increment"
		assert(#C.validateGenerated(generated, generator) == 0, "local control rejected")
		for _, id in { "other:increment", "counter:../increment", "counter:increment:extra", "counter:Increment" } do
			generated.controls[1].id = id
			assert(#C.validateGenerated(generated, generator) > 0, "unsafe namespace accepted")
		end
	end,
	["strict manifests and caret boundaries"] = function()
		assert(#C.validateManifest(manifest(), "counter", "1.4.0") == 0, "contract assertion failed")
		local pairsToCheck: { { any } } = {
			{ "1.2.3", "^1.2.3", true },
			{ "1.2.2", "^1.2.3", false },
			{ "2.0.0", "^1.2.3", false },
			{ "0.2.9", "^0.2.3", true },
			{ "0.3.0", "^0.2.3", false },
			{ "0.0.4", "^0.0.3", false },
			{ "0.0.3", "^0.0.3", true },
			{ "1.0.0", ">=1.0.0", false },
		}
		for _, pair in pairsToCheck do
			assert(C.coreCompatible(pair[1] :: string, pair[2] :: string) == pair[3], "contract assertion failed")
		end
		for _, mutate in
			{
				function(m: any)
					m.genre_contract = nil
				end,
				function(m: any)
					m.genre_contract.api = 2
				end,
				function(m: any)
					m.genre_contract.runtime = "../Contract.luau"
				end,
				function(m: any)
					m.genre_contract.spec = nil
				end,
				function(m: any)
					m.genre_contract.spec = "../genre-spec.yml"
				end,
				function(m: any)
					m.name = "other"
				end,
				function(m: any)
					m.version = "1.0"
				end,
			}
		do
			local m = manifest()
			mutate(m)
			assert(#C.validateManifest(m, "counter", "1.0.0") > 0, "contract assertion failed")
		end
	end,
	["recipes canonicalize exact partners and reject ambiguity"] = function()
		local a, b = runtime("alpha"), runtime("beta")
		b.recipe = {
			id = "pair-v1",
			partners = { "alpha", "beta" },
			create = function(_c, _s)
				return {}
			end,
		}
		local all = { alpha = a, beta = b }
		local order, owner, errors = C.select({ "beta", "alpha" }, all)
		assert(order and order[1] == "alpha" and owner == b and #errors == 0, "contract assertion failed")
		assert(
			#C.validatePack(
					{ api = 1, order = order, configs = { alpha = {}, beta = {} }, recipe = "pair-v1" },
					all
				) == 0,
			"contract assertion failed"
		)
		assert(
			#C.validatePack(
					{ api = 1, order = { "beta", "alpha" }, configs = { alpha = {}, beta = {} }, recipe = "pair-v1" },
					all
				) > 0,
			"contract assertion failed"
		)
		assert(C.select({ "alpha", "alpha" }, all) == nil, "contract assertion failed")
		assert(C.select({ [2] = "alpha" }, all) == nil, "contract assertion failed")
		assert(C.select({ "alpha", "beta" }, all, "unknown") == nil, "contract assertion failed")
		a.recipe = b.recipe
		assert(C.select({ "alpha", "beta" }, all) == nil, "contract assertion failed")
	end,
	["serialization ignores map insertion order and rejects unsafe data"] = function()
		assert(
			C.serialize({ b = 2, a = { y = true, x = "text" } }) == C.serialize({ a = { x = "text", y = true }, b = 2 }),
			"contract assertion failed"
		)
		assert(not pcall(C.serialize, { n = math.huge }), "contract assertion failed")
	end,
	["artifacts cannot overwrite assembly or escape namespace"] = function()
		local generator: any = { id = "counter", runtime = runtime("counter") }
		local generated: any = {
			config = {},
			artifacts = { { path = "design/counter/data.yml", content = "value: 1" } },
			controls = {},
			assetKeys = { "counter-prop" },
			generation = { "procedural", "audio" },
		}
		assert(#C.validateGenerated(generated, generator) == 0, "contract assertion failed")
		for _, path in
			{ "game.yml", "design/counter/../escape.yml", "C:/evil", "assets/other/data.yml", "designcounterevil" }
		do
			generated.artifacts[1].path = path
			assert(#C.validateGenerated(generated, generator) > 0, "contract assertion failed")
		end
	end,
}
