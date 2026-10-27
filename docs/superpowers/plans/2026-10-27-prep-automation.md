# 실행 준비 자동화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** QA 맥 앱이 실행 준비(Artemis·테스트 서버 띄우기, 기기 점검, 빌드 건너뛰기, 빌드·설치·권한·로그인, 시나리오별 초기화)를 Claude Code 없이 셸로 직접 한다.

**Architecture:** 판단과 셸 호출은 전부 `QATwinCore`의 작은 단위(설정 읽기·빌드 env·설치 기록·로그인 규칙·기기 점검·자식 프로세스·준비 조정자)로 두고 Fake로 테스트한다. `QATwinApp`은 승인 시트의 점검 묶음, 새 준비 화면, `AppModel` 연결만 맡는다. 초기화·재로그인은 `RunOrchestrator`가 시나리오 직전에 한다.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftPM, SwiftUI macOS 26, Swift Testing, bash(`tools/android-login.sh`).

**Spec:** `docs/superpowers/specs/2026-10-27-prep-automation-design.md` (절 번호는 이 문서 기준). 화면은 `docs/superpowers/mockups/qa-mac-app/Approval2.dc.html`·`Prepare.dc.html`.

## Global Constraints

- 원본 repo는 읽기 전용. 빌드 전후 `git -C <소스> status --porcelain`·`git diff | shasum`이 다르면 실패로 멈추고 되돌리지 않는다.
- 셸 명령은 `"$SHELL" -lic '<export …;> <명령>'`, stdin `/dev/null`. `ARTEMIS_HOME`·`ARTEMIS_TRACES_DIR`·`QA_APP_ENV`는 명령 문자열 앞 `export`로 넣는다(프로세스 환경 아님). `adb`는 설정·기본 경로 실행 파일을 바로 부른다.
- 가릴 값: `accounts`의 키 값 + 키 이름에 `KEY`·`SECRET`·`TOKEN`·`PASS`가 든 키 값(대소문자 무시). 화면·`prepare.log`·run-state·알림 어디에도 가리기 전 값이 나오지 않는다.
- Artemis 쓰기 API(`POST /api/run`·`/api/stop`)는 승인 뒤 실행 루프만. 준비는 `GET /api/devices`만.
- 시간 제한: Artemis 응답 60초 · health `start_timeout`(기본 60) · 빌드 20분 · 설치 3분 · `pm grant` 묶음 30초 · 로그인 120초 · `pm clear` 30초 · adb 점검 20초. 잠금 대기는 무제한.
- 화면 문구는 한국어 "~해요" 체. 기존 색 토큰(`Color.qa*`)·간격을 쓰고 새 디자인을 만들지 않는다.
- 프로젝트 폴더(`personal/*`·`company/*`) 파일은 이 브랜치에서 고치지 않는다(AGENTS.md "작업 위치와 커밋"). 등록된 두 프로젝트의 `project.yaml` 이관은 Task 11에서 메인 작업 트리로 따로 한다.

## Review Focus

1. **값에 셸 특수문자가 든 설정·경로**(`ARTEMIS_HOME`에 공백·작은따옴표, 소스 경로에 공백) — 명령이 깨지거나 다른 명령이 실행되면 안 된다. → Task 4 `loginShellCommandQuotesValues`.
2. **`.env`에 같은 키가 두 번, 따옴표 값, 빈 값** — 빌드 env는 첫 등장 값을 쓰고(`EnvFile.upsert`가 첫 줄을 고치므로 그 줄이 사용자가 마지막으로 넣은 값이다), 따옴표를 벗기고, 해시가 실행마다 같아야 한다. → Task 2 `buildEnvIsStableAndUsesFirstOccurrence`.
3. **앱이 띄운 서버가 응답 전에 죽음 / 이미 다른 프로세스가 포트를 씀** — 기다리지 않고 바로 실패, 출력 끝부분이 상세에 나온다. → Task 4 `managedProcessReportsEarlyExit`, Task 7 `prepareFailsFastWhenServerExits`.
4. **준비 중 취소·앱 종료** — 자식 프로세스 그룹이 남지 않고 실행 폴더가 생기지 않는다. → Task 7 `cancelStopsChildAndCreatesNoRunDir`.
5. **로그인 시나리오가 중간에 처음 나오거나 초기화 칸과 겹침** — 로그인은 정확히 한 번, 올바른 시점에. → Task 5 `loginPlan*` 표 테스트.

---

## File Structure

