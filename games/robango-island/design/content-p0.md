# 로방고 섬 P0 콘텐츠 목록 (content-p0)

이 문서는 `content.yml`(원본)에 들어간 P0 콘텐츠 전체를 나열한다. 계획 §5(생물군계), §6(로스터), §9.1~9.4(세계관·NPC·의뢰·튜토리얼), §10(텍스트)을 따른다. **표에 나오는 수치는 모두 신규 산정**이며 초기 가설이다. 원작 수치나 커뮤니티 표는 시작점으로도 쓰지 않았다. 밸런스는 이후 `forge econ sim`과 시드 고정 시뮬레이션 spec으로 조정한다.

- 원본: `content.yml` → `forge content codegen` → `src/shared/SurvivalContent.luau`(생성 파일, 손 편집 금지).
- 런타임 카탈로그: `econ.yml`의 `survival-coop.inventory.content` → `forge codegen` → `GenreConfig.luau`. items·recipes·nodes·structures·wildlife·tags는 `content.yml`과 같은 내용으로 맞춰 두었다(§9).
- 생물 전투 규칙과 스폰: `src/shared/WildlifePolicy.luau`의 `catalog.species`와 `spawns`. 17종 모두 규칙이 있고, 17종 모두 섬에 한 마리 이상 스폰된다(§9).
- 표시 이름은 `locale/strings.csv`의 en-us·ko-kr 열에 있다. 키 규칙: `item_<id>`, `recipe_<id>`, `node_<id>`, `structure_<id>`, `wildlife_<id>`(하이픈은 밑줄로 바꾼다).
- 재화: 소프트 재화 표시명은 **조개돈 / Shellmoney**(`currency_name`, `coin_label`)이다. 내부 id `Coins`는 survival-coop 어댑터가 `currency: Coins`를 강제하므로 유지하고, 표시 문자열만 바꿨다.

## 1. 생물군계 (P0 2개, 신규 산정)

| id | 한국어 | English | 실제 식생 팔레트 |
|---|---|---|---|
| temperate-forest | 온대 숲 | Temperate Forest | English oak, silver birch, common hazel, bramble, bracken fern, chanterelle, ivy |
| coastal-marsh | 해안 습지 | Coastal Marsh | Common reed, broadleaf cattail, cordgrass, glasswort (samphire), sea lavender, eelgrass, sea rocket |

현재 스키마에는 생물군계 필드가 없다. 그래서 노드 id 접두사(`forest-`, `marsh-`)로 소속을 표시하고, 생물군계 이름은 로케일 키 `biome_*`로 둔다. `landing`은 첫 상륙지 개발 노드(기존 5종)다.

## 2. 채집 노드 (신규 산정: 수확량·재생 시간)

| id | 한국어 | English | 생물군계 | 수확 | 재생(ms) | 실제 식생 |
|---|---|---|---|---|---|---|
| fallen-tree | 쓰러진 나무 | Fallen Trunk | landing | wood×3 | 120000 | - |
| flint-outcrop | 부싯돌 노두 | Flint Outcrop | landing | flint×3 | 120000 | - |
| fiber-bush | 섬유 덤불 | Fiber Tuft | landing | fiber×3 | 120000 | - |
| berry-bush | 딸기 덤불 | Berry Bush | landing | berry×3 | 120000 | - |
| meat-cache | 사냥감 보관더미 | Hunter's Cache | landing | meat×3 | 120000 | - |
| forest-oak-windfall | 참나무 풍도목 | Oak Windfall | forest | wood×3 | 150000 | English oak (Quercus robur) |
| forest-birch-stand | 자작나무 숲 | Birch Stand | forest | birch-bark×2, wood×1 | 150000 | Silver birch (Betula pendula) |
| forest-hazel-thicket | 개암나무 덤불 | Hazel Thicket | forest | hazelnut×3 | 180000 | Common hazel (Corylus avellana) |
| forest-bramble-patch | 나무딸기 덤불 | Bramble Patch | forest | berry×3 | 150000 | Bramble (Rubus fruticosus agg.) |
| forest-bracken-bed | 고사리 군락 | Bracken Bed | forest | fiber×3 | 120000 | Bracken fern (Pteridium aquilinum) |
| forest-chanterelle-log | 이끼 낀 통나무 | Mossy Log | forest | chanterelle×2 | 240000 | Chanterelle (Cantharellus cibarius) on moss |
| forest-flint-scree | 부싯돌 너덜 | Flint Scree | forest | flint×2, fieldstone×1 | 180000 | Chalk scree, ivy (Hedera helix) |
| forest-boulder-field | 바위밭 | Boulder Field | forest | fieldstone×3 | 240000 | Lichen-covered boulders |
| marsh-reed-bed | 갈대밭 | Reed Bed | marsh | reed×3 | 120000 | Common reed (Phragmites australis) |
| marsh-cattail-stand | 부들 군락 | Cattail Stand | marsh | cattail-root×2, fiber×1 | 180000 | Broadleaf cattail (Typha latifolia) |
| marsh-cordgrass-tussock | 갯줄풀 포기 | Cordgrass Tussock | marsh | fiber×2, reed×1 | 150000 | Cordgrass (Spartina alterniflora) |
| marsh-samphire-flat | 퉁퉁마디 갯벌 | Samphire Flat | marsh | samphire×3 | 180000 | Glasswort (Salicornia europaea) |
| marsh-clay-bank | 점토 둔덕 | Clay Bank | marsh | marsh-clay×3 | 240000 | Sea lavender (Limonium vulgare) on clay |
| marsh-clam-bed | 조개밭 | Clam Bed | marsh | clam×2, shell-fragment×1 | 240000 | Eelgrass (Zostera marina) shallows |
| marsh-driftwood-line | 표류목 띠 | Driftwood Line | marsh | wood×2 | 180000 | Sea rocket (Cakile maritima) strandline |

