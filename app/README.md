# QA Twin 맥 앱

## 빌드

저장소 루트에서 `bash app/scripts/bundle.sh`를 실행한다. 결과는 `app/QATwin.app`에 만들어진다.

## 첫 실행 설정

앱을 처음 열면 `mobile-twin-qa` 루트 폴더를 선택한다. 설정에서 Artemis 주소(기본값 `http://127.0.0.1:8100`), Artemis 홈·trace 폴더, Claude 실행 파일 경로를 확인한다. 알림 권한은 첫 실행 승인 때 요청한다.

## 흐름

앱 소스 폴더를 열어 프로젝트를 고르고 테스트 계획을 확인한 뒤, 기기·서버·시나리오를 승인해 실행한다. 실행이 끝나면 Claude Code 판정을 거쳐 결과, 녹화, 확인 항목과 수정 요청 md를 한 화면에서 검토한다.

화면 확인에는 `QATwin.app/Contents/MacOS/QATwin -openPlan <계획 경로>` 또는 `QATwin.app/Contents/MacOS/QATwin -openRun <실행 폴더 경로>`를 쓴다. 승인 시트도 열려면 `-openSheet approval`을 함께 준다.
