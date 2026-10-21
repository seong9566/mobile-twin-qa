# mobile-twin-qa — 운영 규칙

이 폴더는 **모바일 앱을 실기기·시뮬레이터에서 테스트하기 위한 작업 공간**이다. 앱 코드는 여기에 없다. 여기에는 테스트 계획·실행 결과·프로젝트별 지식만 둔다.
실행 도구는 Android = **Artemis**, iOS·Android = **mobile-mcp**다(`tools/`).

모든 문서는 한국어로 쓴다. 코드 식별자·명령·경로는 원문을 유지한다.

## 1. 작업별 절차

아래 작업은 해당 스킬의 `SKILL.md`를 읽고 그 순서대로 한다. Codex 등 스킬을 자동으로 불러오지 않는 도구도 이 파일을 직접 읽는다.

| 작업                                                     | 스킬                              |
| -------------------------------------------------------- | --------------------------------- |
| 새 프로젝트 등록 (repo URL·로컬 경로를 받아 폴더 만들기) | `.claude/skills/qa-init/SKILL.md` |
| 테스트 계획 쓰기                                         | `.claude/skills/qa-plan/SKILL.md` |
| 계획 실행·결과 기록                                      | `.claude/skills/qa-run/SKILL.md`  |

## 2. 폴더 구조

```
mobile-twin-qa/
  AGENTS.md · CLAUDE.md        이 규칙 (CLAUDE.md는 이 파일을 가져온다)
  .claude/skills/              작업별 절차
  templates/                   계획·프로젝트 설정·지식 양식
  tools/                       Artemis·mobile-mcp 연결·실행 방법
  company/<project>/           회사 프로젝트 — git에 올리지 않는다
  personal/<project>/          개인 프로젝트 — git에 올린다
  .cache/repos/<project>/      repo URL로 받아 둔 소스 (git 제외)
```

프로젝트 폴더 하나의 구성:

```
<company|personal>/<project>/
  project.yaml          repo URL·브랜치·앱 ID·빌드 명령·환경 (공유)
  project.local.yaml    이 기기의 소스 경로·기기 (git 제외)
  .env                  계정·비밀값 (git 제외)
  knowledge.md          누적 지식
  knowledge/<주제>.md   knowledge.md가 200줄을 넘을 때 옮긴 상세
  plans/                테스트 계획
  runs/<plan 파일명>/<yyyy-mm-dd-HHmm>/
    summary.md          실행 요약
    artifacts/          스크린샷·녹화·원본 응답 (git 제외)
```

- `<project>`는 **원본 repo 이름과 똑같이** 쓴다(예: `stsp_patrol`, `departure-assistant`).
- 이 폴더 안의 경로는 **이 폴더 기준 상대 경로**로 적는다. 기기마다 달라지는 절대 경로는 `project.local.yaml`에만 둔다.
- 빈 폴더를 남기려고 `.gitkeep` 같은 자리표시 파일을 만들지 않는다. 폴더는 처음 쓸 때 만든다.

## 3. 원본 repo

- 원본 repo에는 **쓰지 않는다** — 읽기만 한다.
- 원본 쪽에 고칠 것(테스트 코드·문구·문서 불일치)을 발견하면 계획의 "후속 작업"에 적고 사용자에게 보고한다.

## 4. 파일 형식

**project.yaml**

- `templates/project.yaml`의 최상위 키만 쓴다. 필요한 값은 기존 최상위 키 아래에 하위 키로 더한다(예: `environments.local.server`, `build.ios_app`).
- 근거가 있는 사실(소스 `파일:줄`)로 틀린 값을 발견하면 고친다. 근거를 주석으로 남기고 사용자에게 보고한다.

**테스트 계획** (`plans/`)

- 파일명: `yyyy-mm-dd-<project>_test_plan.md`. 같은 날짜 파일이 이미 있으면 끝에 `-HHmm`을 붙인다(예: `2026-10-21-stsp_patrol_test_plan-1530.md`).
- 양식은 `templates/test_plan.md`. 머리말에 분석한 소스의 **커밋 SHA·브랜치·앱 버전**을 적는다.
- `runners`에는 `project.yaml`의 `runners`를 그대로 옮긴다(계획에 없는 플랫폼도 지우지 않는다).
- 시나리오 ID는 `<영역>-<두 자리 번호>`다. 영역은 앱의 탭·기능 이름을 영어 대문자 2~5자로 줄인다(예: `HOME-01`, `PAT-02`, `SET-01`). 프로젝트 안에서 같은 영역 코드를 계속 쓴다.
- 시나리오마다 `platform`(`android`·`ios`·`both`) · 등급(**A 자동** · **B 반자동** · **C 수동**) · `goal` · 통과 조건 · 근거를 적는다.
- `goal`에는 **비밀번호·토큰을 쓰지 않는다.** 로그인이 필요하면 사전 조건에서 사람이 로그인해 둔다.

**knowledge.md**

- **200줄을 넘기지 않는다.** 넘으면 자세한 내용을 `knowledge/<주제>.md`로 옮기고 `knowledge.md`에는 주제별 한 줄 요약과 경로만 남긴다.
- 항목은 **한 줄에 하나**, 근거(`파일:줄`·실행 기록 경로)와 확인 시점 `(yyyy-mm-dd · <소스 SHA>)`를 같은 줄에 적는다.
- 같은 주제가 이미 있으면 새 줄을 더하지 않고 그 줄을 고친다.
- 사실만 적는다. 알게 된 경위·작업 이력은 적지 않는다.

**summary.md** (`runs/`) — 형식은 `qa-run` 스킬.

## 5. git에 올리는 범위

| 경로                                                                     | git               |
| ------------------------------------------------------------------------ | ----------------- |
| `personal/**` (단 `project.local.yaml`·`.env`·`runs/**/artifacts/` 제외) | 올린다            |
| `company/**` (`company/README.md` 제외)                                  | **올리지 않는다** |
| `.cache/`                                                                | 올리지 않는다     |

비밀값은 각 프로젝트의 `.env`에만 둔다. 계획·지식·요약에는 **환경 변수 이름**만 쓴다.

## 6. 실행 전 승인

- 실행 전에 사용자에게 대상 기기·쓰는 서버·실행할 시나리오를 확인받는다.
- 회사 프로젝트는 스크린샷이 LLM 제공자로 전송되는 것을 사용자가 승인한 뒤에만 실행한다.