## 3. 아이템 (신규 산정: 묶음 상한·무게·내구도·음식 효과)

음식 효과는 허기·체력 회복량, 피로 감소량이다(밀리 단위).

| id | 한국어 | English | 분류 | 묶음 | 무게(milli) | 내구도(milli) | 음식(허기/체력/피로) | 태그 |
|---|---|---|---|---|---|---|---|---|
| wood | 쓰러진 통나무 | Windfall Log | raw | 50 | 500 | - | - | - |
| flint | 뗀석기 부싯돌 | Knapping Flint | raw | 50 | 500 | - | - | - |
| fiber | 고사리 섬유 | Bracken Fiber | raw | 50 | 500 | - | - | - |
| berry | 덤불딸기 | Bramble Berry | food | 50 | 500 | - | 5000/0/0 | - |
| meat | 날고기 | Raw Game Meat | raw | 50 | 500 | - | - | - |
| cord | 꼰 끈 | Twisted Cord | intermediate | 50 | 500 | - | - | - |
| stone-axe | 부싯돌 손도끼 | Flint Hatchet | tool | 1 | 2500 | 100000 | - | tool |
| stone-pick | 부싯돌 곡괭이 | Flint Pick | tool | 1 | 2500 | 100000 | - | tool |
| spear | 불에 단련한 창 | Fire-hardened Spear | tool | 1 | 2500 | 100000 | - | tool |
| cooked-meat | 잉걸불 구이 | Ember-roast Meat | food | 50 | 500 | - | 20000/0/0 | - |
| berry-meal | 으깬 딸기죽 | Berry Mash | food | 50 | 500 | - | 15000/0/0 | - |
| plank | 쪼갠 판자 | Split Plank | intermediate | 50 | 500 | - | - | - |
| campfire-kit | 화덕 꾸러미 | Hearth Bundle | kit | 50 | 500 | - | - | - |
| workbench-kit | 작업대 꾸러미 | Bench Bundle | kit | 50 | 500 | - | - | - |
| storage-kit | 상자 꾸러미 | Crate Bundle | kit | 50 | 500 | - | - | - |
| floor-kit | 판자 바닥 부재 | Plank Floor Kit | kit | 50 | 500 | - | - | - |
| roof-kit | 판자 지붕 부재 | Plank Roof Kit | kit | 50 | 500 | - | - | - |
| birch-bark | 자작나무 껍질 | Birch Bark Curl | raw | 80 | 150 | - | - | fuel |
| hazelnut | 개암 | Hazelnut | food | 60 | 100 | - | 3000/0/0 | - |
| chanterelle | 꾀꼬리버섯 | Golden Chanterelle | food | 40 | 150 | - | 2000/1000/0 | - |
| fieldstone | 들돌 | Fieldstone | raw | 30 | 1500 | - | - | material-stone |
| reed | 갈대 줄기 | Common Reed Stalk | raw | 80 | 200 | - | - | - |
| cattail-root | 부들 뿌리줄기 | Cattail Rhizome | food | 40 | 300 | - | 4000/0/0 | - |
| marsh-clay | 갯벌 점토 | Saltmarsh Clay | raw | 30 | 1200 | - | - | material-brick |
| samphire | 퉁퉁마디 순 | Glasswort Sprig | food | 60 | 100 | - | 2000/0/0 | - |
| clam | 갯벌 조개 | Mud Clam | food | 40 | 250 | - | 3000/0/0 | - |
| shell-fragment | 조개껍데기 조각 | Shell Shard | raw | 80 | 100 | - | - | - |
| hide | 질긴 가죽 | Tough Hide | raw | 20 | 800 | - | - | - |
| flint-knife | 부싯돌 칼 | Flint Knife | tool | 1 | 600 | 60000 | - | tool, cutting |
| stone-maul | 돌 메 | Stone Maul | tool | 1 | 3500 | 140000 | - | tool, masonry |
| thatch-bundle | 이엉 다발 | Thatch Bundle | intermediate | 20 | 800 | - | - | material-brick |
| timber-beam | 각재 | Timber Beam | intermediate | 10 | 2500 | - | - | material-timber |
| stone-block | 다듬은 돌 | Dressed Stone Block | intermediate | 10 | 3000 | - | - | material-stone |
| mud-brick | 구운 흙벽돌 | Fired Mud Brick | intermediate | 20 | 1500 | - | - | material-brick |
| timber-wall-kit | 목재 벽 부재 | Timber Wall Kit | kit | 5 | 5000 | - | - | building-part, material-timber |
| stone-floor-kit | 석재 바닥 부재 | Stone Floor Kit | kit | 5 | 6000 | - | - | building-part, material-stone |
| stone-wall-kit | 석재 벽 부재 | Stone Wall Kit | kit | 5 | 9000 | - | - | building-part, material-stone |
| stone-roof-kit | 석재 지붕 부재 | Stone Roof Kit | kit | 5 | 8000 | - | - | building-part, material-stone |
| brick-floor-kit | 벽돌 바닥 부재 | Brick Floor Kit | kit | 5 | 4500 | - | - | building-part, material-brick |
| brick-wall-kit | 벽돌 벽 부재 | Brick Wall Kit | kit | 5 | 7000 | - | - | building-part, material-brick |
| brick-roof-kit | 벽돌 이엉 지붕 부재 | Brick-and-Thatch Roof Kit | kit | 5 | 5000 | - | - | building-part, material-brick |
| roasted-hazelnuts | 볶은 개암 | Roasted Hazelnuts | food | 30 | 200 | - | 12000/2000/0 | - |
| woodland-skewer | 숲 꼬치 | Woodland Skewer | food | 20 | 400 | - | 25000/5000/0 | - |
| clam-bake | 조개 구이 | Clam Bake | food | 20 | 400 | - | 22000/4000/0 | - |
| cattail-flatbread | 부들 납작빵 | Cattail Flatbread | food | 30 | 300 | - | 14000/0/2000 | - |

