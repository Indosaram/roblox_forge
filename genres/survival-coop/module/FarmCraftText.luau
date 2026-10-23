--!strict
-- EN / KO strings and refusal copy for the farming and crafting screens
-- (farm plot, sprayer, crop book, specialization, processing, recipe preview, inbox).
local HudLocale = require("./SurvivalHUDLocale")
local M = {}
M.strings = {
	farm_title = { "Farm plots", "밭" },
	farm_none = { "Visit your home island and place a farm plot.", "개인 섬에 밭을 설치하세요." },
	farm_plot = { "Plot %d: %s", "밭 %d: %s" },
	farm_empty = { "Empty", "비어 있음" },
	farm_growing = { "%s growing, ready in %s", "%s 자라는 중, %s 후 수확" },
	farm_ready = { "%s ready to harvest", "%s 수확 가능" },
	farm_cost = { "Needs 1 seed + 1 water (seed %d, water %d)", "씨앗 1 + 물 1 필요 (씨앗 %d, 물 %d)" },
	farm_plant = { "Plant", "심기" },
	farm_fertilize = { "Fertilize", "비료 주기" },
	farm_harvest = { "Harvest", "수확" },
	farm_area = { "Sprayer", "분무기" },
	farm_book = { "Crop book", "작물 도감" },
	["liquid-fertilizer"] = { "Liquid -20% time", "액체 비료 -20% 시간" },
	["fruit-fertilizer"] = { "Fruit +1 fruit", "과일 비료 +1" },
	["stem-fertilizer"] = { "Stem +1 flax", "줄기 비료 +1" },
	area_title = { "Water sprayer", "물 분무기" },
	area_hint = { "Pick up to 9 plots within 12 studs.", "12칸 안의 밭을 최대 9개 고르세요." },
	area_cost = { "Cost: water %d + fertilizer %d", "비용: 물 %d + 비료 %d" },
	area_apply = { "Apply", "적용" },
	area_done = { "Done", "완료" },
	area_ok = { "Plot %d: applied", "밭 %d: 적용됨" },
	area_fail = { "Plot %d: %s", "밭 %d: %s" },
	book_title = { "Crop book", "작물 도감" },
	book_rank = { "%s rank %d/5, %s", "%s %d/5등급, %s" },
	book_next = { "%d harvests to next rank", "다음 등급까지 수확 %d회" },
	book_max = { "max rank", "최고 등급" },
	book_effects = { "Chosen: %s | Open: %s", "선택: %s | 남음: %s" },
	book_specialize = { "Specialize (%d)", "특화 선택 (%d)" },
	none = { "none", "없음" },
	yield = { "Yield +1", "수확량 +1" },
	time = { "Growth -10%", "성장 -10%" },
	quality = { "Quality +", "품질 +" },
	spec_title = { "Specialize crop", "작물 특화" },
	spec_chosen = { "%s (chosen)", "%s (선택됨)" },
	spec_preview = { "Next %s: %ds, yield %d, quality %d", "다음 %s: %d초, 수확 %d, 품질 %d" },
	spec_confirm = { "Confirm", "확인" },
	spec_back = { "Back", "뒤로" },
	proc_title = { "Processing", "가공" },
	proc_kind = { "Process: %s (next)", "가공: %s (다음)" },
	dry = { "Drying", "건조" },
	tan = { "Tanning", "무두질" },
	polish = { "Polishing", "연마" },
	smelt = { "Smelting", "제련" },
	ferment = { "Fermenting", "발효" },
	compost = { "Composting", "퇴비화" },
	proc_row = { "%s > %s, %ds, budget %d>%d", "%s > %s, %d초, 예산 %d>%d" },
	proc_delta = { "%s %d>%d", "%s %d>%d" },
	proc_none = { "No eligible item in your bag.", "가방에 가공할 재료가 없어요." },
	proc_start = { "Start %s", "%s 시작" },
	job_start = { "Start job", "작업 시작" },
	job_collect = { "Collect", "받기" },
	preview_title = { "Recipe preview", "제작 미리보기" },
	preview_recipe = { "%s (next)", "%s (다음)" },
	preview_main = { "Main: %s x%d from %s (L%d Q%d)", "주재료: %s x%d, %s (L%d Q%d)" },
	preview_support = { "Support: %s x%d (have %d)", "보조: %s x%d (보유 %d)" },
	preview_missing = { "Main: %s x%d missing", "주재료: %s x%d 부족" },
	preview_out = { "Makes %s x%d, L%d, %ds", "결과 %s x%d, L%d, %d초" },
	preview_bonus = { "Main-material return: %d%%", "주재료 반환: %d%%" },
	preview_count = { "Count %d", "수량 %d" },
	preview_less = { "-", "-" },
	preview_more = { "+", "+" },
	preview_queue = { "Queue %d", "%d개 예약" },
	preview_queued = { "Queued %d/%d", "예약 %d/%d" },
	inbox_title = { "Inbox", "보관함" },
	inbox_empty = { "No results waiting.", "받을 결과가 없어요." },
	inbox_item = { "Market item: %s x%d", "장터 물품: %s x%d" },
	inbox_coins = { "Sale proceeds: %d coins", "판매 대금: %d 조개돈" },
	inbox_crafted = { "Crafted: %s (job %s)", "제작 완료: %s (작업 %s)" },
	inbox_running = { "Crafting: %s (job %s)", "제작 중: %s (작업 %s)" },
	inbox_refund = { "Refunded: %s (job %s)", "환불됨: %s (작업 %s)" },
	inbox_claim = { "Claim", "받기" },
	inbox_expedition = { "%s: %d coins, %d XP", "%s: 조개돈 %d, 경험치 %d" },
	inbox_expedition_received = { "%s: %d coins, %d XP (received)", "%s: 조개돈 %d, 경험치 %d (받음)" },
	inbox_expedition_items = { "Items: %s", "물품: %s" },
	ledger_claimed = { "Already claimed", "이미 받았어요" },
	ledger_missing = { "Nothing to claim", "받을 것이 없어요" },
	inbox_page = { "Page %d/%d (next)", "%d/%d쪽 (다음)" },
	ok = { "Done", "완료" },
	TOOL_REQUIRED = { "Needs a sprinkler in home storage", "집 창고에 스프링클러가 필요해요" },
	AREA_LIMIT = { "Pick 1 to 9 plots", "밭을 1~9개 고르세요" },
	OUT_OF_AREA = { "Outside the 12-stud radius", "12칸 범위 밖" },
	ALREADY_FERTILIZED = { "Already fertilized", "이미 비료를 줬어요" },
	ALREADY_READY = { "Already grown", "이미 다 자랐어요" },
	FERTILIZER_NOT_APPLICABLE = { "Not for this crop", "이 작물에는 못 써요" },
	UNKNOWN_FERTILIZER = { "Pick a fertilizer", "비료를 고르세요" },
	DUPLICATE_EFFECT = { "Effect already chosen", "이미 고른 효과예요" },
	RANK_LOCKED = { "Reach rank 1, 3 or 5 first", "1, 3, 5등급에서 고를 수 있어요" },
	EMPTY_PLOT = { "Nothing planted", "심은 작물이 없어요" },
	NOT_GROWN = { "Not grown yet", "아직 자라는 중" },
	PLOT_OCCUPIED = { "Plot already planted", "이미 심은 밭" },
	WRONG_SEED = { "No seed in home storage", "집 창고에 씨앗이 없어요" },
	SKILL_LOCKED = { "Learn the farming node first", "농사 스킬이 필요해요" },
	SKILL_NODE_GATE = { "Learn the skill node first", "스킬이 필요해요" },
	OUT_OF_RANGE = { "Move onto your home island", "개인 섬으로 이동하세요" },
	STATION_UNAVAILABLE = { "Stand near the right station", "알맞은 작업대 가까이 가세요" },
	PROCESSING_BUDGET = { "Processing budget used up", "가공 예산을 다 썼어요" },
	JOB_QUEUE_FULL = { "Job queue full", "작업 대기열이 가득 찼어요" },
	COMMAND_UNAVAILABLE = { "Not available here", "여기서는 쓸 수 없어요" },
}

local function pick(locale: string, key: string): string?
	local row = M.strings[key]
	return if row then row[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else nil
end

function M.text(locale: string, key: string, ...: any): string
	local value = pick(locale, key) or HudLocale.text(locale, key)
	return if select("#", ...) > 0 then string.format(value, ...) else value
end

function M.refusal(locale: string, reason: string?): string
	local key = tostring(reason)
	return pick(locale, key) or HudLocale.refusal(locale, key)
end

-- Seconds as m:ss for growth timers.
function M.clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

return M
