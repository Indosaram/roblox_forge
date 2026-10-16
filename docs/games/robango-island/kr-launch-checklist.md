# 한국 출시 체크리스트

상태: 초안. 한국에만 해당하는 출시 전 단계를 모았습니다. 외부 기관 질의, KR 계정 접속, 비용 지출은 모두 사용자가 직접 합니다(user-actions.md U5·U6·U7·U9). 공통 출시 항목은 계획 §15를 따릅니다.

근거: `preprod/kr-policy.md` H4·H6·H7·C29, `preprod/ADR-preprod.md` ADR-07·ADR-08, `preprod/user-actions.md`.

## 1. GRAC 서면 질의 (H7, U5)

**왜 필요한가.** 게임산업법 제21조제1항은 유통·이용 제공 목적의 게임물이 GRAC 또는 자체등급분류사업자의 등급분류를 받도록 정합니다. 개인 제작자가 Roblox 안에 게시한 체험에 이 조항이 어떻게 적용되는지 공식 해석을 찾지 못했고, Roblox가 자체등급분류사업자로 지정됐는지도 확인하지 못했습니다(kr-policy.md H7, 미해결).
- 법령: https://www.law.go.kr/DRF/lawService.do?OC=test&target=law&MST=265811&type=HTML
- 사람이 읽을 페이지: https://www.law.go.kr/법령/게임산업진흥에관한법률

**보낼 곳.** GRAC 1:1 문의, 또는 문화체육관광부 게임콘텐츠산업과(044-203-3268). 답변은 서면(전자 문서 포함)으로 받아 보관합니다.

**질의문 템플릿** (보내기 전에 legal-review-packet.md §5.3 질문 19에 따라 변호사 검토를 받는 것을 권합니다)

```text
제목: 해외 플랫폼(Roblox) 내 개인 제작 체험의 등급분류 및 확률형 아이템 표시 의무 해당 여부 질의

1. 질의인
- 성명/상호: [사용자 기입]
- 사업자 구분: 개인사업자(간이과세자) [사용자 확인]
- 연락처: [사용자 기입]

2. 사실관계
- 질의인은 미국 Roblox Corporation이 운영하는 플랫폼 "Roblox" 안에 섬 생존·제작 협동 게임 체험 1개를 제작해 게시할 예정입니다.
- 체험은 Roblox 앱과 웹에서만 실행되며, 별도 설치 파일이나 독자 스토어 배포는 없습니다.
- 이용자는 Roblox 계정으로 접속하며, 결제는 Roblox의 가상화폐(Robux)로만 이루어집니다. 질의인은 Roblox의 DevEx 제도를 통해 수익을 받을 수 있습니다.
- 판매 상품은 효과가 미리 정해진 상품(의상 등 외형, 저장 공간 확장, 월간 구독)뿐입니다. 유료로 구매하는 확률형 상품은 없습니다.
- 게임 안에는 플레이로만 얻는 무료 보상 상자가 있을 수 있습니다. 이 상자는 Robux나 Robux로 산 재화로 얻거나 열 수 없고, 유료 아이템과 결합하지도 않습니다. 확률은 자발적으로 공개할 예정입니다.
- Roblox는 자체 "Maturity & Compliance" 설문으로 연령 표시를 하며, 질의인은 이 설문을 작성할 예정입니다.

3. 질의 사항
(1) 위 체험이 「게임산업진흥에 관한 법률」 제21조제1항에 따른 등급분류 대상 게임물에 해당합니까?
(2) 해당한다면, 질의인이 직접 위원회에 등급분류를 신청해야 합니까, 아니면 플랫폼 운영자 또는 자체등급분류사업자를 통한 경로가 있습니까? Roblox가 현재 자체등급분류사업자로 지정되어 있는지도 알려 주시기 바랍니다.
(3) 위 무료 보상 상자가 같은 법 제2조제11호의 "확률형 아이템"에 해당합니까? 플레이로 번 무료 게임 재화를 써서 여는 경우와, 의뢰 완료 보상으로만 지급하는 경우에 차이가 있습니까?
(4) 해당하지 않더라도 확률을 자발적으로 공개할 때 따라야 할 표시 방법(시행령 별표 3의2, 문화체육관광부 고시)이 있습니까?
(5) 질의인에게 같은 법 제31조의2의 국내대리인 지정 의무가 있습니까?
(6) 그 밖에 질의인이 출시 전에 이행해야 할 절차가 있습니까?

4. 첨부
- 체험 개요 1쪽, 판매 상품 목록(확률 요소 없음 표시), Maturity 설문 답변 초안
```

