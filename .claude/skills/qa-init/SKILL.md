---
name: qa-init
description: Use when registering a new app project in mobile-twin-qa — the user gives a GitHub repo URL or a local source path and asks to prepare testing, create the project folder, or "테스트 준비", "프로젝트 등록", "폴더 만들어 줘".
---

# qa-init — 프로젝트 등록

작업 위치(메인 작업 트리)와 커밋은 AGENTS.md "작업 위치와 커밋"을 따른다.

원본 repo를 읽어 `<company|personal>/<project>/`의 설정과 지식 파일을 만든다. 계획은 쓰지 않는다 — 등록이 끝나면 `qa-plan`으로 넘어간다고 안내한다.

## 1. 입력 확정

- **category**: 사용자가 회사/개인을 말하지 않았으면 묻는다. 추측하지 않는다.
- **project 이름** = 원본 repo 이름 그대로.
- 이미 `<category>/<project>/`가 있으면 새로 만들지 않고, 빠진 파일만 채운다고 사용자에게 알린다.

## 2. 소스 확보

1. 로컬 경로를 받았으면 그 경로를 `project.local.yaml`의 `source_path`로 쓰고, `git -C <경로> rev-parse --abbrev-ref HEAD` 값을 `project.yaml`의 `branch`에 적는다.
2. URL만 받았으면 `git clone --depth 50 --no-single-branch <url> .cache/repos/<project>`. 기본 브랜치 `<b>`는 `git -C .cache/repos/<project> symbolic-ref --short refs/remotes/origin/HEAD`에서 `origin/`을 뗀 값이고, `project.yaml`의 `branch`에 적는다. 이미 있으면 `<b>`로 맞춘다: `git -C .cache/repos/<project> fetch --depth 50 origin <b>` → `git -C .cache/repos/<project> checkout -B <b> FETCH_HEAD`. `source_path`는 비운 채로 둔다.
3. 짧은 SHA를 적어 둔다: `git -C <소스> rev-parse --short HEAD`.

## 3. 소스에서 읽을 것

| 채울 칸 | 찾는 곳 (예) |
| --- | --- |
| `apps.android.package`·`launch` | `android/app/build.gradle*`의 `applicationId`, `AndroidManifest.xml`의 LAUNCHER activity |
| `apps.ios.bundle_id` | `*.xcodeproj/project.pbxproj`의 `PRODUCT_BUNDLE_IDENTIFIER` |
| `build.*` | README·CLAUDE.md·CI 워크플로의 빌드 명령, 산출물 경로 |
| `environments` | 서버 주소 설정 파일(값이 비밀이면 키 이름만) |
| `accounts` | 테스트 계정 키 이름(`.env.example` 등). 값은 적지 않는다 |
| `docs` | 기획·화면·상태 문서 경로 |

각 값 옆에 근거 `파일:줄`을 주석으로 단다. 찾지 못한 값은 `# 미확인`으로 둔다.

## 4. 파일 만들기

- `project.yaml` ← `templates/project.yaml`. 최상위 키는 양식 그대로 두고, 필요한 값은 그 아래 하위 키로 더한다.
- `project.local.yaml` ← `templates/project.local.yaml`. 로컬 경로를 받았을 때만 `source_path`를 채우고, 기기 칸은 비워 둔다.
- `knowledge.md` ← `templates/knowledge.md`. 3단계에서 테스트에 영향을 주는 사실(셀렉터 특성·자동화가 안 되는 동작·문서-코드 불일치)을 찾았으면 규칙(AGENTS.md "파일 형식")대로 한 줄씩 넣는다.
- `plans/`·`runs/`는 만들지 않는다.
- 회사 프로젝트면 `git check-ignore -v <파일>`로 제외되는지 확인한다.

## 5. 보고

만든 파일 경로 · `# 미확인`으로 남긴 칸 · 원본 repo 쪽 후속 작업 후보 · 다음 단계(`qa-plan`으로 계획 쓰기, 범위·플랫폼 질문)를 알린다.