## 4. 제작 트리 (신규 산정: 재료 수량·제작 시간)

등급: **맨손**(작업대 없음) → **1단 작업대**(workbench) → **2단 목공대**(joiner-bench) → **3단 석공대**(mason-bench) + 부속 **흙가마**(mud-kiln). 요리는 모닥불(campfire)에서 한다. 건축 부재는 목재·석재·벽돌 3가지 재료로 나뉜다.

| 레시피 id | 결과 | 재료 | 설비 | 필요 도구 태그 | 제작(ms) |
|---|---|---|---|---|---|
| cord | cord×1 (꼰 끈) | fiber×3 | 맨손 | - | 3000 |
| stone-axe | stone-axe×1 (부싯돌 손도끼) | flint×2 | 맨손 | - | 3000 |
| stone-pick | stone-pick×1 (부싯돌 곡괭이) | flint×3 | 맨손 | - | 3000 |
| spear | spear×1 (불에 단련한 창) | wood×3 | 맨손 | - | 3000 |
| cooked-meat | cooked-meat×1 (잉걸불 구이) | meat×1 | campfire | - | 3000 |
| berry-meal | berry-meal×1 (으깬 딸기죽) | berry×3 | campfire | - | 3000 |
| plank | plank×1 (쪼갠 판자) | wood×2 | workbench | - | 3000 |
| campfire-kit | campfire-kit×1 (화덕 꾸러미) | wood×4 | 맨손 | - | 3000 |
| workbench-kit | workbench-kit×1 (작업대 꾸러미) | wood×6 | 맨손 | - | 3000 |
| storage-kit | storage-kit×1 (상자 꾸러미) | plank×4 | workbench | - | 3000 |
| floor-kit | floor-kit×1 (판자 바닥 부재) | plank×2 | workbench | - | 3000 |
| roof-kit | roof-kit×1 (판자 지붕 부재) | plank×3 | workbench | - | 3000 |
| flint-knife | flint-knife×1 (부싯돌 칼) | flint×1, cord×1 | 맨손 | - | 4000 |
| stone-maul | stone-maul×1 (돌 메) | fieldstone×2, wood×1, cord×1 | workbench | - | 6000 |
| thatch-bundle | thatch-bundle×1 (이엉 다발) | reed×4 | workbench | - | 4000 |
| rawhide-lashing | cord×2 (꼰 끈) | hide×1 | workbench | cutting | 4000 |
| timber-beam | timber-beam×1 (각재) | plank×2, cord×1 | joiner-bench | cutting | 8000 |
| timber-wall-kit | timber-wall-kit×1 (목재 벽 부재) | timber-beam×2, plank×2 | joiner-bench | - | 10000 |
| stone-block | stone-block×1 (다듬은 돌) | fieldstone×3 | mason-bench | masonry | 8000 |
| stone-floor-kit | stone-floor-kit×1 (석재 바닥 부재) | stone-block×2 | mason-bench | - | 10000 |
| stone-wall-kit | stone-wall-kit×1 (석재 벽 부재) | stone-block×3, timber-beam×1 | mason-bench | - | 12000 |
| stone-roof-kit | stone-roof-kit×1 (석재 지붕 부재) | stone-block×2, timber-beam×2 | mason-bench | - | 12000 |
| mud-brick | mud-brick×2 (구운 흙벽돌) | marsh-clay×2, birch-bark×1 | mud-kiln | - | 10000 |
| brick-floor-kit | brick-floor-kit×1 (벽돌 바닥 부재) | mud-brick×3 | mason-bench | - | 10000 |
| brick-wall-kit | brick-wall-kit×1 (벽돌 벽 부재) | mud-brick×4, timber-beam×1 | mason-bench | - | 12000 |
| brick-roof-kit | brick-roof-kit×1 (벽돌 이엉 지붕 부재) | mud-brick×2, thatch-bundle×2 | mason-bench | - | 12000 |
| roasted-hazelnuts | roasted-hazelnuts×1 (볶은 개암) | hazelnut×4 | campfire | - | 4000 |
| woodland-skewer | woodland-skewer×1 (숲 꼬치) | chanterelle×2, meat×1 | campfire | - | 5000 |
| clam-bake | clam-bake×1 (조개 구이) | clam×3, samphire×1 | campfire | - | 5000 |
| cattail-flatbread | cattail-flatbread×1 (부들 납작빵) | cattail-root×3 | campfire | - | 5000 |

