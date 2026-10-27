# 실행 준비 자동화 설계 (2026-10-27)

QA 맥 앱(`app/`)의 "실행 준비"를 사람 손과 Claude Code 없이 앱이 직접 하게 바꾼다. 앞선 설계 `2026-10-26-qa-mac-app-design.md`의 4.5 "실행 단계의 역할 나눔" 가운데 준비 부분을 이 문서가 대체한다.

## 1. 왜 바꾸는가

지금 실행 전 준비는 두 조각이다.

- 사람이 터미널에서: Artemis `doctor`·`ui --port 8100` 띄우기, 테스트 서버(`server/run.sh` 등) 띄우기, 앱 `.env`의 서버 주소 맞추기, 폰 잠금 해제.
- Claude Code 준비 단계(`앱 실행 모드: 준비`): 빌드·설치, 앱 실행, `android-login.sh`로 로그인, 사전 조건 확인.

사용자가 이 앱을 쓰며 가장 답답한 지점으로 "준비가 손이 많이 간다"를 골랐다(2026-10-27 인터뷰). 준비 단계의 진행 표시가 출력 줄 수로 어림한 가짜라는 점, 준비 실패 뒤 로그가 남지 않는 점도 같은 뿌리다.

성공: 승인 시트의 "시작"을 누른 뒤 첫 `POST /api/run`까지 사람이 할 일이 잠금 해제뿐이다. 준비에 Claude 비용이 들지 않는다. 준비 화면의 체크가 실제 상태다.

## 2. 목표 · 비목표 · 반목표

**목표**

- 앱이 직접 한다: Artemis 서버 점검·띄우기, 테스트 서버 점검·띄우기, 기기 상태 점검, 빌드 건너뛰기 판단, 빌드·설치·앱 실행·로그인, 시나리오별 앱 데이터 초기화.
- 명령으로 띄울 수 있는 것은 묻지 않고 띄운다. 사람만 할 수 있는 것(잠금 해제, USB 연결)만 멈춰 알린다.
- 테스트에 필요한 값(서버 주소·계정·키)은 프로젝트당 테스트 전용 파일 하나에 둔다. 원본 repo의 `.env`는 읽어 가져올 뿐 쓰지 않는다.
- 이미 켜져 있는 Android 에뮬레이터를 실기기처럼 고를 수 있다.
- 화면은 목업 3b(실행 승인, 준비 점검 포함)·4a(준비 진행)대로.

**비목표 (이번에 하지 않음)**

- iOS·mobile-mcp, AVD 부팅(켜진 에뮬레이터만 인식).
- 테스트 서버의 데이터 시드·계정 생성.
- 준비가 실패했을 때 Claude Code가 오류를 읽고 수습하는 것. 실패하면 오류 끝부분을 보여 주고 멈춘다.
- 사전 조건(예: 근무 중)을 화면에서 확인하는 것. 계획의 goal과 Artemis에 맡긴다.
- 시나리오 사이에 Claude Code가 끼는 것. 판정 단계는 지금처럼 Claude Code가 한다.
- 두 기기 병렬 실행.

**반목표 (이렇게 되면 실패)**

- 원본 repo의 git 추적 파일이 바뀐다.
- 비밀값이 화면·로그·`prepare.log`·run-state·Claude 프롬프트에 나온다.
- 계획에 적지 않은 기기 데이터 초기화를 앱이 한다.
- 어느 단계든 끝나지 않는데 앱이 모른 채 기다린다(모든 단계에 시간 제한).
- 채팅으로 하던 것보다 클릭이 많아진다.

## 3. 제약

