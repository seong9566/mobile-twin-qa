#!/bin/bash
# 로그인 화면의 아이디 칸과 비밀번호 칸(password="true")에 .env 값을 넣는다. 값은 출력하지 않는다.
# 사용법: bash tools/android-login.sh <serial> <.env 경로> <아이디 키> <비밀번호 키> [--tap <글자>] [--wait <초>]   (-x로 실행하지 않는다)
# --tap을 주면 입력 확인 뒤 해당 글자가 든 버튼을 누른다. --wait 기본값은 30초다.
# .env 형식: 한 줄에 KEY=value. 셸 확장은 하지 않는다(따옴표 한 쌍만 벗긴다).
# 종료 코드: 0 입력 확인/로그인 · 2 입력할 수 없는 값 · 3 키 없음 · 4 입력 중 칸이 사라짐·포커스 안 됨 · 5 입력 확인/로그인 실패 · 6 그 밖의 오류(adb 등) · 7 로그인 화면을 못 찾음
# 입력 중 값이 잠깐 adb·input 프로세스 인자로 보인다(ps).
set +x
set -Eeuo pipefail
trap 'exit 6' ERR
export LC_ALL=en_US.UTF-8
[ $# -ge 4 ] || { echo "사용법: bash tools/android-login.sh <serial> <.env 경로> <아이디 키> <비밀번호 키> [--tap <글자>] [--wait <초>]"; exit 6; }
S=$1; ENV_FILE=$2; ID_KEY=$3; PW_KEY=$4
shift 4
TAP_TEXT=""; WAIT_SECONDS=30
while [ $# -gt 0 ]; do
  case "$1" in
    --tap)
      [ $# -ge 2 ] || { echo "--tap 뒤에 글자가 필요하다"; exit 6; }
      TAP_TEXT=$2; shift 2
      ;;
    --wait)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "--wait 뒤에 0 이상의 초가 필요하다"; exit 6; }
      WAIT_SECONDS=$2; shift 2
      ;;
    *)
      echo "알 수 없는 옵션: $1"; exit 6
      ;;
  esac
done
DUMP=/sdcard/android-login-ui.xml
adb -s "$S" get-state >/dev/null 2>&1 || { echo "기기 ${S}에 연결할 수 없다"; exit 6; }
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
id_node() { nodes | grep -v 'password="true"' | head -1 || true; }
pw_node() { nodes | grep 'password="true"' | head -1 || true; }
attr() { grep -oE " $1=\"[^\"]*\"" | sed -E "s/ $1=\"(.*)\"/\1/" || true; }
unxml() { sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g'; }

X=""
for _ in $(seq 8); do  # 앱이 뜨는 동안 8번까지 다시 읽는다(약 30초)
  X=$(dump)
  [ -n "$(printf '%s' "$X" | pw_node)" ] && [ -n "$(printf '%s' "$X" | id_node)" ] && break
  X=""; sleep 2
done
[ -n "$X" ] || { echo "아이디 칸·비밀번호 칸(password) 쌍을 못 찾음 — 로그인 화면이 아니다"; exit 7; }

fill() {  # fill <id|pw> <값> — 매번 화면을 새로 읽고 그 칸을 눌러 지운 뒤 입력
  local node x1 y1 x2 y2 t i
  node=$(dump | "$1_node")
  [ -n "$node" ] || { echo "$1 칸이 사라짐 — 입력하지 않고 멈춘다"; exit 4; }
  read -r x1 y1 x2 y2 <<<"$(printf '%s' "$node" | attr bounds | tr -c '0-9' ' ')"
  adb -s "$S" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 )); sleep 0.5
  node=$(dump | "$1_node")  # 탭이 키보드 등에 맞았으면 포커스가 없다 — 그 칸에 입력하지 않는다
  printf '%s' "$node" | grep -q 'focused="true"' || { echo "$1 칸에 포커스가 가지 않음 — 입력하지 않고 멈춘다"; exit 4; }
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
ims=$(adb -s "$S" shell dumpsys input_method)
if grep -q 'mInputShown=true' <<<"$ims"; then
  adb -s "$S" shell input keyevent KEYCODE_BACK; sleep 1
fi

