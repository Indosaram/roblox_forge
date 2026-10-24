--!strict
-- EN/KO text for the character/progression screens. Keys mirror games/robango-island/locale/strings.csv
-- (char_*). Refusal reasons map to sentences; a raw reason code is never shown.
local Party = require("../../../core/domain/island/Party")
local Guide = require("./GuideEvents")
local M = {}

local strings: { [string]: { string } } = {
	char_title = { "Character", "캐릭터" },
	char_level = { "Level %d / %d", "레벨 %d / %d" },
	char_xp = { "XP %d / %d to next level", "다음 레벨까지 경험치 %d / %d" },
	char_xp_max = { "Maximum level reached", "최고 레벨 달성" },
	char_sp = { "SP %d available / %d total", "SP %d 사용 가능 / 총 %d" },
	char_rank = { "Exploration rank %d / 10", "탐험 등급 %d / 10" },
	char_awards = { "First awards earned %d / %d", "첫 달성 보상 %d / %d" },
	char_open_rank = { "Island rank", "섬 등급" },
	char_open_reset = { "Reset skills", "기술 초기화" },
	char_open_equipment = { "Equipment", "장비" },
	char_open_research = { "Personal research", "개인 연구" },
	reset_title = { "Skill reset", "기술 초기화" },
	reset_refund = { "Refund: %d SP", "환급: SP %d" },
	reset_nodes = { "Removes %d learned skills", "배운 기술 %d개 제거" },
	reset_none = { "No learned skills to reset", "초기화할 기술이 없어요" },
	reset_keep = { "Mastery and crafted gear are kept", "숙련도와 만든 장비는 유지돼요" },
	reset_busy_note = { "Not during combat or crafting", "전투·제작 중에는 불가" },
	reset_confirm = { "Confirm reset", "초기화 확인" },
	reset_done = { "Skills reset. SP refunded", "기술을 초기화하고 SP를 돌려받았어요" },
	rank_title = { "Island rank", "섬 등급" },
	rank_points = { "Development %d (100 per rank)", "개발 점수 %d (등급당 100)" },
	rank_next = { "Next rank at %d", "다음 등급: %d" },
	rank_max = { "Highest rank reached", "최고 등급 달성" },
	rank_lab_open = { "Laboratory unlocked (rank %d)", "연구실 해금 (등급 %d)" },
	rank_lab_locked = { "Laboratory unlocks at rank %d", "연구실은 등급 %d에 해금" },
	rank_guide = { "Finish island missions to earn development", "섬 임무를 마치면 개발 점수를 얻어요" },
	rank_cell_open = { "Island %d-%d: %dx%d studs, rank %d (open)", "섬 %d-%d: %dx%d 스터드, 등급 %d (열림)" },
	rank_cell_locked = { "Island %d-%d: %dx%d studs, needs rank %d", "섬 %d-%d: %dx%d 스터드, 등급 %d 필요" },
	rank_award = { "%s +%d", "%s +%d" },
	rank_award_done = { "Done: %s +%d", "완료: %s +%d" },
	guide_title = { "Guides", "안내" },
	guide_grade = {
		"Island grade %d: development %d / %d for grade %d",
		"섬 개발 등급 %d: 개발 점수 %d / %d (등급 %d)",
	},
	guide_how = {
		"Finish guides and island missions to earn development points",
		"안내와 섬 임무를 마치면 개발 점수를 얻어요",
	},
	guide_done = { "Guides finished %d / %d", "마친 안내 %d / %d" },
	guide_reward = { "%s · +%d development · %d coins", "%s · 개발 +%d · 조개돈 %d" },
	guide_objective = { "%s %s: %d / %d", "%s %s: %d / %d" },
	guide_objective_missing = { "%s %s: %d / %d (coming later)", "%s %s: %d / %d (추후 제공)" },
	guide_locked = {
		"More guides open at level %d, island grade %d",
		"레벨 %d, 섬 등급 %d에 안내가 더 열려요",
	},
	guide_upcoming = {
		"Locked: %s · level %d · +%d development · %d coins",
		"잠김: %s · 레벨 %d · 개발 +%d · 조개돈 %d",
	},
	guide_g01 = { "First gather", "첫 채집" },
	guide_g02 = { "First axe", "첫 도끼" },
	guide_g03 = { "First contract", "첫 계약" },
	guide_g04 = { "Camp donation", "캠프 기부" },
	guide_g05 = { "Home expansion", "집 확장" },
	guide_g06 = { "Visit a home", "집 방문" },
	guide_g07 = { "Cook and eat", "요리와 식사" },
	guide_g08 = { "Harbor market", "항구 장터" },
	guide_g09 = { "Farming", "농사" },
	guide_g10 = { "Clothing", "옷 만들기" },
	guide_g11 = { "Skill reclaim", "기술 회수" },
	guide_g12 = { "Route sharing", "항로 공유" },
	guide_g13 = { "Laboratory", "연구실" },
	guide_g14 = { "Taming", "길들이기" },
	guide_g15 = { "Clan", "클랜" },
	guide_g16 = { "Refrigeration", "냉장 보관" },
	guide_g17 = { "Snow preparation", "설원 준비" },
	guide_g18 = { "Technical support", "기술 지원" },
	guide_g19 = { "Volcano preparation", "화산 준비" },
	guide_g20 = { "Rescue preparation", "구조 준비" },
	guide_g21 = { "Daily contracts", "일일 계약" },
	guide_g22 = { "Wilds preparation", "야생 지대 준비" },
	guide_g23 = { "Wilds: hazelnuts", "야생 지대: 개암" },
	guide_g24 = { "Trail food", "여정 식량" },
	guide_g25 = { "Wilds: mushrooms", "야생 지대: 버섯" },
	guide_g26 = { "Marsh bread", "습지 빵" },
	guide_g27 = { "Deep wilds: clams", "깊은 야생 지대: 조개" },
	guide_g28 = { "Woodland skewer", "숲 꼬치" },
	guide_g29 = { "Deep wilds haul", "깊은 야생 지대 채집" },
	guide_g30 = { "Route supplies", "항로 보급" },
	guide_next = { "%s: %s %d/%d", "%s: %s %d/%d" },
	guide_go_gather = { "gather %s (walk up, press E)", "%s 채집 (다가가서 E)" },
	guide_go_craft = { "craft %s (C key, Menu > Craft)", "%s 제작 (C 키, 메뉴 > 제작)" },
	guide_go_deliver = { "deliver %s (Menu > Contracts)", "%s 납품 (메뉴 > 계약)" },
	guide_go_donate = { "give to %s (Menu > Camp > Give)", "%s에 기부 (메뉴 > 캠프 > 기부)" },
	guide_route_level = {
		"Grade %d reached. Route 1 opens at level %d (now %d): Menu > Routes",
		"등급 %d 달성. 항로 1은 레벨 %d에 열려요 (현재 %d): 메뉴 > 항로",
	},
	guide_route_open = { "Route 1 is open: Menu > Routes", "항로 1이 열렸어요: 메뉴 > 항로" },
	guide_where_region = {
		"%s (Harbor > departure post, level %d area)",
		"%s (항구 > 출발 지점, 레벨 %d 지역)",
	},
	guide_then_region = {
		"%s. Next: level %d opens Harbor > departure post (level %d area)",
		"%s. 다음: 레벨 %d에 항구 > 출발 지점 (레벨 %d 지역)이 열려요",
	},
	guide_then_guide = { "%s. Next: guide %s at level %d", "%s. 다음: 안내 %s (레벨 %d)" },
	guide_complete = { "Guide complete: %s", "안내 완료: %s" },
	guide_target_axe = { "any axe", "아무 도끼" },
	guide_target_contract = { "any contract", "아무 계약" },
	guide_target_camp = { "a camp project", "캠프 공사" },
	guide_act_gather = { "Gather", "채집" },
	guide_act_craft = { "Craft", "제작" },
	guide_act_place = { "Place", "설치" },
	guide_act_rest = { "Rest at", "휴식" },
	guide_act_deliver = { "Deliver", "납품" },
	guide_act_donate = { "Donate to", "기부" },
	guide_act_expand = { "Expand", "확장" },
	guide_act_visit = { "Visit", "방문" },
	guide_act_eat = { "Eat", "먹기" },
	guide_act_list = { "List", "장터 등록" },
	guide_act_settle_return_or_sale = { "Claim sale or return of", "판매·반환 받기" },
	guide_act_practice = { "Practice", "연습" },
	guide_act_purchase = { "Learn", "기술 배우기" },
	guide_act_plant = { "Plant", "심기" },
	guide_act_water = { "Water", "물 주기" },
	guide_act_harvest = { "Harvest", "수확" },
	guide_act_feed = { "Feed", "먹이 주기" },
	guide_act_tame = { "Tame", "길들이기" },
	guide_act_deposit = { "Store", "보관" },
	guide_act_retrieve = { "Take out", "꺼내기" },
	research_title = { "Personal research", "개인 연구" },
	research_line_life = { "Life (climate): %d%%", "생활(기후): %d%%" },
	research_line_light = { "Light work: %d%%", "가벼운 작업: %d%%" },
	research_line_heavy = { "Heavy carry: %d%%", "무거운 운반: %d%%" },
	research_tier = { "T%d %d%% · %d coins · %s · %ds", "T%d %d%% · 조개돈 %d · %s · %d초" },
	research_start = { "Start", "시작" },
	research_cancel = { "Cancel (refund %d)", "취소 (환급 %d)" },
	research_complete = { "Collect", "받기" },
	research_done = { "Done", "완료" },
	research_running = { "Running, ready in %ds", "진행 중, %d초 남음" },
	support_title = { "Technical support", "기술 지원" },
	support_gate = { "Requires level %d (you are %d)", "레벨 %d 필요 (현재 %d)" },
	support_item = { "Item: %s", "장비: %s" },
	support_none = { "Equip an item first", "먼저 장비를 착용하세요" },
	support_current = { "Current effect +%d%%", "현재 효과 +%d%%" },
	support_tier = { "Tier %d: +%d%% · %d coins · %s", "%d단계: +%d%% · 조개돈 %d · %s" },
	support_confirm = { "Confirm tier %d", "%d단계 확인" },
	modify_title = { "Modify", "개조" },
	modify_slot = { "Slot %d: %s", "슬롯 %d: %s" },
	modify_empty = { "empty", "비어 있음" },
	modify_warning = { "Replacing a slot gives no refund", "슬롯을 바꾸면 환급되지 않아요" },
	modify_row = { "+2 %s · %s", "+2 %s · %s" },
	modify_apply = { "Apply to slot %d", "슬롯 %d에 적용" },
	equip_title = { "Equipment", "장비" },
	equip_slot = { "%s: %s", "%s: %s" },
	equip_stats = { "Power %s · Armor %d · Cold %s · Heat %s", "공격 %s · 방어 %d · 추위 %s · 더위 %s" },
	equip_button = { "Equip %s (%s)", "%s 착용 (%s)" },
	equip_unequip = { "Unequip %s", "%s 벗기" },
	equip_modify = { "Modify %s", "%s 개조" },
	equip_support = { "Support %s", "%s 기술 지원" },
	equip_tier = { "Tech tier %d · mods %d/2", "기술 단계 %d · 개조 %d/2" },
	slot_head = { "Head", "머리" },
	slot_top = { "Top", "상의" },
	slot_bottom = { "Bottom", "하의" },
	slot_shoes = { "Shoes", "신발" },
	slot_gloves = { "Gloves", "장갑" },
	slot_bag = { "Bag", "가방" },
	slot_weapon = { "Weapon/tool", "무기·도구" },
	attr_sharpness = { "sharpness", "날카로움" },
	attr_hardness = { "hardness", "단단함" },
	attr_insulation = { "insulation", "보온" },
	attr_flexibility = { "flexibility", "유연성" },
	char_working = { "Sending...", "보내는 중..." },
	-- Refusals.
	STALE_QUOTE = {
		"Your skills changed. Check the new refund",
		"기술이 바뀌었어요. 새 환급량을 확인하세요",
	},
	RESET_BUSY = { "Finish combat and crafting first", "전투와 제작을 먼저 끝내세요" },
	CHARACTER_LEVEL_GATE = { "Your level is too low", "레벨이 부족해요" },
	SKILL_GATE = { "Learn the required skill first", "필요한 기술을 먼저 배우세요" },
	DEVELOPMENT_GATE = { "Raise your island rank first", "섬 등급을 먼저 올리세요" },
	STATION_GATE = { "Stand next to the right station", "알맞은 시설 옆에 서세요" },
	INSUFFICIENT_COINS = { "Not enough coins", "조개돈이 부족해요" },
	INSUFFICIENT_MATERIALS = { "Not enough materials in your bag", "가방에 재료가 부족해요" },
	UPGRADE_PREREQUISITE = { "Finish the previous tier first", "이전 단계를 먼저 끝내세요" },
	ALREADY_COMPLETED = { "Already done", "이미 완료했어요" },
	JOB_PENDING = { "Another job is still running", "다른 작업이 아직 진행 중이에요" },
	NOT_READY = {
		"Still running. Collect when the timer ends",
		"아직 진행 중이에요. 시간이 끝나면 받으세요",
	},
	JOB_FINISHED = { "Already finished. Collect it instead", "이미 끝났어요. 대신 받으세요" },
	CANNOT_CANCEL = { "This job cannot be cancelled", "이 작업은 취소할 수 없어요" },
	INELIGIBLE_EQUIPMENT = { "This item cannot take that", "이 장비에는 쓸 수 없어요" },
	UNKNOWN_EQUIPMENT = { "Equip the item first", "장비를 먼저 착용하세요" },
	ITEM_NOT_OWNED = { "That item is not in your bag", "가방에 그 물건이 없어요" },
	NOT_EQUIPMENT = { "That item cannot be worn", "착용할 수 없는 물건이에요" },
	ITEM_BROKEN = { "Repair the item first", "먼저 장비를 수리하세요" },
	ITEM_RESERVED = { "That item is in use by a job", "작업에 쓰이는 중인 물건이에요" },
	ALREADY_EQUIPPED = { "Already equipped", "이미 착용 중이에요" },
	SLOT_EMPTY = { "Nothing equipped there", "그 칸에는 장비가 없어요" },
	NOT_ALIVE = { "You cannot do this while down", "쓰러진 동안은 할 수 없어요" },
	char_failed = { "That did not work. Try again", "실패했어요. 다시 시도하세요" },
}