- 원본 repo는 읽기 전용. 빌드로 바뀌는 것은 git이 무시하는 파일뿐이어야 한다(AGENTS.md "원본 repo"). 빌드 전후 `git status --porcelain`·`git diff | shasum`을 비교하는 기존 규칙을 앱이 그대로 지킨다.
- 비밀값은 프로젝트 폴더의 `.env`에만 있다. 앱은 값을 `SecretRedactor`로 가린 뒤에만 화면·로그에 보인다.
- Artemis 쓰기 호출(`POST /api/run`·`/api/stop`)은 승인 뒤 앱만 한다. 준비 단계는 `GET /api/devices`만 부른다. Artemis 서버 프로세스를 띄우는 것은 API 쓰기가 아니므로 승인 전(승인 시트를 열 때)에도 한다.
- 앱이 띄우는 셸 명령은 `/bin/bash -lc "<명령>"`으로 실행해 로그인 셸의 PATH(`uv`·`flutter`·`adb`)를 쓴다. GUI 앱의 PATH는 터미널과 다르다.
- Artemis 포트는 설정의 Artemis 주소를 따른다(기본 8100). 8000은 건드리지 않는다.
- 판정·기록·지식 규칙의 정본은 스킬(`.claude/skills/qa-run/SKILL.md`)과 `AGENTS.md`다. 준비를 앱이 맡게 되면 스킬의 `앱 실행 모드: 준비` 절은 지우고 "준비는 앱이 한다"고 적는다.
- macOS 26+, SwiftUI, 기존 `QATwinCore`/`QATwinApp` 구조 위에 더한다.

## 4. 사용자가 정한 것 (2026-10-27 인터뷰)

### 4.1 앱이 대신하는 준비
네 가지 모두: Artemis 서버 점검·띄우기 / 테스트 서버·앱 env 세팅 / 기기 상태 점검·초기화 / 빌드·설치 건너뛰기 판단. 원칙은 **"띄울 수 있는 건 알아서 띄운다"**. 사람만 할 수 있는 것(잠금 해제)만 알리고 기다린다.

### 4.2 테스트 전용 env 파일 하나
프로젝트당 테스트 전용 파일 하나에 서버 주소·로그인 계정·키 등 테스트에 필요한 값을 **작성하거나 원본 repo에서 가져온다**. 원본 repo의 `.env`는 고치지 않는다.

### 4.3 준비는 전부 앱이 셸로
점검·서버·빌드·설치·로그인까지 앱이 직접 한다. Claude Code는 준비에서 뺀다. 실패하면 오류 끝부분을 보여 주고 멈춘다.

### 4.4 에뮬레이터
이미 켜진 에뮬레이터만 인식한다. 부팅은 사람이 한다.

### 4.5 시나리오별 초기화
계획 양식에 시나리오별 `초기화` 칸을 두고, 그 시나리오 직전에 앱이 앱 데이터를 지우고 다시 실행·로그인한다. 목록 확인 표에도 표시한다.

### 4.6 화면
목업 확정: https://claude.ai/artifact/Fy51H7ZaUCya3uQBhKpjYp 세 번째 줄, 원본은 `docs/superpowers/mockups/qa-mac-app/Approval2.dc.html`(3b)·`Prepare.dc.html`(4a). 지어낸 데이터.

- **3b 실행 승인**: 기기 목록에 켜진 에뮬레이터. 서버 선택 아래 "준비 점검" 묶음(Artemis·테스트 서버·기기·빌드·설치·로그인). 테스트 서버는 "시작하면 띄워요", Artemis는 기기 목록에 필요하므로 시트를 열 때 바로 띄우고 "꺼져 있어서 띄웠어요"로 보인다(목업 문구 "시작하면 띄워요"는 이렇게 바뀐다, 5.3). 기기 잠김은 사람 몫으로 표시하고 "다시 확인". 빌드는 설치본 커밋 비교로 "건너뜀" 또는 "다시 빌드", "그래도 다시 빌드" 체크. 계정 칸은 "테스트 env"로 바뀌고 키마다 쓰임(빌드/로그인)을 보이며 "원본 .env에서 가져오기…" 버튼이 있다. 잠금·키 없음·서버 미응답(띄울 명령 없을 때)·동의 없음이 "시작"을 막는다.
- **4a 준비 진행**: Claude 단계 화면 대신 항목 체크리스트(Artemis 서버 → 테스트 서버 → 기기 → 빌드 → 설치·실행 → 로그인 → 시나리오). 항목마다 상태 아이콘·한 줄 상세·경과 시간. 기기 잠김에서는 그 행만 노랗게 멈추고 "다시 확인". 실패하면 그 행이 빨갛게 되고 위에 노트(오류 끝부분 + "다시 시도" / "목록으로"). 아래에 "준비 로그" 접이식(명령 출력 끝부분, 값 가림, 실행 폴더에 남김). 상태 막대에 경과 시간·Claude 비용 $0.

