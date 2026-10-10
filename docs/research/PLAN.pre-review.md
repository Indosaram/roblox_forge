# 로블록스 Top 10 분석 기반 바이럴 게임 구현 계획

## 1. 요약
- 최근 1년 로블록스 흥행은 2025년에 새로 나온 "단순 루프 + 수집 + 사회적 상호작용" 게임이 주도했습니다. 2025년 생성작인 Steal a Brainrot(누적 방문 73.69B, 최고 CCU 25.4M), Grow a Garden(35.94B, 22.3M), 99 Nights in the Forest(29.76B, 14.2M)가 수년 된 대형작(Blox Fruits, Adopt Me!, MM2)의 누적 방문을 1년 만에 따라잡거나 넘었습니다. 수치는 Roblox 공식 API 실측과 위키백과 원문 기준입니다.
- 2026-09-28 현재 CCU 1위는 2026-07-25에 생성된 Steal An Egg(약 1.46M)입니다. "훔치기 + 수집" 계열의 추천 노출이 아직 이어지고 있다는 신호입니다.
- 후보 5개를 바이럴 25점, 수익성 25점 게이트로 검토해 2개를 채택했습니다. 1순위는 Steal a Kaiju Egg(23/23), 2순위는 피벗용 Grow & Defend Garden(21/22)입니다.
- 제작 스택은 Rokit, Rojo, Wally, luau-lsp, StyLua, Selene, Lune, ProfileStore, Blink, Open Cloud, Studio 내장 MCP입니다. 12주 계획으로 W4 소프트런치와 W5-W6 바이럴 푸시를 거치고, W9-W12에 확장 또는 피벗을 판정합니다.

## 2. 최근 1년 인기 Top 10
선정 기준: 2025-09~2026-09 기간에 누적 방문수 또는 현재 동시접속(CCU)이 최상위권인 게임입니다. 수치는 Roblox 공식 API에서 실측(MEASURED)했습니다. 출처는 https://games.roblox.com/v1/games?universeIds=... , https://apis.roblox.com/explore-api/v1/get-sorts , https://apis.roblox.com/game-passes/v1/universes/{id}/game-passes 입니다. 원본 JSON은 roblox-api-measured.json에 있습니다.

| # | 게임 | 개발 그룹 | 장르(API) | 생성일 | 누적 방문(API) | 현재 CCU(API, 2026-09-28T06:26Z) | 역대 최고 CCU(검색 레인) | 유료 게임패스 수 / 가격 중앙값(API) | 게임 URL |
|---|---|---|---|---|---|---|---|---|---|
| 1 | [🥚] Steal a Brainrot | BRAZILIAN SPYDER | Simulation | 2025-05-16 | 73.69B | 73,464 | 25.4M (2025-10) [W1] | 3개 / 중앙값 375 R$ | https://www.roblox.com/games/109983668079237 |
| 2 | [🐿️] Grow a Garden 🌶️ | The Garden Game | Simulation | 2025-03-25 | 35.94B | 21,144 | 22.3M (2025-08-23) [W2] | 0개 / 중앙값 - R$ | https://www.roblox.com/games/126884695634066 |
| 3 | 99 Nights in the Forest 🔦 | Grandma's Favourite Games | Survival | 2025-03-04 | 29.76B | 101,727 | 14.2M [W3] | 1개 / 중앙값 199 R$ | https://www.roblox.com/games/79546208627805 |
| 4 | Blox Fruits | Gamer Robot Inc | RPG | 2019-01-16 | 64.71B | 158,755 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 6개 / 중앙값 450 R$ | https://www.roblox.com/games/2753915549 |
| 5 | [🏚️] Adopt Me! | Uplift Games | Roleplay & Avatar Sim | 2017-07-14 | 44.87B | 90,167 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 5개 / 중앙값 480 R$ | https://www.roblox.com/games/920587237 |
| 6 | Murder Mystery 2 | Nikilis | Survival | 2014-01-18 | 30.88B | 109,586 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 1개 / 중앙값 3399 R$ | https://www.roblox.com/games/142823291 |
| 7 | RIVALS | Nosniy Games | Shooter | 2024-05-26 | 18.41B | 105,782 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 8개 / 중앙값 849 R$ | https://www.roblox.com/games/17625359962 |
| 8 | Steal An Egg | and Collect Rare Pets | Simulation | 2026-07-25 | 5.78B | 1,459,301 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 2개 / 중앙값 467 R$ | https://www.roblox.com/games/107778070777162 |
| 9 | Dress To Impress ⭐ | Dress To Impress Group | Roleplay & Avatar Sim | 2023-10-18 | 11.07B | 34,101 | 651K (2024) [W4] | 14개 / 중앙값 299 R$ | https://www.roblox.com/games/15101393044 |
| 10 | Dead Rails | RCM Games | Adventure | 2025-01-01 | 6.58B | 12,000 | NOT FOUND(공개 API 미제공, 1차 출처 미확보) | 4개 / 중앙값 148 R$ | https://www.roblox.com/games/116495829188952 |