X=$(dump)
got_id=$(printf '%s' "$X" | id_node | attr text | unxml)
got_pw=$(printf '%s' "$X" | pw_node | attr text | unxml)
rc=0
if [ "$got_id" == "$ID" ]; then echo "아이디: 일치"; else echo "아이디: 불일치"; rc=5; fi
if [ "${#got_pw}" -eq "${#PW}" ]; then echo "비밀번호: 길이 일치(${#PW}자)"; else echo "비밀번호: 길이 불일치(입력 ${#got_pw}자 / 기대 ${#PW}자)"; rc=5; fi
if [ -z "$TAP_TEXT" ]; then  # 옵션이 없으면 예전과 똑같이 목록을 보이고 확인 결과로 끝낸다
  echo "--- 누를 수 있는 요소 (로그인 버튼을 골라 탭한다)"
  printf '%s' "$X" | grep -oE '<node [^>]*clickable="true"[^>]*>' | grep -v 'android.widget.EditText' \
    | while IFS= read -r n; do
        l=$(printf '%s' "$n" | attr content-desc); [ -n "$l" ] || l=$(printf '%s' "$n" | attr text)
        [ -z "$l" ] || echo "$l $(printf '%s' "$n" | attr bounds)"
      done || true
  exit $rc
fi
[ $rc -eq 0 ] || exit $rc

# 탭할 글자가 든 clickable 요소가 여럿이면 화면에서 가장 아래 것을 고른다.
tap_node=""; tap_label=""; tap_y=-1
while IFS= read -r n; do
  text=$(printf '%s' "$n" | attr text | unxml)
  desc=$(printf '%s' "$n" | attr content-desc | unxml)
  [[ "$text" == *"$TAP_TEXT"* || "$desc" == *"$TAP_TEXT"* ]] || continue
  read -r x1 y1 x2 y2 <<<"$(printf '%s' "$n" | attr bounds | tr -c '0-9' ' ')"
  if [ "$y2" -ge "$tap_y" ]; then
    tap_node=$n; tap_label=$text; [ -n "$tap_label" ] || tap_label=$desc; tap_y=$y2
  fi
done < <(printf '%s' "$X" | grep -oE '<node [^>]*clickable="true"[^>]*>' | grep -v 'android.widget.EditText' || true)
[ -n "$tap_node" ] || { echo "${TAP_TEXT} 버튼을 찾지 못함"; exit 5; }
read -r x1 y1 x2 y2 <<<"$(printf '%s' "$tap_node" | attr bounds | tr -c '0-9' ' ')"

# 오류는 탭하기 직전에는 없던 일반 텍스트만 대상으로 한다.
texts() {
  local n class text desc
  while IFS= read -r n; do
    class=$(printf '%s' "$n" | attr class)
    [ "$class" == "android.widget.EditText" ] && continue
    text=$(printf '%s' "$n" | attr text | unxml)
    desc=$(printf '%s' "$n" | attr content-desc | unxml)
    [ -z "$text" ] || printf '%s\n' "$text"
    [ -z "$desc" ] || printf '%s\n' "$desc"
  done < <(grep -oE '<node [^>]*>' || true)
}
before_texts=$(printf '%s' "$X" | texts)
new_error() {
  local value redacted
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    grep -Fxq -- "$value" <<<"$before_texts" && continue
    [ "$value" == "$tap_label" ] && continue
    [[ "$value" =~ (중|…|\.\.\.)$ ]] && continue
    redacted=${value//"$ID"/}
    redacted=$(printf '%s' "$redacted" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$redacted" ] || { printf '%s\n' "$redacted"; return; }
  done < <(printf '%s' "$1" | texts)
}

adb -s "$S" shell input tap $(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))
elapsed=0
while [ "$elapsed" -lt "$WAIT_SECONDS" ]; do
  delay=2
  [ $(( WAIT_SECONDS - elapsed )) -ge 2 ] || delay=$(( WAIT_SECONDS - elapsed ))
  sleep "$delay"
  elapsed=$(( elapsed + delay ))
  X=$(dump)
  if [ -z "$(printf '%s' "$X" | pw_node)" ] && [ -z "$(printf '%s' "$X" | id_node)" ]; then
    exit 0
  fi
  error=$(new_error "$X")
  [ -z "$error" ] || { echo "$error"; exit 5; }
done
echo "응답 없음"
exit 5
