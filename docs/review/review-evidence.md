### F1 [SEVERITY: critical]
- Claim attacked: Section 1 요약 "2025년 생성작인 Steal a Brainrot(누적 방문 73.69B, 최고 CCU 25.4M), Grow a Garden(35.94B, 22.3M), 99 Nights in the Forest(29.76B, 14.2M)가 수년 된 대형작(Blox Fruits, Adopt Me!, MM2)의 누적 방문을 1년 만에 따라잡거나 넘었습니다."
- Attack: 명백한 허위 사실(Factual Falsehood)이자 문서 내부 자가당착이다. Section 2 실측 표에서 Blox Fruits는 64.71B(647억), Adopt Me!는 44.87B(448억)이다. Grow a Garden의 35.94B는 Blox Fruits의 55% 수준에 불과하며, 99 Nights의 29.76B는 Adopt Me!의 66%에 불과하다. 수년 된 대형작의 누적 방문을 넘은 것은 Steal a Brainrot(73.69B) 단 1개뿐이며, 나머지 두 게임은 Blox Fruits와 Adopt Me!를 따라잡지도 넘지도 못했다. 요약문에서 통계를 심각하게 부풀려 왜곡했다.
- Evidence: `roblox-api-measured.json:rows` (`Blox Fruits: visits=64708036532`, `Adopt Me!: visits=44867051372`, `Grow a Garden: visits=35944812119`, `99 Nights: visits=29764128978`).
- Fix: 문장을 "Steal a Brainrot(73.69B)이 기존 1위인 Blox Fruits(64.71B)를 제쳤으며, Grow a Garden(35.94B)과 99 Nights(29.76B)는 MM2(30.88B)에 필적하는 누적 방문을 1년 만에 달성했습니다"로 정확한 사실관계로 수정.

### F2 [SEVERITY: critical]
- Claim attacked: Section 3.1 알고리즘 신호 vs Section 7 W4/W5-W6 실행 계획.
Section 3.1: "광고, 큐레이션, 친구, 검색, SNS로 처음 유입된 유저의 지표는 Ranking 단계에 반영되지 않습니다. 추천으로 들어온 유저의 참여와 리텐션만 순위를 결정합니다 [R6]."
Section 7: W4 소프트 런치는 "광고 크레딧 소액 집행"으로 D1 25% 측정, W5-W6은 "크리에이터 10명 비공개 서버 시딩, 숏폼 30편"을 통해 "추천 유입 비중 50% 이상" 달성.
- Attack: 전략 설계의 정면 모순(Direct Contradiction)이다. 공식 문서 [R6]에서 밝힌 로블록스 추천 랭킹(Ranking) 알고리즘의 대원칙은 **"광고(Ads), SNS(숏폼), 크리에이터, 외부 경로로 유입된 유저의 인게이지먼트와 리텐션은 추천 랭킹 산정에 일절 포함되지 않는다"**는 것이다. 그런데 기획서의 성장 파이프라인은 W4에서 '광고 크레딧', W5-W6에서 '숏폼 30편 + 크리에이터 시딩'이라는 외부 유료/SNS 채널에 100% 의존하면서 추천 유입 50%를 만들겠다고 주장한다. 외부 채널로 유입된 트래픽은 추천 엔진 랭킹을 전혀 끌어올리지 못하므로, 이 유입 전략으로는 목표 KPI인 추천 알고리즘 노출을 촉발할 수 없다.
- Evidence: `lane-c-verify.json:["https://create.roblox.com/docs/discovery"]`: "Roblox doesn't count the engagement, monetization, or retention of users first acquired from ads, curation, friends, search, social media, or any other source in the ranking stage of Recommended for You".
- Fix: W4~W6의 콜드스타트 전략을 전면 재수립해야 함. 외부 트래픽 의존을 제거하고, 1단계 Retrieval 풀에 진입하기 위한 검색 키워드 최적화(ASO) 및 플랫폼 내 친구 초대/합류(Social Presence Flow)를 통한 순수 인앱 바이럴 루프로 랭킹 진입 가교를 설계해야 함.

