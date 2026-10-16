# Maturity & Compliance 설문 답변 초안 (목표: Mild)

> **DRAFT — 사용자가 직접 제출해야 합니다.** 이 문서는 답변 초안일 뿐이고 제출된 설문이 아닙니다. 에이전트는 Creator Dashboard에서 설문을 제출하지 않습니다. 제출 전 사용자는 실제 빌드를 직접 확인하고, 답변이 빌드와 다르면 빌드 기준으로 고쳐 답해야 합니다. Roblox는 의도적으로 사실과 다르게 답하면 모더레이션 대상으로 봅니다.

기준 문서: Roblox Creator Docs "Content maturity and compliance", 커밋 `710b20a5`
- https://raw.githubusercontent.com/Roblox/creator-docs/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/promotion/content-maturity.md
- 사람이 읽을 페이지: https://create.roblox.com/docs/production/promotion/content-maturity

게임 내 설계 근거: 계획 §6(비유혈, 처치 시 소멸), §7(TextChatService 필터), §8(결정적 상품만, 유료 랜덤 금지), ADR-07(무료 랜덤 규칙과 자발적 확률 공개), `preprod/kr-policy.md` H5·H7.

## 1. 목표 등급과 이유

- 목표: **Mild**. 문서상 Mild는 "repeated mild violence, heavy unrealistic blood, mild fear-based content, and/or mild crude humor"까지 담을 수 있는 등급입니다. 생물과의 전투가 반복되므로 Minimal("occasional mild violence")보다는 Mild가 정확합니다.
- Minimal과 Mild만 Roblox Kids(5–8세)와 Select(9–15세) 대상이 됩니다(문서 "Content labels").
- Restricted 등급 게임은 한국에서 플레이할 수 없습니다(문서: "unplayable for players who created their accounts or are located in certain countries or regions, such as Korea"). 따라서 Restricted로 올라가는 요소는 하나도 넣지 않습니다.
- Kids/Select와 지역별 정책을 받으려면 설문을 **전부** 작성해야 합니다(문서 "Generate labels"). 첫 질문만 답하는 경로는 쓰지 않습니다.
- 답은 "게임 안에서 볼 수 있는 가장 성숙하거나 극단적인 내용" 기준으로 합니다(문서 "Generate labels").

## 2. 카테고리별 답변 초안

문서 "Questionnaire categories"에 나오는 카테고리는 다음 15개입니다. 모두 답합니다.

| # | 카테고리 | 질문(원문 요지) | 초안 답변 | 근거와 유지 조건 |
| --- | --- | --- | --- | --- |
| 1 | Violence | Q1 폭력 묘사가 있는가 / Q2 강도 / Q3 빈도 | Q1 **예**. Q2 **Mild**. Q3 **Repeated** | 플레이어가 생물과 싸웁니다. 처치된 생물은 체력이 0이 되면 무력화 연출 뒤 소멸합니다(계획 §6 "비유혈 무력화 → 소멸"). 문서의 Mild 예시 "bodies disappearing the moment their health reaches zero"와 맞습니다. 전투가 자주 일어나므로 Repeated입니다. 사실적인 부상 표현이 한 번이라도 나오면 Moderate 이상이 되므로 금지합니다 |
| 2 | Blood | Q1 피 묘사가 있는가 | **아니요** | 피, 핏자국, 붉은 액체 이펙트를 쓰지 않습니다. 부위 파괴 채집도 재료 아이콘으로만 표현합니다(계획 §6). 애셋 검토 항목(§3) |
| 3 | Fear | Q1 공포 요소가 있는가 / Q2 강도 / Q3 빈도 | Q1 **예**. Q2 **Mild**. Q3 **Occasional** | 포식 생물의 경고 동작(telegraph), 울음을 위험 신호로 쓰는 오디오(계획 SYS-235), 위험 큐 음악이 있습니다. 문서의 Mild 예시("ominous music", "gameplay that builds suspense")에 해당합니다. Moderate 기준(사실적 상처, 장기, 피가 흐르는 눈)은 쓰지 않습니다. 빈도가 의심스러우면 Repeated로 답해도 등급은 Mild 범위입니다 |
| 4 | Crude humor | Q1 저속한 유머가 있는가 | **아니요** | 톤은 "가벼운 코미디"지만(계획 §9.1) 트림, 방귀, 배설물 소재를 쓰지 않습니다. 넣는다면 Mild로 답해야 합니다 |
| 5 | Unplayable gambling content | Q1 플레이 불가능한 도박 묘사가 있는가 | **아니요** | 카지노, 카드 게임, 슬롯 같은 장면이 없습니다. 플레이 가능한 도박은 Roblox가 전면 금지합니다 |
| 6 | Strong language | Q1 강한 언어를 묘사하거나 허용하는가 | **아니요** | NPC 대사에 비속어가 없습니다. 플레이어 채팅은 TextChatService 필터를 반드시 거치고, 필터에 실패하면 보내지 않습니다(계획 §7). "Allow strong language" 설정을 켜지 않습니다 |
| 7 | Romantic themes | Q1 로맨스 주제, 사적 공간이 주 무대, 성인용 장소가 있는가 | **아니요** | 로맨스 요소가 없습니다. 본거지섬은 정착지이고 침실·샤워실 같은 사적 공간이 주 무대가 아닙니다. 교역항에 술집이나 클럽을 두지 않습니다 |
| 8 | Alcohol | Q1 음주 묘사·언급이 있는가 | **아니요** | 계획 §9.1이 음주 소재를 배제합니다. 교역항 NPC(조선공, 감정사, 게시판 관리인, 우체부)에도 술집 주인은 없습니다. 음료 아이템을 만들 때 술로 보이지 않게 합니다 |
| 9 | Social hangout | Q1 주된 활동이 소셜 행아웃인가 / Q2 사적 공간 | Q1 **아니요** | 주된 활동은 생존·채집·제작·정착입니다. 채팅은 보조 기능입니다. 문서는 제목이나 설명에 행아웃을 암시하는 문구가 있으면 행아웃으로 분류한다고 하므로, 스토어 설명에 "hangout", "chill", "vibe" 같은 표현을 쓰지 않습니다 |
| 10 | Free-form user creation | Q1 자유 그리기·픽셀 캔버스가 있는가 | **아니요** | 건축은 3D 애셋 조립이므로 해당하지 않습니다(문서 명시). 플레이어 그림 표지판(EditableImage)은 계획 §15에 따라 신고·숨김 흐름이 생기기 전까지 비활성입니다. 이 기능을 켜면 **예**로 바꿔야 하고, 그 기능은 16세 이상에게만 제공됩니다 |
| 11 | Sensitive issues | Q1 주된 주제가 민감한 사회 이슈인가 | **아니요** | 섬 생태 보존단(계획 §9.1)은 자연 관찰 의뢰일 뿐 정치적 쟁점이 주제가 아닙니다 |
| 12 | Paid random items | Q1 유료 랜덤 아이템이 있는가 / Q2 ArePaidRandomItemsRestricted 준수 | Q1 **아니요** | Robux 상품은 모두 결정적입니다(계획 §8.1). 유료 랜덤, 행운·드롭률·성공률 부스트를 팔지 않습니다(ADR-07 규칙 1~4). 무료 랜덤 상자는 확률을 자발적으로 공개합니다(ADR-07 규칙 5). **해석 주의는 §4 참고** |
| 13 | Paid item trading | Q1 유료 아이템 거래가 가능한가 / Q2 IsPaidItemTradingAllowed 준수 | Q1 **아니요** | Robux로 산 아이템은 전부 거래 불가입니다(계획 §7 장터, §8.2). 장터에서는 플레이로 얻은 아이템만 거래합니다 |
| 14 | Media | Q1 게임 내 미디어 공유 / Q2 연속 로딩 피드·자동 재생 / Q3 다른 게임 캡처 콘텐츠 열람 | Q1 **아니요**. Q2 **아니요**. Q3 **아니요** | 게임 안에 스크린샷·영상 공유 도구, 피드, 외부 이미지 뷰어를 두지 않습니다. 배경음악 자동 재생은 피드가 아니므로 해당하지 않는다고 봅니다(사용자가 제출 전 확인) |
| 15 | AI interaction | Q1 생성형 AI와 상호작용하는가 / Q2 유형 | Q1 **아니요** | NPC 대사는 미리 쓴 텍스트입니다(계획 §9.2). 개발에 생성형 도구를 썼는지는 이 질문과 관계없습니다(문서 명시) |