도구 태그 `cutting`은 부싯돌 칼, `masonry`는 돌 메가 가진다. 재료 태그 `material-timber|stone|brick`은 재료별 외형(계획 HI-11)을 붙이기 위한 표지다. 지금은 데이터로만 있고, 외형을 바꾸는 메커니즘은 아직 없다.

## 5. 정착지 건축 정의 (신규 산정: 크기·비용)

| id | 한국어 | English | 크기(X×Z) | 설비 | 비용 | 역할 |
|---|---|---|---|---|---|---|
| campfire | 모닥불 | Campfire | 2×2 | 예 | wood×4 | station: cooking |
| workbench | 작업대 | Workbench | 2×2 | 예 | wood×4 | station tier 1 |
| storage | 보관 상자 | Storage Crate | 2×2 | 아니오 | wood×4 | storage |
| floor | 판자 바닥 | Plank Floor | 2×2 | 아니오 | wood×4 | timber floor |
| joiner-bench | 목공대 | Joiner's Bench | 3×2 | 예 | plank×4, cord×2, flint×2 | station tier 2 |
| mason-bench | 석공대 | Mason's Bench | 3×2 | 예 | timber-beam×2, fieldstone×6 | station tier 3 |
| mud-kiln | 흙가마 | Mud Kiln | 2×2 | 예 | marsh-clay×6, stone-block×2 | station tier 3 annex |
| timber-wall | 목재 벽 | Timber Wall | 2×1 | 아니오 | timber-wall-kit×1 | timber wall |
| timber-roof | 목재 지붕 | Timber Roof | 2×2 | 아니오 | roof-kit×1 | timber roof |
| stone-floor | 석재 바닥 | Stone Floor | 2×2 | 아니오 | stone-floor-kit×1 | stone floor |
| stone-wall | 석재 벽 | Stone Wall | 2×1 | 아니오 | stone-wall-kit×1 | stone wall |
| stone-roof | 석재 지붕 | Stone Roof | 2×2 | 아니오 | stone-roof-kit×1 | stone roof |
| brick-floor | 벽돌 바닥 | Brick Floor | 2×2 | 아니오 | brick-floor-kit×1 | brick floor |
| brick-wall | 벽돌 벽 | Brick Wall | 2×1 | 아니오 | brick-wall-kit×1 | brick wall |
| brick-roof | 벽돌 이엉 지붕 | Brick-and-Thatch Roof | 2×2 | 아니오 | brick-roof-kit×1 | brick roof |