### 4.7 순서
처음 코드 검토에서 찾은 작은 수정 6건(사이드바 같은 날짜 계획 구분, 저장 안 한 수정 유실, 준비·판정 가짜 진행, 준비·판정 기록 없음, Artemis 미응답 문구, 통과 시나리오 메모)은 이 설계와 **별도 PR로 먼저** 고친다. 그중 준비 쪽 두 건(가짜 진행·기록 없음)은 이 설계로 준비 단계가 바뀌면 자연히 사라지므로 그 PR에서는 판정 단계만 다룬다.

## 5. 내가 정한 것 (Claude의 판단 — 사용자가 뒤집을 수 있음)

### 5.1 `project.yaml` 확장
`environments`의 각 서버 이름 아래에 하위 키를 더한다(최상위 키는 양식 그대로, AGENTS.md "파일 형식").

```yaml
environments:
  default: local
  local:
    health: http://{{mac_ip}}:5199/health      # 2xx면 떠 있는 것. 없으면 점검하지 않는다
    start: server/run.sh --urls http://0.0.0.0:5199   # 소스 루트 기준. 없으면 사람이 띄운다
    cwd: .                                     # start를 실행할 폴더(소스 루트 기준). 기본 소스 루트
    start_timeout: 180                         # health가 응답할 때까지 기다리는 초. 기본 60 (dotnet run처럼 첫 기동이 느리면 늘린다)
    vars: { API_BASE_URL: "http://{{mac_ip}}:5199" }   # 빌드 env에 덮어쓸 값(비밀 아님)
  dev:
    health: https://dev-api.example.com/health
    vars: { API_BASE_URL: "https://dev-api.example.com" }
build:
  android: cd app && flutter build apk --dart-define-from-file=$QA_APP_ENV
```

- `build.android`의 env 파일 경로는 `$QA_APP_ENV`로 쓴다. 앱이 빌드 직전에 절대 경로를 넣는다.
- 빌드 명령에 `$QA_APP_ENV`가 없는 프로젝트(지금 등록된 둘 다 소스의 `.env`를 직접 읽는다)는 명령을 그대로 실행하되, 승인 시트의 빌드 행에 "빌드가 원본 .env를 읽어요 — 고른 서버가 빌드에 반영되지 않아요"를 경고로 보인다(시작은 막지 않는다). 이 작업에서 `company/stsp_patrol`·`personal/departure-assistant`의 `project.yaml`을 `$QA_APP_ENV` 방식으로 옮긴다(stsp_patrol은 지금 `TEST_*` 계정값이 APK에 구워지는 상태라 더 그렇다).
- `templates/project.yaml`에 이 예시를 넣고, `qa-init`이 소스(`run.sh`·README·CI·health 컨트롤러)를 읽어 채우게 한다. 못 찾으면 `# 미확인`.
- `{{mac_ip}}`는 앱이 기본 경로 인터페이스의 IPv4로 바꾼다. `.env` 값·`health`·`vars` 어디서든 쓸 수 있다.

