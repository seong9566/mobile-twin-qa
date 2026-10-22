#!/bin/bash
# 로그인 화면의 첫 두 입력 칸에 .env의 아이디·비밀번호를 넣는다. 값은 출력하지 않는다.
# 사용법: bash tools/android-login.sh <serial> <.env 경로> <아이디 키> <비밀번호 키>
# 종료 코드: 0 입력 확인 · 2 입력할 수 없는 값 · 3 키 없음 · 4 입력 칸을 못 찾음 · 5 입력 확인 실패
set -euo pipefail
S=$1; ENV_FILE=$2; ID_KEY=$3; PW_KEY=$4

[ -f "${ENV_FILE}" ] || { echo "${ENV_FILE} 없음 — 사용자에게 ${ID_KEY}·${PW_KEY}를 넣어 달라고 한다"; exit 3; }
set -a; . "${ENV_FILE}"; set +a
ID="${!ID_KEY:-}"; PW="${!PW_KEY:-}"
for k in "${ID_KEY}" "${PW_KEY}"; do
  [ -n "${!k:-}" ] || { echo "${k} 없음 — 사용자에게 ${ENV_FILE}에 넣어 달라고 한다"; exit 3; }
done

# adb input text는 ASCII만 받는다. 공백은 %s, 나머지 특수문자는 기기 셸용으로 \ 이스케이프
for v in "$ID" "$PW"; do
  printf '%s' "$v" | LC_ALL=C grep -q '[^ -~]' && { echo "ASCII가 아닌 문자가 있어 adb로 입력할 수 없다 — 사람이 로그인한다"; exit 2; }
  [[ "$v" == *%s* ]] && { echo "값에 %s가 있어 adb로 입력할 수 없다 — 사람이 로그인한다"; exit 2; }
done
esc() { printf '%s' "$1" | sed -e 's/[^A-Za-z0-9 ]/\\&/g' -e 's/ /%s/g'; }

dump() { adb -s "$S" shell uiautomator dump /sdcard/ui.xml >/dev/null && adb -s "$S" shell cat /sdcard/ui.xml; }
edits() { grep -oE '<node [^>]*class="android.widget.EditText"[^>]*>'; }
attr() { grep -oE " $1=\"[^\"]*\"" | sed -E "s/ $1=\"(.*)\"/\1/"; }

X=$(dump)
[ "$(printf '%s' "$X" | edits | wc -l)" -ge 2 ] || { echo "입력 칸이 2개 미만 — 로그인 화면이 아니다"; exit 4; }

fill() {  # fill <몇 번째 칸> <값>
  local node b x y len
  node=$(printf '%s' "$X" | edits | sed -n "${1}p")
  b=$(printf '%s' "$node" | attr bounds | tr -c '0-9' ' ')
  read -r x1 y1 x2 y2 <<<"$b"; x=$(( (x1 + x2) / 2 )); y=$(( (y1 + y2) / 2 ))
  len=$(printf '%s' "$node" | attr text | wc -m | tr -d ' ')
  adb -s "$S" shell input tap "$x" "$y"; sleep 0.5
  adb -s "$S" shell input keyevent KEYCODE_MOVE_END
  [ "$len" -gt 0 ] && adb -s "$S" shell input keyevent $(printf 'KEYCODE_DEL %.0s' $(seq "$len"))
  adb -s "$S" shell input text "$(esc "$2")"; sleep 0.5
}
fill 1 "$ID"
fill 2 "$PW"

X=$(dump)
got_id=$(printf '%s' "$X" | edits | sed -n 1p | attr text)
got_pw=$(printf '%s' "$X" | edits | sed -n 2p | attr text)
ok=0
[ "$got_id" == "$ID" ] && echo "아이디: 일치" || { echo "아이디: 불일치"; ok=5; }
[ "${#got_pw}" -eq "${#PW}" ] && echo "비밀번호: 길이 일치(${#PW}자)" || { echo "비밀번호: 길이 불일치(입력 ${#got_pw}자 / 기대 ${#PW}자)"; ok=5; }
echo "--- 누를 수 있는 요소 (로그인 버튼을 골라 탭한다)"
printf '%s' "$X" | grep -oE '<node [^>]*clickable="true"[^>]*>' | grep -v 'android.widget.EditText' \
  | while IFS= read -r n; do l=$(printf '%s' "$n" | attr content-desc); [ -n "$l" ] || l=$(printf '%s' "$n" | attr text); [ -n "$l" ] && echo "$l $(printf '%s' "$n" | attr bounds)"; done || true
exit $ok