| 파일 | 책임 |
| --- | --- |
| `app/Sources/QATwinCore/ProjectConfig.swift` (새) | `project.yaml`의 `apps.android`·`build`·`environments.<이름>` 하위 키를 읽는다 |
| `app/Sources/QATwinCore/BuildEnv.swift` (새) | 빌드용 임시 env 내용·해시, `{{mac_ip}}` 치환, 가릴 키 기준 |
| `app/Sources/QATwinCore/InstallRecord.swift` (새) | `.install.json` 읽기·쓰기, 빌드 건너뛰기 판단 |
| `app/Sources/QATwinCore/ManagedProcess.swift` (새) | 로그인 셸 명령 조립, 오래 도는 자식 프로세스 그룹(시작·출력 끝·조기 종료·끝내기) |
| `app/Sources/QATwinCore/LoginPlan.swift` (새) | 로그인 시점·역할 규칙(5.7 표), `android-login.sh` 종료 코드 해석 |
| `app/Sources/QATwinCore/DeviceProbe.swift` (새) | adb 점검(연결·잠금·Wi-Fi·방해 금지·알림 권한·AVD 이름) |
| `app/Sources/QATwinCore/PrepareCoordinator.swift` (새) | 준비 항목 순서·상태·시간 제한·로그, 이벤트 스트림 |
| `app/Sources/QATwinCore/PrepareLog.swift` (새) | 가린 줄 쓰기(App Support → `artifacts/prepare.log` 이동) |
| `app/Sources/QATwinCore/PlanDocument.swift` | `resetsAppData`, `needsLogin` 공개 |
| `app/Sources/QATwinCore/RunOrchestrator.swift` | `preparing` 상태, 초기화·재로그인 경로, `RunStateFile.prepare` |
| `app/Sources/QATwinCore/ClaudeRunner.swift`·`StageRecord.swift` | `Stage.prepare`·`StagePrompt.prepare` 삭제 |
| `app/Sources/QATwinApp/ApprovalSheet.swift`·`AccountsSection.swift` | 준비 점검 묶음, 로그인 역할, 테스트 env·가져오기 |
| `app/Sources/QATwinApp/PrepareView.swift` (새) | 준비 진행 화면(목업 4a) |
| `app/Sources/QATwinApp/AppModel.swift`·`QATwinApp.swift`·`PlanListView.swift`·`RunProgressView.swift`·`StageRunView.swift` | 연결·단계 표시·초기화 칩 |
| `tools/android-login.sh`, `tools/tests/android-login-test.sh` (새) | `--tap`·`--wait`·종료 코드 7, stub adb 테스트 |
| `templates/project.yaml`·`templates/test_plan.md`·`.gitignore`·`AGENTS.md`·`README.md`·`tools/artemis.md`·`.claude/skills/qa-*/SKILL.md` | 문서·양식 |

공통 테스트 도구: `app/Tests/QATwinCoreTests/TestSupport.swift`(새)에 `RecordingShell`(호출 기록 + 명령 패턴별 응답 `[(match: String, status: Int32, out: String)]`, 매칭 안 되면 `(0, "")`)과 `tempDir()`를 둔다. Task 2에서 만들고 이후 task가 쓴다. 기존 `RunOrchestratorTests`의 private `FakeShellRunner`는 그대로 둔다.

---

### Task 1: `project.yaml` 하위 키 읽기

**Files:**
- Create: `app/Sources/QATwinCore/ProjectConfig.swift`
- Modify: `templates/project.yaml` (5.1 예시: `apps.android.permissions`, `environments.local.{health,start,cwd,start_timeout,vars}`, `build.android`의 `$QA_APP_ENV`, `build.env_source`)
- Test: `app/Tests/QATwinCoreTests/ProjectConfigTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ServerConfig: Equatable, Sendable { public let name: String; public let health: String?; public let start: String?; public let cwd: String; public let startTimeout: Int; public let vars: [String: String] }  // cwd 기본 ".", startTimeout 기본 60
  public struct ProjectConfig: Equatable, Sendable {
      public let package: String?; public let launch: String?; public let permissions: [String]
      public let buildAndroid: String?; public let androidAPK: String?; public let envSource: String  // 기본 ".env"
      public let defaultServer: String?; public let servers: [String: ServerConfig]
      public var usesQAAppEnv: Bool  // buildAndroid에 "$QA_APP_ENV" 포함
      public static func parse(_ yaml: String) -> ProjectConfig
  }
  ```
  `servers`에는 하위 키가 없는 이름(`dev:` 한 줄)도 기본값으로 들어간다. `default:`는 서버가 아니다. 줄 끝 `# 주석`은 무시한다. `vars`는 한 줄 `{ K: "v", K2: v2 }` 형식만 읽는다.

- [ ] **Step 1: 실패하는 테스트** — `parsesServerSubkeysAndDefaults()`: 5.1 예시 YAML을 넣어 `servers["local"]!.health == "http://{{mac_ip}}:5199/health"`, `.start == "server/run.sh --urls http://0.0.0.0:5199"`, `.startTimeout == 180`, `.vars == ["API_BASE_URL": "http://{{mac_ip}}:5199"]`, `servers["dev"]!.cwd == "."`, `.startTimeout == 60`, `defaultServer == "local"`, `permissions == ["android.permission.ACCESS_FINE_LOCATION", "android.permission.POST_NOTIFICATIONS"]`, `usesQAAppEnv == true`. `parsesLegacyProjectYAML()`: 기존 fixture(`Fixtures/ws/personal/demo_app/project.yaml`)와 `templates/project.yaml` 이전 모양(`default: dev`만)에서 크래시 없이 `servers.keys == ["dev"]`·`usesQAAppEnv == false`.
- [ ] **Step 2:** `swift test --package-path app --filter ProjectConfigTests` → FAIL (`ProjectConfig` 없음).
- [ ] **Step 3:** `ProjectConfig.parse` 구현 — `Workspace.accountsBlock`처럼 들여쓰기 기반 줄 파서(외부 YAML 라이브러리 추가 금지). `templates/project.yaml` 갱신.
- [ ] **Step 4:** 같은 명령 → PASS.
- [ ] **Step 5:** 커밋 `feat(app): project.yaml 서버·권한·빌드 하위 키 읽기`.

### Task 2: 빌드 env와 가릴 값 기준