M.keys = {} :: { string }
for key in strings do
	table.insert(M.keys, key)
end
table.sort(M.keys)

function M.has(key: string): boolean
	return strings[key] ~= nil
end

function M.text(locale: string, key: string): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

function M.format(locale: string, key: string, ...: any): string
	return string.format(M.text(locale, key), ...)
end

-- Lowest character gate of a support region whose layout is the only source of `item`
-- (no ungated region has a node for it), or nil when the item is gathered at level 1.
local function regionLevel(content: any, item: string): number?
	local nodes = {}
	for _, layout in content.layouts or {} do
		for _, node in layout.resourceNodes or {} do
			if node.item == item then
				nodes[layout.id] = true
			end
		end
	end
	local best: number? = nil
	for _, region in content.supportRegions or {} do
		if nodes[region.layout] then
			local gate = (region.gates or {}).characterLevel or 1
			if gate <= 1 then
				return nil
			end
			best = math.min(best or gate, gate)
		end
	end
	return best
end

local function title(locale: string, guide: any, names: any): string
	local key = "guide_" .. string.sub(guide.id, 4, 6)
	return if strings[key] then M.text(locale, key) else names[guide.id] or guide.id
end

-- First open unfinished guide with a HUD action: "<guide>: <action> have/need".
local function openGuide(
	locale: string,
	content: any,
	ch: any,
	names: any,
	level: number,
	grade: number,
	minRank: number
): string?
	local done, progress = ch.definitions or {}, ch.progress or {}
	for _, g in content.guides or {} do
		if not done[g.id] and Guide.open(g, level, grade) and ((g.gates or {}).developmentRank or 0) >= minRank then
			local o = g.objectives[1]
			for _, objective in g.objectives do
				if (progress[objective.id] or 0) < objective.quantity then
					o = objective
					break
				end
			end
			local go = "guide_go_" .. o.action
			if strings[go] then
				local t = "guide_target_" .. o.target
				local what = M.format(locale, go, if strings[t] then M.text(locale, t) else names[o.target] or o.target)
				local where = if o.action == "gather" then regionLevel(content, o.target) else nil
				if where then
					what = M.format(locale, "guide_where_region", what, where)
				end
				local have = math.min(progress[o.id] or 0, o.quantity)
				return M.format(locale, "guide_next", title(locale, g, names), what, have, o.quantity)
			end
		end
	end
	return nil
