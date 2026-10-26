---
project: demo_app
category: personal
created: 2026-01-02 09:00
author: Claude
source:
  repo: https://example.com/demo_app.git
  branch: main
  commit: abc1234
  dirty: true   # 작업 트리에 변경 있음
  app_version: 1.0.0+1
platforms: [android]
runners: { android: artemis, ios: mobile-mcp }
---

# demo_app 테스트 계획 (2026-01-02)

## 3. 준비

- 계정: `personal/demo_app/.env`의 `DEMO_USER_ID`·`DEMO_USER_PASSWORD`

## 4. 시나리오

공통 실행 옵션: `profile=pro`, `locked_app_package=com.demo`, `verification_level=checkpoints`

### 4.1 홈

#### HOME-01 · 첫 화면
- platform: android · 등급: A · 계정: 사용자
- goal: 앱을 열어 첫 화면 인사 문구를 적어.
- 통과 조건: "안녕하세요" 문구
- 근거: `home_screen.dart:10`

#### HOME-02 · 비상 전화 (HOME-01 뒤)
- platform: android · 등급: B(사람이 확인) · 계정: 사용자
- 실행 옵션: `locked_app_package` 빼고 실행
- goal: 비상 카드의 전화 버튼을 눌러 확인 시트 문구를 적어.
- 통과 조건: 확인 시트
- 근거: `emergency.dart:5`

#### SET-01 · 설정
- platform: android · 등급: A · 계정: 사용자
- 사전 조건: HOME-02의 확인까지
- goal: 설정 화면을 열어 현재 앱 버전을 적어.
- 통과 조건: 앱 버전 표시
- 근거: `settings.dart:20`

### 4.8 수동(C) — 목록만

- 착신 알림 확인
