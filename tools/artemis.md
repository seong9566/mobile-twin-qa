# Artemis (Android)

Artemis 설치 위치는 기기마다 다르므로 `ARTEMIS_HOME` 환경 변수로 가리킨다(예: `export ARTEMIS_HOME=~/Desktop/workspace/artemis`).

## 서버

```bash
cd "$ARTEMIS_HOME"
uv run artemis ui --port 8100      # 8000은 다른 서비스가 쓴다 — 8000으로 띄우지 않는다
uv run artemis doctor              # 기기·키 점검
```

- 휴대폰은 잠금 해제·홈 화면 상태여야 한다(잠겨 있으면 `POST /api/run`이 409).
- 모델 설정: `$ARTEMIS_HOME/config/artemis.jsonc`. 키: `$ARTEMIS_HOME/.env`.
- 설정을 바꾸면 서버를 재시작한다.

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
curl -s "$BASE/api/sessions/$SID/checks"   # 판정 → summary.md
curl -s "$BASE/api/sessions/$SID/usage"    # 비용 → summary.md
curl -s -o artifacts/<ID>/video.mp4 "$BASE/api/sessions/$SID/video"
curl -s -X POST "$BASE/api/stop" -H 'Content-Type: application/json' -d "{\"session_id\":\"$SID\"}"
```

- `app_path`(실행 전 APK 설치)·`locked_app_package`는 REST·`artemis run`에만 있고 웹 콘솔·`artemis batch`에는 없다.
- 결과물은 `runs/<plan 파일명(확장자 제외)>/<yyyy-mm-dd-HHmm>/artifacts/<시나리오 ID>/`에 받는다.

## 하지 않는 것

- NFC 태그 접촉·QR 인쇄물 비추기·두 번째 기기 조작은 Artemis가 못 한다 → 계획에서 B(반자동)로 둔다.
- 화면 좌표 그라운딩(`object_detector`)은 Gemini ER 모델을 쓴다 — `GEMINI_API_KEY`가 필요하다.