## 3. Top 10에서 뽑은 바이럴·수익화 패턴
| 패턴 | 관찰 근거 (MEASURED) | 설계 반영 |
|---|---|---|
| 신작이 단기간에 최상위 진입 | Top 10 중 4개(Steal a Brainrot, Grow a Garden, 99 Nights, Dead Rails)가 2025년 생성, Steal An Egg는 2026-07 생성 후 두 달 만에 CCU 1위(games API) | 4주 안에 출시할 수 있는 범위로 설계 |
| 장르는 Simulation(수집·경제) 강세 | Top 10 중 3개가 API 장르 Simulation이고, Explore "Top Playing Now" 상위 12개 중 6개가 Simulation 계열 | 수집·생산·거래 루프 채택 |
| 업데이트 이벤트가 CCU 기록 견인 | Grow a Garden은 Blood Moon(5월 18일) 약 5M → Bizzy Bees(5월 31일) 11.7M → Summer Update(6월 21일) 21.3M → 8월 23일 22.3M. Steal a Brainrot은 9월 13일 Extinct Event로 24M [W1][W2] | 주간 [UPD] 업데이트와 서버 이벤트 필수 |
| 게임 간 크로스 이벤트 | 2025-08-23 두 개발자의 "admin war" 이벤트로 두 게임 모두 기록 경신, 플랫폼 CCU 47.4M [W1] | 크리에이터·타 게임 콜라보 이벤트를 W5-W6에 배치 |
| 게임패스는 소수의 중가 상품 | Top 10 유료 게임패스 가격 중앙값이 148~849 R$ 구간(MM2 단일 3,399 R$ 제외). Grow a Garden은 유료 게임패스 0개로 개발자 상품 위주(game-passes API) | 게임패스 3종 + 반복 구매 개발자 상품 중심 |
| 제목 태그 관례 | 상위 게임 다수가 이모지·[UPD]·[🥚] 태그 사용(explore-api 제목) | 업데이트마다 제목 태그 갱신 |
| 소규모 팀의 성공 | Grow a Garden은 Splitting Point Studios가 지분을 인수한 2025년 4월에 CCU가 약 1,000이었음 [W2] | 초기에는 소규모 팀으로 시작하고, 지표가 나오면 투자 확대 |


### 3.1 Roblox 추천 알고리즘이 보는 신호 (공식 문서 [R6])
- "Recommended for You"는 Retrieval, Ranking 2단계로 동작하고, engagement(참여), retention(재방문), monetization(수익화)을 핵심 신호로 봅니다 [R6].
- 광고, 큐레이션, 친구, 검색, SNS로 처음 유입된 유저의 지표는 Ranking 단계에 반영되지 않습니다. 추천으로 들어온 유저의 참여와 리텐션만 순위를 결정합니다 [R6].
- 시스템의 목표는 "장기 리텐션이 강한 게임"을 밀어 주는 것입니다 [R6].
- 계획 반영: 숏폼·크리에이터 유입은 초기 표본을 확보하는 수단일 뿐 순위를 직접 올리지 못합니다. 그래서 W4 KPI를 추천 유입 유저의 D1 리텐션과 플레이 시간으로 정의합니다.

## 4. 게임 아이디어 후보 (최대 5개)와 검토 게이트

### 4.1 게이트 규칙
- 바이럴 점수(25점): 30초 안에 이해되는 루프(5), 클립으로 찍을 만한 순간(도둑질, 희귀 뽑기, 반전)(5), 친구를 끌어들이는 사회적 압력(훔치기, 거래, 협동)(5), 현재 트렌드 적합성(Top 10과 Explore 정렬 실측)(5), 1인·소규모 팀이 4주 안에 첫 출시가 가능한가(5).
- 수익성 점수(25점): 게임패스 적합성(5), 반복 구매형 개발자 상품(부스트, 뽑기, 보호막)(5), 고액 결제 상한(5), 구독·광고 보조 수익(5), 라이브옵스 업데이트 주기로 매출 재점화 가능성(5).
- 채택 조건: 바이럴 20점 이상이고 수익성 20점 이상. 한쪽이라도 미달이면 탈락.
- 점수 성격: ASSUMED. 리드 에이전트가 §2 API 실측값과 §3 패턴을 근거로 매긴 정성 점수이며, 플랫폼 실측값이 아닙니다. 출시 전 §7 W4 소프트런치 KPI로 반드시 재검증합니다.

### 4.2 후보와 판정

