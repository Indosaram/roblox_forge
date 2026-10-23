--!strict
-- Character/progression sheet factories, in dock order. Packs append these to their panel list.
return {
	factories = {
		require("./CharacterPanel").factory,
		require("./GuidePanel").factory,
		require("./EquipmentPanel").factory,
		require("./SkillResetPanel").factory,
		require("./IslandRankPanel").factory,
		require("./PersonalResearchPanel").factory,
		require("./TechnicalSupportPanel").factory,
		require("./ModifyPanel").factory,
	},
}
