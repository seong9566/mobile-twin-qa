# mobile-twin-qa

모바일 앱을 실기기·시뮬레이터에서 테스트하는 작업 공간입니다. 앱 코드는 각 원본 repo에 있고, 여기에는 테스트 계획·실행 결과·프로젝트별 지식만 둡니다.

- Android: **Artemis** · iOS·Android: **mobile-mcp**(미검증)
- 계획은 사용자가 쓰는 LLM(Claude Code·Codex 등)이 원본 소스를 분석해서 씁니다.
- 규칙은 `AGENTS.md`, 작업 절차는 `.claude/skills/qa-init`·`qa-plan`·`qa-run`에 있습니다.

## 폴더

```
company/<project>/    회사 프로젝트 (git에 올리지 않음)
personal/<project>/   개인 프로젝트 (git에 올림)
  project.yaml        repo URL·앱 ID·빌드 명령 (공유)
  project.local.yaml  이 기기의 소스 경로·기기 serial (git 제외)
  .env                계정·비밀값 (git 제외)
  knowledge.md        테스트하며 쌓는 지식 (200줄 이하)
  knowledge/          knowledge.md가 200줄을 넘을 때 옮긴 상세
  plans/              yyyy-mm-dd-<project>_test_plan.md
  runs/               실행 결과 summary.md (+ artifacts/, git 제외)
```

## 처음 한 번 (기기마다)

1. 필요한 도구: `git` · `uv` · `jq` · Android platform-tools(`adb`) · 테스트할 앱의 빌드 도구(Flutter·Xcode 등).
2. 이 repo를 clone합니다. 계획 작성·테스트 실행은 **메인 작업 트리**에서 합니다.
   - 이미 등록된 개인 프로젝트는 `project.local.yaml`이 없으니 `qa-init`을 다시 요청해 빠진 파일만 채웁니다.
   - 회사 프로젝트(`company/`)는 git에 없어서 기기 사이에 옮겨지지 않습니다. 새 기기에서는 다시 등록합니다.
3. Artemis를 설치합니다(https://github.com/google/artemis 의 README — `git clone` 후 `./start.sh`). 위치는 셸 프로필(`~/.zshrc` 등)에 환경 변수로 넣고, LLM 세션을 새로 띄웁니다.
   ```bash
   export ARTEMIS_HOME=~/<artemis 설치 경로>
   ```
   - `$ARTEMIS_HOME/.env`에 쓰는 모델의 키(예: `ANTHROPIC_API_KEY`)와 `GEMINI_API_KEY`(화면 좌표 찾기)를 넣습니다.
   - 모델 설정은 `$ARTEMIS_HOME/config/artemis.jsonc`입니다. Claude 5.x 모델을 쓸 때 주의할 점은 `tools/artemis.md`에 있습니다.
4. Android 기기는 USB 디버깅을 켜고 연결해 `adb devices -l`로 보이는지 확인합니다.

## 테스트 절차

### 1. 프로젝트 등록 — `qa-init`

LLM에게 이렇게 요청합니다.

> 개인 프로젝트로 https://github.com/<owner>/<repo> 테스트 준비해 줘.
> (회사 프로젝트면 "회사 프로젝트로", 로컬 소스가 있으면 그 경로를 같이 준다)

- `<category>/<repo 이름>/`에 `project.yaml`·`project.local.yaml`·`knowledge.md`가 생깁니다.
- `project.local.yaml`의 `devices`에 기기 serial을 적습니다.
- 테스트 계정이 필요하면 `<category>/<project>/.env`에 넣습니다(앱 빌드가 쓰는 원본 repo의 `.env`와는 다른 파일). 계획에는 키 이름만 쓰입니다.

### 2. 계획 작성 — `qa-plan`

> <project> Android 테스트 계획 써줘. <범위, 예: <기능> 위주로 10개>

- `plans/yyyy-mm-dd-<project>_test_plan.md`가 생깁니다(같은 날짜가 있으면 `-HHmm`).
- 시나리오마다 등급이 붙습니다: **A** 자동 · **B** 사람이 한 번 끼어듦(태그·두 번째 기기 등) · **C** 수동 목록.
- 계획 끝의 **파일럿**(사람 손 없이 끝나는 2~3개)부터 돌립니다.
- 원본 코드가 바뀌었으면 계획을 다시 씁니다. 머리말의 `commit`으로 낡았는지 판단합니다.

### 3. 실행 준비 (사람)

1. 앱을 빌드해 기기에 설치합니다(`project.yaml`의 `build`).
2. 테스트용 서버·데이터를 준비합니다(`knowledge.md`의 "테스트 데이터·계정 준비").
3. 로그인이 필요한 앱이면 앱에서 직접 로그인해 둡니다(자동 로그인 켬). 비밀번호는 지시문에 넣지 않습니다.
4. 기기를 잠금 해제하고 홈 화면에 둡니다.
5. Artemis를 점검한 뒤, **별도 터미널**에서 서버를 띄워 둡니다(`ui`는 끝나지 않고 계속 돕니다).
   ```bash
   (cd "$ARTEMIS_HOME" && uv run artemis doctor)               # 기기·키 점검
   (cd "$ARTEMIS_HOME" && uv run artemis ui --port 8100)       # 별도 터미널에서
   ```

### 4. 실행 — `qa-run`

> <project> 오늘 계획 파일럿 돌려줘.

- 실행 전에 한 번에 확인을 받습니다: 대상 기기 · 서버 · 시나리오 목록 · (회사 프로젝트면) 스크린샷이 LLM 제공자로 전송되는 것에 대한 승인.
- 승인 뒤 시나리오를 하나씩 실행합니다. B 등급은 사람이 할 동작을 미리 알려 줍니다.
- 결과는 `runs/<계획 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>/summary.md`(통과·실패·보류, 판정, 비용)와 `artifacts/<시나리오 ID>/`(녹화·원본 응답)에 남습니다.
- 진행 화면은 Artemis 웹 콘솔 `http://127.0.0.1:8100`에서 볼 수 있습니다.

### 5. 결과 검토

- 실패는 녹화를 보고 **앱 결함 · 도구 오판 · 환경** 중 하나로 판정합니다.
- 도구 오판·실제 문구 차이는 `knowledge.md`에 반영되고, 다음 계획에 쓰입니다.
- 비용(`usage`)을 보고 모델 배분을 조정합니다(`$ARTEMIS_HOME/config/artemis.jsonc`, 바꾼 뒤 서버 재시작).
- 등록·계획·실행이 끝날 때마다 개인 프로젝트면 커밋할지 묻습니다. 승인하면 `main`에 `test(<project>): …`로 커밋·push됩니다. 회사 프로젝트는 커밋하지 않습니다.

### 6. 범위 넓히기

1. 나머지 A 등급 → 2. B 등급(사람과 함께) → 3. C 등급은 실기기 체크리스트로.

### 7. 회귀 테스트로 옮기기

통과한 A 등급 경로는 `summary.md`의 "회귀 테스트 후보"에 올라갑니다. 원본 repo의 테스트(Patrol·XCUITest·Maestro 등)로 옮기는 작업은 **원본 repo에서, 그 repo의 규칙대로** 합니다.

## 이 repo의 규칙·스킬을 고칠 때

`AGENTS.md`·`CLAUDE.md`·`README.md`·`.claude/skills/`·`templates/`·`tools/`·`.gitignore`·`company/README.md`처럼 프로젝트 폴더 밖의 파일은 `.claude/worktrees/<이름>` 워크트리의 브랜치에서 고치고 PR로 머지합니다.