| # | 가칭 | 한 줄 루프 | 근거 레퍼런스(§2) | 바이럴 | 수익성 | 판정 |
|---|---|---|---|---|---|---|
| 1 | Steal a Kaiju Egg | 알을 부화해 괴수를 키우고, 남의 기지에서 알을 훔쳐 온다. 괴수가 클수록 기지 수입이 늘어난다 | Steal a Brainrot 73.69B, Steal An Egg 현재 CCU 1.46M | 23 | 23 | 채택(1순위) |
| 2 | Grow & Defend Garden | 낮에는 작물을 키우고, 밤에는 몰려오는 괴물로부터 정원을 지킨다 | Grow a Garden 35.94B + 99 Nights 29.76B | 21 | 22 | 채택(2순위, 1순위 성과가 미달하면 피벗) |
| 3 | 99 Floors Below | 2~6인 협동 공포 서바이벌, 층마다 무작위 이상 현상 | 99 Nights, Dead Rails | 22 | 16 | 탈락: 판매할 게 소모품 위주라 고액 결제 상한이 낮음 |
| 4 | Runway Rumble | 테마 코디 대결에 관전자 투표 | Dress To Impress 11.07B | 17 | 21 | 탈락: DTI가 장르를 선점. 차별화 클립이 약함 |
| 5 | Arena Duel FPS | 1v1 경쟁 슈팅 | RIVALS 18.41B | 14 | 18 | 탈락: 네트코드·밸런스 비용이 커 4주 출시가 불가능하고 바이럴 신규성이 낮음 |

### 4.3 채택 사유 요약
- 1순위는 현재 Explore 최상위에 같은 계열(훔치기 + 수집)이 올라 있는 트렌드 적합성이 가장 높습니다. 훔치기 순간은 그 자체가 숏폼 클립이 되고, 수입이 쌓이는 기지 구조라 부스트·보호막·희귀 알 상품을 반복해서 팔 수 있습니다.
- 차별화 장치(필수): 괴수 합체(같은 등급 2마리를 합쳐 상위 등급으로)와 기지 공성전(10분마다 서버 전체 이벤트). 이 두 가지가 없으면 단순 클론이 되고 추천 알고리즘에서 밀립니다.
- 2순위는 1순위와 같은 코드베이스(수집·경제·데이터 저장)를 80% 재사용할 수 있어 피벗 비용이 낮습니다.

## 5. 채택 아이디어 게임 설계: Steal a Kaiju Egg

### 5.1 코어 루프 (30초 / 5분 / 1일)
- 30초: 알 구매 → 부화 → 괴수가 기지에서 초당 코인 생산.
- 5분: 코인으로 더 비싼 알 구매, 다른 플레이어 기지에서 알이나 괴수 훔치기, 내 기지는 잠금 버튼(쿨다운)으로 방어.
- 1일: 합체로 전설 괴수 만들기, 서버 공성전 이벤트, 오프라인 수입 수령, 일일 퀘스트.

### 5.2 바이럴 장치
- 희귀 부화 시 서버 전체 알림과 전용 연출(클립 포인트).
- 훔치기 성공과 실패를 3인칭 슬로모션 킬캠으로 재생(숏폼용 화면).
- 친구 초대 보상(Roblox Friend Invite 흐름)과 같은 서버 합류 보너스.
- 주 1회 신규 괴수 세트와 한정 이벤트. 제목의 [UPD]·이모지 태그는 Top 10 제목 관례(§2)를 따름.
- 크리에이터 코드와 유튜버용 비공개 서버 무료 제공.

### 5.3 수익화 설계 (가격은 §2 게임패스 가격 중앙값 실측 범위 150~850 R$에 맞춤)
| 상품 | 유형 | 가격(안) | 근거 |
|---|---|---|---|
| 2배 코인 | 게임패스 | 399 R$ | Top 10 게임패스 중앙값 대역 |
| VIP 기지 슬롯 +4 | 게임패스 | 699 R$ | 고액 대역 |
| 자동 잠금 | 게임패스 | 249 R$ | 방어 편의 |
| 희귀 알 / 전설 알 | 개발자 상품(반복) | 99 / 499 R$ | 반복 구매 축 |
| 잠금 쿨다운 즉시 해제 | 개발자 상품 | 29 R$ | 저가 충동 구매 |
| 서버 행운 부스트 15분 | 개발자 상품 | 199 R$ | 서버 전체 효과라 사회적 과시 |
| 월 구독 "Kaiju Pass" | 구독 | 월 USD 4.99 내외 | Subscriptions 기능 [R4] |
| 보상형 동영상 광고 | 광고 | 무료 부스트 제공 | Immersive Ads [R5] |

- 가챠 규정 준수: 무작위 유료 상품은 Roblox 정책상 확률 공개가 필요하므로 알 구매 UI에 확률을 표시합니다. 국가별 유료 무작위 아이템 제한 설정(PolicyService)도 반영합니다.

## 6. 메타 도구 스택