end

-- HUD objective: the next open start guide; after route 1's grade, the next open waypoint guide of
-- that grade's band; with none open, route 1's gate plus the next authored step (a support region
-- opening at the harbor departure post, or the next guide's level).
function M.guideObjective(locale: string, content: any, ch: any, names: any): string?
	local level, grade, done = ch.level or 1, math.floor((ch.points or 0) / 100), ch.definitions or {}
	local needLevel, needRank = Party.gates(content, 1)
	if grade < needRank then
		return openGuide(locale, content, ch, names, level, grade, 0)
	elseif level >= needLevel then
		return M.text(locale, "guide_route_open")
	end
	local open = openGuide(locale, content, ch, names, level, grade, needRank)
	if open then
		return open
	end
	local gate = M.format(locale, "guide_route_level", grade, needLevel, level)
	local region: number? = nil
	for _, row in content.supportRegions or {} do
		local at = (row.gates or {}).characterLevel or 1
		if at > level and at < needLevel then
			region = math.min(region or at, at)
		end
	end
	local nextGuide, guideAt = nil, nil
	for _, g in content.guides or {} do
		local gates = g.gates or {}
		local at = gates.characterLevel or 1
		if
			not done[g.id]
			and at > level
			and at < needLevel
			and (gates.developmentRank or 0) <= grade
			and (gates.developmentRank or 0) >= needRank
		then
			if guideAt == nil or at < guideAt then
				nextGuide, guideAt = g, at
			end
		end
	end
	if region and (guideAt == nil or region <= guideAt) then
		return M.format(locale, "guide_then_region", gate, region, region)
	elseif nextGuide then
		return M.format(locale, "guide_then_guide", gate, title(locale, nextGuide, names), guideAt)
	end
	return gate
end

-- "Guide complete" line for guides finished since the previous snapshot.
function M.newGuides(locale: string, seen: any, ch: any): string?
	local new = {}
	for id in type(ch) == "table" and ch.definitions or {} do
		if seen.ready and not seen[id] then
			table.insert(new, M.text(locale, "guide_" .. string.sub(id, 4, 6)))
		end
		seen[id] = true
	end
	seen.ready = seen.ready or type(ch) == "table"
	return if #new > 0 then M.format(locale, "guide_complete", table.concat(new, ", ")) else nil
end

function M.refusal(locale: string, reason: string?): string
	local key = reason or ""
	return M.text(locale, if strings[key] and string.upper(key) == key then key else "char_failed")
end

return M
