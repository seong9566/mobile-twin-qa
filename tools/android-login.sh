#!/bin/bash
# 로그인 화면의 아이디 칸과 비밀번호 칸(password="true")에 .env 값을 넣는다. 값은 출력하지 않는다.
# 사용법: bash tools/android-login.sh <serial> <.env 경로> <아이디 키> <비밀번호 키>   (-x로 실행하지 않는다)
# .env 형식: 한 줄에 KEY=value. 셸 확장은 하지 않는다(따옴표 한 쌍만 벗긴다).
# 종료 코드: 0 입력 확인 · 2 입력할 수 없는 값 · 3 키 없음 · 4 로그인 화면을 못 찾음 · 5 입력 확인 실패 · 6 그 밖의 오류(adb 등)
# 입력 중 값이 잠깐 adb·input 프로세스 인자로 보인다(ps).
set +x
set -euo pipefail
trap 'exit 6' ERR
export LC_ALL=en_US.UTF-8
[ $# -eq 4 ] || { echo "사용법: bash tools/android-login.sh <serial> <.env 경로> <아이디 키> <비밀번호 키>"; exit 6; }
S=$1; ENV_FILE=$2; ID_KEY=$3; PW_KEY=$4
DUMP=/sdcard/android-login-ui.xml
trap 'adb -s "$S" shell rm -f "$DUMP" >/dev/null 2>&1 || true' EXIT

[ -f "${ENV_FILE}" ] || { echo "${ENV_FILE} 없음 — 사용자에게 ${ID_KEY}·${PW_KEY}를 넣어 달라고 한다"; exit 3; }
read_key() {  # read_key <키> — .env에서 그 키의 값만 읽는다
  local v
  v=$(grep -m1 -E "^$1=" "${ENV_FILE}" | cut -d= -f2- | tr -d '\r') || true
  [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]] && v=${BASH_REMATCH[1]}
  printf '%s' "$v"
}
ID=$(read_key "${ID_KEY}"); PW=$(read_key "${PW_KEY}")
[ -n "$ID" ] || { echo "${ID_KEY} 없음 — 사용자에게 ${ENV_FILE}에 넣어 달라고 한다"; exit 3; }
[ -n "$PW" ] || { echo "${PW_KEY} 없음 — 사용자에게 ${ENV_FILE}에 넣어 달라고 한다"; exit 3; }

# adb input text는 ASCII만 받는다. 공백은 %s, 나머지 특수문자는 기기 셸용으로 \ 이스케이프
for v in "$ID" "$PW"; do
  if printf '%s' "$v" | LC_ALL=C grep -q '[^ -~]'; then echo "ASCII가 아닌 문자가 있어 adb로 입력할 수 없다 — 사람이 로그인한다"; exit 2; fi
  if [[ "$v" == *%s* ]]; then echo "값에 %s가 있어 adb로 입력할 수 없다 — 사람이 로그인한다"; exit 2; fi
done
esc() { printf '%s' "$1" | sed -e 's/[^A-Za-z0-9 ]/\\&/g' -e 's/ /%s/g'; }

dump() {  # 화면 XML을 새로 받는다. 실패하면 빈 출력
  adb -s "$S" shell rm -f "$DUMP" >/dev/null
  adb -s "$S" shell uiautomator dump "$DUMP" >/dev/null 2>&1 || true
  adb -s "$S" shell cat "$DUMP" 2>/dev/null | grep -o '<hierarchy.*' || true
}
nodes() { grep -oE '<node [^>]*class="android.widget.EditText"[^>]*>' || true; }
id_node() { nodes | grep -v 'password="true"' | head -1; }
pw_node() { nodes | grep 'password="true"' | head -1; }
attr() { grep -oE " $1=\"[^\"]*\"" | sed -E "s/ $1=\"(.*)\"/\1/" || true; }
unxml() { sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g'; }

X=""
for _ in $(seq 8); do  # 앱이 뜨는 동안 8번까지 다시 읽는다(약 30초)
  X=$(dump)
  [ -n "$(printf '%s' "$X" | pw_node)" ] && [ -n "$(printf '%s' "$X" | id_node)" ] && break
  X=""; sleep 2
done
[ -n "$X" ] || { echo "아이디 칸·비밀번호 칸(password) 쌍을 못 찾음 — 로그인 화면이 아니다"; exit 4; }

fill() {  # fill <id|pw> <값> — 매번 화면을 새로 읽고 그 칸을 눌러 지운 뒤 입력
  local node x1 y1 x2 y2 t i
  node=$(dump | "$1_node")
  [ -n "$node" ] || { echo "$1 칸이 사라짐 — 입력하지 않고 멈춘다"; exit 4; }
  read -r x1 y1 x2 y2 <<<"$(printf '%s' "$node" | attr bounds | tr -c '0-9' ' ')"
  adb -s "$S" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 )); sleep 0.5
  t=$(printf '%s' "$node" | attr text | unxml)
  adb -s "$S" shell input keyevent KEYCODE_MOVE_END
  for (( i = 0; i < ${#t}; i += 40 )); do  # 한 번에 너무 길지 않게 나눠 지운다
    adb -s "$S" shell input keyevent $(printf 'KEYCODE_DEL %.0s' $(seq $(( ${#t} - i < 40 ? ${#t} - i : 40 ))))
  done
  adb -s "$S" shell input text "$(esc "$2")"; sleep 0.5
}
fill id "$ID"
fill pw "$PW"

# 키보드가 로그인 버튼을 가리지 않게 닫는다 — 키보드가 떠 있을 때만 BACK
if adb -s "$S" shell dumpsys input_method | grep -q 'mInputShown=true'; then
  adb -s "$S" shell input keyevent KEYCODE_BACK; sleep 1
fi

X=$(dump)
got_id=$(printf '%s' "$X" | id_node | attr text | unxml)
got_pw=$(printf '%s' "$X" | pw_node | attr text | unxml)
rc=0
if [ "$got_id" == "$ID" ]; then echo "아이디: 일치"; else echo "아이디: 불일치"; rc=5; fi
if [ "${#got_pw}" -eq "${#PW}" ]; then echo "비밀번호: 길이 일치(${#PW}자)"; else echo "비밀번호: 길이 불일치(입력 ${#got_pw}자 / 기대 ${#PW}자)"; rc=5; fi
echo "--- 누를 수 있는 요소 (로그인 버튼을 골라 탭한다)"
printf '%s' "$X" | grep -oE '<node [^>]*clickable="true"[^>]*>' | grep -v 'android.widget.EditText' \
  | while IFS= read -r n; do
      l=$(printf '%s' "$n" | attr content-desc); [ -n "$l" ] || l=$(printf '%s' "$n" | attr text)
      [ -z "$l" ] || echo "$l $(printf '%s' "$n" | attr bounds)"
    done || true
exit $rc
