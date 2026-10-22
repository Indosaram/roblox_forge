--!strict
local M = {}
local strings: { [string]: { string } } = {
	["trade.bundle.list"] = { "List bundle", "묶음 등록" },
	menu_survival = { "Survival", "생존" },
	menu_world = { "World", "세계" },
	menu_social = { "Social", "함께" },
	menu_shop = { "Shop", "상점" },
	menu_settings = { "Settings", "설정" },
	music = { "Music", "연주" },
	dodge = { "Dodge [Q]", "회피 [Q]" },
	guard = { "Guard [G]", "방어 [G]" },
	skills = { "Skills", "기술" },
	learn = { "Learn", "배우기" },
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
	weight = { "Weight", "무게" },
	slots = { "Slots", "칸" },
	slow = { "Heavy load: movement reduced", "짐이 무거워 이동 속도가 줄었어요" },
	eat = { "Eat one", "하나 먹기" },
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
	-- Inventory/Transaction refuse a cost they cannot cover with "UNAVAILABLE" (a live
	-- campfire reserve with 3 of 4 wood in the warehouse read "refresh and retry").
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