### 5.2 테스트 env 파일 규칙
- 파일은 지금 계정용으로 쓰는 `<category>/<project>/.env` 그대로다(이미 git 제외). 여기에 서버 주소·빌드용 키(`API_BASE_URL`·`NAVER_MAP_CLIENT_ID` 등)·계정(`TEST_USER_ID` 등)을 함께 둔다.
- 빌드에 넘길 때 앱이 임시 파일을 만든다: `.env` 전체에서 `accounts.*.id_env`·`password_env`에 적힌 키를 **뺀** 것 + 고른 서버의 `vars`로 덮어쓰기 + `{{mac_ip}}` 치환. 계정 값을 APK에 굽지 않기 위해서다. 임시 파일은 앱 scratch 폴더에 0600으로 만들고 빌드가 끝나면 지운다.
- 승인 시트·설정의 "테스트 env" 칸은 이 키들을 보인다: `accounts`의 키(쓰임 "로그인", 없으면 지금처럼 시작을 막는다) + 프로젝트 `.env`에 이미 있는 그 밖의 키(쓰임 "빌드") + 원본 repo의 `.env.example`(있을 때)에 적혔는데 `.env`에 없는 키(쓰임 "빌드", 경고만). 어느 키가 빌드에 꼭 필요한지는 앱이 알 수 없으므로 "빌드" 키는 없어도 시작을 막지 않는다.
- "원본 .env에서 가져오기…": `project.local.yaml`의 `source_path`(없으면 `.cache/repos/<project>`)에서 `.env`를 찾아 `git check-ignore`로 git 제외 파일인지 확인한다(추적 파일이면 거부하고 이유를 보인다). 원본 `.env`에 있는 **모든 키 이름**을 목록으로 보여 주고(값은 안 보임, 프로젝트 `.env`에 없는 키가 기본 체크) 고른 키를 `.env`에 `upsert`한다. `.env.example`이 없는 프로젝트(stsp_patrol)도 이 목록으로 빌드 키를 가져올 수 있다. 원본 repo의 `.env`가 다른 경로(예: `app/.env`)에 있으면 `project.yaml` `build.env_source: app/.env`로 가리킨다.

### 5.3 Artemis 서버
- 점검: 설정의 Artemis 주소로 `GET /api/devices`.
- 없으면 `cd "$ARTEMIS_HOME" && uv run artemis ui --port <주소의 포트>`를 앱이 자식 프로세스 그룹으로 띄운다. 60초 안에 응답하지 않으면 실패.
- 기기 목록이 `/api/devices`에서 오므로, 승인 시트를 열 때 점검에서 꺼져 있으면 **그 자리에서 바로 띄운다**(시작을 누르기 전). 시트의 Artemis 행은 "꺼져 있어서 띄우는 중…" → "띄웠어요 · 응답"으로 바뀌고, 응답하면 기기 목록을 읽는다. 띄우지 못하면 기기 행에 지금처럼 "Artemis 서버에 연결하지 못했어요"와 "다시 확인".
- 앱이 띄운 프로세스는 앱이 끝날 때 함께 끝낸다. 외부(터미널)에서 띄운 것은 건드리지 않는다.
- 출력은 `~/Library/Application Support/QATwin/artemis.log`에 남기고 준비 로그에는 끝부분만 보인다.
- `artemis doctor`는 돌리지 않는다. 기기·키 문제는 `/api/devices`와 실행 오류로 드러난다.

### 5.4 테스트 서버
- `health`가 있으면 `GET`으로 2xx 확인. 성공하면 끝.
- 실패하고 `start`가 있으면 `cwd`(소스 루트 기준)에서 `start`를 자식 프로세스 그룹으로 띄우고 `start_timeout`초(기본 60) 동안 `health`를 폴링한다. 시간 안에 응답 없으면 실패(프로세스는 끝낸다).
- 실패하고 `start`가 없으면 사람 몫이다. 승인 시트에서는 "시작"을 막고(이유: 서버가 응답하지 않아요, 직접 띄워 주세요), "다시 확인"으로 풀린다.
- `health`가 없으면 이 항목은 생략하고 행도 보이지 않는다.
- 앱이 띄운 서버도 앱이 끝날 때 함께 끝낸다. 준비를 취소하거나 실행이 끝나도 끄지 않는다(다음 실행에서 그대로 쓴다).

