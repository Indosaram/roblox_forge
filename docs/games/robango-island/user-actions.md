# 로방고 섬: 사용자 결정·행동 목록 (2026-10-16)

원본은 로컬 연구 세션 폴더(`.omo/ulw-research/…/preprod/user-actions.md`, gitignore)에 있으며, 이 사본이 저장소 기준본입니다.

에이전트가 할 수 있는 착수 전 작업은 모두 끝났습니다(근거: `ADR-preprod.md`). 아래 항목은 사용자 승인이나 계정, 비용, 외부 기관이 필요해서 에이전트가 대신할 수 없습니다.

## 지금 결정하면 M0를 바로 시작할 수 있는 것
| # | 항목 | 권고 | 필요한 시점 | 근거 |
|---|---|---|---|---|
| U1 | ~~작업명~~ **완료**: 「로방고 섬 / Robango Island」(2026-10-16) | slug `robango-island` | — | trademark-search.md §8 |
| U2 | Roblox Studio 실행 승인 | wildlife-spatial·full-coop-rejoin 같은 Studio QA를 돌릴 때만 필요합니다 | M1~M2 | AGENTS.md |

## 출시 전까지 필요한 것 (M7 리드타임)
| # | 항목 | 내용 | 비용 | 근거 |
|---|---|---|---|---|
| U3 | 상표 정식 검색·출원 | 변리사에게 USPTO·KIPRIS·EUIPO 9·41류 정식 검색을 맡기고, **원작 상표(등록·출원 2건, legal-review-packet.md §3)와 유사한지 판단을 받습니다.** 원하면 출원합니다 | 유료 | trademark-search.md §5 |
| U4 | 외부 법률 검토 | §3 차별화 표와 "섬 분류·아이템 안정성" 행을 첨부합니다 | 유료 | 계획 §15 |
| U5 | GRAC 등급분류 서면 질의 | 개인 제작 Roblox 체험이 GRAC 등급분류 대상인지 묻습니다(GRAC 1:1 문의 또는 문체부 게임콘텐츠산업과 044-203-3268). 미해결 H7 | 무료 | kr-policy.md H7 |
| U6 | 소유 계정 준비 | 신분증 인증, 2단계 인증, 그룹 소유로 할지 결정 | 무료 | kr-policy.md C29 |
| U7 | 저연령(Kids/Select) 노출 요건 | Roblox Plus/Premium 2개월 유지 또는 환불형 퍼블리시 요금, 그리고 16세 이상 평가 기간(engaged 250명). 일정을 줄이려면 신속 심사 50,000 Robux | 유료 | kr-policy.md C29 |
| U8 | DevEx 준비 | W-8BEN 세금 양식과 DevEx 포털(Tipalti). 실명을 일관되게 써야 합니다 | 무료 | kr-policy.md 추가 |
| U9 | KR 실측 | 완료(2026-10-20): 한국 로케일 계정(`ko-kr`)으로 안드로이드 실기기(`SM-N981N`)에서 스테이징에 접속해 `PolicyService` 통과 후 구독(`EXP-4461467833720767028`, `Route Guild Monthly 99/월`) 및 개발자 상품(`3720013569`, `Ridge Strider Gold Skin 199`) 네이티브 결제 프롬프트 표출을 확인했습니다(qa-evidence.md 주 8) | 무료 | ADR-07 |

## 선택
| # | 항목 | 내용 |
|---|---|---|
| U10 | 넥슨 라이선스 문의 | LICENSE 트랙을 원할 때만 필요합니다. 기본은 ORIGINAL입니다 |
| U11 | 서버 정원 상향 | M6 부하 측정 뒤에 다시 판단합니다(ADR-04) |