**Files:**
- Create: `app/Sources/QATwinCore/BuildEnv.swift`, `app/Tests/QATwinCoreTests/TestSupport.swift`
- Modify: `app/Sources/QATwinApp/AppModel.swift` (`stageSecretValues`·`runSecretValues`를 `SecretKeys.values`로)
- Test: `app/Tests/QATwinCoreTests/BuildEnvTests.swift`

**Interfaces:**
- Consumes: `ProjectConfig`·`ServerConfig`(Task 1), `Workspace.accountRoles(projectYAML:)`, `EnvFile`.
- Produces:
  ```swift
  public enum SecretKeys {
      public static func isSecret(_ key: String, accountKeys: Set<String>) -> Bool
      public static func values(envURL: URL, accountKeys: Set<String>) -> [String]   // 가릴 값만
  }
  public struct BuildEnv: Equatable, Sendable {
      public let contents: String; public let sha256: String
      public static func make(envURL: URL, accountKeys: Set<String>, server: ServerConfig, macIP: String) -> BuildEnv
      public func write(to dir: URL) throws -> URL   // 0600, 파일명 "qa-app-<uuid>.env"
  }
  public enum MacIP { public static func current(shell: ShellRunner) async -> String? }  // `route -n get default`의 interface → `ipconfig getifaddr <if>`
  extension EnvFile { public func entriesInOrder() -> [(key: String, value: String)] }  // 첫 등장 키만, 값은 따옴표 벗김
  ```
  `contents`: `.env` 키를 나온 순서대로, account 키 제외, `vars`로 덮어쓰고 없던 `vars` 키는 끝에 이름순으로, 모든 값의 `{{mac_ip}}` 치환, 한 줄 `KEY=value`, 끝에 줄바꿈.

- [ ] **Step 1: 테스트** — `secretKeysMatchAccountsAndNames()`: `isSecret("TEST_USER_ID", accountKeys: ["TEST_USER_ID"])`, `isSecret("naver_secret", accountKeys: [])`, `isSecret("API_KEY", …)`, `isSecret("DB_PW", …)` 참, `isSecret("API_BASE_URL", accountKeys: [])` 거짓. `buildEnvExcludesAccountsAndAppliesVars()`: `.env` = `TEST_USER_ID=u\nAPI_BASE_URL=http://old\nMAP_ID="m"\n` · vars `["API_BASE_URL": "http://{{mac_ip}}:5199"]` · macIP `"192.168.0.12"` → `contents == "API_BASE_URL=http://192.168.0.12:5199\nMAP_ID=m\n"`. `buildEnvIsStableAndUsesFirstOccurrence()`: `.env`에 `A=1\nA=2` → `A=1`, 두 번 만든 `sha256`이 같다. `buildEnvFileIsPrivate()`: `write(to:)` 결과 권한 `0o600`.
- [ ] **Step 2:** `swift test --package-path app --filter BuildEnvTests` → FAIL.
- [ ] **Step 3:** 구현(`CryptoKit.SHA256`). `AppModel`의 두 가리기 목록을 `SecretKeys.values(envURL:accountKeys:)`로 바꾸고 accountKeys는 `Workspace.accountEnvKeys(projectYAML:)`.
- [ ] **Step 4:** `swift test --package-path app` 전체 → PASS (기존 `SecretRedactorTests` 포함).
- [ ] **Step 5:** 커밋 `feat(app): 빌드용 env(계정 키 제외·서버 vars·맥 IP)와 가릴 값 기준`.

### Task 3: 설치 기록과 빌드 건너뛰기

**Files:**
- Create: `app/Sources/QATwinCore/InstallRecord.swift`
- Modify: `.gitignore`(`.install.json`), `AGENTS.md` 폴더 구조에 `.install.json   이 기기에 설치한 빌드 기록 (git 제외)`
- Test: `app/Tests/QATwinCoreTests/InstallRecordTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct InstallEntry: Codable, Equatable, Sendable { public var package: String; public var commit: String; public var dirty: Bool; public var envSHA256: String; public var at: Date }  // JSON 키 "env_sha256"
  public struct InstallRecords: Sendable {
      public static func load(projectDir: URL) -> [String: InstallEntry]          // 없거나 깨지면 [:]
      public static func save(_ entry: InstallEntry, serial: String, projectDir: URL) throws  // 다른 serial 보존
  }
  public enum BuildSkip: Equatable, Sendable {
      case skip
      case build(reason: String)
      public static func decide(entry: InstallEntry?, headCommit: String, sourceDirty: Bool, envSHA256: String, packageInstalled: Bool, forceRebuild: Bool) -> BuildSkip
  }
  ```
  `reason` 문구(그대로): 기록 없음 `"이 기기에 설치한 기록이 없어요"` · 설치본 dirty `"설치본이 커밋하지 않은 변경으로 빌드됐어요"` · 소스 dirty `"소스에 커밋하지 않은 변경이 있어요"` · 커밋 `"설치본 \(entry.commit) ≠ 소스 \(headCommit)"` · env `"서버 설정이 바뀌었어요"` · 미설치 `"기기에 앱이 없어요"` · 강제 `"다시 빌드를 골랐어요"`. 이 순서로 처음 걸린 것.