## 6. 야생 로스터 (아키타입 6 × 2종 = 12종, 신규 산정)

현재 스키마의 행동은 `grazer`(감지→도주)와 `hunter`(경고→추격→전조→타격→귀환) 두 가지뿐이다. 계획 §6의 passive / retaliate / aggressive 3단계는 core 스키마가 확장된 뒤에 매핑한다. 지금은 다음과 같이 둔다. 초식 무리형과 청소부형은 grazer, 나머지 공격형 4개 아키타입은 hunter다. 체력·피해·드롭은 `WildlifePolicy.luau`에 있다.

| id | 한국어 | English | 아키타입 | 생물군계 | 행동 | 감지/도주 또는 경고/공격/리쉬(studs) | 전조/쿨다운(ms) | 체력(milli) | 피해(milli) | 드롭 |
|---|---|---|---|---|---|---|---|---|---|---|
| grazer | 풀밭느림보 | Meadow Plodder | dev stand-in (grazer rig) | landing | grazer | 12/24 | - | 40000 | 0 | meat×2 |
| hunter | 덤불살금이 | Brush Stalker | dev stand-in (hunter rig) | landing | hunter | 12/4/40 | 1000/2000 | 60000 | 10000 | meat×3 |
| leaper-fernhop | 고사리뜀이 | Fernhopper | leaper | forest | hunter | 14/5/36 | 900/1800 | 45000 | 7000 | meat×2, hide×1 |
| leaper-reedvault | 갈대도약이 | Reed Vaulter | leaper | marsh | hunter | 12/5/32 | 900/1800 | 42000 | 7000 | meat×2, hide×1 |
| charger-oakbrow | 참나무이마박치기 | Oakbrow Rammer | charger | forest | hunter | 16/6/44 | 1300/2600 | 90000 | 12000 | meat×4, hide×2 |
| charger-mudbrow | 진흙이마박치기 | Mudbrow Rammer | charger | marsh | hunter | 14/6/40 | 1300/2600 | 85000 | 12000 | meat×4, hide×2 |
| tailswing-mossback | 이끼등꼬리채 | Mossback Swinger | tailswing | forest | hunter | 8/5/24 | 1100/2400 | 110000 | 9000 | meat×3, hide×2 |
| tailswing-shellclub | 조가비곤봉꼬리 | Shellclub Swinger | tailswing | marsh | hunter | 8/5/22 | 1100/2400 | 100000 | 9000 | meat×3, shell-fragment×2 |
| roarer-thicket | 덤불울림이 | Thicket Bellower | roarer | forest | hunter | 20/4/48 | 1500/3000 | 75000 | 14000 | meat×3, hide×1 |
| roarer-tidecall | 물때울림이 | Tidecall Bellower | roarer | marsh | hunter | 18/4/44 | 1500/3000 | 70000 | 14000 | meat×3, hide×1 |
| scavenger-barkpicker | 껍질뒤짐이 | Barkpicker | scavenger | forest | grazer | 10/20 | - | 30000 | 0 | meat×1, birch-bark×1 |
| scavenger-flotsam | 표류물킁킁이 | Flotsam Sniffer | scavenger | marsh | grazer | 10/22 | - | 30000 | 0 | meat×1, shell-fragment×1 |
| herd-acorncrest | 도토리볏풀뜯이 | Acorncrest Grazer | herd-grazer | forest | grazer | 14/28 | - | 55000 | 0 | meat×2, hide×1 |
| herd-sedgewader | 사초건너미 | Sedge Wader | herd-grazer | marsh | grazer | 12/26 | - | 50000 | 0 | meat×2, hide×1 |

`grazer`·`hunter` 두 개는 기존 개발용 대역 id다. 장르 QA 시나리오와 DinosaurRig가 이 id를 참조하므로 그대로 두고, 이름만 오리지널로 붙였다. 종 이름은 모두 새로 지었다.

## 7. 생존 수치 (기존 값 유지)

