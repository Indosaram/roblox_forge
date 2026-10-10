--!strict
local cliutil = require("../lib/cliutil")
local fulfill = require("./genfulfill")
local procedural = require("./genprocedural")
local launchart = require("./genlaunchart")
local icons = require("./genicons")
local audio = require("./genaudio")
local provider = require("./genprovider")
local M = {}
M.isValidFulfillRequest = fulfill.isValidFulfillRequest
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	if args[2] == "fulfill" then
		return fulfill.run(args, context)
	end
	if args[2] == "procedural" then
		return procedural.run(args, context)
	end
	if args[2] == "launchart" then
		return launchart.run(args, context)
	end
	if args[2] == "icons" then
		return icons.run(args, context)
	end
	if args[2] == "audio" then
		return audio.run(args, context)
	end
	return provider.run(args, context)
end
return M
