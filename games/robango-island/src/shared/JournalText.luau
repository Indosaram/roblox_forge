--!strict
-- Authored journal copy mirrors locale/strings.csv; chapter/objective IDs come from content.yml.
local rows: { [string]: { string } } = {
	["rw.c01.signal-trace.title"] = { "Signal trace", "신호의 흔적" },
	["rw.c01.signal-trace.summary"] = {
		"The relay repeats a pattern. Read the inland signal and test a lens.",
		"중계기가 같은 신호를 반복해요. 내륙 신호를 조사하고 렌즈를 시험하세요.",
	},
	["rw.c01.signal-trace.1.text"] = { "Survey the inland signal", "내륙 신호 조사" },
	["rw.c01.signal-trace.2.text"] = { "Assemble a signal lens", "신호 렌즈 조립" },
	["rw.c01.signal-trace.3.text"] = { "Activate the harbor relay", "항구 중계기 작동" },
	["rw.c01.signal-trace.4.text"] = { "Speak with Bram", "브램과 대화" },
	["rw.c02.home-station.title"] = { "Home station", "우리 집 기지" },
	["rw.c02.home-station.summary"] = {
		"Recover the wreck components and tune your home station.",
		"난파선 부품을 회수하고 집의 중계기를 조율하세요.",
	},
	["rw.c02.home-station.1.text"] = { "Inspect the wreck", "난파선 조사" },
	["rw.c02.home-station.2.text"] = { "Craft a signal relay kit", "신호 중계기 꾸러미 제작" },
	["rw.c02.home-station.3.text"] = { "Deploy a signal relay", "신호 중계기 설치" },
	["rw.c02.home-station.4.text"] = { "Tune the signal relay", "신호 중계기 조율" },
	["rw.c02.home-station.5.text"] = { "Speak with Hop", "홉과 대화" },
	["rw.c03.grassland-samples.title"] = { "Grassland samples", "초원의 표본" },
	["rw.c03.grassland-samples.summary"] = {
		"Gather readings from the grassland route and bring three samples.",
		"초원 항로를 조사하고 표본 세 개를 가져오세요.",
	},
	["rw.c03.grassland-samples.1.text"] = { "Survey the first grassland stage", "초원 첫 구역 조사" },
	["rw.c03.grassland-samples.2.text"] = { "Survey the fourth grassland stage", "초원 네 번째 구역 조사" },
	["rw.c03.grassland-samples.3.text"] = { "Assemble a sample case", "표본 상자 조립" },
	["rw.c03.grassland-samples.4.text"] = { "Deposit survey samples", "조사 표본 기탁" },
	["rw.c03.grassland-samples.5.text"] = { "Speak with Bram", "브램과 대화" },
	["rw.c04.marsh-remedy.title"] = { "Marsh remedy", "습지의 치료제" },
	["rw.c04.marsh-remedy.summary"] = {
		"Read the marsh markers and bring soup and medicine to the refuge.",
		"습지 표식을 조사하고 대피소에 수프와 치료제를 가져가세요.",
	},
	["rw.c04.marsh-remedy.1.text"] = { "Survey the second marsh stage", "습지 두 번째 구역 조사" },
	["rw.c04.marsh-remedy.2.text"] = { "Survey the third marsh stage", "습지 세 번째 구역 조사" },
	["rw.c04.marsh-remedy.3.text"] = { "Cook onion soup", "양파 수프 요리" },
	["rw.c04.marsh-remedy.4.text"] = { "Eat onion soup", "양파 수프 먹기" },
	["rw.c04.marsh-remedy.5.text"] = { "Administer the remedy", "치료제 투여" },
	["rw.c04.marsh-remedy.6.text"] = { "Speak with Ines", "이네스와 대화" },
	["rw.c05.shared-research.title"] = { "Shared research", "공동 연구" },
	["rw.c05.shared-research.summary"] = {
		"Survey the desert and neutral outpost and contribute your research.",
		"사막과 중립 거점을 조사하고 연구 자료를 기여하세요.",
	},
	["rw.c05.shared-research.1.text"] = { "Survey the desert marker", "사막 표식 조사" },
	["rw.c05.shared-research.2.text"] = { "Inspect the neutral outpost", "중립 거점 조사" },
	["rw.c05.shared-research.3.text"] = { "Assemble a research bundle", "연구 자료 묶음 조립" },
	["rw.c05.shared-research.4.text"] = { "Submit the research bundle", "연구 자료 묶음 제출" },
	["rw.c05.shared-research.5.text"] = { "Speak with Marit", "마리트와 대화" },
	["rw.c06.snow-protection.title"] = { "Snow protection", "설원의 방한 준비" },
	["rw.c06.snow-protection.summary"] = {
		"Protect the relay shelter with a liner made from real fur.",
		"모피로 안감을 만들어 중계기 대피소를 보호하세요.",
	},
	["rw.c06.snow-protection.1.text"] = { "Survey the first snow stage", "설원 첫 구역 조사" },
	["rw.c06.snow-protection.2.text"] = { "Survey the fourth snow stage", "설원 네 번째 구역 조사" },
	["rw.c06.snow-protection.3.text"] = { "Assemble a shelter liner", "대피소 안감 조립" },
	["rw.c06.snow-protection.4.text"] = { "Install the shelter liner", "대피소 안감 설치" },
	["rw.c06.snow-protection.5.text"] = { "Speak with Ines", "이네스와 대화" },
	["rw.c07.tyrant-material.title"] = { "Tyrant material", "폭군의 재료" },
	["rw.c07.tyrant-material.summary"] = {
		"Read the volcanic marker and reinforce the station with a fresh tyrannosaurus bone.",
		"화산 표식을 조사하고 갓 얻은 티라노사우루스 뼈로 기지를 보강하세요.",
	},
	["rw.c07.tyrant-material.1.text"] = { "Survey the volcanic marker", "화산 표식 조사" },
	["rw.c07.tyrant-material.2.text"] = { "Hunt a tyrannosaurus", "갓 처치한 티렉스의 뼈 확보" },
	["rw.c07.tyrant-material.3.text"] = { "Assemble a heat brace", "내열 지지대 조립" },
	["rw.c07.tyrant-material.4.text"] = { "Install the heat brace", "내열 지지대 설치" },
	["rw.c07.tyrant-material.5.text"] = { "Speak with Bram", "브램과 대화" },
	["rw.c08.collapse-return.title"] = { "Collapse and return", "붕괴와 귀환" },
	["rw.c08.collapse-return.summary"] = {
		"Build the transponder and bring the survivor home through the refuges.",
		"구조 송신기를 만들고 대피소를 거쳐 생존자를 귀환시키세요.",
	},
	["rw.c08.collapse-return.1.text"] = { "Survey the five final markers", "마지막 표식 다섯 개 조사" },
	["rw.c08.collapse-return.2.text"] = { "Assemble a rescue transponder", "구조 송신기 조립" },
	["rw.c08.collapse-return.3.text"] = { "Activate the rescue beacon", "구조 신호기 작동" },
	["rw.c08.collapse-return.4.text"] = { "Escort the survivor", "생존자 호위" },
	["rw.c08.collapse-return.5.text"] = { "Return through the exit", "출구를 통해 귀환" },
	["rw.c08.collapse-return.6.text"] = { "Speak with Marit", "마리트와 대화" },
	-- Authored dialogue lines (chapter offer/complete, market board guide) used by ui.dialogue.
	["rw.c01.signal-trace.offer"] = {
		"The relay is repeating a pattern. Read the inland signal, assemble a lens, and test it here.",
		"중계기가 같은 패턴을 되풀이하고 있어요. 내륙 신호를 읽고 렌즈를 조립해서 여기서 시험해 봐요.",
	},
	["rw.c01.signal-trace.complete"] = {
		"That pattern is a distress call, not weather noise. We have a direction to follow.",
		"그건 날씨 잡음이 아니라 조난 신호예요. 따라갈 방향이 생겼어요.",
	},
	["rw.c02.home-station.offer"] = {
		"The wreck has the components for your station. Recover them, build the kit, and tune the station at home.",
		"난파선에 당신 기지에 쓸 부품이 있어요. 부품을 회수해 꾸러미를 만들고, 집에서 기지를 조율하세요.",
	},
	["rw.c02.home-station.complete"] = {
		"Your station can now keep the journal connected. Technical support still waits until level sixty.",
		"이제 기지가 일지를 계속 연결해 줄 거예요. 기술 지원은 여전히 레벨 60을 기다려야 해요.",
	},
	["rw.c03.grassland-samples.offer"] = {
		"Bring readings from the first and fourth grassland stages, with three samples in a case.",
		"초원 첫 번째와 네 번째 구역의 측정값을, 표본 세 개를 담은 상자와 함께 가져오세요.",
	},
	["rw.c03.grassland-samples.complete"] = {
		"The samples carry the same trace. The signal crossed the whole route, not just one island.",
		"표본마다 같은 흔적이 있어요. 신호가 섬 하나가 아니라 항로 전체를 가로질렀다는 뜻이에요.",
	},
	["rw.c04.marsh-remedy.offer"] = {
		"Read the marsh markers, make onion soup, and take this remedy to the refuge.",
		"습지 표식을 읽고 양파 수프를 끓인 다음, 이 치료제를 대피소로 가져가세요.",
	},
	["rw.c04.marsh-remedy.complete"] = {
		"The explorer is stable. The soup was food; the supplied remedy was treatment. Do not confuse either with immunity.",
		"탐험가는 안정을 찾았어요. 수프는 음식이었고, 건넨 치료제가 치료였어요. 어느 쪽도 면역이라고 착각하진 마세요.",
	},
	["rw.c05.shared-research.offer"] = {
		"Survey the desert marker and the neutral outpost, then contribute a research bundle to the public ledger.",
		"사막 표식과 중립 거점을 조사한 뒤, 공용 장부에 연구 묶음을 기부하세요.",
	},
	["rw.c05.shared-research.complete"] = {
		"Your contribution is recorded. You can continue alone; clan research and outpost ownership remain separate choices.",
		"기부가 기록됐어요. 혼자서도 계속할 수 있어요. 부족 연구와 거점 소유는 각자 따로 고르는 거예요.",
	},
	["rw.c06.snow-protection.offer"] = {
		"The snow readings need a protected relay shelter. Obtain real fur and assemble its liner.",
		"설원 측정에는 보호된 중계 쉼터가 필요해요. 진짜 털을 구해 안감을 조립하세요.",
	},
	["rw.c06.snow-protection.complete"] = {
		"The shelter is protected. The fur came from snow animals, and the route remains open without a full outfit.",
		"쉼터가 보호됐어요. 털은 설원 동물에게서 얻었고, 옷을 다 갖추지 않아도 항로는 열려 있어요.",
	},
	["rw.c07.tyrant-material.offer"] = {
		"Read the volcanic marker. A fresh tyrannosaurus bone can brace the station against the interference.",
		"화산 표식을 읽으세요. 갓 얻은 티라노사우루스 뼈라면 간섭을 버티도록 기지를 보강할 수 있어요.",
	},
	["rw.c07.tyrant-material.complete"] = {
		"The brace is installed. The source record matches your kill, and the final survivor signal is clear.",
		"보강재를 달았어요. 출처 기록이 당신의 사냥과 일치하고, 마지막 생존자 신호도 또렷해졌어요.",
	},
	["rw.c08.collapse-return.offer"] = {
		"Build the transponder, read all five final markers, and bring the survivor back through the refuges.",
		"송신기를 만들고 마지막 표식 다섯 개를 모두 읽은 뒤, 대피소를 거쳐 생존자를 데려오세요.",
	},
	["rw.c08.collapse-return.complete"] = {
		"Our passenger reached home. The passage is sealed, and your journal now records the whole journey. You can sail again whenever you wish.",
		"구조한 사람이 집에 도착했고 통로도 봉쇄했어요. 일지에 여정이 모두 남았네요. 원할 때 다시 출항하세요.",
	},
	["rw.g08.market.offer"] = {
		"List this fiber for one Coin, cancel the listing, and collect it from returns.",
		"이 섬유를 1코인에 등록했다가 취소하고, 반환함에서 찾아가세요.",
	},
}
return function(locale: string, key: string): string?
	local row = rows[key]
	return if row then row[if string.sub(locale, 1, 2) == "ko" then 2 else 1] else nil
end
