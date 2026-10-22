---
name: qa-run
description: Use when running scenarios from a mobile-twin-qa test plan on a device or simulator with Artemis or mobile-mcp — "파일럿 돌려줘", "계획 실행해줘", "HOME-01 돌려봐", or recording results of a run.
---

# qa-run — 계획 실행·결과 기록

작업 위치(메인 작업 트리)와 커밋은 AGENTS.md "작업 위치와 커밋"을 따른다.

## 1. 실행 전 점검 (기기를 건드리기 전에)

1. **계획 고르기**: 사용자가 말한 계획, 없으면 `plans/`에서 가장 최근 파일. 시나리오를 말하지 않았으면 계획의 "파일럿".
2. **계획이 낡았는지**: 소스의 현재 SHA(`qa-plan`과 같은 방법으로 찾은 소스)를 머리말 `commit`과 비교한다. 다르면 사용자에게 알리고 계속할지 묻는다.
3. **도구 상태**: `platform`별 러너(`project.yaml`의 `runners`) — Artemis는 `tools/artemis.md`의 `GET /api/devices`, mobile-mcp는 `tools/mobile-mcp.md`. 응답이 없으면 띄우는 방법을 알려 주고 멈춘다.
4. **확인받기** — 한 번에 묻는다:
   - 대상 기기(`project.local.yaml`의 `devices`, 비었으면 Android는 `adb devices -l`, iOS는 `xcrun simctl list devices booted` 결과에서 고르게)
   - 쓰는 서버(`project.yaml`의 `environments`)
   - 실행할 시나리오 목록과 각 등급(B는 사람이 해야 할 동작을 적는다)
   - 회사 프로젝트면 스크린샷이 LLM 제공자로 전송되는 것에 대한 승인
   - 빌드·설치를 할지(사용자가 이미 설치했으면 건너뜀)와 로그인할 계정 역할
   승인 전에 쓸 수 있는 것은 기기 목록 조회뿐이다. 빌드·설치·로그인, Artemis `POST /api/run`, mobile-mcp의 다른 모든 도구(스크린샷·화면 읽기 포함)는 승인 뒤에만 한다.

## 2. 실행 준비 (승인 뒤, 첫 시나리오 전)

1. **빌드·설치** (Android, 승인받았을 때): 소스(`qa-plan`과 같은 방법으로 찾은 소스) 루트에서 `project.yaml`의 `build.android`를 실행하고 `adb -s <serial> install -r <build.android_apk>`.
   - 빌드 명령이 소스 쪽 파일(예: `--dart-define-from-file=.env`)을 쓰면 그 파일이 있는지, 가리키는 서버가 승인받은 서버인지 먼저 확인한다. 서버를 정하는 키 줄만 `grep '^<키>='`로 읽고 파일 전체를 읽지 않는다. 없거나 다르면 빌드하지 않고 사용자에게 알린다.
   - 빌드 전후에 `git -C <소스> status --porcelain`과 `git -C <소스> diff | shasum`을 비교한다. 하나라도 다르면(git이 무시하지 않는 파일이 바뀜) 되돌리지 말고 멈춰 사용자에게 보고한다.
   - 빌드·설치가 실패하면 오류 끝부분을 보여 주고 멈춘다.
