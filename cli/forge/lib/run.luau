--!strict
local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local M = {}

export type ExecResult = {
	ok: boolean,
	code: number,
	stdout: string,
	stderr: string,
}

local function resolveExecutable(tool: string): string
	if process.os == "windows" then
		-- On Windows, try to find %USERPROFILE%\.rokit\bin\<tool>.exe
		local userProfile = process.env["USERPROFILE"]
		if userProfile then
			local candidate = userProfile .. "/.rokit/bin/" .. tool .. ".exe"
			if fs.isFile(candidate) then
				return candidate
			end
			local backslashCandidate = userProfile .. "\\.rokit\\bin\\" .. tool .. ".exe"
			if fs.isFile(backslashCandidate) then
				return backslashCandidate
			end
		end
	else
		-- On Linux/macOS, try $HOME/.rokit/bin/<tool> (rokit's default install dir)
		local home = process.env["HOME"]
		if home then
			local candidate = home .. "/.rokit/bin/" .. tool
			if fs.isFile(candidate) then
				return candidate
			end
		end
	end
	return tool
end

function M.exec(tool: string, args: { string }): ExecResult
	local candidate = resolveExecutable(tool)
	local ok, res = pcall(process.exec, candidate, args)
	if not ok then
		return {
			ok = false,
			code = 127,
			stdout = "",
			stderr = tostring(res),
		}
	end
	return {
		ok = res.ok,
		code = res.code,
		stdout = res.stdout,
		stderr = res.stderr,
	}
end

-- Keep admission tied to the shipped manifest, not a second version registry.
function M.preflight(tools: { string }): (boolean, string?)
	local decoded, manifest = pcall(function()
		return serde.decode("toml", fs.readFile("rokit.toml"))
	end)
	if not decoded or type(manifest) ~= "table" or type(manifest.tools) ~= "table" then
		return false, "FORGE_TOOLCHAIN_INVALID: restore rokit.toml and run rokit install"
	end
	local function expected(tool: string): string?
		local pin = manifest.tools[tool]
		return if type(pin) == "string" then string.match(pin, "@(%d+%.%d+%.%d+)$") else nil
	end
	local lune = expected("lune")
	-- Lune injects _VERSION from its own compiled package version before loading scripts.
	local current = string.match(_VERSION, "^Lune (%d+%.%d+%.%d+)%+[%d%.]+$")
	if not lune then
		return false, "FORGE_TOOLCHAIN_INVALID: missing lune pin; restore rokit.toml and run rokit install"
	end
	if current ~= lune then
		return false,
			"FORGE_RUNTIME_UNSUPPORTED: lune expected="
				.. lune
				.. " observed="
				.. (current or "unknown")
				.. "; run rokit install and invoke Forge with the pinned Lune"
	end
	for _, tool in tools do
		local version = expected(tool)
		if not version then
			return false,
				"FORGE_TOOLCHAIN_INVALID: missing " .. tool .. " pin; restore rokit.toml and run rokit install"
		end
		local result = M.exec(tool, { "--version" })
		if not result.ok then
			return false, "FORGE_TOOL_UNAVAILABLE: " .. tool .. "; run rokit install and check PATH"
		end
		local observed = string.match(result.stdout, "^%S+%s+(%d+%.%d+%.%d+)%s*$")
			or string.match(result.stdout, "^%s*(%d+%.%d+%.%d+)%s*$")
		if observed ~= version then
			return false,
				"FORGE_TOOL_UNSUPPORTED: "
					.. tool
					.. " expected="
					.. version
					.. " observed="
					.. (observed or "unknown")
					.. "; run rokit install and check PATH"
		end
	end
	return true, nil
end

return M
