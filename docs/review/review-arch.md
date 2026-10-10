### F1 [SEVERITY: critical]
- **Claim attacked**: Section 11.3 (Line 183 & 185) proposes generative models for commercial production: `AudioCraft, Roblox 오디오 [R8], ElevenLabs` for sound (`forge gen sfx|bgm`), and `Roblox Cube, Hunyuan3D-2, TRELLIS` for 3D meshes (`forge gen mesh`).
- **Attack**: This generative AI pipeline is a legal and commercial minefield that will result in immediate DMCA takedowns, copyright infringement lawsuits, and platform bans:
  1. **AudioCraft (Meta)**: While the code repository is MIT, the official pre-trained model weights (`facebookresearch/audiocraft/main/LICENSE_weights`) are strictly licensed under **Creative Commons Attribution-NonCommercial 4.0 International (CC-BY-NC 4.0)**. Generating SFX/BGM for a monetized Roblox game containing GamePasses and Robux developer products is an explicit commercial violation.
  2. **Roblox Cube**: Governed by the **CUBE3D RESEARCH-ONLY RAIL-MS LICENSE**. Section I.1.(k) defines `Permitted Purpose` strictly as "for academic or research purposes only", and Section II.2 explicitly restricts copyright and patent grants "only in connection with the Permitted Purpose". Using Cube to generate assets for live commercial games violates Roblox's own RAIL license.
  3. **Tencent Hunyuan3D-2**: The `TENCENT HUNYUAN 3D 2.0 COMMUNITY LICENSE AGREEMENT` explicitly states in its header: *"THIS LICENSE AGREEMENT DOES NOT APPLY IN THE EUROPEAN UNION, UNITED KINGDOM AND SOUTH KOREA AND IS EXPRESSLY LIMITED TO THE TERRITORY"*. Any developer operating in South Korea or deploying services there has zero license grant to use or distribute Hunyuan 3D 2.0.
  4. **TRELLIS**: Relies on submodules including `diff-gaussian-rasterization` (derived from Inria's GraphDeco project), which carries non-commercial research restrictions.
- **Evidence**:
  - `https://raw.githubusercontent.com/facebookresearch/audiocraft/main/LICENSE_weights` -> "Attribution-NonCommercial 4.0 International"
  - `https://raw.githubusercontent.com/Roblox/cube/main/LICENSE` -> Lines 19, 27: "(k) 'Permitted Purpose' means for academic or research purposes only." / "each Contributor hereby grants to You, only in connection with the Permitted Purpose..."
  - `https://raw.githubusercontent.com/Tencent-Hunyuan/Hunyuan3D-2/main/LICENSE` -> Header: "THIS LICENSE AGREEMENT DOES NOT APPLY IN THE EUROPEAN UNION, UNITED KINGDOM AND SOUTH KOREA"
  - `ROBLOX_VIRAL_GAME_PLAN.md`: Lines 183, 185.
- **Fix**: Replace all non-commercial open-weight models in Section 11.3 with commercially licensed cloud APIs or permissive models. Replace AudioCraft with commercial ElevenLabs Sound Effects API / Suno / Udio enterprise licenses, or an in-house fine-tuned Stable Audio Open instance. Replace Hunyuan3D-2 and Roblox Cube with commercially licensed 3D APIs (e.g., Meshy API, Tripo3D API) or Studio's native `generate_mesh` MCP tool which is backed by Roblox's Creator terms.

---

### F2 [SEVERITY: critical]
- **Claim attacked**: Section 11.3 (Line 185): `forge gen sfx|bgm "<prompt>": 생성 → 음량 정규화 → 업로드` to dynamically populate sound effects and music across multiple games.
- **Attack**: The plan ignores Roblox's hard Open Cloud asset upload quotas. According to official Roblox Open Cloud documentation for the Assets API (`/docs/en-us/cloud/guides/usage-assets`), audio uploads are subject to severe monthly limits:
  - **ID-verified accounts**: Maximum **100 audio uploads per month**.
  - **Non-verified accounts**: Maximum **10 total audio uploads per month**.
  - Audio assets are **not available for updating** (immutable).
  A single game (like *Steal a Kaiju Egg* in Section 5) requires dozens of sound assets (egg crack, hatch fanfare, rarity stingers, footstep variations, base alarm, lock engage/disengage, 3rd-person killcam impact, coin collection, fusion effects, and background music tracks). A generative AI loop creating and testing sound variations across multiple games will exhaust the 100-upload monthly quota in a single afternoon, completely blocking the factory CI/CD pipeline for the remaining month.
- **Evidence**: `https://create.roblox.com/docs/en-us/cloud/guides/usage-assets.md` -> Supported asset types table: Audio (`.mp3`, `.ogg`, `.wav`, `.flac`): *"Up to 100 uploads per month if you're ID-verified. Up to 10 total uploads per month if you aren't ID-verified. Not available for updating."*
- **Fix**: Remove automated audio asset uploading from the CI/CD generative loop. Implement an asset reuse catalogue (`audio_registry.json`) mapping shared sound effects to existing Creator Store audio IDs (licensed public Roblox sound library). Reserve Open Cloud audio upload quota strictly for final curated BGM tracks, and implement an upload quota budget tracker in `forge gen audio` that blocks execution if remaining monthly allowance falls below a critical threshold.

---

### F3 [SEVERITY: critical]
- **Claim attacked**: Section 11.1 (Lines 159-162) & Section 11.6 (Line 231): `3. Game Pack(게임별): game.yml 설정, 기획 문서, 밸런스 CSV, 에셋, 상품 목록. 새 게임은 이 층만 새로 만듭니다.` and `M5 (범용성 검증): 장르가 다른 두 번째 게임 팩(grow-and-defend-garden = grow-harvest + survival-coop): Core·Genre 코드 수정 0줄, 게임 팩 파일만으로 플레이 가능한 프로토타입 완성.`
- **Attack**: The claim of "0 lines of Core/Genre code change for Game #2" by only editing declarative configuration (`game.yml`, CSV, assets) is architectural fantasy. In Roblox, game behavior requires executable Luau logic.
  1. The Game Pack layer explicitly forbids containing custom Luau scripts (`Game Pack 안에서 Core나 Genre Module 코드를 복사·수정하는 것은 금지합니다`).
  2. Composing two disparate genres (`grow-harvest` and `survival-coop`) requires concrete interaction mechanics: Do harvested crops serve as barricades against monsters? Does eating a harvested vegetable restore health during night raids? Does monster acid destroy planted crops? 
  3. Without custom glue code in the Game Pack or an extensible ECS/action-binding runtime in Core, two independently written genre modules cannot interact. The result would be two disjoint systems running simultaneously in the same place (a player farming wheat in a corner while monsters attack empty space).
  4. Furthermore, game-specific mechanics from Section 5 leaked directly into the supposedly generic genre modules: `collect-steal` in Section 11.4 hardcodes `합성` (fusion crafting), which is specific to *Kaiju Egg* and irrelevant to basic theft games like *Steal a Brainrot*.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Lines 159-162, 194, 231.
- **Fix**: Acknowledge that Game Packs must support custom Luau behavior. Redefine Game Pack structure to include `src/client/`, `src/server/`, and `src/shared/` containing game-specific Luau controllers/services that inherit from and hook into Genre Modules via an explicit Event/Action Hook Pipeline (e.g., `RegisterHarvestHandler`, `OnWaveSpawnModifier`). Downgrade M5 criterion from "0 lines of code change" to "100% Core/Genre engine reuse via declarative hooks and standard Game Pack Luau extension controllers (<300 LOC glue code)".

---

### F4 [SEVERITY: critical]
- **Claim attacked**: Section 6 (Line 189) & Section 11.3 (Line 189): `| 배포 | 게임 팩의 mantle.yml로 place, 게임패스, 상품, 배지, 썸네일을 게임별로 선언. 모든 게임이 같은 CI 파이프라인 사용 | Mantle, Open Cloud universes·places [R13], rbxcloud | https://github.com/blake-mealey/mantle (★116, push 2026-05-28)`.
- **Attack**: The deployment layer of the entire meta-tool is built on top of an officially abandoned and unmaintained tool. Mantle's official repository explicitly warns in its README header:
  `> [!IMPORTANT]`
  `> Mantle is no longer maintained. Do not expect responses to tickets, bug fixes, or new features.`
  Relying on Mantle as the Infrastructure-as-Code (IaC) backbone for a multi-game commercial factory means:
  1. No support for modern Roblox monetization features (e.g., Subscriptions API, Immersive Ads, new Open Cloud Creator Store asset endpoints).
  2. Any breaking change in Roblox's Open Cloud API authentication (such as OAuth2 scopes or credential rotations) will permanently break the deployment pipeline without upstream fixes.
  3. State drift and lockfile corruption in Mantle cannot be resolved without maintaining an internal fork of a complex Rust codebase.
- **Evidence**: `https://raw.githubusercontent.com/blake-mealey/mantle/main/README.md` -> `Mantle is no longer maintained. Do not expect responses to tickets, bug fixes, or new features.`
- **Fix**: Remove Mantle completely from the architecture. Build a native, lightweight Lune CLI deployment script (`cli/forge/deploy.luau`) that interacts directly with Roblox Open Cloud v2 REST APIs using standard `net.request`. Replace `mantle.yml` with a standard `deploy.json`/`game.yml` schema processed directly by `forge deploy`, utilizing `rbxcloud` CLI (active) as a fallback.

---

### F5 [SEVERITY: critical]
- **Claim attacked**: Section 11.2 (Line 168): `| 코드 | script_read, multi_edit, script_search, script_grep | Rojo를 쓰지 않는 긴급 수정, Studio 쪽 스크립트 점검 |`.
- **Attack**: This creates a fatal "split-brain" architecture with two conflicting sources of truth. 
  1. The entire development workflow (Section 6 & 11.3) establishes Rojo as the single source of truth syncing files from local Git repositories to Roblox Studio.
  2. Allowing an AI agent to use Studio 내장 MCP's `multi_edit` or `script_read` to perform "Rojo를 쓰지 않는 긴급 수정" (emergency edits without Rojo) writes directly into the live Roblox Studio DataModel memory.
  3. When Rojo syncs subsequent file changes from disk, or when an engineer pulls Git commits, Rojo will overwrite the in-memory Studio edits without warning, silently discarding the AI agent's changes. Conversely, if Studio saves over the `.rbxl` file, Git history desynchronizes, causing merge conflicts and untracked code regressions.
  4. Bypassing Git via Studio MCP `multi_edit` destroys audit trails, PR review gates, automated CI linting (Selene/StyLua), and regression testing.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Line 168; `studio-mcp-tools.txt`: lines describing `multi_edit`.
- **Fix**: Forbid `multi_edit` in the AI agent prompt and tool permissions when connected to Studio. Mandate that all code modifications follow a strict unidirectional pipeline: `Agent edits local file on disk -> Selene/StyLua validates -> Git tracks -> Rojo syncs to Studio`. Studio MCP code tools must be restricted to **read-only inspection** (`script_read`, `script_search`, `script_grep`) to verify in-engine script resolution and runtime state.

---

### F6 [SEVERITY: major]
- **Claim attacked**: Section 11.3 (Line 187): `장르 무관 경제 그래프 엔진: 재화, Source(획득처), Sink(소비처), 전환(합성·뽑기·거래), 가격, 확률을 YAML 그래프로 선언하면 forge econ sim이 가상 플레이어 N명 × D일을 돌려 인플레이션, 첫 결제 체감 시점, 재화 병목을 리포트합니다.`
- **Attack**: A static YAML graph of Sources, Sinks, and Conversion rates executed in an isolated Lune script is fundamentally incapable of modeling the core dynamics of *Steal a Kaiju Egg* or competitive multiplayer games:
  1. **Zero-Sum Peer-to-Peer Theft**: In *Steal a Kaiju Egg*, Player A's sink is Player B's source. Theft success is not an independent random distribution; it depends on spatial base proximity, base defense lock timing, active defender presence in the server, and server matchmaking density.
  2. **Player Trading & Market Arbitrage**: Peer-to-peer trading creates floating price discovery, asset hoovering, and black-market conversion rates that a static Markov chain cannot predict.
  3. **Runtime Divergence**: If the economy simulation is run in Lune from a detached YAML file while the actual game executes Luau server scripts, the two will desynchronize the moment a developer tweaks coin generation rates in code. Unless YAML is the single authoritative source that *code-generates* all runtime economy tables, the simulation is useless theater.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Line 187 vs Section 5.1 (Lines 68-72).
- **Fix**: Require the YAML economy schema to be the **authoritative code-generation source** (`econ.yml` compiles to `EconConfig.luau` via a darklua/Lune build step). Upgrade `forge econ sim` from an isolated single-player Monte Carlo simulator to an agent-based multi-actor simulation that explicitly models concurrent player interactions: simulated server instances with N concurrent bots running base-raid behavior, lock cooldown contention, and bilateral trading logic.

---

### F7 [SEVERITY: major]
- **Claim attacked**: Section 11.3 (Lines 183-184): Using Asphalt to upload 3D meshes and models: `forge gen mesh ... -> Assets API 업로드 | Asphalt (Tarmac은 비추천)`.
- **Attack**: Asphalt explicitly warns against using Open Cloud web APIs for 3D model/mesh ingestion. In Asphalt's official README:
  `- 3D Models (.fbx, .gltf, .glb)`
  `- Roblox does not offer control over the import settings through the web API. As such, this is not a route most should take. You should instead use the 3D Importer to upload these assets, then either sync them with Rojo or save them as Roblox model files.`
  Furthermore, the official Roblox Open Cloud Assets API documentation specifies that the raw `Mesh` asset endpoint accepts *only content downloaded from the Asset Delivery API* (`model/x-file-mesh-data`), not arbitrary mesh files. Custom 3D meshes uploaded via Open Cloud Model API lose vertex group data, collision geometry settings, auto-rigging, and material bindings.
- **Evidence**:
  - `https://raw.githubusercontent.com/jackTabsCode/asphalt/master/README.md` -> Supported Asset Types section: 3D Models (.fbx, .gltf, .glb): *"Roblox does not offer control over the import settings through the web API. As such, this is not a route most should take. You should instead use the 3D Importer to upload these assets..."*
  - `https://create.roblox.com/docs/en-us/cloud/guides/usage-assets.md` -> Mesh restrictions: *"Only content downloaded from Asset delivery API is accepted."*
- **Fix**: Remove automated Open Cloud web API mesh uploading from the runtime CLI. Use Studio 내장 MCP's native `generate_mesh` or `insert_asset` directly within an active Studio session, allowing Studio's internal 3D Import pipeline to process mesh decomposition, collision fidelity, and scale properly. Export resulting instances into `assets/models/*.rbxm` tracked via Git and synced by Rojo.

---

### F8 [SEVERITY: major]
- **Claim attacked**: Section 6 (Line 105) & Section 11.3 (Line 187): Using Lune for offline simulation and testing: `Lune: Studio 밖 Luau 실행: 빌드 스크립트, Open Cloud 호출, 테스트 러너` and `forge econ sim: Lune, Studio MCP execute_luau`.
- **Attack**: Lune is a standalone Luau CLI runtime that completely lacks the Roblox Engine C++ API. 
  1. Lune does not define globals such as `game`, `Workspace`, `Instance.new`, `RunService`, `DataStoreService`, `Players`, `HttpService`, or `TweenService`.
  2. Game code in Section 6 heavily depends on `ProfileStore`, `ByteNet`, and `Fusion`. None of these libraries can run inside Lune without mock shims. If `forge econ sim` or test suites attempt to require game code that touches `game:GetService(...)` or creates Roblox Instances, Lune will crash immediately with runtime nil-index errors.
  3. The plan fails to specify an abstraction layer decoupling pure domain logic from Roblox engine dependencies.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Line 105, 187; Lune repository specifications (`lune-org/lune`).
- **Fix**: Architect the `core/` Luau packages into a strict hexagonal / ports-and-adapters architecture:
  - `core/domain/`: Pure Luau business logic (math, state machines, progression formulas, inventory calculations) containing ZERO references to `game`, `Instance`, or Roblox services. This layer runs natively in Lune for instant CLI testing and economic simulations.
  - `core/infra/`: Roblox-dependent adapters (`DataStoreProfileStoreAdapter.luau`, `ReplicationByteNetAdapter.luau`) executed exclusively inside Studio or via Open Cloud Luau Execution API.

---

### F9 [SEVERITY: major]
- **Claim attacked**: Section 11.5 (Lines 204-223): Monorepo structure containing `core/`, `genres/`, and `games/` on a single branch with automated deployment triggered on `main` push: `변경된 층 기준으로 영향받는 모든 게임을 테스트·배포`.
- **Attack**: Operating multiple commercial games in a single unversioned monorepo creates catastrophic blast-radius exposure:
  1. If an engineer or AI agent updates `core/economy` or `core/data` to fix an issue in Game #2 (*Grow and Defend Garden*), pushing to `main` automatically triggers deployment pipelines across *all* games, including live production Game #1 (*Steal a Kaiju Egg*).
  2. A subtle regression in `core/data` (e.g., ProfileStore session release logic) will corrupt player save data across all live games simultaneously.
  3. Without semantic versioning (`semver`) and dependency pinning (e.g., Wally lockfiles per game), games cannot be maintained on stable releases while Core advances.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Lines 204-223 (`roblox-game-forge/` monorepo layout).
- **Fix**: Decouple `core/` and `genres/` into versioned packages managed via a local Wally registry or Git submodules. Each game in `games/<slug>` must maintain its own `wally.toml` and `wally.lock`, explicitly pinning dependencies to specific semantic versions (e.g., `forge-core = "1.2.0"`). Core updates must require an explicit dependency bump and validation PR in each individual game directory before deployment.

---

### F10 [SEVERITY: major]
- **Claim attacked**: Section 11.3 (Lines 183-185) & Section 11.6 (Line 227): Fully automated asset generation and deployment pipeline: `프롬프트 한 줄로 에셋이 게임 팩에 들어가고 screen_capture로 확인됨`.
- **Attack**: The plan completely ignores Roblox's asynchronous asset moderation delay and moderation failure modes:
  1. Every uploaded asset (image, mesh texture, audio) is subjected to automated and manual moderation review before becoming visible in-game.
  2. Moderation latency ranges from 5 minutes to over 24 hours. During this pending state, textures render as solid gray/invisible, and audio fails to load (`Asset is not approved for use`).
  3. Automated visual QA (`screen_capture` via Studio MCP) will fail or capture untextured placeholder assets if run immediately after asset generation.
  4. AI-generated textures and audio regularly trigger false-positive moderation flags, which can result in temporary universe suspension or developer account moderation strikes. A fully automated unattended pipeline risks getting production universes banned.
- **Evidence**: Official Roblox Creator Hub Moderation Guidelines; `official-docs-check.json`.
- **Fix**: Introduce an asynchronous **Asset Moderation Quarantine Buffer**:
  1. Newly generated assets must be assigned a `PendingModeration` state in the asset manifest.
  2. CI/CD automated QA must poll asset moderation status via Open Cloud Assets API or verify texture loading before triggering `screen_capture` validation.
  3. Production deployments must strictly require a human asset clearance gate, verifying that zero assets in the deployment bundle are unapproved or pending review.

---

### F11 [SEVERITY: major]
- **Claim attacked**: Section 11.3 (Line 188) & Section 11.6 (Line 230): Automated multi-game CI using Luau Execution API: `장르 모듈이 제공하는 시나리오 템플릿(튜토리얼, 핵심 루프 1회, 첫 구매, 저장·재접속)을 게임 팩 설정으로 채워 실행 | Luau Execution API [R12], place-ci-cd-demo`.
- **Attack**: The Open Cloud Luau Execution API enforces strict quota boundaries that make it unsuitable for running end-to-end multi-game playtest matrices:
  1. **Execution Time Limit**: Tasks have a hard execution cap of **up to 5 minutes**. Any comprehensive playtest scenario verifying a full core loop (tutorial -> egg hatch -> coin generation -> base theft -> save/reconnect) will easily exceed 5 minutes, resulting in forced termination.
  2. **Concurrency Limit**: Roblox enforces a strict limit of **10 concurrent tasks per place/universe**. In a monorepo setup where a commit to `core/` triggers parallel testing across multiple game packs, test tasks will be throttled and rejected with HTTP 429 errors.
  3. Luau Execution runs headlessly on a bare server; it does not simulate client rendering, user mouse input, or GUI screen captures.
- **Evidence**: `https://create.roblox.com/docs/en-us/cloud/reference/features/luau-execution.md` -> *"Tasks can run for up to 5 minutes, with a limit of 10 concurrent tasks per place."*
- **Fix**: Use Luau Execution API strictly for fast, headless integration smoke tests (<60 seconds, verifying DataStore schemas and network buffer serialization). For long-form gameplay QA and visual verification, rely on dedicated, local headless Studio instances driven by Lune or Studio MCP playtest subagents with queue management to respect rate limits.

---

### F12 [SEVERITY: major]
- **Claim attacked**: Section 11.3 (Line 183): Recommending `ahujasid/mcp-for-blender` for automated 3D mesh processing in the AI toolchain (`Blender 정리(폴리곤 예산은 게임 팩 설정)`).
- **Attack**: `mcp-for-blender` introduces a severe remote code execution (RCE) security vulnerability into the automated pipeline:
  1. The server operates by opening an unauthenticated local TCP socket (default port 9876) communicating directly with a Blender Python add-on.
  2. Incoming commands execute raw, unsanitized Python code directly inside Blender's embedded Python interpreter (`bpy`).
  3. In an automated agent workflow where an LLM generates geometry processing scripts, any prompt injection or malformed script can execute arbitrary OS commands via Python's `os.system`, `subprocess`, or file I/O APIs, completely compromising the CI/developer host environment.
- **Evidence**: `https://raw.githubusercontent.com/ahujasid/mcp-for-blender/main/README.md` -> Architecture and setup specifications (`uvx mcp-for-blender`, local TCP socket).
- **Fix**: Replace `mcp-for-blender` with deterministic, standalone headless Python scripts (`blender --background --python scripts/cleanup_mesh.py -- --poly-budget <limit>`) executed in isolated ephemeral containers. The script parameters (decimation ratio, origin centering, UV unwrapping) must be strictly validated CLI flags, preventing LLMs from injecting arbitrary Python commands into Blender.

---

### F13 [SEVERITY: major]
- **Claim attacked**: Section 8 (Line 147): Mitigating movement exploits in one line: `익스플로잇(속도·텔레포트) | 서버 측 이동 검증, RemoteEvent 레이트 리밋`.
- **Attack**: Section 8 severely underestimates the complexity of anti-exploit in Roblox, and Section 11 completely omits an authoritative movement module from Core.
  1. In Roblox, physical character movement is client-authoritative by default. In a game whose core loop is *literally stealing physical eggs/kaijus and carrying them back to base*, client-side speed hacks, noclip, physics desync, and teleport exploits are fatal to the game economy.
  2. If an exploiter teleports into a base, grabs an egg, and teleports back in a single network frame, naive "RemoteEvent rate limiting" does nothing because the physics movement itself bypasses RemoteEvents.
  3. Implementing robust server-side movement verification on Roblox requires tick-based position history tracking, raycast trajectory validation against Workspace geometry, and server-side carry state management. Putting zero architecture for this in `core/` means every game pack will either re-invent flawed anti-cheat or collapse under exploiter raids.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Line 147 vs Section 5.1 (Lines 68-72).
- **Fix**: Add `core/anticheat/` to the Core architecture in Section 11.5. This module must provide:
  - Server-authoritative carrying state machine (`CarryService`): eggs/kaijus are attached via server-side Motor6D/Weld, not client physics.
  - Spatial validation middleware: verifies Euclidean distance traveled per second (`SpeedValidator`), raycasting backwards along the movement vector to detect wall noclip.
  - Server-side interaction range verification before validating any steal action.

---

### F14 [SEVERITY: minor]
- **Claim attacked**: Section 7 (Line 132) & Section 11.6 (Lines 224-235): Completing meta-tool milestones M1 through M4 *before* Week 0 of a 12-week schedule with an unstated team size (`§7의 W0는 M1-M4 완료 후 시작합니다`).
- **Attack**: The schedule is completely detached from engineering reality:
  1. Building M1-M4 requires: a full monorepo toolchain, an automated 3D mesh generation/cleanup pipeline, a generative sound pipeline, a cross-genre economy graph simulation engine, an automated multi-game CI/CD infrastructure, an automated localization pipeline, and Studio MCP automated playtest harness.
  2. For a small or solo developer team, building this enterprise-grade platform from scratch would take 3 to 6 months of full-time systems engineering *before writing a single line of game code*.
  3. Attempting to compress this entire engine build into a "pre-W0 setup" phase while committing to launch Game #1 in Week 4 guarantees either that the meta-tool is never finished, or that Game #1 launches as broken, unpolished shovelware.
- **Evidence**: `ROBLOX_VIRAL_GAME_PLAN.md`: Line 132, Lines 224-235.
- **Fix**: Restructure the project from a "waterfall meta-tool first" plan to an **"extract-as-you-build" agile strategy**:
  - W0-W3: Build Game #1 (*Steal a Kaiju Egg*) directly using standard established tools (Rojo, Wally, ProfileStore, ByteNet).
  - W4: Soft-launch Game #1.
  - W5-W8: Extract validated patterns from Game #1 into `core/` (data, economy, monetization).
  - W9+: Build the first Genre Module (`collect-steal`) and test reuse on Game #2.

---

### F15 [SEVERITY: minor]
- **Claim attacked**: Section 6 (Line 119): `| Immersive Ads / 광고 | 게임 내 광고 수익 | 수익화 | https://create.roblox.com/docs/production/monetization/immersive-ads (HTTP 200 확인) |`.
- **Attack**: The documentation verification is demonstrably inaccurate. Live inspection of `official-docs-check.json` (and official Roblox Creator Hub routing) reveals that `https://create.roblox.com/docs/production/monetization/immersive-ads` returned an HTTP 404 Next.js error page (`"page":"/404"`). The author claimed "HTTP 200 확인" without verifying that the response was not a client-rendered 404 page. The actual official URL for Immersive Ads documentation on Roblox is `/docs/en-us/monetization/immersive-ads`. Relying on unverified or broken documentation links introduces friction and hallucinated parameters into AI agent tool usage.
- **Evidence**:
  - `ROBLOX_VIRAL_GAME_PLAN.md`: Line 119.
  - `official-docs-check.json`: `"ads": { "status": 404, "hits": [..., "{\"props\":{\"pageProps\":{}},\"page\":\"/404\",...}"] }`.
- **Fix**: Update the documentation URL in Section 6 and Section 10 [R5] to the correct canonical URL (`https://create.roblox.com/docs/en-us/monetization/immersive-ads`), and add a build-time link-checker in CI that verifies both HTTP status code and non-404 DOM content for all referenced documentation endpoints.
assistant: > I read this as acknowledgment of the child task completion (`skeptic-evidence`) - verifying that both the Engineering/Tooling and Business/Evidence adversarial audits are finalized. I'll stop now as all deliverables are complete.

모든 감사가 완료되었습니다. 목표는 이미 완수(`status: complete`) 상태이며, 두 개의 독립적인 적대적 리뷰(총 30개 지적 사항)가 모두 실측 증거와 함께 도출되었습니다:

1. **엔지니어링 & 툴체인 적대적 리뷰 (Engineering & Tooling Review)**:
   - F1~F15: 생성 AI 라이선스 위반(AudioCraft CC-BY-NC, Roblox Cube RAIL 연구용 제한, Hunyuan3D-2 한국/EU/UK 제외), Open Cloud 오디오 업로드 월 100건 하드 리밋, M5 '코드 수정 0줄' 3층 분리 허구성, Mantle 공식 개발 중단(Abandoned), Rojo vs Studio MCP `multi_edit` 두 개의 진실 원천 충돌, Lune 런타임 엔진 API 부재, Blender MCP RCE 보안 취약점 등 15개 항목 보고 완료.

2. **비즈니스 로직 & 데이터셋 적대적 리뷰 (Business Logic & Evidence Review, `st_01a0e6d5`)**:
   - F1~F15: Top 10 누적 방문수 왜곡(Adopt Me/Blox Fruits 허위 비교), 알고리즘 신호(Discovery R6)와 외부 광고/숏폼 유입 전략의 정면 모순, Steal a Brainrot 미국 저작권(PA002544969) 침해 및 연방 소송 리스크, 누적 스톡과 최근 플로우 혼동, PolicyService 가챠 차단 지역 대응 부재, Grow a Garden CCU 99.9% 붕괴(22.3M → 2.1만) 간과 등 15개 항목 검증 완료.

추가적인 백그라운드 태스크나 열린 작업 없이 전체 리뷰 작업이 성공적으로 종결되었습니다.