2. **앱 실행**: 빌드 여부와 상관없이 `adb -s <serial> shell am start -n <apps.android.launch>`.
3. **로그인** (Android, 앱이 로그인 화면일 때): 승인받은 역할의 키를 `project.yaml`의 `accounts`에서 찾아 실행한다. 그 역할이 `accounts`에 없으면 사용자에게 묻는다. `bash -x`로 실행하지 않는다.
   ```bash
   bash tools/android-login.sh <serial> <category>/<project>/.env <id_env> <password_env>
   ```
   - 종료 코드 0: 출력된 목록에서 로그인 버튼을 탭하고, 화면이 로그인 화면에서 바뀌었는지 확인한다. 로그인 화면에 오류 문구가 뜨면 그 문구를 알리고(아이디가 들어 있으면 빼고), 네트워크 오류면 버튼을 한 번만 다시 누른다. 그래도 안 되면 사용자에게 직접 로그인해 달라고 한다.
   - 종료 코드 3(키 없음): 사용자에게 그 키를 `<category>/<project>/.env`에 `KEY=value` 형식으로 넣어 달라고 하고 기다린다. 값을 대화로 받지 않는다.
   - 그 밖의 0이 아닌 코드: 출력된 이유를 알리고 사용자에게 직접 로그인해 달라고 한다. 다시 돌리거나 스크린샷으로 대신하지 않는다. 직접 로그인으로 바꾸는 데 새 승인은 필요 없다.
   - `.env` 값은 화면·로그·대화·`goal` 어디에도 출력하지 않는다.
   - iOS는 미확인이라 사용자가 로그인한다.
4. **사전 조건**: 첫 시나리오의 사전 조건(예: 근무 중)이 화면에 맞는지 확인한다. 맞지 않으면 사용자에게 알린다.

## 3. 실행

- 실행 폴더: `runs/<plan 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>/` — 첫 시나리오를 보내기 직전에 만든다. 같은 이름이 이미 있으면 1분 뒤 시각으로 다시 정한다.
- 시나리오를 **하나씩** 보낸다(Artemis는 `POST /api/run`에 계획의 실행 옵션과 `device_serial`). 끝날 때까지 `GET /api/sessions/{id}`로 상태를 보고, `tools/artemis.md` "멈춤 감시"에 걸리면 세션을 멈추고 결과를 "보류"(판정 "도구 오판" 또는 "환경")로 적는다.
- 네트워크 오류(시간 초과·연결 실패)로 실패하면 기기의 Wi-Fi 상태(Android는 `adb -s <serial> shell cmd wifi status`, iOS는 사용자에게 확인을 부탁한다)를 보고, 약하거나 끊겼으면 사용자에게 알린 뒤 고쳐졌다는 말을 듣고 같은 실행 폴더에서 한 번만 다시 돌린다. 다시 돌리기 전에 첫 시도의 파일을 `artifacts/<ID>/try1/`로 옮긴다. `summary.md`에는 다시 돌린 결과를 적고, 첫 실패는 상세에 "환경"과 `try1/` 경로로 한 줄 남긴다. 다시 돌려도 네트워크로 실패하면 "보류 / 환경"으로 적는다. 멈춤 감시에 걸린 원인이 네트워크였으면 이 규칙을 따른다. 이 실패는 앱 결함으로 적지 않는다.
- B 등급은 사람이 할 동작이 화면에 나올 시점을 사용자에게 미리 알린다.
- 시나리오마다 녹화를 `artifacts/<ID>/`에 받고, Artemis면 `checks`·`usage` 원본도 같은 곳에 받는다(`tools/artemis.md` 예시), `summary.md`에는 요약만 적는다. 녹화를 받지 못했으면 근거 칸에 "녹화 없음"을 적는다.
- 앞 시나리오 결과가 뒤 시나리오의 사전 조건이면, 앞이 실패했을 때 뒤는 보내지 않고 "보류"로 적는다.

## 4. summary.md

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

## 5. 지식 반영

- **도구 오판**: `knowledge.md` "흔들리는 화면·알려진 오판"에 한 줄. 이미 있으면 확인 시점만 갱신한다.
- 기존 오판 항목의 시나리오를 이번에 돌렸는데 재현되지 않았으면 항목 끝에 `미재현 1회`를 붙이고, 이미 `미재현 1회`면 항목을 지운다.
- 화면 문구가 계획과 달랐으면 실제 문구를 지식에 남기고, 다음 계획에서 고칠 시나리오로 보고한다(기존 계획 파일은 고치지 않는다).

## 6. 보고

결과 표 · 실패 판정 · 총비용 · 지식 변경 · 사용자가 할 일(원본 repo 수정 후보 등). 개인 프로젝트면 커밋할지 묻는다.