**체크**
- [ ] 질의 발송(날짜, 접수 번호 기록)
- [ ] 회신 수령, 원문 보관 경로 기록
- [ ] 회신이 "등급분류 필요"이면 출시 일정을 다시 잡고 사용자와 경로를 정함
- [ ] 회신 내용을 kr-policy.md H7의 미해결 표시와 대조해 갱신(별도 PR)

## 2. PolicyService 실측 (H4, U9)

**왜 필요한가.** `PolicyService:GetPolicyInfoForPlayerAsync`의 값은 "geolocation, age group, and platform" 기준으로 정해지는데, 한국 플레이어가 어떤 값을 받는지 국가별 표가 문서에 없습니다(kr-policy.md H4). 코드는 값과 관계없이 안전하게 동작하도록 설계했지만(유료 랜덤 없음, 유료 아이템 거래 불가, ADR-07) 실제 값을 기록해 둡니다.
- 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/reference/engine/classes/PolicyService.yaml
- https://create.roblox.com/docs/reference/engine/classes/PolicyService

**역할.** 로그 코드는 에이전트가 만들고(스테이징 전용), 접속은 사용자가 합니다. Studio 실행과 스테이징 접속은 사용자 승인 후 진행합니다(계획 D-12).

**절차**
1. 스테이징 Universe에만 기록용 서버 스크립트를 넣습니다. 프로덕션에는 넣지 않습니다.
2. 스크립트는 `Players.PlayerAdded`에서 `pcall`로 `GetPolicyInfoForPlayerAsync`를 호출합니다(문서상 pcall 필수).
3. 기록 필드: `AreAdsAllowed`, `ArePaidRandomItemsRestricted`, `IsContentSharingAllowed`, `IsEligibleToPurchaseCommerceProduct`, `IsEligibleToPurchaseSubscription`, `IsPaidItemTradingAllowed`, `IsPhotoToAvatarAllowed`, `IsSubjectToChinaPolicies`, `AllowedExternalLinkReferences`, `IsEndlessContentLoadAllowed`, `IsEndlessContentAutoplayAllowed`. 문서에 없는 필드가 오면 이름만 따로 기록합니다.
4. UserId, 이름, IP 같은 식별 정보는 로그에 남기지 않습니다. 대신 측정 조건 라벨(아래 표의 케이스 번호)만 남깁니다.
5. 사용자가 아래 케이스로 각각 접속하고, 결과를 표로 옮깁니다.

| 케이스 | 계정 | 접속 위치 | 플랫폼 | 기록 |
| --- | --- | --- | --- | --- |
| K1 | KR에서 만든 성인 계정 | 한국 | PC | |
| K2 | KR에서 만든 성인 계정 | 한국 | 모바일(실기기) | |
| K3 | KR에서 만든 16세 미만 테스트 계정(있을 때만) | 한국 | 모바일 | |
| C1 | 비교용 비KR 계정(있을 때만) | 한국 외 | PC | |

6. 실패도 기록합니다. pcall이 실패하면 오류 종류만 남기고, 그 케이스는 "미측정"으로 둡니다. 실패를 기본값으로 메우지 않습니다.
7. 측정이 끝나면 기록용 스크립트를 스테이징에서 뺍니다.

**판정 기준**
- `ArePaidRandomItemsRestricted`가 true여도 영향이 없어야 합니다(유료 랜덤 없음).
- `IsPaidItemTradingAllowed`가 false여도 영향이 없어야 합니다(유료 아이템 거래 불가 단일 경로, 계획 §8.2).
- `IsEligibleToPurchaseSubscription`이 false인 케이스에서는 구독 구매 프롬프트가 0회여야 합니다(QA-BM-04). 이 확인은 같은 접속에서 함께 합니다.

**체크**
- [ ] 스테이징 전용 기록 스크립트 준비, 사용자 승인
- [ ] K1, K2 측정(필수), K3, C1(가능할 때)
- [ ] 결과 표와 QA-BM-04 결과 보관
- [ ] 기록 스크립트 제거 확인

## 3. Kids/Select 노출 요건 일정 (C29, ADR-08, U6·U7)

한국을 포함해 16세 미만에게 노출하려면 아래 요건을 모두 충족해야 합니다. 1차 출처로 확인한 내용입니다(kr-policy.md C29).
- 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/publishing/kids-and-select.md
- 등급 기준: https://raw.githubusercontent.com/Roblox/creator-docs/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/promotion/content-maturity.md (Minimal, Mild만 Kids 대상. Restricted는 한국에서 플레이 불가)

비용이 드는 항목은 **[비용 · 사용자 승인 필요]**로 표시했습니다. 에이전트는 결제하지 않습니다.