- [ ] **Step 1: 테스트** — `buildSkipDecidesInOrder()`: 조건별 7케이스 + 모두 맞으면 `.skip`. `installRecordsKeepOtherSerials()`: A 저장 → B 저장 → `load`에 둘 다.
- [ ] **Step 2:** `--filter InstallRecordTests` → FAIL. **Step 3:** 구현. **Step 4:** PASS. **Step 5:** 커밋 `feat(app): 기기별 설치 기록과 빌드 건너뛰기 판단`.

### Task 4: 로그인 셸 명령과 자식 프로세스

**Files:**
- Create: `app/Sources/QATwinCore/ManagedProcess.swift`
- Test: `app/Tests/QATwinCoreTests/ManagedProcessTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum LoginShell {
      public static func command(_ body: String, exports: [(String, String)]) -> String   // "export K='v'; …; body"
      public static func arguments(_ body: String, exports: [(String, String)]) -> (exe: String, args: [String])  // ($SHELL ?? "/bin/zsh", ["-lic", command])
  }
  public final class ManagedProcess: @unchecked Sendable {
      public init(exe: String, args: [String], cwd: URL, logURL: URL?)
      public func start() throws
      public var isRunning: Bool { get }
      public var exitStatus: Int32? { get }
      public func tail(lines: Int) -> String           // 마지막 n줄(가리지 않은 원문 — 호출자가 가린다)
      public func terminate() async                     // 그룹 SIGTERM → 2초 → SIGKILL
  }
  ```
  `command`의 값은 작은따옴표로 감싸고 내부 `'`는 `'\''`로. 출력은 별도 스레드에서 계속 읽어(파이프가 차서 멈추지 않게) 메모리에 최근 64KB, `logURL`이 있으면 파일에도 덧붙인다. 프로세스 그룹 처리는 `ProcessShellRunner`의 `terminateGroup`과 같은 방식.

- [ ] **Step 1: 테스트** — `loginShellCommandQuotesValues()`: `command("cd \"$ARTEMIS_HOME\" && ls", exports: [("ARTEMIS_HOME", "/a b/it's")])` == `"export ARTEMIS_HOME='/a b/it'\\''s'; cd \"$ARTEMIS_HOME\" && ls"`. `managedProcessReportsEarlyExit()`: `/bin/sh -c "echo boom; exit 3"` 시작 → 1초 안에 `isRunning == false`, `exitStatus == 3`, `tail(lines: 5).contains("boom")`. `terminateKillsGroup()`: `/bin/sh -c "sleep 30 & sleep 30"` → `terminate()` 뒤 그룹의 모든 pid가 사라짐(`kill(-pgid, 0) != 0`).
- [ ] **Step 2:** FAIL. **Step 3:** 구현. **Step 4:** PASS. **Step 5:** 커밋 `feat(app): 로그인 셸 명령과 오래 도는 자식 프로세스 관리`.

### Task 5: 로그인 규칙과 `android-login.sh --tap`

**Files:**
- Create: `app/Sources/QATwinCore/LoginPlan.swift`, `tools/tests/android-login-test.sh`, `tools/tests/fixtures/` (덤프 XML 4개)
- Modify: `tools/android-login.sh`, `app/Sources/QATwinCore/PlanDocument.swift` (`needsLogin`을 `public static`으로)
- Test: `app/Tests/QATwinCoreTests/LoginPlanTests.swift`

**Interfaces:**
- Consumes: `Scenario.accountRoleKey`, `Scenario.resetsAppData`(Task 8에서 생기므로 이 task에서 `Scenario`에 `public var resetsAppData: Bool = false` 필드만 먼저 더한다 — 파싱은 Task 8), `AccountRole`.
- Produces:
  ```swift
  public struct LoginPlan: Equatable, Sendable {
      public enum When: Equatable, Sendable { case none, duringPrepare, beforeScenario(String) }
      public let when: When; public let role: String?
      public static func make(scenarios: [Scenario], roles: [String: AccountRole], chosenRole: String?) -> LoginPlan
      public static func defaultRole(scenarios: [Scenario], roles: [String: AccountRole]) -> String?
      /// 그 시나리오 앞(초기화 뒤)에서 쓸 역할: 시나리오 역할 키 → chosenRole
      public static func role(for scenario: Scenario, chosenRole: String?, roles: [String: AccountRole]) -> String?
  }
  public enum LoginOutcome: Equatable, Sendable {
      case loggedIn, alreadyLoggedIn
      case retryOnce(String)        // 5 + 네트워크 문구
      case failed(String)
      public static func interpret(status: Int32, output: String, freshInstallOrReset: Bool) -> LoginOutcome
  }
  ```
  `interpret`: 0 → `.loggedIn`. 7 → `freshInstallOrReset ? .failed("로그인 화면을 찾지 못했어요 — 권한 요청 창이나 온보딩이 가리고 있을 수 있어요") : .alreadyLoggedIn`. 5이고 출력에 `네트워크`·`연결`·`network`(대소문자 무시) → `.retryOnce(출력 마지막 줄)`. 그 밖 → `.failed(출력 마지막 비어 있지 않은 줄)`.
  `android-login.sh`: 머리 주석에 `--tap <글자>`·`--wait <초>`(기본 30)·종료 코드 `7 로그인 화면을 못 찾음`(4는 `입력 중 칸이 사라짐·포커스 안 됨`)을 적는다. 옵션은 위치 인자 4개 뒤에 온다. 옵션이 없으면 지금 동작 그대로. 오류 문구 기준은 스펙 5.7 그대로.