| 도구 | 용도 | 단계 | 출처 (GitHub API 실측 2026-09-28) |
|---|---|---|---|
| Rokit | Rojo·Wally·StyLua 등 CLI 버전 고정 설치(툴체인 매니저) | 빌드 | https://github.com/rojo-rbx/rokit (★462, 최근 push 2026-09-27) |
| Rojo | 파일 시스템 ↔ Studio 동기화, Git 기반 협업 | 빌드 | https://github.com/rojo-rbx/rojo (★1,756, 최근 push 2026-07-06) |
| Argon | Rojo 대안 동기화 도구(양방향 동기화) | 빌드 | https://github.com/argon-rbx/argon (★147, 최근 push 2026-07-01) |
| Wally | Luau 패키지 매니저 | 빌드 | https://github.com/UpliftGames/wally (★498, 최근 push 2026-09-26) |
| Pesde | Luau 패키지 매니저(Wally 대안, Lune 런타임 지원) | 빌드 | https://github.com/pesde-pkg/pesde (★128, 최근 push 2026-09-26) |
| luau-lsp | Luau 타입 검사·자동완성(VS Code 연동) | 빌드 | https://github.com/JohnnyMorganz/luau-lsp (★541, 최근 push 2026-09-27) |
| StyLua | 코드 포매터 | 빌드·CI | https://github.com/JohnnyMorganz/StyLua (★2,297, 최근 push 2026-09-13) |
| Selene | 린터 | 빌드·CI | https://github.com/Kampfkarren/selene (★824, 최근 push 2026-05-21) |
| Darklua | 코드 변환·번들(require 경로 변환, 최소화) | 빌드 | https://github.com/seaofvoices/darklua (★242, 최근 push 2026-07-13) |
| Lune | Studio 밖 Luau 실행: 빌드 스크립트, Open Cloud 호출, 테스트 러너 | CI·배포 | https://github.com/lune-org/lune (★955, 최근 push 2026-09-26) |
| jest-lua | 단위 테스트 프레임워크 | 테스트 | https://github.com/jsdotlua/jest-lua (★59, 최근 push 2024-12-23) |
| ProfileStore | 세션 잠금 DataStore 저장(복제·롤백 방지) | 런타임 | https://github.com/MadStudioRoblox/ProfileStore (★337, 최근 push 2025-07-31) |
| Blink | IDL 기반 버퍼 네트워킹 코드 생성(대역폭 절감) | 런타임 | https://github.com/1Axen/blink (★185, 최근 push 2026-09-23) |
| ByteNet | 버퍼 네트워킹 라이브러리(Blink 대안) | 런타임 | https://github.com/ffrostfall/ByteNet (★181, 최근 push 2025-08-01) |
| Fusion | 반응형 UI 라이브러리 | 런타임 UI | https://github.com/dphfox/Fusion (★797, 최근 push 2026-02-02) |
| react-lua | React 17 포팅 UI 라이브러리(Fusion 대안) | 런타임 UI | https://github.com/jsdotlua/react-lua (★570, 최근 push 2025-05-23) |
| Knit | 게임 프레임워크. 아카이브되어 신규 프로젝트에는 비추천 | 제외 | https://github.com/Sleitnick/Knit (★629, 최근 push 2024-07-31, 아카이브됨) |
| Studio MCP | 구형 외부 MCP 서버. 공식 README가 Studio 내장 MCP로 이전을 권고 | 제외(대체: 아래 내장 MCP) | https://github.com/Roblox/studio-rust-mcp-server (★492, 최근 push 2026-04-03, 아카이브됨) |
| Roblox Studio 내장 MCP 서버 | Claude·Cursor 등 외부 AI 에이전트가 Studio를 조작 | AI | https://create.roblox.com/docs/studio/mcp (HTTP 200 확인) |
| Roblox Open Cloud | Place 게시, DataStore, MessagingService 등 웹 API (CI/CD·라이브옵스) | 배포·라이브옵스 | https://create.roblox.com/docs/cloud/open-cloud (HTTP 200 확인) |
| Subscriptions | 월 구독 상품 | 수익화 | https://create.roblox.com/docs/production/monetization/subscriptions (HTTP 200 확인) |
| Immersive Ads / 광고 | 게임 내 광고 수익 | 수익화 | https://create.roblox.com/docs/production/monetization/immersive-ads (HTTP 200 확인) |

### 6.1 추천 조합 (소규모 팀 기준)
- 코드: Rokit(버전 고정) + Rojo + Wally + luau-lsp + StyLua + Selene + Lune(빌드·배포 스크립트), 그리고 GitHub에서 PR 단위 리뷰. Knit는 아카이브되어 쓰지 않습니다.
- 데이터: ProfileStore(세션 잠금으로 거래·훔치기 복제 버그 방지), 네트워킹은 ByteNet 또는 Blink.
- CI/CD: GitHub Actions에서 lint, 테스트, rbxl 빌드를 돌리고 Open Cloud Place Publishing API로 테스트 place에 자동 배포.
- AI 보조: Roblox Studio Assistant와 Cube 3D로 초벌 에셋 생성(기능 URL은 레인 B 확인 대상), Studio 내장 MCP 서버로 코딩 에이전트가 Studio를 직접 조작. 구형 studio-rust-mcp-server는 아카이브되어 쓰지 않습니다.
- 운영: Creator Analytics 커스텀 이벤트와 퍼널(부화, 첫 훔치기, 첫 구매), 경제 이벤트 로깅, Open Cloud MessagingService로 라이브 이벤트 방송.

## 7. 단계별 구현 계획 (주차·산출물·KPI)