`vitals`: 허기 1단위 감소 주기 18000ms, 행동당 피로 500, 휴식 회복 2000/s, 기아 피해 주기 5000ms. 한도는 슬롯 20, 소프트 무게 60000, 하드 무게 90000, 품질 1~5000, 캠프원 4명이다. 기존 값을 바꾸지 않았다.

음식 사다리(신규 산정, 허기 회복량): 날것 채집물 2000~5000 → 모닥불 단품 12000~20000 → 조합 요리 22000~25000(체력 +4000~5000).

## 8. 텍스트 (§9.1~9.4, §10, 신규 집필)

`locale/strings.csv`에 en-us·ko-kr 쌍으로 들어 있다.

- 세계관: `lore_premise`, `lore_role`, `lore_rift`(조수 균열 / Tidal Rift), `org_searoute_company`(항로단 / Searoute Company).
- 세력 3개와 각 세력의 동기: `faction_survey_guild`(항로 측량회), `faction_craft_union`(장인 길드 연합), `faction_ecology_trust`(섬 생태 보존단).
- NPC 7명: 현장 연락원 3명(마리트 오셀, 브람 테오도르, 이네스 캘러웨이)과 교역항 상주 4명(조선공 홉 영감, 감정사 셀라 베인, 게시판지기 턱 매로, 우체부 핍 랜트리). 인사 대사 5줄.
- 첫날 고정 의뢰 3개(`contract_day1_*`): 통나무 6개 채집, 부싯돌 손도끼 제작, 정착지 구획과 작업대 배치.
- 튜토리얼 5단계와 완료 문구(`tutorial_*`): 도착(건너뛰기 가능) → 채집 → 손도끼 제작 → 정착지 선언 → 첫 의뢰.
- 로딩 팁 6개(`tip_01`~`tip_06`). P0 목표는 30개이고 나머지는 후속 작업이다.

## 9. 월드 배치, 카탈로그 동기화, 남은 한계

### 9.1 섬 지형

`src/server/SurvivalWorldBootstrap.luau`가 서버 시작 때 `Workspace.Terrain`에 섬을 만든다. 높이와 재질은 `src/shared/IslandTerrain.luau`의 고정 수식에서 나온다(난수 없음). 섬은 약 260×200 스터드 타원이고, 가장자리에서 모래 해안선을 거쳐 수심 -12의 바다(해수면 -4)로 내려간다.

| 구역 | 범위 | 지면 | 재질 |
|---|---|---|---|
| 상륙지(landing) | -44 < x < 44 | 평탄(-0.6), 기존 `IslandFloor` 64×48 판과 정착 격자 유지 | Grass |
| 온대 숲(forest) | x < -44 | 완만한 언덕(약 0~5) | LeafyGrass / Ground |
| 해안 습지(marsh) | x > 44 | 낮은 갯벌(약 -2.4~-3), 민물 웅덩이 2곳 | Mud / Grass, 웅덩이는 Water |

상륙지의 기존 이름(`DevelopmentIsland` 폴더, `SurvivalSpawn`, `campfire`, `workbench`, `WarehouseApproach`, `GatherLOSWall`, `CameraTestRoof`, 기존 5개 노드)과 위치는 그대로다. QA 표지 `wildlife-approach-01`(-19, 0.1, 19; grazer-01 집에서 5스터드)과 `WildlifeApproach`(같은 위치), `BuildApproach`(-6, 0.1, -10; 바닥 미리보기 입구 칸)를 새로 두었다. 셋 다 충돌·쿼리가 없는 반투명 판이다. 상륙지에서 양쪽 생물군계로 가는 디딤돌 길과 표지판 2개(`Temperate Forest`, `Coastal Marsh`)가 있다. 숲 나무 26그루와 습지 갈대 18포기는 고정 시드(20261018) `Rng`로 흩뿌리며, 노드·생물 집·길과는 9스터드 이상 떨어진다. 장식 파트는 모두 `IslandScenery` 폴더에 있고 CanCollide·CanQuery가 꺼져 있다(나무 줄기만 충돌). 모든 지오메트리는 런타임에 만들어지므로 빌드된 place의 정적 인스턴스 수(QA-PERF-01)는 바뀌지 않는다.

### 9.2 노드 배치 (20종 전부, `SurvivalWorldConfig.luau`)

생물군계 노드의 y는 `IslandTerrain.nodeY`로 정한다(지면을 반 스터드 단위로 내림 + 파트 높이의 절반). 채집 파트는 도달 거리 8 안에 프롬프트가 오도록 낮게 만들고, 키 큰 실루엣(자작나무 줄기, 부들 이삭 등)은 장식으로 따로 둔다.

