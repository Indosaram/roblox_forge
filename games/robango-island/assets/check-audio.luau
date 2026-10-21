--!strict
-- Standalone scoped runner: the global Forge loader compiles every concurrent spec.
local suites: { { [string]: () -> () } } = {
	require("../../../genres/survival-coop/module/AudioDirector.spec"),
	require("./render-audio.spec"),
	require("../../../genres/survival-coop/module/SurvivalAudio.spec"),
	require("../../../core/infra/audio/SoundBank.spec"),
}
local passed = 0
for _, suite in suites do
	for name, check in suite do
		check()
		passed += 1
		print("PASS", name)
	end
end
print("audio scoped specs:", passed, "passed, 0 failed")