### 5.5 기기 점검
- `adb -s <serial>`로 본다: 연결(`get-state`), 화면 켜짐·잠금(`dumpsys`), Wi-Fi(`cmd wifi status`, 에뮬레이터 `emulator-*`는 생략), 방해 금지(`settings get global zen_mode`), 알림 권한(패키지가 설치돼 있을 때만).
- 막는 것(blocker): 연결 안 됨, 잠김, Wi-Fi 끊김(에뮬레이터 제외). 경고만(진행은 함): 방해 금지 켜짐, 알림 권한 없음.
- 잠겨 있으면 macOS 알림을 보내고 5초마다 다시 본다. 사람이 "다시 확인"을 누르지 않아도 풀리면 이어서 간다. 기다리는 동안 시간 제한은 없다(사람 몫).
- 기기 목록은 지금처럼 Artemis `/api/devices`에서 온다. 에뮬레이터는 `model`이 없을 수 있으니 serial이 `emulator-`로 시작하면 "에뮬레이터 <AVD 이름>"으로 보인다(`adb -s <serial> emu avd name`).

### 5.6 빌드 건너뛰기
- 설치 기록 `<category>/<project>/.install.json`(git 제외에 추가): `{ "serial", "package", "commit", "dirty", "env_sha256", "apk_sha256", "at" }`. `env_sha256`은 빌드에 넘긴 임시 env 파일 내용(5.2, `{{mac_ip}}` 치환 뒤)의 해시다. `$QA_APP_ENV`를 안 쓰는 프로젝트는 빈 문자열. 설치가 끝날 때마다 쓴다.
- 건너뛰는 조건(전부 참): 기록이 있다 ∧ 같은 serial ∧ 기록의 `dirty`가 false ∧ 지금 소스가 dirty가 아니다 ∧ 기록의 `commit` = 지금 `HEAD` ∧ 기록의 `env_sha256` = 이번에 만들 env의 해시(서버를 바꾸거나 맥 IP가 바뀌면 다시 빌드한다) ∧ 기기에 패키지가 설치돼 있다(`pm path <package>`). 하나라도 아니면 빌드·설치한다. 승인 시트에 어느 조건이 어긋났는지 한 줄로 보인다(예: "설치본 abc1234 ≠ 소스 def5678", "서버 설정이 바뀜").
- "그래도 다시 빌드"를 켜면 조건과 상관없이 빌드한다.
- 빌드 전후 `git -C <소스> status --porcelain`과 `git diff | shasum`을 비교해 추적 파일이 바뀌었으면 실패로 멈춘다(되돌리지 않는다).
- 빌드 명령은 소스 루트에서 `/bin/bash -lc`로, `QA_APP_ENV`를 환경 변수로 넣어 실행한다.

### 5.7 설치 · 앱 실행 · 로그인
- 설치: `adb -s <serial> install -r <build.android_apk>`. 실행: `adb shell am start -n <apps.android.launch>`.
- 로그인 역할은 승인 시트의 "로그인 역할" 선택(`accounts`의 역할 키 목록)으로 정한다. 기본값은 첫 포함 시나리오의 `계정` 칸 백틱 역할 키, 그것이 없으면(지금 stsp_patrol 계획처럼 ``계정: 근무자 (…)``만 적힌 경우) `accounts`가 하나면 그것, 여럿이면 첫 번째. 사용자가 바꿀 수 있고 run-state의 `prepare.loginRole`에 남는다. `accounts`가 비었거나 로그인하는 시나리오가 하나도 없으면 로그인 항목은 생략한다.
- `tools/android-login.sh`에 `--tap <글자>` 옵션을 더한다(기본 "로그인"): 입력·확인 뒤 그 글자가 든 clickable 요소를 탭하고 3초 뒤 다시 덤프해 아이디·비밀번호 칸이 사라졌으면 0, 남아 있으면 5로 끝내며 화면에 보이는 오류 문구(아이디가 들어 있으면 뺌)를 출력한다. 앱은 이 스크립트를 그대로 부른다. 값은 지금처럼 스크립트가 `.env`에서 읽는다.
- 앱을 띄운 뒤 로그인 화면을 못 찾으면(종료 코드 4): 빌드·설치를 건너뛴 경우에만 "이미 로그인돼 있음"으로 보고 진행한다. 새로 설치했거나 앱 데이터를 초기화한 직후면 로그인됐을 리 없으므로 실패로 멈춘다(상세: "로그인 화면을 찾지 못했어요 — 권한 요청 창이나 온보딩이 가리고 있을 수 있어요"). 네트워크 오류 문구면 한 번만 다시 누른다.