| 주차 | 단계 | 산출물 | KPI / 통과 기준 |
|---|---|---|---|
| W0 | 셋업 | §11 Roblox Game Forge(범용 메타 도구) M1-M4 완료 상태에서 시작. Rojo 프로젝트, Wally 의존성, CI(lint·test·publish), 테스트 place 2개(dev·staging) | main 푸시 시 staging 자동 배포 성공 |
| W1 | 코어 루프 | 알 구매·부화·기지 생산, ProfileStore 저장, 서버 권위 경제 | 5명 내부 테스트에서 저장 손실 0건 |
| W2 | 사회 루프 | 훔치기·잠금·킬캠, 서버 알림, 합체 | 내부 테스트 평균 세션 15분 이상 |
| W3 | 수익화·분석 | 게임패스 3종, 개발자 상품 4종, 확률 표시, 분석 이벤트 12종, 튜토리얼 | 구매 퍼널 이벤트 100% 발화 확인 |
| W4 | 소프트 런치 | 공개 전환, 썸네일·아이콘 A/B 2종, 광고 크레딧 소액 집행 | D1 리텐션 25% 이상, 평균 플레이 12분 이상, 결제 전환율(payer %) 1% 이상 |
| W5-W6 | 바이럴 푸시 | 첫 [UPD] 신규 괴수 세트, 공성전 이벤트, 크리에이터 10명 비공개 서버 시딩, 숏폼 30편 | 최고 CCU 1,000 이상, 추천 유입 비중 50% 이상 |
| W7-W8 | 라이브옵스 | 주간 업데이트 파이프라인, 구독 출시, 경제 밸런스 조정 | D7 리텐션 8% 이상, ARPDAU 목표 달성 |
| W9-W12 | 확장 또는 피벗 판정 | 성과 미달 시 2순위(Grow & Defend Garden)로 코드 재사용 피벗 | 두 번 연속 업데이트 후 CCU 반등이 없으면 피벗 |

- KPI 수치 성격: ASSUMED. §3의 알고리즘 신호를 근거로 잡은 내부 목표값이며, Roblox가 공표한 임계값이 아닙니다.

## 8. 리스크와 대응
| 리스크 | 대응 |
|---|---|
| 클론 과포화로 추천 노출 부족 | 합체·공성전 차별화를 W2 필수 범위에 포함, 썸네일 A/B |
| 훔치기·거래 복제 버그로 경제 붕괴 | ProfileStore 세션 잠금, 서버 권위 트랜잭션, 거래 로그 |
| 익스플로잇(속도·텔레포트) | 서버 측 이동 검증, RemoteEvent 레이트 리밋 |
| 무작위 유료 상품 규정 | 확률 표시, PolicyService 지역 분기 |
| 트렌드 수명 단축 | 주간 업데이트 루틴, 2순위 피벗 준비 |

## 11. 범용 바이브코딩 메타 도구: "Roblox Game Forge"

### 11.1 설계 원칙: 게임 하나가 아니라 게임 공장
- 목표: 사람은 자연어로 지시하고 승인만 합니다. AI 에이전트가 **어떤 장르의 로블록스 게임이든** 기획, 코드, 3D, 사운드, 현지화, 경제 밸런스, QA, 배포, 운영까지 같은 도구로 처리합니다.
- Steal a Kaiju Egg는 이 도구의 **첫 번째 사용 사례**일 뿐입니다. 도구 안에는 특정 게임 이름, 괴수, 알 같은 개념이 하나도 들어가지 않습니다.
- 3층 분리
  1. **Core(모든 게임 공통)**: 데이터 저장, 경제 엔진, 수익화, 분석, 현지화, 라이브옵스, 에셋·배포 파이프라인, 에이전트 스킬.
  2. **Genre Module(장르별 재사용)**: 루프 규칙, 표준 이벤트, QA 시나리오 템플릿, 경제 템플릿. 여러 게임이 같은 모듈을 공유합니다.
  3. **Game Pack(게임별)**: `game.yml` 설정, 기획 문서, 밸런스 CSV, 에셋, 상품 목록. 새 게임은 이 층만 새로 만듭니다.
- 규칙: Game Pack 안에서 Core나 Genre Module 코드를 복사·수정하는 것은 금지합니다. 필요한 기능은 상위 층에 설정 옵션이나 확장 지점(hook)으로 추가하고, 기존 게임 전체의 회귀 테스트를 통과해야 합니다.

### 11.2 제작 레이어의 중심: Studio 내장 MCP (게임과 무관한 공통 기반)
Roblox Studio에는 MCP 서버가 내장돼 있습니다. 외부 AI 클라이언트가 열린 Studio 세션에 붙어 데이터 모델 탐색, 스크립트 작성, Luau 실행, 플레이 모드 테스트를 할 수 있습니다 [R1]. 공식 문서에 나열된 도구는 26개이고, 원문은 studio-mcp-tools.txt에 있습니다.