## 구현 후 갱신 (통합 브랜치, 2026-10-16)
| # | 항목 | 내용 | 비용 | 근거 |
|---|---|---|---|---|
| U12 | ~~main 반영 승인~~ **완료**: 사용자 승인("모두 가장 좋은 대로", 2026-10-17)에 따라 에이전트가 `durango/integration`을 main 에 fast-forward 했습니다(force 없음). 이후 main 보호 규칙·리뷰 정책은 사용자가 정합니다 | — | AGENTS.md layer rules |
| U13 | 라이브 서버 QA 2층 | Studio 시나리오 wildlife-spatial·full-coop-rejoin·tutorial(QA-CORE-01)은 2026-10-19 Windows Studio에서 통과했습니다(qa-evidence.md 주 7). 실제 TeleportService 왕복(QA-TP-01의 2층)과 실제 MemoryStore 부하(QA-SPIKE-01의 2층)는 라이브 서버가 필요해 아직 실행하지 않았습니다 | 무료 | 계획 §12 |
| U14 | 스테이징 배포 | 완료(2026-10-19): 비공개 체험 `Robango Staging`(universeId `10771918494`, placeId `95467272687768`)을 생성하고 Open Cloud API 키를 `.env.local`(gitignore)에 설정해 `forge deploy --env staging --pack robango-island --development`로 버전 2를 게시·검증했습니다(qa-evidence.md 주 8). 프로덕션 배포만 별도 Universe/Place·승인이 필요합니다 | 무료 | deploy.yml |
| U15 | Robux 상품 등록 | 완료(2026-10-19, 스테이징): `Robango Staging` Universe(`10771918494`)에 Game Pass 2종(`routeGuildPatron` `2040232413`, `wideWarehouse` `2037904759`), Developer Product 1종(`skinRidgeStriderGold` `3720013569`), Experience Subscription 1종(`routeGuildMonthly` `EXP-4461467833720767028`)을 원가 그대로 등록·활성화하고 `game.yml`과 `MonetizationCatalog.luau`에 반영했습니다. 프로덕션 Universe를 따로 만들 경우 그 Universe의 ID로 교체해야 합니다 | 무료(등록) | AGENTS.md, QA-BM-01 |
| U16 | 오디오·3D 애셋 제작 확정 | 스펙·정적 예산(QA-PERF-01) 안에서 3D 월드(Atmosphere/Bloom/ColorCorrection, 모닥불 화덕·삼각대·불꽃·광원, 작업대 모루·망치, 창고 지붕·상자·배럴, 지붕 기둥, 채집 노드 5종 입체 디테일)와 공룡 리그(초식·육식 등판 가시·주둥이·볏·황금 눈) 및 스토어 아이콘(512×512)·썸네일(1920×1080)을 제작·적용했습니다(2026-10-20) | 완료 | AGENTS.md, qa-evidence.md 주 8 |
| U17 | 출처 지문 갱신 | 원작 참고 자료 지문(cli/forge/provenance/reference-ip)은 2026-10-16 시점 공개 문서 기준입니다. 공개 자료가 바뀌면 재생성 여부를 정합니다 | 무료 | A3 provenance |
| U18 | 원작 제목 히스토리 정리 | 통합 브랜치 초기 커밋 3개(d2565da, 9556e85, 1f4002a)의 메시지·파일에 원작 제목이 남아 있습니다. 현재 트리는 금칙어 0건이지만, 이 커밋들은 이미 공개 원격의 `durango/integration`에 올라가 있고, main fast-forward 로 main 히스토리에도 포함됩니다. 지우려면 히스토리 재작성(squash 또는 filter-repo) 후 main·integration 둘 다 force-push 해야 하며, 이미 받아 간 사본은 회수할 수 없습니다. force-push 라 에이전트는 하지 않았습니다 | 무료 | QA-NAME-01 |
| U19 | 저사양 실기기 성능 확인(QA-PERF-01 2층) | 완료(2026-10-18~20): Studio 최저 품질(Level01)에서 첫 상호작용 2.86초, 월드 생성 0.24초, Studio 최대 메모리 2,639MB(LuaHeap 806MB)를 실측했고, 안드로이드 실기기(`SM-N981N` Galaxy Note 20 5G, Snapdragon 865+, Android 13, 2400x1080)에서 `com.roblox.client` PSS 704.0MB(RSS 848.6MB, Private Dirty 575.7MB, Native Heap 50.1MB, Graphics 34.9MB), 프레임 시간 p50 12ms(GPU p50 9ms), p90 23ms, p95 36ms를 실측했습니다 | 무료 | qa-evidence.md 주 3·8 |
| U20 | 스테이징 QA 2층 확인 | 스테이징 클라우드 및 안드로이드 실기기 검증 완료(2026-10-19~20, 주 8): 게시된 스테이징 플레이스에서 Open Cloud Luau Execution 및 안드로이드 실기기(`SM-N981N`) 접속으로 `DataStoreService`/`MemoryStoreService` 읽기·쓰기, 한국 계정 `PolicyService` 통과 및 구독·상품 네이티브 프롬프트(QA-BM-04 2층), 채집·제작·섭취·계약·캠프 기부·데스 존 전환 및 재접속 영속성을 모두 확인했습니다. 64인 동시 접속 MemoryStore 부하(QA-SPIKE-01 2층)만 다인 부하 테스트가 필요합니다 | 무료 | qa-evidence.md 주 8 |
| U21 | 배포 대상·키 입력 | 완료(2026-10-19, 스테이징): `.env.local`(gitignore)에 `FORGE_STAGING_UNIVERSE_ID=10771918494`, `FORGE_STAGING_PLACE_ID=95467272687768`, `ROBLOX_STAGING_API_KEY`, `ROBLOX_API_KEY`를 구성해 `forge deploy --env staging --pack robango-island --development`가 동작합니다. 프로덕션(`FORGE_PROD_UNIVERSE_ID`, `FORGE_PROD_PLACE_ID`, `ROBLOX_PROD_API_KEY`)만 출시 시점에 입력하면 됩니다 | 무료 | .env.example |
| U22 | Roblox Studio 설치·실행 | 완료(2026-10-18~19): Windows Studio에서 데스크톱·모바일 첫 플레이 캡처, 전체 흐름 플레이 점검(주 6), Studio 시나리오 3종(주 7)을 실행했습니다. 다시 돌릴 때만 Studio 실행 승인이 필요합니다 | 무료 | docs/release/studio-qa.md |
| U23 | 품질 등급 승격 | `quality.yml` 등급이 starter입니다. release-candidate로 올리려면 실제 첫 플레이 캡처(데스크톱·모바일), 독립 레퍼런스, 평가자(FORGE_QUALITY_EVALUATOR) 승인 영수증이 필요합니다. 에이전트가 스스로 승인할 수 없습니다 | 무료 | forge quality --help |

결정안: 착수에 필요한 사용자 결정은 모두 끝났고, 나머지는 M7 출시 준비까지 처리하면 된다.