### 5.8 시나리오별 초기화
- 계획 양식(`templates/test_plan.md`) 시나리오 블록에 `- 초기화: 앱 데이터` 줄을 더한다. 없거나 `없음`이면 하지 않는다. `qa-plan` 스킬에 "빈 상태에서 시작해야 하는 시나리오에만 적는다"를 더한다.
- `PlanDocument`가 `resetsAppData: Bool`로 읽는다. 목록 확인 표의 "사람 개입" 칸 옆에 "초기화" 칩, 승인 시트 시나리오 줄 아래 "<ID> 앞에서 앱 데이터를 초기화해요"를 보인다.
- 실행 루프(`RunOrchestrator`)가 그 시나리오 직전에 `pm clear <package>` → `am start` → (그 시나리오에 계정이 있으면) 로그인 → `POST /api/run`. 진행 화면 그 행에 "초기화 중" 상태를 보이고, run-state에는 `.running` 앞 단계로 남긴다(`ScenarioRunState`에 `preparing` 추가).
- 초기화 뒤 로그인은 승인 시트에서 고른 역할로 한다(5.7). 초기화·로그인이 실패하면(로그인 화면을 못 찾은 종료 코드 4 포함) 그 시나리오를 보류(환경, 사유 "초기화 실패: <이유>")로 두고 다음으로 간다. 뒤 시나리오가 이것에 의존하면 지금 규칙대로 보류.

### 5.9 승인 시트와 준비 화면의 흐름
- 승인 시트가 열리면 점검을 한 번 돌린다(행마다 스피너 → 결과). Artemis가 꺼져 있으면 이때 띄운다(5.3). "다시 확인"은 전부 다시 본다. 시트를 연 채 두면 기기 잠금만 5초마다 다시 본다.
- 시트에 "로그인 역할" 선택이 생긴다(5.7). `accounts`가 비었으면 보이지 않는다.
- "시작" 조건: 로그인 키 전부 있음 ∧ 기기 연결·잠금 해제·Wi-Fi ∧ (서버 health 실패면 `start`가 있음) ∧ (회사면) 동의. 빌드 키 없음·방해 금지·알림 권한·`$QA_APP_ENV` 미사용은 경고만.
- "시작" → 실행 폴더 생성 → `AppPhase.preparing(runDir:)` → 준비 화면. 항목 순서: Artemis 서버 → 테스트 서버 → 기기 → 빌드 → 설치·실행 → 로그인 → 시나리오. 시트에서 "건너뜀"으로 본 항목은 화면에서도 건너뜀으로 바로 체크된다.
- 항목 상태: 대기 / 진행 중 / 끝남 / 건너뜀 / 사람 대기 / 실패. 상세 한 줄과 경과 시간.
- 준비 로그: 명령마다 시각·항목·명령·출력 끝부분. 화면에는 마지막 200줄, 값은 `SecretRedactor`로 가린다. 전체(가린 것)를 `<실행 폴더>/artifacts/prepare.log`에 쓴다(artifacts는 git 제외).
- 끝나면 바로 지금의 실행 루프(`RunOrchestrator.start`)로 넘어간다. 진행 화면 위쪽에 "준비 완료 · 1:38" 한 줄과 준비 로그 접이식을 남긴다(지금의 "준비 단계 Claude Code 출력" 자리).
- 취소("준비 취소…" 확인 뒤): 지금 도는 자식 프로세스 그룹을 끝내고, 실행 폴더가 비었으면 지우고, 목록 확인으로 돌아간다. 앱이 띄운 Artemis·테스트 서버는 끄지 않는다.
- 실패: 그 항목이 빨갛게 되고 위에 노트(마지막 30줄 + "다시 시도" / "목록으로"). "다시 시도"는 실패한 항목부터 다시 한다. "목록으로"는 취소와 같다.
- 종료 확인(`applicationShouldTerminate`)은 준비 중에도 뜬다. 종료하면 앱이 띄운 프로세스를 모두 끝낸다.