### F3 [SEVERITY: critical]
- Claim attacked: Section 4.3 & Section 5.1 코어 루프("알 구매 → 부화 → 기지 코인 생산 → 남의 기지에서 알/괴수 훔치기, 잠금 버튼 방어") 및 Section 8 "클론 과포화로 추천 노출 부족: 합체·공성전 차별화로 대응".
- Attack: 법적 침해 및 지식재산권(IP) 소송 리스크의 치명적 간과. Wikipedia 원문(`wikiRaw.Steal_a_Brainrot`)에 따르면, Steal a Brainrot은 미국 저작권청에 정식 등록(PA002544969)되어 있으며, 소유사인 Spyder Games / DoBig Studios는 2025년 10월 유사 포맷을 무단 복제한 'Stealing Brainrots' 개발사를 상대로 **연방 법원에 실제 저작권 침해 소송을 제기**했다. Section 5.1에 기재된 기지 코인 생산, 도둑질, 잠금 버튼 쿨다운 구조는 Steal a Brainrot의 1:1 기계적 복제물이다. "합체"나 "공성전" 같은 부가 요소 추가만으로는 저작권 침해 소송 및 로블록스 DMCA 게시중단(Takedown) 청구를 피할 수 없다.
- Evidence: `wiki-raw.json:Steal_a_Brainrot`: "The game is registered at the U.S Copyright Office (PA002544969). In October 2025, Spyder Games sued the creator of an unlicensed copy of Steal a Brainrot called Stealing Brainrots within Fortnite Creative, claiming that the Stealing Brainrots infringed on Spyder's copyrights."
- Fix: Section 8 리스크에 "원작사(DoBig Studios/Spyder Games)의 등록 저작권(PA002544969) 침해 소송 리스크"를 최우선 항목으로 명시하고, 제목에서 'Steal a...' 명명 패턴을 폐기하며, 기지 잠금/훔치기 메커니즘을 1:1 복제하지 않는 독자적 비대칭 대전/경쟁 룰로 전면 재설계.

### F4 [SEVERITY: critical]
- Claim attacked: Section 2 선정 기준 "2025-09~2026-09 기간에 누적 방문수 또는 현재 동시접속(CCU)이 최상위권인 게임입니다."
- Attack: 누적 방문수(Cumulative Stock)와 최근 12개월 흥행(Recent Flow)을 뒤섞은 치명적인 통계적 오류(Confounding). Murder Mystery 2는 2014년 1월(12년 전), Adopt Me!는 2017년 7월(9년 전), Blox Fruits는 2019년 1월(7년 전) 출시되었다. 이들의 300억~640억 누적 방문은 7~12년에 걸쳐 쌓인 과거의 총량이지, 지난 12개월간의 성과가 아니다. 이를 '최근 1년 인기 Top 10'으로 묶어 벤치마킹하는 것은 12년 전 레거시 게임의 누적 총량을 신규 바이럴 공식으로 둔갑시키는 근본적인 연구 방법론 결함이다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Section 2 Table`, `roblox-api-measured.json:rows` (`created`: MM2 2014-01-18, Adopt Me! 2017-07-14, Blox Fruits 2019-01-16).
- Fix: Section 2의 데이터셋을 '과거 레거시 장기 흥행작(Pre-2024)'과 '최근 12개월 신규 출시 돌풍작(Post-2025)'의 두 개 표로 명확히 분리하고, 바이럴 루프 벤치마킹 대상을 최근 1년 내 출시되어 급성장한 게임으로만 한정할 것.

### F5 [SEVERITY: critical]
- Claim attacked: Section 5.3 수익화 상품 "희귀 알 / 전설 알 | 개발자 상품(반복) | 99 / 499 R$" 및 "가챠 규정 준수: ... 국가별 유료 무작위 아이템 제한 설정(PolicyService)도 반영합니다."
- Attack: 로블록스 가챠 규정 준수 및 수익화 가능성에 대한 피상적 접근과 플랫폼 셧다운 리스크. 로블록스의 유료 무작위 아이템(Paid Random Items) 정책에 따르면 `PolicyService:ArePaidRandomItemsRestricted`가 참(True)인 국가(네덜란드, 벨기에, 호주 등) 및 부모 통제 계정에서는 Robux를 직접 지불하는 확률형 무작위 상품의 노출 및 판매가 전면 차단된다. 기획서에서 가장 중요한 반복 결제 모델("반복 구매 축")로 선정한 99/499 R$ 알 구매가 규제 지역 플레이어에게는 아예 결제 불가 상태가 된다. 대체 천장 시스템이나 확정 구매 경제가 문서에 전무하여, 해당 지역 유저는 핵심 수익화 동선에서 완전 이탈한다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Line 115`, Roblox Developer Documentation on PolicyService (`ArePaidRandomItemsRestricted`).
- Fix: 유료 Robux로는 무작위 알이 아닌 '확정 괴수' 또는 '부화 가속권/재화'만 판매하고, 무작위 알 부화는 게임 내 플레이를 통해 얻는 무료 인게임 재화로만 동작하도록 경제 루프를 수정하여 가챠 정책 리스크를 근본적으로 원천 차단할 것.