- [ ] **Step 1: Swift 테스트** — `loginPlanFirstScenarioLogsInDuringPrepare()`: [A(계정 `` `user` ``)] → `.duringPrepare`, role `"user"`. `loginPlanSkipsPrepareWhenFirstLoginResets()`: [A(계정, resetsAppData)] → `.beforeScenario("A")`. `loginPlanWaitsForFirstLoginScenario()`: [L(`로그아웃 상태`), A(계정)] → `.beforeScenario("A")`. `loginPlanNone()`: 계정 없는 시나리오만, 또는 roles 비었음 → `.none`. `defaultRoleFallsBack()`: 역할 키 없음 + roles 하나 → 그 키, 여럿 → 이름순 첫 번째. `loginOutcomeInterpretsCodes()`: 위 규칙 6케이스.
- [ ] **Step 2: 셸 테스트** — `tools/tests/android-login-test.sh`: 임시 dir에 `adb` stub(`shell uiautomator dump`/`cat`은 순서대로 fixture XML을 돌려주고 `input`·`rm`·`get-state`·`dumpsys input_method`는 성공)을 PATH 앞에 두고 네 경우를 확인한다 — 로그인 화면 없음 → 종료 7 · `--tap 로그인 --wait 4`에서 탭 뒤 칸이 사라진 덤프 → 0 · 새 텍스트 "비밀번호가 올바르지 않습니다." → 5와 그 문구 출력 · "로그인 중…"만 뜬 채 4초 → 5 "응답 없음". 옵션 없이 부르면 기존처럼 입력 확인까지만 하고 0. 실행: `bash tools/tests/android-login-test.sh` → 처음엔 FAIL.
- [ ] **Step 3:** `LoginPlan` 구현, 스크립트 수정.
- [ ] **Step 4:** `swift test --package-path app --filter LoginPlanTests` PASS, `bash tools/tests/android-login-test.sh` → `ok 5/5`.
- [ ] **Step 5:** 커밋 `feat(app): 로그인 시점·역할 규칙, android-login.sh --tap·--wait·종료 코드 7`.

### Task 6: 기기 점검

**Files:**
- Create: `app/Sources/QATwinCore/DeviceProbe.swift`
- Test: `app/Tests/QATwinCoreTests/DeviceProbeTests.swift`

**Interfaces:**
- Consumes: `ShellRunner`, `RecordingShell`(Task 2).
- Produces:
  ```swift
  public struct DeviceStatus: Equatable, Sendable {
      public var connected: Bool; public var locked: Bool?; public var wifiConnected: Bool?   // 에뮬레이터면 nil
      public var dndOn: Bool?; public var notificationsAllowed: Bool?; public var packageInstalled: Bool?
      public var blockers: [String] { get }   // "기기가 연결돼 있지 않아요" · "잠겨 있어요 — 앱이 풀 수 없어요" · "Wi-Fi가 끊겨 있어요"
      public var warnings: [String] { get }   // "방해 금지 모드가 켜져 있어요" · "앱 알림 권한이 없어요"
  }
  public struct DeviceProbe: Sendable {
      public init(shell: ShellRunner, adbPath: String)
      public func status(serial: String, package: String?) async -> DeviceStatus
      public func avdName(serial: String) async -> String?   // emulator- 로 시작할 때만
      public static func isEmulator(_ serial: String) -> Bool
  }
  ```
  `nil`은 "미확인"이며 blocker가 아니다. 잠금: `dumpsys window` 출력의 `mDreamingLockscreen=true` 또는 `isKeyguardShowing=true`(또는 `mShowingLockscreen=true`). Wi-Fi: 기존 `RunOrchestrator.isWifiDown`과 같은 문자열. 방해 금지: `settings get global zen_mode` ≠ `0`. 알림: `dumpsys notification` 대신 `cmd appops get <pkg> POST_NOTIFICATION`에 `deny`/`ignore`. 설치: `pm path <pkg>` 출력이 `package:`로 시작.

- [ ] **Step 1: 테스트** — `deviceProbeReadsLockedAndWifi()`(RecordingShell 응답으로 잠김·Wi-Fi 끊김 → blockers 두 개), `deviceProbeSkipsWifiOnEmulator()`(`emulator-5554` → `wifiConnected == nil`, Wi-Fi 명령 호출 없음), `deviceProbeUnknownIsNotBlocker()`(모든 명령이 빈 출력 → blockers는 연결만 판정, 나머지 nil).
- [ ] **Step 2:** FAIL. **Step 3:** 구현. **Step 4:** PASS. **Step 5:** 커밋 `feat(app): adb 기기 점검(잠금·Wi-Fi·방해 금지·알림·설치)`.

### Task 7: 준비 조정자