| id | 위치 (x, y, z) | 생물군계 | 횟수 |
|---|---|---|---|
| fallen-tree-01 | -20, 2, 14 | landing | 3 |
| flint-outcrop-01 | -10, 2, 14 | landing | 3 |
| fiber-bush-01 | 0, 2, 14 | landing | 3 |
| berry-bush-01 | 10, 2, 14 | landing | 3 |
| meat-cache-01 | 20, 2, 14 | landing | 3 |
| forest-oak-windfall-01 | -70, 1.25, 14 | forest | 3 |
| forest-birch-stand-01 | -80, 2, -12 | forest | 3 |
| forest-hazel-thicket-01 | -68, 4.5, -30 | forest | 3 |
| forest-bramble-patch-01 | -84, 3.75, 28 | forest | 3 |
| forest-bracken-bed-01 | -62, 0.25, 0 | forest | 3 |
| forest-chanterelle-log-01 | -92, 3, 6 | forest | 2 |
| forest-flint-scree-01 | -96, 1, -28 | forest | 3 |
| forest-boulder-field-01 | -80, 4.5, 44 | forest | 2 |
| marsh-reed-bed-01 | 64, -1.5, 14 | marsh | 3 |
| marsh-cattail-stand-01 | 86, -1.5, 8 | marsh | 3 |
| marsh-cordgrass-tussock-01 | 70, -1.75, -18 | marsh | 3 |
| marsh-samphire-flat-01 | 92, -3, -16 | marsh | 3 |
| marsh-clay-bank-01 | 78, -1.25, 28 | marsh | 2 |
| marsh-clam-bed-01 | 98, -2.5, 10 | marsh | 2 |
| marsh-driftwood-line-01 | 86, -2.25, -36 | marsh | 3 |

### 9.3 생물 스폰 (17종 전부, `WildlifePolicy.luau`, maximum 24)

스폰 y는 그 지점 지면보다 3~5스터드 위다(리그가 떨어져 착지). 공격형(leaper·charger·roarer·tail-sweeper 행동과 `bluff-bounder`)은 상륙 지점에서 60스터드 이상 떨어진 생물군계 안쪽에 둔다. 단, `hunter-01`은 장르 QA 시나리오가 (22, 4, 24)를 집으로 참조하므로 상륙지에 남겼다.

| id | 위치 (x, y, z) | 생물군계 |
|---|---|---|
| grazer-01 | -20, 4, 24 | landing |
| hunter-01 | 22, 4, 24 | landing |
| ridge-strider-01 | -66, 7, 34 | forest |
| herd-acorncrest-01 | -74, 8, -46 | forest |
| scavenger-barkpicker-01 | -76, 4, -4 | forest |
| leaper-fernhop-01 | -100, 6, -14 | forest |
| charger-oakbrow-01 | -102, 7, 18 | forest |
| tailswing-mossback-01 | -90, 6, -44 | forest |
| roarer-thicket-01 | -94, 6, 40 | forest |
| bluff-bounder-01 | -108, 7, -4 | forest |
| fen-trotter-01 | 68, 2, -4 | marsh |
| herd-sedgewader-01 | 72, 2, 40 | marsh |
| scavenger-flotsam-01 | 76, 2, -30 | marsh |
| leaper-reedvault-01 | 100, 2, -24 | marsh |
| charger-mudbrow-01 | 104, 2, 4 | marsh |
| tailswing-shellclub-01 | 90, 2, -42 | marsh |
| roarer-tidecall-01 | 98, 1, 30 | marsh |

`world.spec.luau`가 이 배치를 검사한다. 20종 노드 전부 배치, 17종 전부 스폰, 모든 지점이 해수면 위 육지이고 올바른 생물군계 안, 공격형은 상륙 지점에서 60스터드 이상, 스폰 수가 maximum(≤32) 이하인지 본다.

노드·생물 목록이 바뀌었으므로 영속 키를 `nodes-v2`, `wildlife-v2`로 올렸다. 기존 v1 저장본은 5개 노드만 담고 있어 새 노드의 재생 타이머를 찾지 못하기 때문이다. 대신 스테이징의 이전 노드 잔량·생물 상태는 처음부터 다시 시작한다. `worldRevision`(`development-island-v1`)은 장르 QA 시나리오가 참조하므로 바꾸지 않았다.

### 9.4 런타임 카탈로그 동기화

