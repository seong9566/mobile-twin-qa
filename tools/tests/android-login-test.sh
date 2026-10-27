#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURES="$ROOT/tools/tests/fixtures"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
printf 'USER_ID=user\nUSER_PASSWORD=pass\n' >"$TMP/test.env"

cat >"$TMP/bin/adb" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$*" in
  *"shell uiautomator dump"*)
    count=0
    [ ! -f "$STUB_STATE/count" ] || count=$(cat "$STUB_STATE/count")
    IFS=: read -r -a fixtures <<<"$ADB_FIXTURES"
    index=$count
    [ "$index" -lt "${#fixtures[@]}" ] || index=$(( ${#fixtures[@]} - 1 ))
    printf '%s' "$FIXTURE_DIR/${fixtures[$index]}" >"$STUB_STATE/current"
    printf '%s' $(( count + 1 )) >"$STUB_STATE/count"
    ;;
  *"shell cat"*)
    cat "$(cat "$STUB_STATE/current")"
    ;;
esac
STUB
cat >"$TMP/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMP/bin/adb" "$TMP/bin/sleep"

passed=0
run_login() {
  local fixtures=$1
  shift
  rm -f "$TMP/state/count" "$TMP/state/current"
  set +e
  output=$(ADB_FIXTURES="$fixtures" FIXTURE_DIR="$FIXTURES" STUB_STATE="$TMP/state" \
    PATH="$TMP/bin:$PATH" bash "$ROOT/tools/android-login.sh" serial "$TMP/test.env" \
    USER_ID USER_PASSWORD "$@" 2>&1)
  status=$?
  set -e
}
expect_status() {
  local expected=$1
  [ "$status" -eq "$expected" ] || {
    echo "FAIL: 종료 코드 $status (기대 $expected)"
    echo "$output"
    exit 1
  }
  passed=$(( passed + 1 ))
}

run_login logged-in.xml
expect_status 7

run_login login.xml:login.xml:login.xml:login.xml:login.xml:login.xml:logged-in.xml --tap 로그인 --wait 4
expect_status 0

run_login login.xml:login.xml:login.xml:login.xml:login.xml:login.xml:bad-password.xml --tap 로그인 --wait 4
expect_status 5
grep -Fq "비밀번호가 올바르지 않습니다." <<<"$output" || { echo "FAIL: 오류 문구 없음"; exit 1; }

run_login login.xml:login.xml:login.xml:login.xml:login.xml:login.xml:progress.xml --tap 로그인 --wait 4
expect_status 5
grep -Fq "응답 없음" <<<"$output" || { echo "FAIL: 응답 없음 문구 없음"; exit 1; }

run_login login.xml
expect_status 0

echo "ok $passed/5"
