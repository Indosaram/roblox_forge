--!strict
local M = {}
local strings: { [string]: { string } } = {
	["trade.bundle.list"] = { "List bundle", "묶음 등록" },
	harbor = { "Harbor buys %d/%d today", "항구 매입 %d/%d" },
	sell = { "Sell %s (%d each)", "%s 팔기 (개당 %d)" },
	DAILY_CAP = { "Daily limit reached", "오늘 한도 도달" },
	NOT_AT_HARBOR = { "Only at the harbor", "항구에서만 가능" },
	repair = { "Repair (%d coins)", "수리 (%d 조개돈)" },
	INSUFFICIENT_FUNDS = { "Not enough coins", "조개돈 부족" },
	repaired = { "Repaired", "수리 완료" },
	INSUFFICIENT_ITEMS = { "You do not hold that many", "보유 수량이 부족해요" },
	oversell = {
		"You cannot sell more than you hold (held %d)",
		"보유 수량보다 많이 팔 수 없어요 (보유 %d)",
	},
	["market.account"] = {
		"Market trading is unavailable for this account right now.",
		"지금은 이 계정으로 장터 거래를 할 수 없어요.",
	},
	["market.age"] = {
		"Market listing opens once your Roblox account is 7 days old.",
		"로블록스 계정이 7일 이상 되어야 장터에 등록할 수 있어요.",
	},
	["market.playtime"] = {
		"Market listing opens after 2 hours of play. Keep exploring and come back.",
		"2시간 이상 플레이해야 장터에 등록할 수 있어요. 더 탐험한 뒤 다시 오세요.",
	},
	["market.tutorial"] = {
		"Finish the first-day tutorial to open market listing.",
		"첫날 튜토리얼을 마치면 장터에 등록할 수 있어요.",
	},
	["market.invalid"] = {
		"Enter a quantity you carry and a price of at least 1.",
		"가진 만큼의 수량과 1 이상의 가격을 입력하세요.",
	},
	["market.declined"] = {
		"Those goods could not be escrowed (reserved, equipped, or 20 listings up). Check your bag.",
		"재료를 맡길 수 없어요 (예약·장착 중이거나 등록 20개 초과). 가방을 확인하세요.",
	},
	["market.pending"] = {
		"Listing is still settling. Press List again in a moment; it will not list twice.",
		"등록을 정산하는 중이에요. 잠시 뒤 다시 누르세요. 두 번 등록되지 않아요.",
	},
	["market.conflict"] = {
		"That request already listed different goods. Change the amount or price and list again.",
		"같은 요청으로 다른 묶음이 이미 등록됐어요. 수량이나 가격을 바꿔 다시 등록하세요.",
	},
	["market.expired"] = {
		"Session refreshed. Reopen the market and list again.",
		"세션이 새로 고쳐졌어요. 장터를 다시 열고 등록하세요.",
	},
	["market.combat"] = {
		"A wildlife fight is still settling. Wait a moment, then list again.",
		"야생 동물과의 전투를 정산하는 중이에요. 잠시 뒤 다시 등록하세요.",
	},
	["market.rate"] = {
		"Too fast. Wait a moment, then list again.",
		"너무 빨라요. 잠시 뒤 다시 등록하세요.",
	},
	["market.left"] = {
		"You left this server. Rejoin to list.",
		"서버를 떠났어요. 다시 접속한 뒤 등록하세요.",
	},
	["market.unavailable"] = {
		"The market is still connecting. Wait a moment and try again.",
		"장터에 연결하는 중이에요. 잠시 뒤 다시 시도하세요.",
	},
	["market.transport"] = {
		"Connection uncertain. Press List again; it will not list twice.",
		"연결이 불확실해요. 다시 누르세요. 두 번 등록되지 않아요.",
	},
	["market.refused"] = { "The market refused this listing.", "장터가 이 등록을 거절했어요." },
	INELIGIBLE_REPAIR = { "This item cannot be repaired", "수리할 수 없는 물건" },
	preset = { "Terrain %d", "지형 %d" },
	PRESET_LOCKED = { "Terrain %d: Patron Pass", "지형 %d: 후원 패스" },
	preset_applied = { "Terrain preset %d applied", "지형 %d 적용됨" },
	menu_survival = { "Survival", "생존" },
	menu_world = { "World", "세계" },
	menu_social = { "Social", "함께" },
	menu_shop = { "Shop", "상점" },
	menu_settings = { "Settings", "설정" },
	music = { "Music", "연주" },
	dodge = { "Dodge [Q]", "회피 [Q]" },
	guard = { "Guard [G]", "방어 [G]" },
	shoot = { "Shoot [V]", "사격 [V]" },
	stance = { "Stance: %s [X]", "태세: %s [X]" },
	["stance.none"] = { "None", "없음" },
	["stance.attack"] = { "Attack", "공격" },
	["stance.defense"] = { "Defense", "방어" },
	["stance.counter"] = { "Counter", "역습" },
	["stance.onslaught"] = { "Onslaught", "맹공" },
	["stance.charge"] = { "Charge", "돌격" },
	["stance.shoot"] = { "Shooting", "사격" },
	skills = { "Skills", "기술" },
	coins = { "Shellmoney %d", "조개돈 %d" },
	level_sp = { "Level %d / SP %d", "레벨 %d / SP %d" },
	learn = { "Learn", "배우기" },
	["skills.survival"] = { "Survival", "생존" },
	["skills.butchering"] = { "Butchering", "도축" },
	["skills.gathering"] = { "Gathering", "채집" },
	["skills.processing"] = { "Processing", "가공" },
	["skills.weapon_tool"] = { "Weapons & Tools", "무기·도구" },
	["skills.ranged"] = { "Ranged", "원거리" },
	["skills.melee"] = { "Melee", "근접" },
	["skills.construction"] = { "Construction", "건축" },
	["skills.farming"] = { "Farming", "농사" },
	["skills.tailoring"] = { "Tailoring", "재봉" },
	["skills.cooking"] = { "Cooking", "요리" },
	["skills.defense"] = { "Defense", "방어" },
	skill_reset = { "Reset specializations", "전문 기술 초기화" },
	wood = { "Wood", "목재" },
	fiber = { "Fiber", "섬유" },
	flint = { "Flint", "부싯돌" },
	berry = { "Berries", "열매" },
	meat = { "Meat", "고기" },
	cord = { "Cord", "끈" },
	["stone-axe"] = { "Stone axe", "돌도끼" },
	["stone-pick"] = { "Stone pick", "돌곡괭이" },
	spear = { "Spear", "창" },
	["cooked-meat"] = { "Cooked meat", "구운 고기" },
	["berry-meal"] = { "Berry meal", "열매 요리" },
	plank = { "Plank", "널빤지" },
	campfire = { "Campfire", "모닥불" },
	workbench = { "Workbench", "작업대" },
	storage = { "Storage", "창고" },
	floor = { "Floor", "바닥" },
	roof = { "Roof", "지붕" },
	["campfire-kit"] = { "Campfire kit", "모닥불 키트" },
	["workbench-kit"] = { "Workbench kit", "작업대 키트" },
	["storage-kit"] = { "Storage kit", "창고 키트" },
	["floor-kit"] = { "Floor kit", "바닥 키트" },
	["roof-kit"] = { "Roof kit", "지붕 키트" },
	bag = { "Bag [I]", "가방 [I]" },
	craft = { "Craft [C]", "제작 [C]" },
	build = { "Build [B]", "건설 [B]" },
	attack = { "Attack [F]", "공격 [F]" },
	WEAPON_UNAVAILABLE = {
		"Craft a Starter Club at a workbench, then equip it from your bag before attacking.",
		"작업대에서 입문용 곤봉을 제작한 뒤 가방에서 장착하고 공격하세요.",
	},
	craft_nearby = { "Nearby / materials", "주변 시설 / 보유 재료" },
	craft_all = { "All recipes", "모든 레시피" },
	craft_favorite = { "Favorite", "즐겨찾기" },
	craft_unfavorite = { "Unfavorite", "즐겨찾기 해제" },
	craft_track = { "Track (to-do)", "할 일 추적" },
	craft_untrack = { "Untrack", "추적 해제" },
	tracker_title = { "To-do recipes", "할 일 레시피" },
	tracker_ready = { "Ready", "준비됨" },
	TODO_LIMIT = { "You can track up to 5 recipes.", "레시피는 최대 5개까지 추적할 수 있어요." },
	INVALID_MARK = { "That mark is not available.", "그 표시는 쓸 수 없어요." },
	FAVORITE_LIMIT = {
		"Too many favorites. Remove one first.",
		"즐겨찾기가 너무 많아요. 하나를 먼저 해제하세요.",
	},
	WILDLIFE_UNREACHABLE = {
		"Move within range and face a dinosaur",
		"공룡 가까이 이동하고 공룡을 바라보세요",
	},
	close = { "Close", "닫기" },
	cameraHelp = { "Camera controls", "카메라 조작" },
	cameraHint = {
		"Turn the view: [ / ] keys, right-mouse drag, or twist two fingers outside the HUD. E gathers nearby resources.",
		"시점 회전: [ / ] 키, 마우스 오른쪽 버튼 드래그 또는 HUD 밖에서 두 손가락 돌리기. E로 주변 자원을 채집해요.",
	},
	ready = { "Explore, gather, and make camp", "탐험하고 채집해서 야영지를 만드세요" },
	loading = { "Connecting to your supplies...", "보급품을 불러오는 중..." },
	pending = { "Pending - awaiting server confirmation", "대기 중 - 서버 확인을 기다리는 중" },
	confirmed = { "Confirmed - supplies saved", "확인됨 - 보급품 저장 완료" },
	SETTLEMENT_PUBLICATION_FAILED = {
		"Construction saved; world display is recovering. Refresh supplies; do not rebuild or repay.",
		"건설은 저장됐으며 월드 표시를 복구 중입니다. 보급품을 새로 고치세요. 다시 건설하거나 지불하지 마세요.",
	},
	conflict = { "Action refused", "작업 거절됨" },
	retry = { "Retry same request", "같은 요청 재시도" },
	refresh = { "Refresh supplies", "보급품 새로 고침" },
	empty = {
		"No items yet. Gather nearby resources.",
		"아직 아이템이 없어요. 주변 자원을 채집하세요.",
	},
	reserved = { "Reserved", "예약됨" },
	quality = { "Quality", "품질" },
	durability = { "Durability", "내구도" },
	freshness = { "Freshness %d%%", "신선도 %d%%" },
	freshness_spoiling = {
		"Freshness %d%% - eat or cool it soon",
		"신선도 %d%% - 곧 먹거나 냉장고에 넣으세요",
	},
	weight = { "Weight", "무게" },
	slots = { "Slots", "칸" },
	slow = { "Heavy load: movement reduced", "짐이 무거워 이동 속도가 줄었어요" },
	eat = { "Eat one", "하나 먹기" },
	hungry = {
		"You are getting hungry: open the bag (I) and press Eat one on berries or cooked food.",
		"배가 고파요: 가방(I)을 열고 열매나 익힌 음식의 '하나 먹기'를 누르세요.",
	},
	deposit = { "Store one", "하나 보관" },
	withdraw = { "Take one", "하나 꺼내기" },
	warehouse = { "Shared storage", "공용 창고" },
	reserve = { "Reserve ingredients", "재료 예약" },
	missing = { "Missing", "부족한 재료" },
	placementHint = {
		"Point at the ground, then confirm placement",
		"바닥을 가리킨 뒤 배치를 확정하세요",
	},
	inputs = { "Ingredients (available / needed)", "재료 (사용 가능 / 필요)" },
	outputs = { "Makes", "결과" },
	station = { "Station", "제작 시설" },
	tool = { "Tool", "도구" },
	hand = { "By hand", "손으로 제작" },
	start = { "Start", "시작" },
	complete = { "Collect", "받기" },
	cancel = { "Cancel", "취소" },
	Reserved = { "Reserved", "예약됨" },
	Running = { "Crafting", "제작 중" },
	Ready = { "Ready to collect", "받기 가능" },
	jobs = { "Your crafting jobs", "내 제작 작업" },
	health = { "Health", "체력" },
	hunger = { "Hunger", "포만감" },
	fatigue = { "Fatigue", "피로" },
	rest = { "Rest at campfire [R]", "모닥불에서 휴식 [R]" },
	resting = { "Resting - move to stop", "휴식 중 - 움직이면 종료" },
	rotate = { "Rotate", "회전" },
	["X-"] = { "Move left", "왼쪽으로 이동" },
	["X+"] = { "Move right", "오른쪽으로 이동" },
	["Z-"] = { "Move forward", "앞으로 이동" },
	["Z+"] = { "Move back", "뒤로 이동" },
	place = { "Place", "설치" },
	preview = { "Preview only - server validates placement", "미리보기 - 서버가 설치 위치를 확인해요" },
	buildHint = {
		"Point at the ground; rotate, then reserve. Costs use shared storage.",
		"바닥을 가리키고 회전한 뒤 예약하세요. 공용 창고 재료를 사용해요.",
	},
	select = { "Select an item for details", "아이템을 선택하면 정보가 나와요" },
	TRANSPORT_FAILED = {
		"Connection uncertain. Retry the same request; do not repeat the purchase or craft.",
		"연결 상태가 불확실해요. 같은 요청을 재시도하세요.",
	},
	HANDSHAKE_FAILED = {
		"Supplies are not connected. Refresh, then try again.",
		"보급품 연결이 안 됐어요. 새로 고친 뒤 다시 시도하세요.",
	},
	REQUEST_EXPIRED = {
		"Session expired. Refresh before a new action.",
		"세션이 만료됐어요. 새로 고친 뒤 작업하세요.",
	},
	capacity = {
		"Not enough space. Store items, then collect again; reserved ingredients are safe.",
		"공간이 부족해요. 아이템을 보관한 뒤 다시 받으세요. 예약 재료는 유지돼요.",
	},
	stale = {
		"Supplies changed. Refresh and check the new amounts before retrying.",
		"보급품이 변경됐어요. 새로 고쳐 수량을 확인한 뒤 다시 시도하세요.",
	},
	materials = {
		"Gather more ingredients, or cancel another reservation.",
		"재료를 더 채집하거나 다른 예약을 취소하세요.",
	},
	MISSING_INPUTS = {
		"Not enough free materials. Gather more, or cancel a reserved job to free them.",
		"쓸 수 있는 재료가 모자라요. 더 채집하거나 예약한 작업을 취소해 재료를 풀어 주세요.",
	},
	-- Inventory/Transaction refuse an uncoverable cost with "UNAVAILABLE".
	UNAVAILABLE = {
		"The camp warehouse lacks the materials. Store more from your bag, then reserve again.",
		"공용 창고에 재료가 모자라요. 가방에서 재료를 더 보관한 뒤 다시 예약하세요.",
	},
	-- The server checks the actor can reach the preview's entry tile (the small marker).
	PLACEMENT_UNREACHABLE = {
		"Move closer to place (max 12 studs from the preview's entry marker).",
		"더 가까이 가서 설치하세요 (미리보기 입구 표시에서 최대 12스터드).",
	},
	ITEM_RESERVED = {
		"That item is held by a reserved job. Cancel the job first.",
		"예약한 작업이 쓰고 있는 물건이에요. 먼저 그 작업을 취소하세요.",
	},
	UNKNOWN_RECIPE = {
		"That recipe is not available here.",
		"여기서는 만들 수 없는 레시피예요.",
	},
	STATION_UNAVAILABLE = {
		"Move closer to the required station, then reserve again.",
		"필요한 제작 시설(모닥불·작업대 등) 가까이 이동한 뒤 다시 예약하세요.",
	},
	WAREHOUSE_UNREACHABLE = {
		"Walk to the camp warehouse (the storage crate) to store or take items.",
		"공용 창고(보관 상자) 가까이 가서 보관하거나 꺼내세요.",
	},
	TRANSFER_UNAVAILABLE = {
		"Camp storage is not connected yet. Wait a moment, then try again.",
		"공용 창고가 아직 연결되지 않았어요. 잠시 뒤 다시 시도하세요.",
	},
	CAMPFIRE_UNREACHABLE = {
		"Move closer to a campfire to rest.",
		"모닥불 가까이 이동하면 쉴 수 있어요.",
	},
	SETTLEMENT_UNAVAILABLE = {
		"Shared camp is unavailable. Reconnect to its owner before building or storing.",
		"공용 야영지를 사용할 수 없어요. 소유자와 다시 연결한 뒤 건설하거나 보관하세요.",
	},
	COLLISION = {
		"Footprint or entry is blocked. Move or rotate the preview.",
		"설치 공간이나 입구가 막혔어요. 위치를 옮기거나 회전하세요.",
	},
	OUT_OF_BOUNDS = {
		"Keep the footprint and entry inside the camp grid.",
		"건물과 입구를 야영지 격자 안에 놓으세요.",
	},
	FORBIDDEN = {
		"Camp membership does not allow this action. Ask the owner to restore access.",
		"야영지 권한이 없어요. 소유자에게 접근 권한을 요청하세요.",
	},
	NOT_READY = {
		"Crafting is still running. Collect when its timer ends.",
		"아직 제작 중이에요. 시간이 끝나면 받으세요.",
	},
	unknown = {
		"Refresh and review your supplies before trying again.",
		"새로 고쳐 보급품을 확인한 뒤 다시 시도하세요.",
	},
}
function M.text(locale: string, key: string): string
	local entry = strings[key]
	return if entry then entry[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else key
end
-- Food freshness line from remaining permille; under a quarter left it warns to eat or refrigerate.
function M.freshness(locale: string, permille: number): string
	return string.format(M.text(locale, if permille < 250 then "freshness_spoiling" else "freshness"), permille // 10)
end
-- Skills row: category name, rank and cost; an unknown category shows its id with spaces.
function M.skill(locale: string, node: { category: string, rank: number?, cost: number }): string
	local key = "skills." .. node.category
	local name = if strings[key] then M.text(locale, key) else (string.gsub(node.category, "_", " "))
	return name .. (if node.rank then " " .. tostring(node.rank) else "") .. " · " .. tostring(node.cost) .. " SP"
end
function M.refusal(locale: string, reason: string): string
	local key = reason
	if string.find(reason, "WEIGHT") or string.find(reason, "SLOTS") or string.find(reason, "CAPACITY") then
		key = "capacity"
	elseif string.find(reason, "STALE") then
		key = "stale"
	elseif string.find(reason, "INGREDIENT") or string.find(reason, "RESERVED") or string.find(reason, "QUANTITY") then
		key = "materials"
	end
	return M.text(locale, if strings[key] then key else "unknown")
end
return M