`econ.yml`의 `survival-coop.inventory.content`에 있는 items(46), recipes(31), nodes(20), structures(15), wildlife(17), tags(8)를 `content.yml`과 같게 맞추고 `forge codegen robango-island`로 `GenreConfig.luau`를 다시 만들었다. 이제 세션 인벤토리와 개인 제작 검증도 신규 아이템·레시피(flint-knife, stone-maul, timber-beam, mud-brick, 각종 벽·바닥·지붕 부재, roasted-hazelnuts, woodland-skewer, clam-bake, cattail-flatbread, rawhide-lashing, thatch-bundle 등)를 인식한다. limits·rules·vitals는 원래 같았다. 내구 정책(`GenreDurable.luau`)은 바뀌지 않았다.

### 9.4b 중반 일일 의뢰 (신규 산정)

첫날 의뢰 3종과 초반 일일 의뢰 6종은 목재·섬유·딸기 단계에서 끝난다. 숲·습지 소재와 2단계 시설(소목 작업대·진흙 가마·석공 작업대)로 넘어간 뒤에도 일일 보드에 할 일이 남도록 일일 풀에 6종을 더했다(풀 15종, 하루 3종 추첨).

| id | 세력 | 납품 | 보상 | 신뢰 |
|---|---|---|---|---|
| daily-survey-reeds | 항로 측량회 | branch×12 | plank×3 | 20 |
| daily-survey-beams | 항로 측량회 | plank×6 | cord×4, flint×2 | 40 |
| daily-guild-bricks | 장인 길드 연합 | flint-knife×1 | timber-beam×1 | 35 |
| daily-guild-stone | 장인 길드 연합 | stone-pick×1 | thatch-bundle×2 | 35 |
| daily-eco-hazelnuts | 섬 생태 신탁 | water×6 | berry-meal×2 | 20 |
| daily-eco-clambake | 섬 생태 신탁 | capture-bola×1 | roasted-hazelnuts×2, hide×1 | 30 |

(p33: 납품 열은 content.yml 실제 값으로 고쳤다. 의뢰 id는 저장 키라 그대로 두며, id 이름과 납품물이 다른 것은 bricks/stone/hazelnuts/clambake/reeds다.)

어느 보상도 추가 재료 없이 같은 의뢰의 납품물로 되돌아가지 않으므로, 의뢰만 반복해 소재를 불리는 순환은 없다. 보상은 다음 단계 제작에 쓰는 중간재 위주다.

### 9.4c 조개돈 획득률 (의뢰 `coins`, 신규 산정)

조개돈(`Coins`)의 유일한 획득원은 의뢰 납품이다. `content.yml` 의뢰 항목의 선택 필드 `coins: N`을 ContractsExtension이 납품 아이템 교환과 **같은 개인 저장 한 번**에 지갑에 더한다(마커 영수증으로 재시도·서버 중단 뒤에도 한 번만 지급). 시장(장터)이 정산하는 지갑과 같다. 시작 잔액은 0, Robux 환전은 없다.

| 구분 | 의뢰(조개돈) |
|---|---|
| 첫날 (합 40) | survey-driftwood 10, guild-stone-axe 20, eco-fiber-sample 10 |
| 초반 일일 | daily-survey-flint 15, daily-eco-berries 15, daily-survey-planks 20, daily-guild-cord 20, daily-eco-meal 25, daily-guild-spear 30 |
| 중반 일일 | daily-survey-reeds 15, daily-eco-hazelnuts 15, daily-eco-clambake 30, daily-survey-beams 35, daily-guild-bricks 35, daily-guild-stone 40 |

- 난이도 기준: 원재료 납품 15, 1차 가공품 20~25, 도구·요리 30, 2단계 시설 가공품 35~40.
- 하루 보드 3종 기준 일일 획득은 약 45~105(평균 약 75), 첫날은 40.
- 시장 비용: 등록 수수료 5%(최소 1, 소멸). 원재료 10개 묶음을 개당 5~10에 사면 50~100 조개돈으로, 의뢰 2~5건이다.
- 현재 획득원은 의뢰뿐이다. 수치는 임시 산정이며 실측 후 조정한다.

### 9.5 남은 한계

- 생물군계, 노출, 선공 3단계, 무리, 스폰 테이블 필드는 아직 `Content.luau`에 없다. 소속은 노드 id 접두사와 이 문서의 배치표로만 표시한다.
- `DinosaurRig`는 `grazer|hunter` 두 실루엣만 만든다. 17종이 모두 스폰되지만, 종마다 다른 외형은 genre PR이 필요하다.
- 정착 격자는 상륙지 64×48 판 위에만 있다. 숲·습지에는 아직 건축할 수 없다.
- 지형과 장식의 시각 품질, 경로 탐색, 스튜디오 동선은 아직 Studio에서 확인하지 않았다.
