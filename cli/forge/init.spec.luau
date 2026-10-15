--!strict
-- Exit-code contract of the CLI entry point, exercised as a real process.
local process = require("@lune/process")

local function forge(args: { string }): { code: number, stdout: string, stderr: string }
	local argv = { "run", "cli/forge" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local res = process.exec("lune", argv)
	return { code = res.code, stdout = res.stdout, stderr = res.stderr }
end

local function expectCode(res: { code: number, stdout: string, stderr: string }, code: number)
	assert(
		res.code == code,
		string.format("expected exit %d, got %d\nstdout: %s\nstderr: %s", code, res.code, res.stdout, res.stderr)
	)
end

local tests = {}

function tests.helpFlagPrintsUsageToStdoutAndExitsZero()
	for _, flag in { "--help", "-h", "help" } do
		local res = forge({ flag })
		expectCode(res, 0)
		assert(string.find(res.stdout, "Usage: lune run cli/forge", 1, true), flag .. ": usage missing from stdout")
		for _, command in { "test [filters...]", "replay <journal.json>", "imagediff <base.png>" } do
			assert(string.find(res.stdout, command, 1, true), flag .. ": usage lacks " .. command)
		end
	end
end

function tests.commandHelpPrintsOnlyThatSection()
	local res = forge({ "check", "--help" })
	expectCode(res, 0)
	assert(string.find(res.stdout, "--only <stage[,stage]>", 1, true), "check section missing --only")
	assert(not string.find(res.stdout, "imagediff <base.png>", 1, true), "check --help printed other commands")
end

function tests.noArgumentsPrintsUsageToStderrAndExitsTwo()
	local res = forge({})
	expectCode(res, 2)
	assert(res.stdout == "", "no-args usage must not go to stdout")
	assert(string.find(res.stderr, "Usage: lune run cli/forge", 1, true), "usage missing from stderr")
end

function tests.unknownCommandExitsTwo()
	local res = forge({ "bogus" })
	expectCode(res, 2)
	assert(string.find(res.stderr, "Unknown command: 'bogus'", 1, true), "unknown command not reported")
end

function tests.testWithMatchingFilterExitsZero()
	local res = forge({ "test", "cli/forge/lib/cliutil.spec", "--quiet" })
	expectCode(res, 0)
	assert(string.find(res.stdout, "specs: %d+ passed, 0 failed, 1 files"), "summary missing: " .. res.stdout)
end

function tests.testWithZeroMatchFilterExitsOne()
	local res = forge({ "test", "no-such-spec-zz9" })
	expectCode(res, 1)
	assert(string.find(res.stdout, "specs: no tests matched no-such-spec-zz9", 1, true), "zero-match message missing")
end

return tests