**Files:**
- Create: `app/Sources/QATwinCore/PrepareCoordinator.swift`, `app/Sources/QATwinCore/PrepareLog.swift`
- Test: `app/Tests/QATwinCoreTests/PrepareCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1~6 전부, `ArtemisAPI.devices()`, `SecretRedactor.redact`.
- Produces:
  ```swift
  public protocol HealthChecker: Sendable { func isUp(_ url: URL) async -> Bool }   // GET 2xx, 타임아웃 5초
  public struct URLSessionHealthChecker: HealthChecker { public init() }
  public protocol ProcessLauncher: Sendable { func launch(exe: String, args: [String], cwd: URL, logURL: URL?) throws -> ManagedProcess }
  public enum PrepareStep: String, CaseIterable, Sendable { case artemis, server, device, build, install, login, scenarios }
  public enum PrepareItemState: Equatable, Sendable { case waiting, running, done(String), skipped(String), waitingForHuman(String), failed(String) }
  public enum PrepareEvent: Equatable, Sendable { case item(PrepareStep, PrepareItemState); case log(String); case finished(PrepareResult) }
  public struct PrepareResult: Codable, Equatable, Sendable {   // RunStateFile.prepare
      public var artemisStartedByApp: Bool; public var serverStartedByApp: Bool; public var buildSkipped: Bool; public var skipReason: String?
      public var installedCommit: String?; public var sourceCommit: String?; public var planCommit: String; public var loginRole: String?; public var durationSeconds: Int
      public var succeeded: Bool; public var failure: String?
  }
  public struct PrepareInput: Sendable {
      public let projectDir: URL; public let sourceDir: URL; public let config: ProjectConfig; public let serverName: String
      public let serial: String; public let scenarios: [Scenario]; public let plan: PlanDocument; public let loginRole: String?
      public let forceRebuild: Bool; public let artemisURL: URL; public let artemisHome: URL; public let tracesDir: URL?
      public let adbPath: String; public let loginScript: URL; public let logURL: URL
  }
  public actor PrepareCoordinator {
      public init(input: PrepareInput, api: ArtemisAPI, shell: ShellRunner, health: HealthChecker, launcher: ProcessLauncher, clock: any Clock<Duration> = ContinuousClock())
      public nonisolated var events: AsyncStream<PrepareEvent> { get }
      public func run() async                           // .finished를 꼭 낸다
      public func retryFromFailed() async
      public func cancel() async                        // 지금 자식 그룹 종료, .finished(succeeded: false, failure: "사용자 취소")
      public func recheckDevice() async                 // 잠금 대기 중이면 즉시 다시 본다
      public func ownedProcesses() -> [ManagedProcess]  // 앱 종료 때 끝낼 것(Artemis·서버)
      /// 승인 시트용: 실행 없이 점검만. Artemis가 꺼져 있고 루프백이면 띄운다.
      public static func preflight(input: PrepareInput, api: ArtemisAPI, shell: ShellRunner, health: HealthChecker, launcher: ProcessLauncher) async -> (items: [PrepareStep: PrepareItemState], artemis: ManagedProcess?)
  }
  public struct PrepareLog: Sendable {
      public init(url: URL, secrets: [String])
      public func append(step: PrepareStep, _ text: String)   // "HH:mm:ss  <step>  <가린 text>"
      public func move(toRunDir runDir: URL) throws            // artifacts/prepare.log
      public static func url(project: ProjectRef, runName: String) -> URL   // App Support/QATwin/prepare-logs/<category>_<name>__<runName>.log
  }
  ```
  항목 동작은 스펙 5.3~5.7·5.10 그대로. 로그인은 `LoginPlan.make`가 `.duringPrepare`일 때만, 아니면 `.skipped("<ID> 초기화 뒤에 해요")` 또는 `.skipped("로그인하는 시나리오가 없어요")`. 빌드는 `BuildEnv.write`로 만든 파일을 `QA_APP_ENV`로 export하고 끝나면 지운다. 실행 폴더는 만들지 않는다(호출자 몫).

- [ ] **Step 1: 테스트** (Fake: `FakeArtemisAPI`를 `TestSupport.swift`로 옮겨 공유, `FakeHealth`(URL별 응답 순서), `FakeLauncher`(`/bin/sh -c` 스크립트로 실제 `ManagedProcess`를 만든다), `RecordingShell`, 테스트 clock `pollInterval`은 ms 단위):
  - `prepareStartsArtemisAndServerWhenDown()` — devices 첫 호출 unreachable 후 성공, health 실패→성공. 이벤트에 `artemis .done`, `server .done`, `PrepareResult.artemisStartedByApp && serverStartedByApp`. launcher가 받은 Artemis 명령에 `export ARTEMIS_HOME=`와 `uv run artemis ui --port 8100`.
  - `prepareSkipsBuildAndInstallWhenRecordMatches()` — `.install.json` 일치 → `build .skipped`, `install`은 `am start`만 호출(`install -r` 호출 없음).
  - `prepareFailsFastWhenServerExits()` — start 스크립트가 `echo "address already in use"; exit 1` → `server .failed`에 그 문구, `start_timeout` 만큼 기다리지 않음(경과 < 2초).
  - `prepareWaitsForUnlockThenContinues()` — 잠김 2회 뒤 풀림 → `device .waitingForHuman` 다음 `.done`, 끝까지 성공.
  - `prepareRejectsTrackedFileChange()` — 빌드 전후 `git status --porcelain` 응답이 다름 → `build .failed("빌드가 원본 repo의 추적 파일을 바꿨어요 — 되돌리지 않았어요")`.
  - `prepareLogRedactsSecrets()` — 로그인 스크립트 출력에 비밀값 → `prepare.log`에 `****`, 원문 없음. `API_BASE_URL` 값은 그대로 보임.
  - `cancelStopsChildAndCreatesNoRunDir()` — 긴 빌드 중 `cancel()` → 자식 그룹 사라짐, `input.projectDir/runs` 없음, `.finished(succeeded: false)`.
- [ ] **Step 2:** `--filter PrepareCoordinatorTests` FAIL. **Step 3:** 구현. **Step 4:** PASS + 전체 테스트 PASS. **Step 5:** 커밋 `feat(app): 준비 조정자 — 서버·기기·빌드·설치·권한·로그인을 셸로`.

### Task 8: 시나리오별 초기화와 run-state `prepare`

**Files:**
- Modify: `app/Sources/QATwinCore/PlanDocument.swift`(`- 초기화:` 파싱), `app/Sources/QATwinCore/RunOrchestrator.swift`, `templates/test_plan.md`(시나리오 블록에 `- 초기화: <앱 데이터|없음>`), `.claude/skills/qa-plan/SKILL.md`(6절에 스펙 5.8 문장)
- Test: `app/Tests/QATwinCoreTests/PlanDocumentTests.swift`, `app/Tests/QATwinCoreTests/RunOrchestratorTests.swift`

**Interfaces:**
- Consumes: `LoginPlan`·`LoginOutcome`(Task 5), `PrepareResult`(Task 7), `ProjectConfig.permissions`.
- Produces:
  - `Scenario.resetsAppData` — `- 초기화:` 값에 `앱 데이터`가 있으면 true.
  - `ScenarioRunState.preparing` (Codable 케이스 추가; 옛 run-state.json은 그대로 읽힌다).
  - `RunStateFile.prepare: PrepareResult?` (없으면 nil로 디코드).
  - `RunOrchestrator.init`에 `reset: ResetContext?` 인자 추가(기본 nil — 기존 호출·테스트 무변경):
    ```swift
    public struct ResetContext: Sendable {
        public let package: String; public let launch: String; public let permissions: [String]
        public let loginScript: URL; public let envURL: URL; public let roles: [String: AccountRole]; public let chosenRole: String?
        public let loginBefore: String?   // LoginPlan.when == .beforeScenario(id)인 id
    }
    ```
    시나리오가 `resetsAppData`이거나 id == `loginBefore`이면 `POST /api/run` 전에 `.preparing` → (`resetsAppData`면 `pm clear` → `pm grant`) → `am start` → (로그인이 필요하면) `bash <loginScript> <serial> <envURL> <id_env> <password_env> --tap 로그인 --wait 50` 120초 제한, `LoginOutcome.interpret(…, freshInstallOrReset: resetsAppData)`. 실패면 `.held(reason: "초기화 실패: <이유>")`.

- [ ] **Step 1: 테스트** — `parsesResetLine()`(fixture 계획에 `- 초기화: 앱 데이터` 한 줄 추가한 새 fixture `2026-01-03-demo_app_test_plan.md`). `resetRunsClearGrantLaunchLoginBeforeRun()`(FakeShell 호출 순서 `pm clear` → `pm grant`×n → `am start` → `bash …android-login.sh … --tap 로그인 --wait 50` → 그다음 `api.run`). `resetLoginFailureHoldsScenario()`(로그인 스크립트 종료 7 → `.held("초기화 실패: 로그인 화면을 찾지 못했어요 — …")`, `api.run` 미호출, 다음 시나리오는 진행). `loginBeforeWithoutResetSkipsClear()`. `runStateDecodesWithoutPrepare()`(옛 JSON).
- [ ] **Step 2:** FAIL. **Step 3:** 구현. **Step 4:** 전체 PASS. **Step 5:** 커밋 `feat(app): 시나리오별 앱 데이터 초기화·재로그인, run-state prepare 기록`.

### Task 9: 승인 시트 — 준비 점검·로그인 역할·테스트 env

**Files:**
- Modify: `app/Sources/QATwinApp/ApprovalSheet.swift`, `app/Sources/QATwinApp/AccountsSection.swift`, `app/Sources/QATwinApp/AppModel.swift`(`Approval`에 `loginRole: String?`·`forceRebuild: Bool`, `buildInstall` 제거; 시트용 `preflight` 호출·Artemis 프로세스 보관)
- Create: `app/Sources/QATwinApp/EnvImportSheet.swift`
- Test: 화면은 빌드 + 수동 확인. 가져오기 판단은 Core로: `app/Sources/QATwinCore/EnvImport.swift` + `EnvImportTests.swift`

**Interfaces:**
- Consumes: `PrepareCoordinator.preflight`, `ProjectConfig`, `BuildSkip`, `LoginPlan.defaultRole`, `DeviceProbe.avdName`.
- Produces (Core):
  ```swift
  public enum EnvImport {
      public enum Refusal: Error, Equatable { case notFound(String), tracked(String) }   // 문구: "원본 .env가 없어요 (<경로>)" · "원본 .env가 git에 올라가 있어 가져오지 않아요 (<경로>)"
      public static func candidates(sourceDir: URL, envSource: String, shell: ShellRunner) async throws -> [(key: String, defaultChecked: Bool)]  // 키 이름만, .env.example에 있는 키만 기본 체크
      public static func apply(keys: [String], from sourceEnv: URL, to projectEnv: URL) throws          // EnvFile.upsert
  }
  ```
  화면: 목업 3b 그대로 — 준비 점검 묶음 6행(행마다 상태 아이콘·한 줄·"다시 확인"), 빌드 행의 "그래도 다시 빌드" 체크와 `$QA_APP_ENV` 미사용 경고, 로그인 역할 `Picker`(`accounts` 비면 숨김), "테스트 env" 칸(쓰임 "로그인"/"빌드", "원본 .env에서 가져오기…" → `EnvImportSheet`), 에뮬레이터 라벨 `"에뮬레이터 <AVD> · <serial>"`. blocker 규칙은 스펙 5.9. 시트를 연 동안 잠금만 5초마다 재확인.

- [ ] **Step 1: Core 테스트** — `envImportRefusesTrackedFile()`(RecordingShell: `git ls-files --error-unmatch` 0 → `.tracked`), `envImportDefaultsToExampleKeys()`(`.env.example`에 `A`만 → `[("A", true), ("B", false)]`), `envImportApplyKeepsOtherLines()`.
- [ ] **Step 2:** FAIL. **Step 3:** Core 구현 + 화면. **Step 4:** `swift test --package-path app` PASS, `swift build --package-path app` 성공, `bash app/scripts/bundle.sh` 후 `app/QATwin.app/Contents/MacOS/QATwin -openPlan <fixture 계획> -openSheet approval`로 시트를 열어 목업 3b와 행 구성이 같은지 확인.
- [ ] **Step 5:** 커밋 `feat(app): 승인 시트에 준비 점검·로그인 역할·테스트 env 가져오기`.

### Task 10: 준비 화면과 흐름 연결, Claude 준비 단계 제거

**Files:**
- Create: `app/Sources/QATwinApp/PrepareView.swift`
- Modify: `app/Sources/QATwinApp/AppModel.swift`(`AppPhase.preparing(runName: String)`, `startRun`을 조정자로, 실행 폴더는 준비 성공 뒤 생성·`prepare.log` 이동·`RunStateFile.prepare` 기록, `RunOrchestrator`에 `ResetContext` 전달, 종료 시 `ownedProcesses` 정리), `QATwinApp.swift`(툴바 제목·단계 경로·"준비 취소…"·종료 확인), `RunProgressView.swift`("준비 완료 · m:ss" 줄 + 준비 로그 접이식이 Claude 출력 자리를 대신), `PlanListView.swift`(초기화 칩), `StageRunView.swift`·`ClaudeRunner.swift`·`StageRecord.swift`(`.prepare` 케이스·`StagePrompt.prepare` 삭제), `.claude/skills/qa-run/SKILL.md`(스펙 5.11), `README.md`(스펙 5.12), `tools/artemis.md`
- Test: `app/Tests/QATwinCoreTests/ClaudeRunnerTests.swift`(prepare 프롬프트 테스트 삭제), 나머지는 빌드 + 수동 확인

**Interfaces:**
- Consumes: `PrepareCoordinator`(Task 7), `ResetContext`(Task 8), `Approval`(Task 9).

- [ ] **Step 1:** `Stage.prepare` 참조를 지우고 `swift build --package-path app` → 컴파일 오류 목록이 바꿀 곳 목록이 된다(현재 `AppModel.swift:512-522, 951, 988, 1010`, `QATwinApp.swift:191, 233`, `StageRunView.swift:144, 155, 184`, `StageRecord.swift:115`).
- [ ] **Step 2:** `PrepareView`(목업 4a: 7행 표·실패 노트 "다시 시도"/"목록으로"·준비 로그 접이식·상태 막대 "Claude 비용 $0.00")와 `AppModel` 연결 구현. 사이드바·단계 경로는 준비 중 `.run`만 열리게(`availableSteps`·`completedSteps`). 조정자가 `device .waitingForHuman`을 내면 `Notifier.send(title: "기기 잠금을 풀어 주세요", body: "풀면 준비를 이어서 해요.")`를 한 번 보낸다.
- [ ] **Step 3:** 스킬·README·`tools/artemis.md` 수정(스펙 5.11·5.12 문장).
- [ ] **Step 4:** `swift test --package-path app` PASS, `bash app/scripts/bundle.sh` 성공. 수동: 실기기 또는 켜진 에뮬레이터 + `personal/departure-assistant` 계획에서 Artemis를 끈 채 시트 열기 → Artemis가 뜸 → 시작 → 준비 화면 7행이 차례로 체크 → 첫 시나리오가 Artemis로 간다. 실패 경로는 테스트 서버 `start`를 틀린 명령으로 바꿔 빨간 노트·"다시 시도"를 확인하고 되돌린다.
- [ ] **Step 5:** 커밋 `feat(app): 준비 화면 — 앱이 셸로 준비하고 Claude 준비 단계는 없앤다`.

### Task 11: 등록된 프로젝트 이관 (메인 작업 트리, 이 브랜치 머지 뒤)

**Files:** `personal/departure-assistant/project.yaml`(커밋), `company/stsp_patrol/project.yaml`(git 제외 — 파일만 고침)

- [ ] **Step 1:** 두 파일의 `build.android`를 `--dart-define-from-file=$QA_APP_ENV`로, `environments`에 스펙 5.1의 `health`·`start`·`vars`(근거 `파일:줄` 주석), `apps.android.permissions`(AndroidManifest 근거)를 넣는다. 근거를 못 찾은 값은 `# 미확인`.
- [ ] **Step 2:** 앱에서 승인 시트를 열어 두 프로젝트 모두 빌드 행에 `$QA_APP_ENV` 경고가 없고 "테스트 env"에 빌드 키가 보이는지 확인. 빠진 빌드 키는 "원본 .env에서 가져오기…"로 채운다(사용자 확인 뒤).
- [ ] **Step 3:** 개인 프로젝트만 `git add personal/departure-assistant/project.yaml` → `test(departure-assistant): project.yaml 준비 자동화 키` 로 main에 커밋(사용자 승인 뒤).
