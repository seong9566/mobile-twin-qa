---
name: qa-plan
description: Use when writing or refreshing a test plan for a project registered in mobile-twin-qa — "테스트 계획 써줘", "시나리오 만들어줘", a new app version or branch needs scenarios, or an existing plan's source SHA is outdated.
---

# qa-plan — 테스트 계획 쓰기

계획은 사용자가 쓰는 LLM이 원본 소스와 문서를 직접 분석해서 쓴다. 형식 규칙은 AGENTS.md "파일 형식"이 정본이다.

## 1. 범위 확정

사용자가 말하지 않은 것 중 계획 내용을 바꾸는 것만 묻는다: 플랫폼(Android·iOS), 기능 범위, 시나리오 수. 프로젝트 폴더가 없으면 `qa-init`을 먼저 한다.

## 2. 소스 맞추기

1. 소스 위치: `project.local.yaml`의 `source_path` → 없으면 `.cache/repos/<project>`(없으면 `git clone --depth 50 --no-single-branch <repo> .cache/repos/<project>`로 받는다 — `project.yaml`의 `branch`는 바꾸지 않는다).
2. `.cache` 소스는 `project.yaml`의 `branch`(`<b>`)로 맞춘다: `git -C <소스> fetch --depth 50 origin <b>` → `git -C <소스> checkout -B <b> FETCH_HEAD`. `source_path`는 사용자 작업 트리이므로 브랜치를 바꾸지 않고 현재 상태를 읽는다.
3. 기록할 값: 브랜치 · `git rev-parse --short HEAD` · 앱 버전(pubspec·gradle·Info.plist 등) · 커밋하지 않은 변경 여부(`git status --porcelain`이 비어 있지 않으면 `dirty: true`).

## 3. 지식 정리 (분석 전에)

`knowledge.md`를 읽고 항목마다:
- 근거 `파일:줄`이 지금 소스에서 같은지 확인한다 → 같으면 확인 시점을 이번 SHA로 갱신, 다르면 고치거나 지운다.
- 더 이상 사실이 아닌 항목(해소된 불일치, 구현된 미구현 기능)은 지운다.
- 지식에 이미 있는 사실은 다시 분석하지 않고 쓴다.

## 4. 분석

`project.yaml`의 `docs`와 범위에 해당하는 화면 코드를 읽는다. 시나리오마다 필요한 것: 진입 경로 · 화면 문구(코드의 문자열 그대로) · 상태 분기 · 입력 검증 · 기기·서버 의존.

## 5. 파일명

```
d=$(date +%Y-%m-%d); f=<category>/<project>/plans/$d-<project>_test_plan.md
[ -e "$f" ] && f=<category>/<project>/plans/$d-<project>_test_plan-$(date +%H%M).md
```
그 이름도 이미 있으면 쓰지 말고 사용자에게 알린 뒤 멈춘다. 기존 계획 파일은 고치지 않는다.

## 6. 작성

`templates/test_plan.md`를 채운다.
- 머리말 `runners`는 `project.yaml` 값을 그대로 옮긴다.
- 시나리오 ID는 `<영역>-<두 자리>`. 이전 계획이 있으면 같은 영역 코드를 이어 쓴다.
- `goal`은 도구가 그대로 따를 수 있는 순서 있는 지시문으로, 화면에 보이는 문구를 따옴표로 넣는다. 위험한 동작(실제 발신·삭제·결제)은 "누르지 마"를 명시하거나 시나리오에서 뺀다.
- 통과 조건은 화면에서 확인할 수 있는 문장으로, 근거 `파일:줄`과 함께.
- 사람이 끼어야 하는 단계가 있으면 B, OS·하드웨어가 핵심이면 C로 두고 C는 목록만 적는다.
- 파일럿 2~3개: 사람 개입 없이 끝나고 서버 쓰기가 적고 상태 전이를 넓게 타는 것.

## 7. 마무리

- 분석 중 새로 알게 된 사실을 `knowledge.md`에 넣는다(한 줄 · 근거 · 확인 시점, 같은 주제는 고쳐 쓴다, 200줄 이하).
- `project.yaml`에서 근거가 있는 틀린 값을 발견했으면 고치고 근거를 주석으로 단다.
- 보고: 계획 경로 · 머리말 · 시나리오 ID 목록 · 파일럿 · `knowledge.md`·`project.yaml` 변경 · 묻지 못해 정한 가정.
