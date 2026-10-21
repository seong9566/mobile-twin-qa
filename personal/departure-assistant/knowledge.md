# departure-assistant — 테스트 지식

<!-- 200줄 이하 · 한 줄에 한 항목 · 끝에 (yyyy-mm-dd · SHA) · 같은 주제는 고쳐 쓴다 · 규칙은 AGENTS.md "파일 형식" -->

## 셀렉터·화면 특성

- Android는 Flutter(`app/`), iOS는 네이티브 SwiftUI(`ios/`) — 같은 시나리오도 플랫폼별 문구·구조를 따로 확인한다 (2026-10-21 · 7bf7959)
- 사용자에게 보이는 「알람」은 양쪽 모두 「전화」로 바뀌었다(`STATUS.md:121`) (2026-10-21 · 7bf7959)

## 테스트 데이터·계정 준비

- 서버가 계획을 못 만들면 홈 카드에 「계획 불가」 배지가 뜬다 — 「임시값」 표시는 없어졌다(`app/lib/features/home/presentation/widgets/schedule_card.dart:274,312`) (2026-10-21 · 7bf7959)
- ODsay 키 `ApiKeyAuthFailed` 기록(`STATUS.md:101`) — 출발 역산 시나리오 전에 서버 `/health` 확인 (2026-10-21 · 7bf7959)

## 자동화가 안 되는 동작 (사람이 처리)

- VoIP 착신·잠금 화면·앱 완전 종료 후 착신·도즈 모드·AlarmKit 울림(`STATUS.md:56,68,74`) (2026-10-21 · 7bf7959)

## 흔들리는 화면·알려진 오판

## 문서-코드 불일치

- README "목업으로 물러나는 경우"는 「임시값입니다」 표시를 설명하지만 코드는 목업 폴백을 없앴다(T43, `app/lib/features/schedule/departure_estimate.dart:14-34`) (2026-10-21 · 7bf7959)