| 순서 | 항목 | 내용 | 비용 | 시점(상대 일정) | 담당 |
| --- | --- | --- | --- | --- | --- |
| 1 | 소유 형태 결정 | 개인 소유 또는 그룹 소유. 그룹이면 그룹 소유자 계정이 아래 요건을 채워야 합니다 | 무료 | M7 시작 전 | 사용자 |
| 2 | 계정 상태 | 계정 상태 양호(good standing) | 무료 | 상시 | 사용자 |
| 3 | 계정 인증 | 18세 이상은 정부 신분증 인증 | 무료 | M7 시작 전 | 사용자 |
| 4 | 2단계 인증 | 2FA 활성화 | 무료 | M7 시작 전 | 사용자 |
| 5 | 성숙도 설문 | 전체 작성, 목표 Mild(maturity-questionnaire-draft.md). 미리보기에서 한국 non-compliant 표시 여부 캡처 | 무료 | 콘텐츠 동결 후 | 사용자 제출 |
| 6 | 게시 자격 | Roblox Plus 또는 Premium **2개월 연속** 유지, 또는 1회성 환불형 퍼블리시 요금. Community Standards 위반으로 영구 삭제되면 요금은 환불되지 않습니다 | **[비용 · 사용자 승인 필요]** | 평가 시작 2개월 전부터 구독 유지 | 사용자 |
| 7 | 16세 이상 평가 기간 | 먼저 16세 이상 연령확인 유저에게만 공개. **60일 안에 "highly engaged" 유저 250명**의 고유 플레이가 필요합니다. 이 유저는 최근 60일 안에 Roblox에서 결제한 적이 있어야 합니다. 안전성 검토도 거칩니다 | 무료 | 소프트런치(M8)와 겹쳐 진행 | 사용자, 지표 확인은 에이전트 |
| 8 | 신속 심사(선택) | 7번 대신 **50,000 Robux** 환불형 expedited review | **[비용 · 사용자 승인 필요]** | 7번이 늦어질 때만 | 사용자 |
| 9 | 구독 판매 자격 | Robux 가격 구독은 인증 없이 판매 가능, 최소 49 Robux. 구매 전 `IsEligibleToPurchaseSubscription` 확인(§2) | 무료 | M4 이후 | 에이전트(코드), 사용자(가격 확정) |
| 10 | DevEx 준비 | 13세 이상, Earned Robux 30,000 이상, 인증 이메일, DevEx 포털(Tipalti), W-8BEN. 실명 일관성 유지 | 무료 | 첫 출금 전 | 사용자 |

구독·DevEx 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/subscriptions.md , https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/developer-exchange.md

**일정 요약(달력 날짜는 정하지 않음, 계획 D-10)**

```text
T-2개월  6. Plus/Premium 구독 시작 [비용 · 사용자 승인]  (또는 출시 직전 퍼블리시 요금)
T-1개월  1~4. 소유 형태, 신분증 인증, 2FA
T-2주    5. 성숙도 설문 제출(콘텐츠 동결 후), 한국 표시 캡처
T0       16세 이상 공개 시작 = 7. 평가 기간 시작(60일 창)
T+60일   250 engaged 미달이면 8. 신속 심사 검토 [비용 · 사용자 승인]
```

## 4. 한국 BM 하드 룰 확인 (ADR-07)

출시 전에 아래 규칙이 CI로 증명됐는지 확인합니다. 이 규칙들이 증명되면 KR에서도 무료 랜덤을 켤 수 있습니다(ADR-07, QA-BM-05 확장).

- [ ] 무료 재화를 Robux로 팔거나 Robux 재화와 교환하는 상품 0(QA-BM-01)
- [ ] 유료 행운·드롭률·획득량 부스트 0(QA-BM-01)
- [ ] 유료 재료와 무료 재료를 섞는 랜덤 조합·강화 0
- [ ] 구독 혜택에 확률 변경 요소 0
- [ ] 무료 랜덤 상자의 확률 표기(합계 100%, 이름 붙은 버튼 뒤) 존재. 표시 형식 출처: https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/paid-random-items.md
- [ ] 게임산업법 제2조제11호 정의(유상 구매, 유상·무상 결합)와 대조한 메모 첨부: https://www.law.go.kr/DRF/lawService.do?OC=test&target=law&MST=265811&type=HTML

## 5. 남은 미확인 사항

- Roblox UGC 체험에 대한 GRAC 등급분류·확률 표시 의무의 공식 해석(§1 질의로 해소)
- 한국 플레이어의 실제 PolicyService 값(§2 실측으로 해소)
- 시행령 별표 3의2와 문체부 고시 원문(변호사 검토 또는 §1 질의 (4))
- 2024-08 한국 체험 차단 건의 1차 출처(kr-policy.md H7). 계획 §15는 Roblox 공지를 참고합니다: https://about.roblox.com/en-au/newsroom/2024/08/an-update-for-users-and-developers-in-korea
