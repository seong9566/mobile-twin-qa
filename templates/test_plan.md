---
project: <project>
category: <personal|company>
created: <yyyy-mm-dd HH:mm>
author: <분석한 LLM, 예: Claude Opus 5.5 / Codex>
source:
  repo: <repo URL>
  branch: <branch>
  commit: <short SHA>
  dirty: false                 # 분석 시점에 커밋하지 않은 변경이 있었으면 true
  app_version: <버전>
platforms: [android, ios]
runners: { android: artemis, ios: mobile-mcp }
---

# <project> 테스트 계획 (<yyyy-mm-dd>)

## 1. 범위와 근거

- 분석한 것: <소스 경로·문서 목록>
- 기기에서 확인하지 않은 가정: <목록>

## 2. 전제·제약

| 항목 | 내용 | 근거 |
| --- | --- | --- |

## 3. 준비

- 빌드·설치:
- 계정 (`.env` 키 이름):
- 서버·데이터:
- 기기 상태:
- 시나리오 사이 초기화:

## 4. 시나리오

<!-- 시나리오마다 아래 블록을 반복한다 -->

### <ID> · <제목>

- platform: <android|ios|both> · 등급: <A|B|C> · 계정: <역할> (`<accounts 역할 키>`)
- 사전 조건:
- goal: <도구에 그대로 넣는 지시문 — 비밀번호 금지>
- 통과 조건:
- 근거: <파일:줄 · 문서>
- 실행 옵션: <예: profile=pro, locked_app_package=..., verification_level=checkpoints>

## 5. 돌리면서 확인할 문서-코드 불일치

| 항목 | 문서 | 코드 |
| --- | --- | --- |

## 6. 파일럿

<먼저 돌릴 시나리오 2~3개와 고른 이유>

## 7. 후속 작업

<원본 repo에서 할 일: 회귀 테스트로 옮길 후보, 발견한 결함 등>