## 3. 제출 전 확인 목록

- [ ] 실제 빌드에서 처치된 생물이 피 없이 사라지는지 확인(애셋, VFX, 사운드 포함). 계획 §15 "비유혈 애셋 검토"
- [ ] 위험 큐 음악과 생물 울음이 Mild 공포를 넘지 않는지 확인
- [ ] 스토어 제목·설명에 행아웃, 로맨스, 음주를 연상시키는 표현이 없는지 확인
- [ ] EditableImage 표지판이 꺼져 있는지 확인
- [ ] econ.yml에 확률 필드가 없는지(QA-BM-01), 유료 아이템 거래 불가(계획 §15 "결제")가 PASS인지 확인
- [ ] 설문 미리보기(Questionnaire Preview)에서 등급이 Mild로 나오는지, **한국이 non-compliant 지역으로 표시되지 않는지** 확인하고 화면을 캡처해 보관(kr-policy.md H7 설계 영향)
- [ ] 제출 후 업데이트가 답을 바꾸면 다시 제출(문서: "you must update your answers and resubmit")

## 4. 해석이 갈릴 수 있는 지점 (사용자 판단 필요)

**무료 랜덤과 "other currency".** 문서 Paid random items Q1은 유료 랜덤 아이템을 "virtual items players can purchase with Robux or other currency"로 정의하고, 보고하지 않아도 되는 경우를 "an action that doesn't involve the payment of Robux **or any other currency**"로 적습니다. 즉 플레이로 번 재화(조개돈)를 **써서** 여는 랜덤 상자는 문자 그대로 읽으면 "other currency" 결제에 걸릴 수 있습니다. kr-policy.md H5도 이 문구가 "다소 넓다"고 기록했습니다.

- 안전한 형태: 무료 랜덤 보상은 행동 완료(의뢰 납품, 탐사 기록 달성 등)의 보상으로만 지급하고, 어떤 재화도 쓰지 않게 합니다. 이 경우 Q1 **아니요**가 문구와 정확히 맞습니다.
- 계획 §8.2의 "earned-only 태그 재화로만 여는 확률 표면"(P2)을 그대로 만든다면, 사용자는 Q1을 **예**로 답하고 Q2에서 ArePaidRandomItemsRestricted를 준수한다고 답할지 결정해야 합니다. 이때도 확률 합 100% 표기는 이미 계획에 있습니다. 등급 자체가 Mild를 벗어나지는 않지만 콘텐츠 설명 문구가 붙습니다.
- 이 초안은 안전한 형태를 전제로 **아니요**로 적었습니다. 확률 표면 설계가 바뀌면 이 행을 다시 씁니다.

출처: https://raw.githubusercontent.com/Roblox/creator-docs/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/promotion/content-maturity.md (Paid random items 섹션), https://github.com/Roblox/creator-docs/blob/710b20a5f4f1f4567c025786f6f1833c749f9d7e/content/en-us/production/monetization/paid-random-items.md
