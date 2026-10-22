# Artemis (Android)

Artemis 설치 위치는 기기마다 다르므로 `ARTEMIS_HOME` 환경 변수로 가리킨다(예: `export ARTEMIS_HOME=~/Desktop/workspace/artemis`).

## 서버

```bash
(cd "$ARTEMIS_HOME" && uv run artemis doctor)           # 기기·키 점검 (먼저)
(cd "$ARTEMIS_HOME" && uv run artemis ui --port 8100)   # 별도 터미널에서 띄워 둔다(끝나지 않음). 서브셸이라 현재 폴더는 그대로. 8000은 다른 서비스가 쓴다
```

- 휴대폰은 잠금 해제·홈 화면 상태여야 한다(잠겨 있으면 `POST /api/run`이 409).
- 모델 설정: `$ARTEMIS_HOME/config/artemis.jsonc`. 키: `$ARTEMIS_HOME/.env`.
- 설정을 바꾸면 서버를 재시작한다.
- Claude 5.x 모델: 원본 Artemis는 Anthropic 요청에 `temperature`·`thinking.budget_tokens`를 보내는데, Claude 5.x는 이를 거부한다(Claude API 문서 기준). `artemis/llm/router.py`의 Anthropic 분기에서 5.x 모델이면 `temperature`를 빼고 `thinking={"type": "adaptive"}`와 effort(`ChatAnthropic`의 `reasoning_effort` 인자 → API의 `output_config.effort`)를 넘기도록 고친다. 고친 뒤 실제 호출로 한 번 확인한다. 화면 좌표 노드(`object_detector`)는 Gemini ER로 둔다.

## 실행 (REST)

```bash
BASE=http://127.0.0.1:8100
curl -s "$BASE/api/devices"
SID=$(curl -s -X POST "$BASE/api/run" -H 'Content-Type: application/json' -d '{
  "goal": "<계획의 goal>",
  "profile": "pro",
  "locked_app_package": "<project.yaml apps.android.package>",
  "verification_level": "checkpoints",
  "device_serial": "<project.local.yaml devices.android>"
}' | jq -r '.tasks[0].session_id')

curl -s "$BASE/api/sessions/$SID"          # status: completed | failed | cancelled
RUN="$(git -C <mobile-twin-qa 경로> rev-parse --show-toplevel)/<category>/<project>/runs/<plan 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>"   # 절대 경로 — qa-run의 실행 폴더
mkdir -p "$RUN/artifacts/<ID>"
curl -sSf -o "$RUN/artifacts/<ID>/checks.json" "$BASE/api/sessions/$SID/checks"   # 원본 저장, summary.md에는 요약만
curl -sSf -o "$RUN/artifacts/<ID>/usage.json"  "$BASE/api/sessions/$SID/usage"
curl -sSf -o "$RUN/artifacts/<ID>/video.json"  "$BASE/api/sessions/$SID/video"   # 녹화 파일이 아니라 위치 정보(JSON)
U=$(jq -r '.video_url // empty' "$RUN/artifacts/<ID>/video.json")
[ -n "$U" ] && curl -sSf -o "$RUN/artifacts/<ID>/video.mp4" "$BASE$U"          # 비었거나 실패하면 summary.md에 "녹화 없음"
curl -s -X POST "$BASE/api/stop" -H 'Content-Type: application/json' -d "{\"session_id\":\"$SID\"}"
```

- `app_path`(실행 전 APK 설치)·`locked_app_package`는 REST·`artemis run`에만 있고 웹 콘솔·`artemis batch`에는 없다.
- 결과물은 `runs/<plan 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>/artifacts/<시나리오 ID>/`에 받는다.

## 하지 않는 것

- NFC 태그 접촉·QR 인쇄물 비추기·두 번째 기기 조작은 Artemis가 못 한다 → 계획에서 B(반자동)로 둔다.
- 화면 좌표 그라운딩(`object_detector`)은 Gemini ER 모델을 쓴다 — `GEMINI_API_KEY`가 필요하다.
