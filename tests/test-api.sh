#!/usr/bin/env bash
# The chassis's api.cgi, as built for an app, with a stub sign-in: roles and every core branch.
#   chassis/tests/test-api.sh <target/ui dir> [app dir]   (the app dir's tests/app-api.sh adds its own checks)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); UI=$(cd "${1:?target/ui dir}" && pwd); CGI=$UI/api.cgi; APPDIR=${2:-}
. "$UI/pkg.env"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export CHASSIS_VAR=$work/var CHASSIS_SHARE=$work/share CHASSIS_PKG=$work/pkg CHASSIS_AUTH_CGI=$here/stub-auth.sh CHASSIS_ADMINS=$(id -gn)
mkdir -p "$CHASSIS_VAR" "$CHASSIS_SHARE/backups" "$CHASSIS_PKG"; echo running > "$CHASSIS_VAR/state"
echo "{\"at\":1,\"backups\":[{\"name\":\"$PKG_NAME-20260101-0200.tar\",\"size\":3,\"at\":1}]}" > "$CHASSIS_VAR/status.json"; echo hi > "$CHASSIS_SHARE/backups/$PKG_NAME-20260101-0200.tar"; echo "# notes" > "$CHASSIS_PKG/CHANGELOG.md"
pass=0; fail=0; me=$(id -un)
get() { STUB_USER=$1 REQUEST_METHOD=GET QUERY_STRING=$2 "$CGI"; }
post() { local body=$3; STUB_USER=$1 REQUEST_METHOD=POST QUERY_STRING="action=$2" CONTENT_LENGTH=${#body} "$CGI" <<< "$body"; }
expect() { local got; got=$(sed -n '1s/^Status: \([0-9]*\).*/\1/p' <<< "$3"); if [[ "$got" == "$2" ]]; then (( pass++ )); echo "  ok   $1"; else (( fail++ )); echo "  FAIL $1: wanted $2, got ${got:-nothing}"; fi; }
request_is() { if [[ "$(cat "$CHASSIS_VAR/request" 2>/dev/null)" == "$2" ]]; then (( pass++ )); echo "  ok   $1"; else (( fail++ )); echo "  FAIL $1: $(cat "$CHASSIS_VAR/request" 2>/dev/null | paste -sd'|')"; fi; rm -f "$CHASSIS_VAR/request"; }
expect "no session → 401" 401 "$(get '' 'action=status')"
expect "admin status → 200" 200 "$(get "$me" 'action=status')"
[[ -f "$CHASSIS_VAR/watching" ]] && { (( pass++ )); echo "  ok   status touches watching"; } || { (( fail++ )); echo "  FAIL watching"; }
expect "non-admin → viewer, status 200" 200 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=status')"
CHASSIS_ADMINS=no-such-group get "$me" 'action=status' | grep -q '"role":"viewer"' && { (( pass++ )); echo "  ok   role viewer"; } || { (( fail++ )); echo "  FAIL role"; }
expect "viewer log → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=log&part=setup')"
expect "viewer POST → 403" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" restart 'action=restart')"
expect "log setup" 200 "$(get "$me" 'action=log&part=setup')"; expect "log bad part" 400 "$(get "$me" 'action=log&part=../x')"
expect "changelog" 200 "$(get "$me" 'action=changelog')"; expect "report before made → 404" 404 "$(get "$me" 'action=report')"
expect "backup listed" 200 "$(get "$me" "action=backup&name=$PKG_NAME-20260101-0200.tar")"; expect "backup traversal → 404" 404 "$(get "$me" 'action=backup&name=../.env')"
expect "restart → 202" 202 "$(post "$me" restart 'action=restart')"; request_is "restart request" "ACTION='restart'
BY='$me'"
touch "$CHASSIS_VAR/request"; expect "second while pending → 409" 409 "$(post "$me" backup 'action=backup')"; rm -f "$CHASSIS_VAR/request"
expect "restore listed" 202 "$(post "$me" restore "action=restore&name=$PKG_NAME-20260101-0200.tar")"; rm -f "$CHASSIS_VAR/request"
expect "restore unlisted" 400 "$(post "$me" restore "action=restore&name=$PKG_NAME-20260109-0200.tar")"
expect "settings good" 202 "$(post "$me" settings 'action=settings&url=https%3A%2F%2Fhelp.example.com&port=8060&ssl_proxy=1&tz=Europe%2FLondon')"; rm -f "$CHASSIS_VAR/request"
expect "settings bad url" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F1.2.3.4%3A8060%2Fx&port=8060&ssl_proxy=0&tz=UTC')"
expect "settings bad tz" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F1.2.3.4&port=8060&ssl_proxy=0&tz=%24(id)')"
expect "prefs good" 200 "$(post "$me" prefs 'action=prefs&nightly=1&keep=30')"; expect "prefs bad" 400 "$(post "$me" prefs 'action=prefs&nightly=1&keep=0')"
expect "wipe wrong phrase" 400 "$(post "$me" wipe 'action=wipe&confirm=yes')"; expect "wipe" 202 "$(post "$me" wipe 'action=wipe&confirm=remove+everything')"; request_is "wipe request" "ACTION='wipe'
CONFIRM='REMOVEEVERYTHING'
BY='$me'"
expect "unknown action" 400 "$(post "$me" rm 'action=rm')"; expect "oversized body" 400 "$(STUB_USER=$me REQUEST_METHOD=POST CONTENT_LENGTH=99999 "$CGI" <<< 'action=restart')"
expect "non-numeric length" 400 "$(STUB_USER=$me REQUEST_METHOD=POST CONTENT_LENGTH='x[$(id)]' "$CGI" <<< 'action=restart')"
expect "take_secret none → 404" 404 "$(post "$me" take_secret 'action=take_secret')"; echo '{"email":"a","password":"x"}' > "$CHASSIS_VAR/secret.json"
expect "take_secret once → 200" 200 "$(post "$me" take_secret 'action=take_secret')"; [[ ! -f "$CHASSIS_VAR/secret.json" ]] && { (( pass++ )); echo "  ok   secret removed"; } || { (( fail++ )); echo "  FAIL secret"; }
[[ -n "$APPDIR" && -f "$APPDIR/tests/app-api.sh" ]] && . "$APPDIR/tests/app-api.sh"   # the app's own CGI checks
echo; echo "api.cgi: $pass passed, $fail failed"; (( fail == 0 ))
