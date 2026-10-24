--!strict
-- Localized wildlife species names (EN first, ko-kr second), shared by the taming panel and
-- the expedition objective lines. Keys mirror the pack's wildlife_<id> rows in
-- games/robango-island/locale/strings.csv; an unknown id falls back to the raw id.
local M = {}

local strings: { [string]: { string } } = {
	wildlife_ridge_strider = { "Ridge Strider", "능선걸음이" },
	wildlife_fen_trotter = { "Fen Trotter", "늪종종이" },
	wildlife_bluff_bounder = { "Bluff Bounder", "벼랑깡충이" },
	wildlife_compsognathus = { "Compsognathus", "콤프소그나투스" },
	wildlife_oviraptor = { "Oviraptor", "오비랍토르" },
	wildlife_protoceratops = { "Protoceratops", "프로토케라톱스" },
	wildlife_gallimimus = { "Gallimimus", "갈리미무스" },
	wildlife_parasaurolophus = { "Parasaurolophus", "파라사우롤로푸스" },
	wildlife_stegosaurus = { "Stegosaurus", "스테고사우루스" },
	wildlife_ankylosaurus = { "Ankylosaurus", "안킬로사우루스" },
	wildlife_triceratops = { "Triceratops", "트리케라톱스" },
	wildlife_brachiosaurus = { "Brachiosaurus", "브라키오사우루스" },
	wildlife_utahraptor = { "Utahraptor", "유타랍토르" },
	wildlife_velociraptor = { "Velociraptor", "벨로키랍토르" },
	wildlife_dilophosaurus = { "Dilophosaurus", "딜로포사우루스" },
	wildlife_allosaurus = { "Allosaurus", "알로사우루스" },
	wildlife_tyrannosaurus = { "Tyrannosaurus", "티라노사우루스" },
	wildlife_smilodon = { "Smilodon", "스밀로돈" },
	wildlife_tropicalSmilodon = { "Tropical Smilodon", "열대 스밀로돈" },
	wildlife_direWolf = { "Dire Wolf", "다이어울프" },
	wildlife_mammoth = { "Mammoth", "매머드" },
	wildlife_deer = { "Deer", "사슴" },
	wildlife_elephant = { "Elephant", "코끼리" },
	wildlife_crocodile = { "Crocodile", "악어" },
	wildlife_turtle = { "Turtle", "거북" },
	wildlife_dodo = { "Dodo", "도도" },
	wildlife_boar = { "Boar", "멧돼지" },
	wildlife_grazer = { "Meadow Plodder", "풀밭느림보" },
	wildlife_hunter = { "Brush Stalker", "덤불살금이" },
	wildlife_leaper_fernhop = { "Fernhopper", "고사리뜀이" },
	wildlife_leaper_reedvault = { "Reed Vaulter", "갈대도약이" },
	wildlife_charger_oakbrow = { "Oakbrow Rammer", "참나무이마박치기" },
	wildlife_charger_mudbrow = { "Mudbrow Rammer", "진흙이마박치기" },
	wildlife_tailswing_mossback = { "Mossback Swinger", "이끼등꼬리채" },
	wildlife_tailswing_shellclub = { "Shellclub Swinger", "조가비곤봉꼬리" },
	wildlife_roarer_thicket = { "Thicket Bellower", "덤불울림이" },
	wildlife_roarer_tidecall = { "Tidecall Bellower", "물때울림이" },
	wildlife_scavenger_barkpicker = { "Barkpicker", "껍질뒤짐이" },
	wildlife_scavenger_flotsam = { "Flotsam Sniffer", "표류물킁킁이" },
	wildlife_herd_acorncrest = { "Acorncrest Grazer", "도토리볏풀뜯이" },
	wildlife_herd_sedgewader = { "Sedge Wader", "사초건너미" },
}

M.strings = strings

function M.name(locale: string, species: string): string
	local entry = strings["wildlife_" .. string.gsub(species, "%-", "_")]
	if entry == nil then
		return species
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

return M