| 분류 | 내장 MCP 도구 | 메타 도구에서 쓰는 곳 |
|---|---|---|
| 코드 | script_read, multi_edit, script_search, script_grep | Rojo를 쓰지 않는 긴급 수정, Studio 쪽 스크립트 점검 |
| 3D·에셋 생성 | generate_mesh(텍스트로 텍스처 메시 생성), generate_material, generate_procedural_model, wait_job_finished | 괴수·알·기지 초벌 모델, 재질 |
| 에셋 검색·삽입 | search_asset, insert_asset, upload_image, store_image | Creator Store 에셋 재사용, 참조 이미지 |
| 실행·상태 | execute_luau(Edit/Client/Server), get_studio_state, search_game_tree, inspect_instance, get_console_output | 경제 시뮬레이션 실행, 오류 로그 수집 |
| 자동 QA | start_stop_play, character_navigation, user_keyboard_input, user_mouse_input, screen_capture, subagent(playtest) | 튜토리얼·훔치기·구매 흐름 자동 플레이테스트와 스크린샷 판정 |
| 지식 | http_get(Roblox 문서 한정), skill | 에이전트가 최신 API를 스스로 확인 |
| 멀티 인스턴스 | list_roblox_studios(모든 호출에 studio_id 지정) | Studio 여러 개를 띄우고 에이전트 여럿이 병렬 작업 |


### 11.3 레이어별 도구 (모두 게임 비종속, 2026-09-28 GitHub API 또는 공식 문서 HTTP 200으로 확인)

| 레이어 | Core가 제공하는 범용 기능 | 도구 | 출처 |
|---|---|---|---|
| 기획·트렌드 | `forge trends`: Roblox games/explore/game-passes API로 장르별 상위 게임, CCU, 가격 분포를 수집해 기획 근거를 리포트합니다. 이 문서의 §2가 그 출력 예입니다 | Roblox 공개 API | §2 [A1]-[A3] |
| 코드 | 모노레포 Luau 툴체인, 공통 타입, 린트·포맷 | Rojo, luau-lsp, Selene, StyLua, Wally(§6), roblox-ts(선택) | https://github.com/roblox-ts/roblox-ts (★1,307, push 2026-09-28) |
| 3D 모델링 | `forge gen mesh "<prompt>" --style <pack style>`: Studio generate_mesh → 부족하면 오픈 생성기 → Blender 정리(폴리곤 예산은 게임 팩 설정) → Assets API 업로드 | Studio MCP [R1], Roblox Cube, Blender MCP, Hunyuan3D-2, TRELLIS, Assets API [R7] | https://github.com/Roblox/cube (★1,256, push 2026-05-28) / https://github.com/ahujasid/mcp-for-blender (★29,510, push 2026-09-27) / https://github.com/Tencent-Hunyuan/Hunyuan3D-2 (★14,980, push 2025-10-28) / https://github.com/microsoft/TRELLIS (★13,714, push 2026-06-26) |
| 에셋 동기화 | 게임 팩마다 `assets/`를 자동 업로드하고 asset ID 상수를 생성 | Asphalt (Tarmac은 비추천) | https://github.com/jackTabsCode/asphalt (★161, push 2026-07-28) / https://github.com/rojo-rbx/tarmac (★34, push 2024-03-05) |
| 사운드 | `forge gen sfx|bgm "<prompt>"`: 생성 → 음량 정규화 → 업로드 | AudioCraft, Roblox 오디오 [R8], ElevenLabs(REST API. 공식 MCP는 아카이브) | https://github.com/facebookresearch/audiocraft (★23,651, push 2026-03-03) / https://github.com/elevenlabs/elevenlabs-mcp (★1,536, push 2026-08-20, 아카이브됨) |
| 현지화 | `forge locale sync`: 문자열 추출 → 에이전트 번역 → Localization API 반영. 모든 게임이 같은 흐름 사용 | Automatic Translation [R9], Localization API [R10] | 공식 문서 |
| 경제 시뮬레이션 | **장르 무관 경제 그래프 엔진**: 재화, Source(획득처), Sink(소비처), 전환(합성·뽑기·거래), 가격, 확률을 YAML 그래프로 선언하면 `forge econ sim`이 가상 플레이어 N명 × D일을 돌려 인플레이션, 첫 결제 체감 시점, 재화 병목을 리포트합니다. 출시 후에는 같은 Source/Sink 이름으로 Economy Events를 로깅해 실측과 비교합니다 | Lune, Studio MCP execute_luau, Economy Events [R11] | §6 Lune / 공식 문서 |
| 자동 QA | 장르 모듈이 제공하는 시나리오 템플릿(튜토리얼, 핵심 루프 1회, 첫 구매, 저장·재접속)을 게임 팩 설정으로 채워 실행 | Luau Execution API [R12], place-ci-cd-demo, run-in-roblox, MCP playtest subagent | https://github.com/Roblox/place-ci-cd-demo (★44) / https://github.com/rojo-rbx/run-in-roblox (★78, push 2024-03-06) |
| 배포 | 게임 팩의 `mantle.yml`로 place, 게임패스, 상품, 배지, 썸네일을 게임별로 선언. 모든 게임이 같은 CI 파이프라인 사용 | Mantle, Open Cloud universes·places [R13], rbxcloud | https://github.com/blake-mealey/mantle (★116, push 2026-05-28) / https://github.com/Sleitnick/rbxcloud (★140, push 2025-03-23) |
| 운영 | 여러 게임을 한 대시보드로 묶어 지표 비교, 라이브 이벤트 방송, 주간 업데이트 PR 자동 생성 | Creator Analytics [R14], MessagingService | 공식 문서 |