### F6 [MAJOR] : Scoring Gate
- Claim attacked: Section 4.1 게이트 규칙 (바이럴 25점, 수익성 25점, 통과 기준 각 20점 이상) 및 Section 4.2 채택표.
- Attack: 완벽한 순환 논리(Circular Reasoning)이자 반증 불가능(Unfalsifiable)한 자가 채점. 바이럴 루브릭 세부 항목을 보면 2번 "클립으로 찍을 만한 순간(도둑질, 희귀 뽑기...)", 3번 "사회적 압력(훔치기, 거래...)"으로 아예 1순위 후보작(Steal a Kaiju Egg)의 고유 메커니즘인 **'도둑질', '훔치기'**를 루브릭 채점 기준 자체에 명시해 두었다. 정답을 미리 정해놓고 채점표를 역설계한 것이다. 또한 세부 5개 항목별 점수 배점 근거(각 1~5점)가 전혀 공개되지 않은 채 23/23이라는 총점만 제시되었으며, 문서 스스로 "ASSUMED(리드 에이전트의 정성 점수)"라고 고백했듯 객관적 검증이 불가능한 고무줄 잣대다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Lines 74-76, 80-87`.
- Fix: 평가 항목에서 '도둑질/훔치기' 같은 특정 게임 메커니즘 명칭을 삭제하고 '비대칭 인터랙션 강도', '플레이어 간 자산 전이성' 등 객관적 추상 지표로 교체하며, 5개 후보작 전원에 대해 5개 세부 항목별 1~5점 점수와 정량적 산출 근거를 투명하게 공개할 것.

### F7 [MAJOR] : Candidate Scoring Double Standard
- Claim attacked: Section 4.2 후보 3번(99 Floors Below: 바이럴 22, 수익성 16) 탈락 사유 "판매할 게 소모품 위주라 고액 결제 상한이 낮음" vs 후보 2번(Grow & Defend Garden: 바이럴 21, 수익성 22) 채택.
- Attack: 탈락 후보와 채택 후보 간의 노골적인 이중 잣대(Double Standard). 후보 2번(Grow & Defend)은 Grow a Garden(유료 게임패스 0개)과 99 Nights(유료 게임패스 1개, 199 R$)를 결합한 게임인데 수익성 점수를 22점(통과)을 부여했다. 반면 99 Nights를 벤치마킹한 후보 3번은 "소모품 위주라 고액 결제가 낮다"며 16점(탈락)을 주었다. 유료 게임패스가 0개와 1개인 두 게임을 합쳤더니 수익성이 22점으로 치솟고, 1개인 게임을 변형했더니 16점으로 탈락한다는 것은 수치적 일관성이 전무하다. 또한 후보 4번(Runway Rumble)은 "DTI가 장르를 선점했다"며 바이럴 17점으로 탈락시켰으면서, Steal a Kaiju Egg는 Steal a Brainrot(73.7B)과 Steal An Egg(동접 146만)라는 압도적 골리앗이 시장을 완전 장악하고 있음에도 바이럴 23점을 매긴 모순을 범했다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Section 4.2 table`, `Section 2 table` (Grow a Garden 게임패스 0개, 99 Nights 1개, Steal An Egg 현재 CCU 1,459,301).
- Fix: 후보 1번의 바이럴 점수를 시장 과포화 패널티를 적용해 하향 조정하고, 후보 3번의 수익 모델(부활 토큰, VIP 클래스, 영구 무기 등 서바이벌 특화 BM)을 재평가하여 동일한 잣대로 5개 후보를 재채점할 것.