### 5.10 시간 제한
Artemis 응답 60초 · 테스트 서버 health 60초 · 빌드 20분 · 설치 3분 · 로그인 60초 · `pm clear` 30초 · adb 점검 명령 20초(기존 `ShellRunner` 기본값). 기기 잠금 대기는 제한 없음. 넘기면 그 항목 실패.

### 5.11 run-state.json · 판정 단계
- `RunStateFile`에 `prepare` 블록을 더한다: `{ "artemisStartedByApp", "serverStartedByApp", "buildSkipped", "skipReason", "installedCommit", "loginRole", "durationSeconds" }`.
- `qa-run` 스킬의 `앱 실행 모드: 준비` 절을 지우고 "준비(점검·서버·빌드·설치·로그인·초기화)는 앱이 한다"고 적는다. `판정` 절에 `run-state.json`의 `prepare`와 `artifacts/prepare.log`를 참고해 `summary.md` 머리말(소스 SHA·빌드 건너뜀 여부)을 쓰라고 더한다. 계획 SHA와 소스 SHA가 다르면 앱이 `prepare`에 두 값을 남기고 판정이 적는다.
- `StagePrompt.prepare`·`Stage.prepare`는 지운다. 준비 단계 `StageRecord`는 필요 없어진다(로그가 실행 폴더에 남는다).

### 5.12 문서·양식
- `README.md` "3. 실행 준비 (사람)" 절을 "앱이 한다, 사람은 기기 잠금 해제와 USB 연결"로 줄이고, 터미널로 쓰는 경우(`qa-run` 채팅 실행)의 절차는 스킬에 남긴다.
- `AGENTS.md` 폴더 구조에 `.install.json`을, `.gitignore`에 `.install.json`을 더한다.
- `templates/project.yaml`에 5.1 예시, `templates/test_plan.md`에 5.8 칸.
- `tools/artemis.md`의 "서버" 절에 "앱에서 실행하면 앱이 띄운다"를 더한다.

## 6. 빌더에게 맡기는 것

- adb 점검의 정확한 명령과 출력 파싱(잠금·화면 켜짐·알림 권한은 Android 버전마다 다르다). 못 읽는 값은 "미확인"으로 두고 막지 않는다.
- 자식 프로세스 그룹을 띄우고 앱 종료 때 끝내는 구현(기존 `ProcessShellRunner`·`ClaudeRunner.cancel`의 프로세스 그룹 처리를 재사용).
- 준비 화면·승인 시트의 SwiftUI 세부(목업 기준), `AppModel` 안에서 준비 상태를 어디에 둘지(1600줄이 더 커지지 않게 준비 조정자를 `QATwinCore`에 따로 두는 것을 권한다).
- `.install.json`·`prepare.log`·`prepare` 블록의 정확한 필드와 테스트 fixture.
- `android-login.sh --tap`의 요소 고르기(글자가 든 clickable이 여럿이면 가장 아래 것).

## 7. 참고

- 앞선 설계: `docs/superpowers/specs/2026-10-26-qa-mac-app-design.md`
- 목업: https://claude.ai/artifact/Fy51H7ZaUCya3uQBhKpjYp (3b·4a), 원본 `docs/superpowers/mockups/qa-mac-app/Approval2.dc.html`·`Prepare.dc.html`
- 실행 기록 예: `company/stsp_patrol/runs/2026-10-22-stsp_patrol_test_plan/2026-10-26-1540/`(앱으로 돌린 첫 실행, 준비는 Claude)
- 테스트 서버가 있는 프로젝트 예: `personal/departure-assistant`(`server/run.sh`, `/health`)