### 11.4 장르 모듈 (Top 10 실측 장르에서 도출)
| 장르 모듈 | 공통 루프 | 대표 레퍼런스(§2) | 모듈이 제공하는 것 |
|---|---|---|---|
| `collect-steal` | 구매 → 수집 → 기지 수입 → 남의 것 훔치기·방어 | Steal a Brainrot, Steal An Egg | 기지 소유권, 훔치기·잠금, 서버 알림, 합성 |
| `grow-harvest` | 심기 → 성장 대기(오프라인 진행) → 수확 → 판매·거래 | Grow a Garden, Plants & Brainrots | 타이머 성장, 오프라인 진행, 날씨·변이 이벤트, 거래 |
| `survival-coop` | 협동 생존 → 날·층 진행 → 자원 → 제작 | 99 Nights in the Forest, Dead Rails | 웨이브·밤 스케줄러, 파티 매칭, 제작 테이블 |
| `rpg-progression` | 전투 → 레벨·능력 → 지역 해금 | Blox Fruits, Slayers 2 | 스탯·스킬, 퀘스트, 보스 스폰 |
| `social-rp-fashion` | 꾸미기 → 역할놀이·대결 → 투표 | Adopt Me!, Dress To Impress | 아바타·의상 슬롯, 테마 라운드, 투표 |
| `pvp-arena` | 매칭 → 라운드 → 랭크 | RIVALS, Murder Mystery 2 | 라운드 상태 머신, 매치메이킹, 랭크 |
- 새 장르가 뜨면 Genre Module 하나만 추가합니다. `forge trends`가 Explore 정렬에서 기존 모듈에 없는 장르를 감지하면 신규 모듈 후보로 보고합니다.

### 11.5 저장소 구조 (모노레포)
```
roblox-game-forge/
  AGENTS.md                    # 에이전트 규칙, 층 분리 규칙, 승인 게이트
  cli/forge                    # Lune 기반 CLI: new, trends, gen, econ, locale, qa, deploy, report
  core/                        # 모든 게임 공통 Luau 패키지
    data/ economy/ monetization/ analytics/ localization/ liveops/ ui-kit/
  genres/
    collect-steal/ grow-harvest/ survival-coop/ rpg-progression/ social-rp-fashion/ pvp-arena/
      module/  econ-template.yml  qa-scenarios/  design-template.md
  games/
    steal-a-kaiju-egg/         # 첫 번째 게임 팩
      game.yml  design/  balance/econ.yml  assets/  locale/  mantle.yml
    grow-and-defend-garden/    # 두 번째 게임 팩 (피벗 후보, 장르 조합 검증용)
  skills/                      # 레이어별 에이전트 스킬 (3d, audio, locale, econ, qa, liveops)
  .github/workflows/           # 변경된 층 기준으로 영향받는 모든 게임을 테스트·배포
```
- `game.yml` 예시 필드: `genres: [collect-steal]`(여러 개 조합 가능), `currencies`, `monetization`(게임패스·상품·구독 목록), `art_style`, `poly_budget`, `locales`, `qa_scenarios`, `liveops_cadence`.
- 새 게임 만들기: `forge new <slug> --genre grow-harvest,survival-coop` → 장르 템플릿으로 기획서·경제 그래프·QA 시나리오 초안 생성 → 에이전트가 설정과 에셋만 채움.
- 승인 게이트(모든 게임 공통): 에이전트 자동 배포는 staging까지만 합니다. production 배포, 가격·확률 변경, Core·Genre 변경은 사람이 PR을 머지해야 반영됩니다. Core·Genre를 바꾸는 PR은 모든 게임 팩의 테스트를 통과해야 합니다.

### 11.6 구축 일정과 "범용성" 통과 기준
| 단계 | 산출물 | 통과 기준 |
|---|---|---|
| M1 | 모노레포, AGENTS.md, CLI 뼈대, Studio MCP 연결 | `forge new test-game`이 실행 가능한 place를 만들고, 에이전트가 play 모드 console 출력을 읽어 옴 |
| M2 | 3D·사운드·에셋 파이프라인(`forge gen`) | 프롬프트 한 줄로 에셋이 게임 팩에 들어가고 screen_capture로 확인됨 |
| M3 | 장르 무관 경제 그래프 엔진(`forge econ sim`) | 구조가 다른 경제 2종(collect-steal, grow-harvest)이 같은 엔진, 서로 다른 YAML만으로 시뮬레이션됨 |
| M4 | CI, Mantle 배포, 현지화, QA 시나리오 템플릿 | main 머지 시 영향받는 게임 전체가 테스트·배포되고 플레이테스트 스크린샷이 PR에 첨부됨 |
| M5 (범용성 검증) | 장르가 다른 두 번째 게임 팩(grow-and-defend-garden = grow-harvest + survival-coop) | **Core·Genre 코드 수정 0줄**, 게임 팩 파일만으로 플레이 가능한 프로토타입 완성. 수정이 필요했다면 그 기능을 설정이나 hook으로 올린 뒤 재검증 |
| M6 (장르 확장 검증) | 세 번째 장르 모듈 1개 추가(예: pvp-arena) | 기존 두 게임 팩의 회귀 테스트가 변경 없이 통과 |

