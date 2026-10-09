#!/usr/bin/env bash
#
# The setup container for real, on any Linux box with Docker, for an app on
# this chassis. The app's own steps come from <app>/tests/e2e-app.sh, which
# defines app_e2e_answers (extra answers.env lines) and app_e2e_act (checks).
#   chassis/tests/e2e.sh <app dir> up|act|down|clean|wipe
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); CH=$(cd "$here/.." && pwd); APPDIR=$(cd "${1:?app dir}" && pwd); shift
. "$APPDIR/package.conf"
E2E=${E2E_DIR:-${TMPDIR:-/tmp}/$PKG_NAME-e2e}; PKG=$E2E/target; VAR=$E2E/var; APP=$E2E/share; PORT=${E2E_PORT:-$PORT}; NAME=$PKG_NAME-setup-e2e
[[ -f "$APPDIR/tests/e2e-app.sh" ]] && . "$APPDIR/tests/e2e-app.sh"
log() { echo "== $*"; }
up() {
  mkdir -p "$PKG" "$VAR" "$APP"; rm -rf "$PKG"/*
  bash "$CH/build.sh" "$APPDIR" 999 >/dev/null && tar -C "$PKG" -xzf <(tar -xOf "$APPDIR/dist/$PKG_NAME-$(tr -d ' \n' < "$APPDIR/VERSION")-999.spk" package.tgz)
  echo "$(tr -d ' \n' < "$APPDIR/VERSION")-e2e" > "$PKG/build-id"
  if [[ ! -f "$APP/.env" ]]; then
    { printf "LAN_IP='127.0.0.1'\nTZ='Europe/London'\nHTTP_PORT='%s'\nHOST_UID='%s'\nHOST_GID='%s'\n" "$PORT" "$(id -u)" "$(id -g)"; declare -F app_e2e_answers >/dev/null && app_e2e_answers; } > "$VAR/answers.env"
  fi
  docker build -q -t "$PKG_NAME-setup:local" "$PKG/setup" >/dev/null || { echo "the setup image didn't build"; exit 1; }
  docker rm -f "$NAME" >/dev/null 2>&1; rm -f "$VAR/state"
  log "starting the setup container ($NAME); its log: $VAR/package.log"
  docker run -d --name "$NAME" --user 0:0 --network host -e CHASSIS_PKG_DIR=/pkg -e CHASSIS_VAR_DIR=/pkgvar -e CHASSIS_APP_DIR="$APP" \
    -v /var/run/docker.sock:/var/run/docker.sock -v "$PKG:/pkg:ro" -v "$VAR:/pkgvar" -v "$APP:$APP" --entrypoint bash "$PKG_NAME-setup:local" /pkg/setup/run.sh >/dev/null || exit 1
  local t=0 phase_seen=""
  while (( t < 900 )); do
    case "$(cat "$VAR/state" 2>/dev/null)" in
      starting) [[ -f "$VAR/phase" && -z "$phase_seen" ]] && { phase_seen=1; echo "  (phase: $(cat "$VAR/phase"))"; } ;;
      running) until jq -e '.at' "$VAR/status.json" >/dev/null 2>&1; do sleep 2; done; log "state: running"; return 0 ;;
      failed) log "state: FAILED"; tail -n 30 "$VAR/package.log"; return 1 ;;
    esac
    docker ps -q --filter "name=^$NAME$" | grep -q . || { log "the setup container exited"; docker logs "$NAME" 2>&1 | tail -n 5; return 1; }
    sleep 5; t=$(( t + 5 ))
  done; log "not running after 15 minutes"; tail -n 30 "$VAR/package.log"; return 1
}
request() {   # lines… — done when the loop has answered THIS request
  local f="$VAR/request" start what; start=$(date +%s); what=$(sed -n "s/^ACTION='\([a-z]*\)'$/\1/p" <<< "$1")
  printf '%s\n' "$@" "BY='e2e'" > "$f.tmp" && mv "$f.tmp" "$f"; touch "$VAR/watching"
  while [[ -f "$f" || "$(jq -r '.busy // ""' "$VAR/status.json" 2>/dev/null)" != "" || "$(jq -r '.last.action // ""' "$VAR/status.json" 2>/dev/null)" != "$what" || "$(jq -r '.last.at // 0' "$VAR/status.json" 2>/dev/null)" -lt "$start" ]]; do
    sleep 2; touch "$VAR/watching"; (( $(date +%s) - start > 900 )) && { echo "  TIMEOUT waiting for: $1"; return 1; }
    docker ps -q --filter "name=^$NAME$" | grep -q . || { echo "  FAIL the setup container died during: $1"; docker logs --tail 3 "$NAME" 2>&1 | sed 's/^/       /'; return 1; }
  done
  jq -r '"  " + (if .last.ok then "ok  " else "FAIL" end) + " " + .last.action + " (" + (.last.took|tostring) + " s): " + .last.message' "$VAR/status.json"; [[ "$(jq -r '.last.ok' "$VAR/status.json")" == true ]]
}
act() {
  local fail=0 name
  log "status"; jq -c '{parts, version, url, app: (.app | if . == null then null else (keys) end)}' "$VAR/status.json"
  request "ACTION='backup'" || fail=1
  name=$(jq -r '.backups[0].name // ""' "$VAR/status.json"); [[ -n "$name" ]] && echo "  ok   backup listed: $name" || { echo "  FAIL no backup listed"; fail=1; }
  tar -tf "$APP/backups/$name" | grep -qE '/(MANIFEST|env)$' && echo "  ok   backup has manifest and env" || { echo "  FAIL backup contents"; fail=1; }
  request "ACTION='check'" || fail=1
  request "ACTION='report'" || fail=1; grep -qE 'lan-ip-1' "$VAR/report.txt" && echo "  ok   report is redacted" || { echo "  FAIL report not redacted"; fail=1; }
  declare -F app_e2e_act >/dev/null && { app_e2e_act || fail=1; }
  request "ACTION='settings'" "APP_URL='http://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='1'" "APP_TZ='Europe/Paris'" || fail=1
  request "ACTION='settings'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" || fail=1
  request "ACTION='restore'" "BACKUP='$name'" || fail=1
  request "ACTION='delbackup'" "BACKUP='$name'" || fail=1
  request "ACTION='restart'" || fail=1
  local n0; n0=$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log"); printf "ACTION='restart'\nBY='\$(id)'\n" > "$VAR/request"
  for i in $(seq 1 30); do touch "$VAR/watching"; [[ ! -f "$VAR/request" ]] && break; sleep 3; done
  [[ "$(grep -c "ignoring a request that wasn't in order" "$VAR/package.log")" -gt "$n0" ]] && echo "  ok   hostile request ignored" || { echo "  FAIL hostile request not ignored"; fail=1; }
  echo; (( fail == 0 )) && echo "e2e actions: all passed" || echo "e2e actions: something FAILED (above)"; return $fail
}
wipe() {
  local fail=0 s v
  request "ACTION='wipe'" "CONFIRM='REMOVEEVERYTHING'" || fail=1
  for s in $SERVICES; do docker ps -a --format '{{.Names}}' | grep -qx "$PKG_NAME-$s" && { echo "  FAIL $PKG_NAME-$s remains"; fail=1; }; done
  for v in $VOLUMES; do docker volume ls -q | grep -qx "${PKG_NAME}_$v" && { echo "  FAIL volume $v remains"; fail=1; }; done
  [[ -z "$(ls -A "$APP" | grep -v package.log)" ]] && echo "  ok   share emptied" || { echo "  FAIL share not empty: $(ls -A "$APP" | paste -sd' ')"; fail=1; }
  [[ "$(cat "$VAR/state")" == removed ]] && echo "  ok   state: removed" || { echo "  FAIL state"; fail=1; }
  (( fail == 0 )) && echo "  wipe: all passed" || echo "  wipe: something FAILED"; return $fail
}
down() { log "stopping the setup container (SIGTERM)"; docker stop -t 180 "$NAME" >/dev/null 2>&1; sleep 1
  [[ "$(cat "$VAR/state" 2>/dev/null)" =~ ^(stopped|removed)$ ]] && echo "  ok   state: $(cat "$VAR/state")" || echo "  FAIL state: $(cat "$VAR/state" 2>/dev/null)"
  echo "  setup container's last stderr lines:"; docker logs "$NAME" 2>&1 >/dev/null | tail -n 6 | sed 's/^/     /'; docker rm -f "$NAME" >/dev/null 2>&1; }
clean() { down; local s v; for s in $SERVICES; do docker rm -f "$PKG_NAME-$s" >/dev/null 2>&1; done; for v in $VOLUMES; do docker volume rm "${PKG_NAME}_$v" >/dev/null 2>&1; done; docker network rm "${PKG_NAME}_default" >/dev/null 2>&1
  [[ -d "$E2E" ]] && docker run --rm -v "$E2E:/e" alpine sh -c 'rm -rf /e/share /e/var /e/target' 2>/dev/null; rm -rf "$E2E" 2>/dev/null || rmdir "$E2E" 2>/dev/null || true; }
case "${1:-all}" in up) up ;; act) act ;; wipe) wipe ;; down) down ;; clean) clean ;; all) up && act; rc=$?; down; exit $rc ;; esac
