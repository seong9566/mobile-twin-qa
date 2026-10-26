---
project: demo_app
category: personal
created: 2026-01-01 09:00
author: Claude
source:
  repo: https://example.com/demo_app.git
  branch: main
  commit: def5678
  dirty: false
  app_version: 1.0.0+1
platforms: [android]
runners: { android: artemis, ios: mobile-mcp }
---

# demo_app 테스트 계획 (2026-01-01)

## 3. 준비

- 계정: `personal/demo_app/.env`의 `DEMO_USER_ID`·`DEMO_USER_PASSWORD`

## 4. 시나리오

공통 실행 옵션: `profile=pro`, `locked_app_package=com.demo`, `verification_level=checkpoints`

### HOME-01 · 첫 화면
- platform: android · 등급: A · 계정: 사용자
- goal: 앱을 열어 첫 화면 인사 문구를 적어.
- 통과 조건: "안녕하세요" 문구
- 근거: `home_screen.dart:10`

### 수동(C) — 목록만

- 착신 알림 확인