- 일정·통과 기준의 성격: ASSUMED(설계안). 도구별 기능은 위 출처로 확인했지만, 이 조합을 끝까지 통합해 실행해 보지는 않았습니다.
- 게임 일정과의 관계: §7의 W0는 M1-M4 완료 후 시작합니다. M5는 게임 W4 소프트런치와 병행하고, 1순위 게임이 부진하면 M5의 두 번째 게임 팩이 곧바로 피벗 대상이 됩니다.

## 9. 방법론과 한계
- 검색 레인: 3개(A: Top 10 인기 데이터, B: 메타 도구, C: 바이럴·수익화). 3개 모두 `muse/mimo-v2.6-flash-free` 모델로 고정했습니다(task_id st_01a0e6b0 / st_01a0e6b1 / st_01a0e6b2, 스폰 시 model 오버라이드). 다른 모델로 수행한 웹 검색은 없습니다.
- 리드 직접 실측: 검색이 아니라 공식 API를 직접 호출했습니다(Roblox games / explore-api / game-passes / omni-search, GitHub repos API). 원본은 roblox-api-measured.json, explore-sorts.json, official-docs-check.json에 있습니다.
- 수치 성격: API 수치는 MEASURED(측정 시각 표기). 아이디어 점수와 KPI 목표는 ASSUMED(리드 판단). 검색 레인 수치는 출처 URL을 붙여 표기합니다.
- 레인 결과(mimo): A2(최고 CCU)는 3회 호출 중 2회가 환경 오류로 실패해 전 항목 NOT FOUND를 반환했습니다. 그래서 최고 CCU는 리드가 위키백과 원문을 직접 받아 채웠습니다. C2(바이럴·수익)는 호출이 실패한 상태에서 "DevEx 100,000 R$ = USD 350 (USD 0.0035/R$)"를 https://create.roblox.com/devex 출처로 제시했지만, 리드가 확인해 보니 그 URL은 HTTP 404였습니다. 따라서 이 수치는 미검증으로 본문에서 제외했습니다(교정 로그). C2가 제시한 디스커버리 문서는 https://create.roblox.com/docs/discovery 로 HTTP 200과 본문 내용을 확인해 §3.1에 반영했습니다. B2(도구)는 아직 실행 중이며, 도구 표는 리드가 GitHub API와 공식 문서로 직접 검증했습니다.
- 한계: Roblox 공개 API는 역대 최고 CCU와 기간별(최근 12개월) 방문수를 제공하지 않습니다. 따라서 "최근 1년 인기"는 누적 방문수, 현재 CCU, 2025년 이후 생성 여부, 검색 레인의 기록 CCU 보도를 함께 보고 선정했습니다. Brookhaven RP는 games API가 TITLE UNAVAILABLE을 반환해 표에서 제외했습니다. DevEx 공식 문서 URL은 404가 나 직접 확인하지 못했습니다.

## 10. 출처
- [A1] Roblox games API: https://games.roblox.com/v1/games?universeIds=7709344486,7436755782,7326934954,994732206,383310974,66654135,6035872082,10563114921,5203828273,7018190066 (2026-09-28 조회, roblox-api-measured.json)
- [A2] Roblox Explore API: https://apis.roblox.com/explore-api/v1/get-sorts (explore-sorts.json)
- [A3] Roblox Game Passes API: https://apis.roblox.com/game-passes/v1/universes/{universeId}/game-passes
- [A4] Roblox Omni Search API: https://apis.roblox.com/search-api/omni-search
- [W1] https://en.wikipedia.org/wiki/Steal_a_Brainrot
- [W2] https://en.wikipedia.org/wiki/Grow_a_Garden
- [W3] https://en.wikipedia.org/wiki/List_of_Roblox_games
- [W4] https://en.wikipedia.org/wiki/Dress_to_Impress
- [G] GitHub REST API: https://api.github.com/repos/{owner}/{repo} (tools-github.json)
- [R1] https://create.roblox.com/docs/studio/mcp
- [R2] https://github.com/Roblox/studio-rust-mcp-server (README: 내장 MCP로 이전 권고)
- [R3] https://create.roblox.com/docs/cloud/open-cloud
- [R4] https://create.roblox.com/docs/production/monetization/subscriptions
- [R5] https://create.roblox.com/docs/production/monetization/immersive-ads
- [R6] https://create.roblox.com/docs/discovery (HTTP 200, 2026-09-28 확인)
- [R7] https://create.roblox.com/docs/cloud/guides/usage-assets (Assets API 지원 형식)
- [R8] https://create.roblox.com/docs/audio
- [R9] https://create.roblox.com/docs/production/localization/automatic-translations
- [R10] https://create.roblox.com/docs/cloud/reference/features/localization
- [R11] https://create.roblox.com/docs/production/analytics/economy-events
- [R12] https://create.roblox.com/docs/cloud/reference/features/luau-execution
- [R13] https://create.roblox.com/docs/cloud/reference/features/universes
- [R14] https://create.roblox.com/docs/production/analytics
