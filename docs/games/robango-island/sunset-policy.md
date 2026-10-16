# 로방고 섬 서비스 종료(sunset) 정책

상태: 초안. 출시 전에 정의해 게시해야 하는 문서이며(계획 §13, §15 "배포"), 아직 게시하지 않았습니다. 이 문서는 어떤 판매 중단, 배포, 데이터 변경도 승인하지 않습니다. 실제 실행에는 사용자 승인이 필요합니다.

근거: 이식 계획서(경로는 [README.md](README.md) 참조) §8, §13, §15, ADR-07(구독 해지 시 창고 보존), `preprod/kr-policy.md` "추가. 판매 요건과 DevEx".

## 1. 원칙

- 종료는 예고 없이 하지 않습니다. 종료를 공지하는 날에 결제를 먼저 끊고, 플레이는 정해진 기간 동안 계속 열어 둡니다.
- 플레이어가 만든 것(본거지섬, 캠프 공동 건설물)은 지우지 않고 읽기 전용으로 남기는 것을 기본으로 합니다.
- 환불은 Roblox 플랫폼 정책을 따릅니다. 이 게임이 자체 환불 약속을 따로 하지 않습니다. 원작의 종료 시 환불 사례(C37, 가정/미검증)는 참고하지 않습니다(계획 §16 R17).
- 마지막 기간에는 엔딩 이벤트를 열어 시즌 이야기를 마무리합니다.

## 2. 일정 용어

| 표기 | 의미 | 초기값(신규 산정, 사용자 결정 필요) |
| --- | --- | --- |
| D0 | 종료 공지일 = 결제 차단일 | 사용자가 정함 |
| D0 ~ Dend | 플레이 유지 기간(엔딩 이벤트 포함) | 30일 이상 권고 |
| Dend | 정규 서버 종료일. 이후에는 보존 플레이스만 남김 | D0 + 30일 이상 |
| Dkeep | 보존 플레이스 유지 종료일(정하지 않으면 무기한) | 사용자가 정함 |

일정의 시작과 끝은 `core/infra/liveops/Schedule.luau` 이벤트로 넣고, 판정은 주입 clock으로 합니다(계획 D-8). 서버 시계를 직접 읽지 않습니다.

## 3. 결제 차단일(D0)

D0에 공지와 동시에 다음을 처리합니다.

1. 모든 Game Pass와 Developer Product를 판매 중단합니다(Creator Dashboard에서 off sale). 게임 내 구매 UI는 `FeatureFlags`로 숨기고, `MarketplaceService:GetProductInfo`의 `IsForSale`이 false이면 구매 프롬프트를 띄우지 않습니다.
   - 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/developer-products.md
2. 월간 구독은 **Take Off Sale**을 선택하고 "cancel future renewals for current subscribers" 옵션을 고릅니다. 구독을 삭제(Delete)하지 않습니다. Roblox 문서는 삭제 대신 판매 중단 후 갱신을 취소하고 현재 기간이 끝나기를 기다리라고 권고합니다.
   - 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/subscriptions.md
3. 이미 받은 혜택은 회수하지 않습니다. 구독이 끝난 계정의 창고 확장분은 읽기 전용으로 보존하고 추가 입고만 막습니다(ADR-07, 데이터 손실 0).
4. 처리 중인 `ProcessReceipt` 영수증은 D0 이후에도 멱등 처리 경로를 유지해 지급을 끝냅니다(QA-BM-03). 판매 중단은 처리 중인 영수증을 버리는 근거가 되지 않습니다.

## 4. 환불 창

이 게임은 Robux 가격 상품만 팝니다(kr-policy.md "추가": 구독은 Robux 가격으로 시작).

| 상품 | 환불 정책 | 출처 |
| --- | --- | --- |
| 구독(Robux 가격) | Robux로 결제한 구독은 환불 대상이 아닙니다("Subscriptions purchased with Robux are not eligible for refunds"). 갱신 취소 후에도 현재 결제 기간이 끝날 때까지 혜택이 유지됩니다 | https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/subscriptions.md |
| 구독(현지 통화 가격) | 판매하지 않습니다. 만약 판매했다면 삭제 시 현재 구독자 전원을 환불해야 하므로 삭제하지 않습니다 | https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/subscriptions.md |
| Game Pass, Developer Product | 확인한 문서(passes.md, developer-products.md)에는 제작자 측 환불 절차가 없습니다. 플레이어 환불 요청은 Roblox 고객지원 절차로 안내합니다. 이 항목은 미확인이며 출시 전 다시 확인합니다 | https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/passes.md |

- 이 게임은 별도 환불 창을 약속하지 않습니다. 공지문에는 "환불은 Roblox 정책을 따른다"와 위 출처만 적습니다.
- 소프트 재화(조개돈)는 Robux로 판매하지 않으므로(ADR-07 규칙 1) 환불 대상이 생기지 않습니다.

## 5. 본거지섬 보존