### F8 [MAJOR] : Selection Integrity & Omissions
- Claim attacked: Section 2 Top 10 순위 테이블의 정렬 기준 및 Section 9 "Brookhaven RP는 games API가 TITLE UNAVAILABLE을 반환해 표에서 제외했습니다."
- Attack: 순위표의 정렬 기준 부재 및 자의적 필터링(Cherry-picking). 순위표는 누적 방문수 정렬도 아니고(4위 Blox Fruits 64.7B가 2위 Grow a Garden 35.9B보다 훨씬 높음), 현재 CCU 정렬도 아니며(8위 Steal An Egg CCU가 146만으로 1위인데 8위에 배치됨), 생성일자 정렬도 아니다. 또한 누적 방문수 500억 이상, 플랫폼 최상위권인 `Brookhaven RP`를 단지 비인증 API 호출에서 연령/지역 제한으로 `[TITLE UNAVAILABLE]`이 떴다는 이유만으로 Top 10 분석에서 통째로 누락시켰다. 게다가 `roblox-api-measured.json`에 엄연히 존재하는 `[🌋] Ride A Pet`(2026-04 생성, 실측 CCU 238,990)은 Blox Fruits, Adopt Me, MM2, Rivals, Grow a Garden, DTI, Dead Rails보다 실측 CCU가 높음에도 Top 10에서 임의 배제되었다.
- Evidence: `roblox-api-measured.json:rows` (`Ride A Pet: playing=238990`, `Dead Rails: playing=12000`, `u=0, place=0 [TITLE UNAVAILABLE]`); `ROBLOX_VIRAL_GAME_PLAN.md:Line 214`.
- Fix: 순위표를 '실측 CCU 순' 또는 '최근 30일 추정 방문수 순' 단일 정량 기준으로 엄격하게 재정렬하고, Brookhaven RP를 인증된 Place ID/Universe ID로 재조회하여 포함시키며, Ride A Pet과 같은 2026년 실측 최상위 신작을 데이터셋에 정당하게 반영할 것.

### F9 [MAJOR] : Grow a Garden Retention Collapse
- Claim attacked: Section 1 & Section 2: Grow a Garden(누적 방문 35.94B, 최고 CCU 22.3M)을 핵심 성공 모델로 채택하고, Section 4에서 2순위 피벗 게임의 뼈대로 삼음.
- Attack: 생존 편향 및 99.9% 유저 이탈(Retention Cliff) 간과. Grow a Garden의 역대 최고 CCU는 2025년 8월 23일 기록한 22.3M(2,230만)이지만, 2026년 9월 28일 기준 실측 CCU는 **21,144명**이다. 유저가 무려 **99.9% 증발**했다. 2,230만 CCU는 대형 개발사(Splitting Point, DoBig)와 최상위 인플루언서들이 총동원된 단발성 인위적 이벤트("admin war")로 인한 기형적 스파이크였을 뿐, 게임의 오가닉 잔존력이 아니었다. 이 게임의 코어 루프를 벤치마킹하여 장기 라이브옵스를 설계하는 것은 급격한 유저 이탈 절벽을 자초하는 치명적인 사업적 오판이다.
- Evidence: `roblox-api-measured.json:rows` (`[🐿️] Grow a Garden 🌶️: playing=21144`), `wiki-raw.json:Grow_a_Garden` (2025-08-23 admin war peak 22.3M).
- Fix: Section 3 분석에 Grow a Garden의 1년 뒤 CCU 붕괴(2,230만 → 2.1만)에 대한 원인 분석(엔드게임 부재, 인플레이션 붕괴)을 필수 반면교사로 추가하고, 단기 이벤트 스파이크와 장기 잔존 지표를 분리하여 평가할 것.

