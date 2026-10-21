# mobile-mcp (iOS·Android)

> **미확인 — 아직 설치·검증하지 않았다.** 설치 전에 공식 README(https://github.com/mobile-next/mobile-mcp)에서 명령과 iOS 요구 사항을 확인하고 이 문서를 고친다.

- 자체 모델 없이 화면 읽기·탭·입력 도구만 제공하는 MCP 서버로 알려져 있다. 판단은 연결한 LLM(Claude Code 등)이 한다.
- 이 폴더에서는 Claude Code에 **project 범위**로 등록한다(`claude mcp add ... --scope project`) — 등록 명령은 README 확인 후 여기에 적는다.
- 계획의 `goal`을 Claude Code에 그대로 주고, 판정·요약은 Artemis와 같은 형식으로 `runs/.../summary.md`에 남긴다.
