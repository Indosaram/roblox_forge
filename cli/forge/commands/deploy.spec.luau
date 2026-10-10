--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local deploy = require("./deploy")

return {
	["legacy production refuses before output and named development remains offline"] = function()
		local pack = "fixture-task-twelve-authorization"
		local directory = "games/" .. pack
		local output = directory .. "/plan.json"
		local artifact = "build/" .. pack .. ".rbxl"
		assert(not fs.isDir(directory) and not fs.isFile(directory), "fixture path already owned")
		assert(
			not fs.isFile(artifact) and not fs.isFile(artifact .. ".identity.json"),
			"fixture artifact already owned"
		)
		assert(not fs.isDir(artifact .. ".identity-project"), "fixture overlay already owned")
		local ok, reason = xpcall(function()
			fs.writeDir(directory)
			fs.writeFile(directory .. "/game.yml", "name: Authorization fixture\nmonetization: {}\n")
			-- No project or credentials: refusal must precede any attempt to build.
			for _, args in
				{
					{ "deploy", "plan", "--env", "production", "--pack", pack, "--out", output },
					{ "deploy", "--env", "production", "--pack", pack },
					{ "deploy", "plan", "--env", "production", "--pack", pack, "--development", "--out", output },
					{ "deploy", "plan", "--env", "staging", "--pack", pack, "--out", output },
					{ "deploy", "plan", "--env", "staging", "--development", "--out", output },
					{
						"deploy",
						"plan",
						"--env",
						"production",
						"--env",
						"staging",
						"--pack",
						pack,
						"--development",
						"--out",
						output,
					},
					{ "deploy", "plan", "--env", "production", "--pack", pack, "--target", "starter", "--out", output },
				}
			do
				assert(not deploy.run(args), "unauthorized command must fail")
				assert(not fs.isFile(output), "refusal must not write a plan")
				assert(not fs.isFile("build/" .. pack .. ".rbxl"), "refusal must not build")
			end
			assert(
				deploy.run({ "deploy", "plan", "--env", "staging", "--pack", pack, "--development", "--out", output })
			)
			local plan = serde.decode("json", fs.readFile(output))
			assert(
				plan.quality.code == "STAGING_DEVELOPMENT" and not plan.quality.releaseApproved,
				'plan.quality.code == "STAGING_DEVELOPMENT" and not plan.quality.releaseApproved'
			)
			assert(
				plan.apiVerified == false and plan.externalReleaseAuthorized == false,
				"plan.apiVerified == false and plan.externalReleaseAuthorized == false"
			)
			assert(not fs.isFile("build/" .. pack .. ".rbxl"), "offline plan must not build")
		end, debug.traceback)
		local cleaned, cleanupError = pcall(function()
			for _, path in { artifact, artifact .. ".identity.json" } do
				if fs.isFile(path) then
					fs.removeFile(path)
				end
			end
			if fs.isDir(artifact .. ".identity-project") then
				fs.removeDir(artifact .. ".identity-project")
			end
			if fs.isDir(directory) then
				fs.removeDir(directory)
			end
		end)
		assert(cleaned, tostring(cleanupError))
		assert(ok, tostring(reason))
	end,
}