### F10 [MAJOR] : Misinterpretation of Gamepass Economics
- Claim attacked: Section 2 Table & Section 3 "Grow a Garden은 유료 게임패스 0개로 개발자 상품 위주(game-passes API)", Section 5.3 수익화 설계.
- Attack: API 측정값에 대한 중대한 오독 및 수익화 메커니즘 왜곡. 로블록스 공개 `game-passes` API는 영구 귀속형 'Game Pass'만 반환하며, 소비성 'Developer Products(개발자 상품)'는 전혀 조회하지 못한다. Wikipedia 원문(`wikiRaw.Grow_a_Garden`)에 따르면 Grow a Garden은 밭 성장 가속, 작물 도둑질, 펫 뽑기 상자 등 수많은 소비성 개발자 상품을 극단적으로 판매하여 "과도한 수익화(excessive monetization)를 도입했다"고 강한 비판을 받은 게임이다. 유료 게임패스가 0개인 것은 '가벼운 수익화'를 해서가 아니라 '약탈적 소비성 결제'에 집중했기 때문인데, 기획서는 이를 오독하여 유료 상품이 적은 것처럼 서술했다. 그러고는 정작 Section 5.3에서는 2배 코인(399 R$), VIP 슬롯(699 R$), 자동 잠금(249 R$) 등 전형적인 구시대 게임패스 3종을 채택해 분석 결과와 기획 설계가 완전히 따로 논다.
- Evidence: `wiki-raw.json:Grow_a_Garden`: "Roblox's built-in premium currency, Robux, can be used to speed up waiting, gain additional perks, and steal others' crops... The studio has been criticized for introducing excessive monetization".
- Fix: Section 3을 수정하여 "Grow a Garden은 게임패스가 없는 대신 공격적인 소모성 개발자 상품(Robux 가속/뽑기) 중심의 과금 모델"임을 명시하고, Section 5.3의 수익화 설계를 영구 게임패스 중심에서 시즌/소모성 중심으로 정합성을 맞출 것.

### F11 [MAJOR] : Ghost KPI in Liveops Gate
- Claim attacked: Section 7 W7-W8 통과 기준 "D7 리텐션 8% 이상, ARPDAU 목표 달성".
- Attack: 목표 수치와 경제 모델이 존재하지 않는 유령 KPI(Ghost KPI). W7-W8 게이트에서 'ARPDAU 목표 달성'을 통과 기준으로 명시했으나, 문서 전체 어디에도 ARPDAU 목표 수치(예: 몇 Robux 또는 몇 USD인지)가 정의되어 있지 않다. 더욱이 Section 9 한계점에서는 "DevEx 공식 문서 URL이 404가 나서 Robux당 달러 환전 비율(0.0035 USD/R$)을 본문에서 제외했다"고 밝혔다. 환전 비율도 없고, 유저당 결제액 목표도 없는데 어떻게 'ARPDAU 목표 달성'을 판정할 수 있는가? 통과 기준으로서 기능할 수 없는 공허한 문구다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Line 158` (Section 7 Table W7-W8), `Line 207-211` (Section 9 한계점 인정).
- Fix: 로블록스 캐주얼 시뮬레이션 장르의 표준 벤치마크를 근거로 구체적 ARPDAU 목표치(예: 일일 활성 유저당 0.05~0.12 Robux / 약 $0.00018~$0.00042 USD)를 수치로 명시하고, DAU 대비 예상 월 매출 추산 수식을 보완할 것.

### F12 [MAJOR] : Real-Money Loss Conflict with Moderation Policy
- Claim attacked: Section 5.1 & Section 5.3: 희귀/전설 알을 유료 Robux(개발자 상품 99 / 499 R$)로 구매해 괴수를 부화시키고, 다른 유저가 "남의 기지에서 알이나 괴수를 훔쳐 오는" 메커니즘.
- Attack: 플레이어 자산 손실 및 로블록스 신뢰&안전(Trust & Safety) 규정 충돌. 유저가 실제 현금(Robux)을 결제하여 획득한 고가 자산(전설 괴수)을 다른 플레이어가 인게임에서 훔쳐 갈 수 있게 설계하면, 결제 유저의 박탈감으로 인한 대량 환불 분쟁(Chargeback) 및 평가 폭락(Like 비율 급락)을 초래한다. 로블록스 커뮤니티 가이드라인은 유저 간 불공정 자산 탈취 및 사기성 메커니즘에 엄격하며, 실제 현금 결제 아이템이 영구 도난당할 경우 운영 정책상 '사기/약탈성 게임'으로 제재되거나 플랫폼 신고 누적으로 추천 목록에서 블랙리스트 처리될 위험이 극도로 높다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Section 5.1, 5.3`, `wiki-raw.json:Steal_a_Brainrot` (캐릭터를 도난당한 어린이 유저들의 울부짖음과 자동화 스크립트 악용 논란 언급).
- Fix: 유료 Robux로 구매한 괴수나 알은 '도난 방지(Soulbound / 금고 보관)' 속성을 영구 부여하고, 오직 무료 플레이를 통해 생산된 일반 자원/기본 알만 훔치기 대상이 되도록 시스템적으로 강제 격리할 것.

