---
name: qa-run
description: Use when running scenarios from a mobile-twin-qa test plan on a device or simulator with Artemis or mobile-mcp — "파일럿 돌려줘", "계획 실행해줘", "HOME-01 돌려봐", or recording results of a run.
---

# qa-run — 계획 실행·결과 기록

## 1. 실행 전 점검 (기기를 건드리기 전에)

1. **계획 고르기**: 사용자가 말한 계획, 없으면 `plans/`에서 가장 최근 파일. 시나리오를 말하지 않았으면 계획의 "파일럿".
2. **계획이 낡았는지**: 소스의 현재 SHA(`qa-plan`과 같은 방법으로 찾은 소스)를 머리말 `commit`과 비교한다. 다르면 사용자에게 알리고 계속할지 묻는다.
3. **도구 상태**: `platform`별 러너(`project.yaml`의 `runners`) — Artemis는 `tools/artemis.md`의 `GET /api/devices`, mobile-mcp는 `tools/mobile-mcp.md`. 응답이 없으면 띄우는 방법을 알려 주고 멈춘다.
4. **확인받기** — 한 번에 묻는다:
   - 대상 기기(`project.local.yaml`의 `devices`, 비었으면 `adb devices -l` 결과에서 고르게)
   - 쓰는 서버(`project.yaml`의 `environments`)
   - 실행할 시나리오 목록과 각 등급(B는 사람이 해야 할 동작을 적는다)
   - 회사 프로젝트면 스크린샷이 LLM 제공자로 전송되는 것에 대한 승인
   승인 없이는 `POST /api/run`을 보내지 않는다.

## 2. 실행

- 실행 폴더: `runs/<plan 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>/` — 첫 시나리오를 보내기 직전에 만든다.
- 시나리오를 **하나씩** 보낸다(Artemis는 `POST /api/run`에 계획의 실행 옵션과 `device_serial`). 끝날 때까지 `GET /api/sessions/{id}`로 상태를 본다.
- B 등급은 사람이 할 동작이 화면에 나올 시점을 사용자에게 미리 알린다.
- 시나리오마다 `checks`·`usage`·녹화를 `artifacts/<ID>/`에 받는다.
- 앞 시나리오 결과가 뒤 시나리오의 사전 조건이면, 앞이 실패했을 때 뒤는 보내지 않고 "보류"로 적는다.

## 3. summary.md

```markdown
# <plan 파일명> 실행 — <yyyy-mm-dd HH:mm>

- 기기: <모델 · OS · serial> · 서버: <환경> · 소스: <SHA> · 러너: <artemis|mobile-mcp> · 모델: <`$ARTEMIS_HOME/config/artemis.jsonc`의 default·planner 모델 — ARTEMIS_HOME이 없으면 "미확인">

| ID | 결과 | 판정 | 근거 | 비용 |
| --- | --- | --- | --- | --- |
| HOME-01 | 통과 / 실패 / 보류 | 앱 결함 · 도구 오판 · 환경 · — | 실제 화면 문구나 checks 요약, artifacts 경로 | usage 합계 |

## 실패·보류 상세
<ID별: 기대 → 실제, 판정 이유>

## 회귀 테스트 후보
<통과한 A 등급 ID — 원본 repo 테스트로 옮길 후보>
```

판정은 녹화·스크린샷으로 확인한 뒤 적는다. 확인하지 못했으면 "판정 보류"로 둔다.

## 4. 지식 반영

- **도구 오판**: `knowledge.md` "흔들리는 화면·알려진 오판"에 한 줄. 이미 있으면 확인 시점만 갱신한다.
- 기존 오판 항목의 시나리오를 이번에 돌렸는데 재현되지 않았으면 항목 끝에 `미재현 1회`를 붙이고, 이미 `미재현 1회`면 항목을 지운다.
- 화면 문구가 계획과 달랐으면 실제 문구를 지식에 남기고, 다음 계획에서 고칠 시나리오로 보고한다(기존 계획 파일은 고치지 않는다).

## 5. 보고

결과 표 · 실패 판정 · 총비용 · 지식 변경 · 사용자가 할 일(원본 repo 수정 후보 등).