두 가지 방식 중 하나를 D0 전에 정합니다. 둘 다 섬 저장 형식(template + seed + delta, 계획 §5.2)을 그대로 씁니다.

| 방식 | 내용 | 장점 | 비용과 제약 |
| --- | --- | --- | --- |
| A. 읽기 전용 보존 플레이스(권고) | Dend 이후 정규 플레이스를 닫고, 본거지섬을 열람만 할 수 있는 보존 플레이스를 남깁니다. 쓰기 경로(채집, 제작, 건설, 거래, 구매)는 코드에서 비활성화하고, 섬 리스(FencedStore)를 얻지 않습니다 | 플레이어가 자기 섬을 계속 볼 수 있음 | 보존 플레이스 유지에 저장 사용량이 남음. Dkeep을 정해야 함 |
| B. 스냅샷 내보내기 | Dend에 모든 섬 상태를 소유자가 승인된 저장 절차로 보관용 사본으로 내보냅니다. 게임은 닫습니다 | 운영비가 가장 적음 | 플레이어가 직접 볼 수 없음. 내보내기 자체가 별도 승인 대상 |

공통 조건:

- 보존 전에 [docs/release/rollback.md](../../release/rollback.md)의 백업 매니페스트 절차를 따릅니다. 백업 파일이 있다는 것만으로 복원 가능하다고 보지 않습니다.
- 모든 쓰기 주체가 멈췄는지(quiescence)를 관찰한 뒤 스냅샷을 만듭니다. 진행 중인 아이템 이전은 FINALIZED까지 진행시킨 뒤 보존합니다.
- 보존 플레이스에서는 버전 숫자를 낮추거나 기본값으로 덮어쓰지 않습니다.
- 개인정보 삭제 요청 처리는 보존 기간에도 계속합니다. 해당 절차의 Roblox 원문은 이 문서에서 확인하지 않았으므로 출시 전 확인합니다.

## 6. 엔딩 이벤트 순서

D0부터 Dend까지 `Schedule.luau` 이벤트로 진행합니다. 각 단계는 `Broadcast.announce`로 공지합니다.

| 순서 | 시점(초기값) | 내용 |
| --- | --- | --- |
| 1 | D0 | 공지: 종료 일정, 결제 차단, 환불 정책, 보존 방식. 게임 내 공지와 그룹 공지를 같은 문구로 냅니다 |
| 2 | D0 ~ D0+7일 | 모든 항로와 밴드를 게이트 없이 개방합니다. 플레이 획득 보상만 늘리며, 유료 상품은 없습니다 |
| 3 | D0+7일 ~ D0+21일 | 마지막 공동 프로젝트: 교역항에 서버 전체가 함께 짓는 기념물. 기여는 결정적 점수로 집계합니다 |
| 4 | D0+21일 ~ Dend-2일 | 마지막 이야기: 조수 균열의 결말 장면을 공개합니다(계획 §9.1, "함께 지은 것이 남는다") |
| 5 | Dend-2일 ~ Dend | 작별 기간: 교역항 기념물 공개, 기념 칭호(무료, 고정 지급). 게임 내 미디어 공유 기능은 추가하지 않습니다(성숙도 설문 Media 답변 유지) |
| 6 | Dend | 정규 서버 종료, 보존 방식 A 또는 B 실행 |

엔딩 이벤트의 보상은 모두 무료이고 확률이 없습니다(계획 D-5). 이벤트 기간에 새 판매 상품을 만들지 않습니다.

## 7. 체크리스트

각 항목은 증거 경로와 서명자를 남깁니다.

**D0 전(출시 전에 완료)**
- [ ] 이 문서를 플레이어가 볼 수 있는 곳에 게시(계획 §15 "배포")
- [ ] 보존 방식 A/B 결정, Dend와 Dkeep 초기값 결정(사용자)
- [ ] 구매 UI를 한 번에 끄는 FeatureFlag 존재 확인
- [ ] 보존 플레이스의 쓰기 경로 차단을 증명하는 QA 시나리오 작성

**D0**
- [ ] 모든 Game Pass, Developer Product off sale
- [ ] 구독 Take Off Sale + 갱신 취소(삭제하지 않음)
- [ ] 게임 내 구매 UI 숨김 확인(스테이징에서 먼저)
- [ ] 공지 발송: 일정, 환불 정책(출처 포함), 보존 방식

**D0 ~ Dend**
- [ ] 엔딩 이벤트 1~5단계 Schedule 등록, 스테이징 리허설
- [ ] 미처리 영수증 0 확인(지급 원장)
- [ ] 진행 중 아이템 이전 0 확인(전송 저널 FINALIZED)

**Dend**
- [ ] 쓰기 주체 정지 관찰
- [ ] 백업 매니페스트 작성, 사본 복호화 비교 영수증 확보(rollback.md)
- [ ] 보존 방식 실행, 보존 플레이스 접속 확인 또는 내보내기 사본 해시 기록
- [ ] 정규 플레이스 비공개 전환(사용자 승인)