### F13 [MINOR] : Developer Attribution Mismatch
- Claim attacked: Section 2 Table 8위 `Steal An Egg`의 개발 그룹명 `and Collect Rare Pets`.
- Attack: 개발사 식별 및 귀속 오류. 표에는 개발 그룹이 "and Collect Rare Pets"로 기재되어 있다. 이는 로블록스 검색창에서 게임 제목과 합쳐져 "Steal An Egg and Collect Rare Pets"로 읽히도록 조작한 전형적인 SEO 스팸형 그룹 작명 트릭이다. 이를 필터링 없이 그대로 개발 그룹명으로 기재한 것은 로블록스 플랫폼 생태계의 작명 관행을 비판 없이 원시 API 텍스트 그대로 수용한 미숙한 분석이다.
- Evidence: `roblox-api-measured.json:rows` (`name: "Steal An Egg", creator: "and Collect Rare Pets"`).
- Fix: 해당 개발 그룹명이 SEO용 변칙 표기임을 주석으로 명시하고, 실제 운영 주체(그룹 ID: 825735094 소유자)를 정확히 명시할 것.

### F14 [MINOR] : Unsupported Citation for Peak CCU
- Claim attacked: Section 2 Table 3위 `99 Nights in the Forest 🔦`의 최고 CCU `14.2M [W3]`, 인용 출처 `[W3] https://en.wikipedia.org/wiki/List_of_Roblox_games`.
- Attack: 인용 출처의 주장 미뒷받침. 문서에서는 위키백과 목록 페이지 `[W3]`을 출처로 달았으나, 정작 수집 데이터셋인 `wiki-raw.json` 내 `List_of_most_popular_Roblox_games` 항목은 `"MISSING"`으로 기록되어 실제 웹상에서 정상 페치되지 않았다. 비록 원시 텍스트 파일(`wiki-list-roblox-games.txt`)에 해당 단락이 존재하지만, 공식적으로 제시된 URL 출처 [W3]만으로는 검증이 실패하는 레퍼런스 결함이다.
- Evidence: `wiki-raw.json:List_of_most_popular_Roblox_games` (`"MISSING"`), `ROBLOX_VIRAL_GAME_PLAN.md:Line 221`.
- Fix: 결측 처리된 [W3] 대신 실제 14.2M 기록이 보도된 1차 뉴스 기사나 로블록스 혁신 어워드 공식 수상 기록 URL로 출처를 갱신할 것.

### F15 [MINOR] : Macro Justification vs Micro Execution Mismatch
- Claim attacked: Section 1 요약(Steal a Brainrot 2,540만 CCU, Grow a Garden 2,230만 CCU) vs Section 7 W5-W6 KPI ("최고 CCU 1,000 이상").
- Attack: 기획서 거시 근거와 미시 목표 간의 4자릿수 규모 불일치(Scale Mismatch). 사업 기획서의 서두에서는 2,000만~2,500만 CCU를 기록한 초대형 바이럴 신작들을 근거로 시장 기회와 바이럴 루프를 정당화했다. 그런데 정작 12주 개발 계획의 W5-W6 바이럴 푸시 성공 기준은 "최고 CCU 1,000 이상"이다. 1,000 CCU는 2,500만 CCU의 0.004%에 불과한 소규모 수치다. 피크 CCU 1,000 수준(DAU 약 1.5만~2만)에서는 일일 수익이 수십 달러에 불과하여 Section 6 및 11에서 제안한 복잡한 12개 메타 툴체인, 모노레포, 주간 라이브옵스, 3D/오디오 파이프라인의 고정 유지비조차 회수할 수 없다. 기획의 거시적 명분과 실행 목표 간의 괴리가 지나치게 크다.
- Evidence: `ROBLOX_VIRAL_GAME_PLAN.md:Line 4` vs `Line 157`.
- Fix: 프로젝트 목표를 명확히 할 것. 1,000 CCU 목표의 린(Lean)한 1인 인디 프로토타입인지, 아니면 수십만 CCU를 겨냥해 메타 툴체인 투자를 회수할 상업적 바이럴 프로젝트인지 규모의 일관성을 맞추어 KPI를 현실화(최소 목표 피크 CCU 10,000~50,000 이상)할 것.