#!/usr/bin/env bash
#
# The setup container's life, for any Docker app packaged for DSM with this
# chassis: install the app's compose project into the shared folder, start it,
# keep watch, and do the things only root can — backups, settings, updates,
# a support report, removal. Runs as root with Docker's socket.
#
# What is the app's is in /pkg/setup/app.sh (sourced below), which fills the
# hooks named app_* — see README.md in the chassis for the contract. What the
# package's own user leaves here ($VAR/answers.env from the wizard, $VAR/request
# from the window's api.cgi, $VAR/prefs) is read as data, never run.
set -euo pipefail

PKG=${CHASSIS_PKG_DIR:-/pkg}
VAR=${CHASSIS_VAR_DIR:-/pkgvar}
# package.conf, as the build wrote it: PKG_NAME PKG_TITLE APP_ID REPO SERVICES VOLUMES IMAGE_VARS …
. "$PKG/setup/pkg.env"
APP=${CHASSIS_APP_DIR:-/var/packages/$PKG_NAME/shares/$PKG_NAME}
LOG=$VAR/package.log
UPDATES=updates
export COMPOSE_PROJECT_NAME=$PKG_NAME

BUSY=""; LAST="null"; UPDATE_AT=0; DISK_AT=0; STOPPING=0; WIPED=0
APPJ="null"; STATUS_ERR=""; MAIL_JSON="null"; DISK_JSON="null"; UPDATE_JSON="null"; IMAGE_UPDATE="null"; STORAGE_JSON="null"; STORAGE_AT=0
HOST_UID=1000; HOST_GID=1000; MSG=""

# ------------------------------------------------------------------ basics
say() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOG"; }
set_state() { echo "$1" > "$VAR/state"; }
phase() { printf '%s\n' "$1" > "$VAR/phase.tmp" && mv "$VAR/phase.tmp" "$VAR/phase"; say "$1"; }
publish_log() { cp "$LOG" "$APP/package.log" 2>/dev/null || true; }
failed() { say "✗ $*"; set_state failed; write_status 2>/dev/null || true; publish_log; exit 1; }
fresh() { [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1") < $2 )); }
env_get() { grep -E "^$1=" "$APP/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
env_set() {   # key value — .env rewritten whole; values come from validated inputs or are made here
  { grep -vE "^$1=" "$APP/.env" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$APP/.env.tmp"
  chmod 600 "$APP/.env.tmp"; mv "$APP/.env.tmp" "$APP/.env"
}
json() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$(tr -d '\000-\037' <<< "$s")"; }
for_window() { chown "$HOST_UID:$HOST_GID" "$1.tmp" 2>/dev/null || true; chmod 600 "$1.tmp"; mv "$1.tmp" "$1"; }
now() { date +%s; }
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }
qr_png_b64() { qrencode -t PNG -s 6 -m 2 -o - "$1" 2>/dev/null | base64 -w0; }   # text → a QR code as base64 PNG, for an <img> in the window
compose() { docker compose -f "$APP/compose.yaml" --project-directory "$APP" "$@"; }
has() { declare -F "$1" >/dev/null; }                   # is this hook defined by app.sh?
# A short-lived container over one of the app's volumes (this image has tar, du, sqlite3):
# nothing from the share is mounted into it — what goes in arrives on stdin, what comes out leaves on stdout.
in_volume() { local vol=$1 mode=$2; shift 2; [[ "${1:-}" == -- ]] && shift
  # Made here before compose's first up, so made with compose's labels — or compose warns the volume isn't its own.
  docker volume inspect "${PKG_NAME}_$vol" >/dev/null 2>&1 || docker volume create --label com.docker.compose.project="$PKG_NAME" --label com.docker.compose.volume="$vol" "${PKG_NAME}_$vol" >/dev/null
  docker run --rm -i --entrypoint sh -v "${PKG_NAME}_$vol:/vol:$mode" "$PKG_NAME-setup:local" -c "$*"; }

# A file the package's user wrote: only the names given, each with a value of
# its own shape (the app's names through app_validate), the whole file refused on one bad line.
read_settings() {   # file, allowed names…
  local file=$1 line key value re="^([A-Z][A-Z0-9_]*)='([A-Za-z0-9._/+@:-]*)'$"; shift
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $re ]] || return 1
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ " $* " == *" $key "* ]] || return 1
    [[ -z "$value" ]] && continue
    case "$key" in
      LAN_IP)                 [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ;;
      TZ|APP_TZ)              [[ "$value" =~ ^([A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$ ]] ;;
      HTTP_PORT)              [[ "$value" =~ ^[0-9]{2,5}$ ]] && (( value >= 1024 && value <= 65535 )) ;;
      HOST_UID|HOST_GID)      [[ "$value" =~ ^[0-9]{1,6}$ ]] ;;
      ACTION)                 [[ "$value" =~ ^(restart|backup|restore|delbackup|settings|updateapp|upgrade|check|clearcache|report|wipe|${APP_ACTIONS:-none})$ ]] ;;
      BY)                     [[ "$value" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] ;;
      BACKUP)                 [[ "$value" =~ ^$PKG_NAME-[0-9]{8}-[0-9]{4}(-[a-z]{1,12})?\.tar$ ]] ;;
      APP_URL)                [[ "$value" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{2,5})?$ ]] ;;
      SSL_PROXY|ON)           [[ "$value" =~ ^[01]$ ]] ;;
      CONFIRM)                [[ "$value" == REMOVEEVERYTHING ]] ;;
      *)                      has app_validate && app_validate "$key" "$value" ;;
    esac || return 1
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$file"
}
ANSWER_KEYS="LAN_IP TZ HTTP_PORT HOST_UID HOST_GID ${APP_ANSWER_KEYS:-}"
REQUEST_KEYS="ACTION BY BACKUP APP_URL HTTP_PORT SSL_PROXY APP_TZ ON CONFIRM ${APP_REQUEST_KEYS:-}"
clear_request_vars() { unset $REQUEST_KEYS 2>/dev/null || true; }
pref() { local v; v=$(sed -n "s/^$1='\([0-9]\{1,3\}\)'$/\1/p" "$VAR/prefs" 2>/dev/null | tail -1); echo "${v:-$2}"; }

# DSM's firewall list of applications, as .env has the port now.
sync_dsm() {
  local http sc=""
  http=$(env_get HTTP_PORT); [[ -n "$http" ]] || return 0
  for sc in "/dsm-etc/services.d/$PKG_NAME.sc" "/dsm-etc/service.d/$PKG_NAME.sc" ""; do [[ -f "$sc" ]] && break; done
  [[ -n "$sc" ]] || { say "no $PKG_NAME.sc under /usr/local/etc to update"; return 0; }
  { printf '[%s_web]\ntitle="%s: web app"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/tcp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$http"
    has app_extra_ports && app_extra_ports; } > "$sc" 2>/dev/null && say "the firewall's application list: $PKG_TITLE on $http" || say "couldn't rewrite $sc"
}

# A DSM notification: synodsmnotify only runs as root on the Synology itself.
notify() {   # key, hours between, values for its {0} {1}…
  local key=$1 hours=$2 mark arg args=(); shift 2
  for arg in "$@"; do args+=("$(printf '%s' "$arg" | tr -d '\000-\037' | cut -c1-80)"); done
  mkdir -p "$VAR/notified"; mark="$VAR/notified/$key-$(printf '%s|' "${args[@]}" | md5sum | cut -c1-12)"
  fresh "$mark" $(( hours * 3600 )) && return 0
  touch "$mark"
  if docker run --rm --privileged --pid=host --network=host --entrypoint nsenter "$PKG_NAME-setup:local" \
       -t 1 -m -u -i -n -p -- /usr/syno/bin/synodsmnotify -c "$APP_ID" @administrators \
       "$APP_ID:notification:title" "$APP_ID:notification:$key" "${args[@]}" >> "$LOG" 2>&1; then say "told DSM: $key${args[*]:+ (${args[*]})}"
  else say "a DSM notification ($key) didn't go — the lines above say why"; fi
}

# ------------------------------------------------------- the app's containers
cname() { echo "$PKG_NAME-$1"; }                       # compose service → container name (app.sh sets container_name this way)
state_of() { docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null || echo "missing -"; }
svc_up() { local s; read -r s _ < <(state_of "$(cname "$1")"); [[ "$s" == running ]]; }
all_up() { local s; for s in $SERVICES; do svc_up "$s" || return 1; done; }

# Default health: the web port answers (the app may give app_health instead).
health() { if has app_health; then app_health; else local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$(env_get HTTP_PORT)${HEALTH_PATH:-/}" 2>/dev/null); [[ "$c" =~ ^(2|3|401|503) ]]; fi; }
wait_ready() {   # seconds
  local limit=${1:-600} t=0
  while (( t < limit )); do
    (( STOPPING )) && stop
    if health; then say "✓ $PKG_TITLE answers on port $(env_get HTTP_PORT)"; return 0; fi
    all_up || { say "$PKG_TITLE's containers aren't all running"; container_logs; return 1; }
    (( t % 30 == 0 )) && say "waiting for $PKG_TITLE to answer ($t s)…"
    sleep 5; t=$(( t + 5 ))
  done
  say "$PKG_TITLE hasn't answered after $limit s"; container_logs; return 1
}
container_logs() {
  local s c
  for s in $SERVICES; do c=$(cname "$s")
    say "--- last lines from $c ($(docker inspect -f '{{.State.Status}}, exit {{.State.ExitCode}}' "$c" 2>/dev/null || echo missing)):"
    docker logs --tail 40 "$c" 2>&1 | sed 's/^/    /' | tee -a "$LOG" >/dev/null || true
  done
}
start_app() {
  local var img
  for var in $IMAGE_VARS; do img=$(env_get "$var"); [[ -n "$img" ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 && continue
    phase "pulling $img (follow it in the log)"
    docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  done
  phase "starting $PKG_TITLE's containers"
  has app_before_up && app_before_up
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { container_logs; return 1; }
  has app_after_up && app_after_up
  phase "waiting for $PKG_TITLE to answer on port $(env_get HTTP_PORT)"
  wait_ready 600
}

# ----------------------------------------------------------- what's known
list_backups() {
  local f
  for f in "$APP"/backups/$PKG_NAME-*.tar; do [[ -f "$f" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
  done | sort -r | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], size: (.[1] | tonumber), at: (.[2] | tonumber)})'
}
disk_usage() {
  local free; free=$(df -Pm "$APP" 2>/dev/null | awk 'NR == 2 {print $4}')
  jq -n -c --argjson free "${free:-0}" --argjson backups "$(du -sm "$APP/backups" 2>/dev/null | cut -f1 || echo 0)" '{free_mb: $free, backups_mb: $backups}'
}
storage_report() {   # every volume's size, plus what the app adds
  local v entries="{}" mb extra="{}"
  for v in $VOLUMES; do mb=$(in_volume "$v" ro -- du -sm /vol 2>/dev/null </dev/null | tail -n 1 | cut -f1); [[ "$mb" =~ ^[0-9]+$ ]] || mb=0   # du on a busy volume can say other things
    entries=$(jq -c --arg k "$v" --argjson m "$mb" '. + {($k): $m}' <<< "$entries"); done
  has app_storage && extra=$(app_storage); [[ "$extra" == \{* ]] || extra="{}"
  jq -n -c --argjson volumes "$entries" --argjson app "$extra" --argjson at "$(now)" '{at: $at, volumes: $volumes, app: $app}'
}
write_status() {
  local parts="[]" s st h j_backups j_nightly j_keep j_blast j_secret n bad=""
  for s in $SERVICES; do read -r st h < <(state_of "$(cname "$s")"); parts=$(jq -c --arg n "$s" --arg s "$st" --arg h "$h" '. + [{name: $n, state: $s, health: $h}]' <<< "$parts"); done
  j_backups=$(list_backups); j_nightly=$(pref NIGHTLY 1); j_keep=$(pref KEEP 14)
  j_blast=$(cat "$VAR/backup.last" 2>/dev/null || echo null); j_secret=$([[ -f "$VAR/secret.json" ]] && echo true || echo false)
  # One bad part (an app hook's output, a busy du) must not leave the window with nothing: it becomes null, and the log says so once.
  for n in LAST parts APPJ DISK_JSON STORAGE_JSON j_backups j_nightly j_keep j_blast UPDATE_JSON IMAGE_UPDATE; do
    [[ -n "${!n}" ]] && jq empty >/dev/null 2>&1 <<< "${!n}" && continue
    bad="$n wasn't JSON ([$(head -c 120 <<< "${!n}" | tr -d '\000-\037')]) and was left out"; printf -v "$n" '%s' null
  done
  [[ -n "$bad" && "$bad" != "$STATUS_ERR" ]] && { STATUS_ERR=$bad; say "status for the window: $bad"; }
  jq -n -c \
    --argjson at "$(now)" --arg build "$BUILD" --arg busy "$BUSY" --argjson last "$LAST" --argjson parts "$parts" \
    --arg version "$(has app_version && app_version || echo "")" --arg url "$(env_get APP_URL)" --arg port "$(env_get HTTP_PORT)" \
    --arg lan_ip "$(env_get LAN_IP)" --arg tz "$(env_get TZ)" --arg ssl_proxy "$(env_get SSL_PROXY)" \
    --argjson app "$APPJ" --argjson disk "$DISK_JSON" --argjson storage "$STORAGE_JSON" \
    --argjson backups "$j_backups" --argjson nightly "$j_nightly" --argjson keep "$j_keep" \
    --argjson backup_last "$j_blast" \
    --argjson update "$UPDATE_JSON" --argjson image_update "$IMAGE_UPDATE" \
    --argjson secret "$j_secret" \
    '{at: $at, build: $build, busy: $busy, last: $last, parts: $parts, version: $version, url: $url, port: $port, lan_ip: $lan_ip, tz: $tz,
      ssl_proxy: ($ssl_proxy == "1"), app: $app, disk: $disk, storage: $storage, backups: $backups,
      backup: {nightly: ($nightly == 1), keep: $keep, last: $backup_last}, update: $update, image_update: $image_update, secret: $secret}' \
    > "$VAR/status.json.tmp" 2>"$VAR/.status-err" && { for_window "$VAR/status.json"; rm -f "$VAR/.status-err"; return 0; }
  n=$(head -c 200 "$VAR/.status-err" 2>/dev/null)
  [[ -n "$n" && "$n" != "$STATUS_ERR" ]] && { STATUS_ERR=$n; say "✗ the status for the window couldn't be written: $n"; }
  return 1
}
write_logs() {   # the containers' last lines, and whatever the app adds, for the window
  local s
  mkdir -p "$VAR/logs"; chown "$HOST_UID:$HOST_GID" "$VAR/logs" 2>/dev/null || true
  for s in $SERVICES; do docker logs --tail 300 "$(cname "$s")" > "$VAR/logs/$s.log.tmp" 2>&1 || true; for_window "$VAR/logs/$s.log"; done
  has app_logs && app_logs
}
refresh_rich() {
  has app_status && APPJ=$(app_status); [[ "$APPJ" == \{* ]] || APPJ="null"
  if (( $(now) - DISK_AT > 600 )); then DISK_JSON=$(disk_usage); DISK_AT=$(now); fi
  if (( $(now) - STORAGE_AT > 600 )); then STORAGE_JSON=$(storage_report); STORAGE_AT=$(now); fi
}

# -------------------------------------------------------------- the watchdog
declare -A BAD_SINCE=() RESTARTS=()
watchdog() {
  [[ -z "$BUSY" && "$WIPED" == 0 ]] || return 0
  local s c state h t recent
  for s in $SERVICES; do c=$(cname "$s")
    read -r state h < <(state_of "$c")
    if [[ "$state" == running && "$h" != unhealthy ]]; then BAD_SINCE[$s]=""; continue; fi
    [[ -n "${BAD_SINCE[$s]:-}" ]] || { BAD_SINCE[$s]=$(now); continue; }
    (( $(now) - BAD_SINCE[$s] >= 90 )) || continue
    recent=0; for t in ${RESTARTS[$s]:-}; do (( $(now) - t < 3600 )) && (( recent++ )); done
    if (( recent >= 3 )); then notify failing 6 "$c" "$recent"; continue; fi
    say "watchdog: $c $([[ "$state" == running ]] && echo "stopped answering" || echo "is $state") — starting it again"
    if [[ "$state" == running ]]; then docker restart "$c" >> "$LOG" 2>&1 || true; else compose up -d --no-deps "$s" >> "$LOG" 2>&1 || true; fi
    RESTARTS[$s]="${RESTARTS[$s]:-} $(now)"; BAD_SINCE[$s]=""
    notify restarted 1 "$c"
  done
}

# ------------------------------------------------------------------ backups
# A backup is one tar: what app_backup puts in a folder (usually a database
# dump and the data volume), the package's .env, and a MANIFEST.
MADE=""
make_backup() {   # [suffix] → the file's name in $MADE
  local name dir work; MADE=""
  name="$PKG_NAME-$(date +%Y%m%d-%H%M)${1:+-$1}"; work="$APP/backups/.work"; dir="$work/$name"
  rm -rf "$work"; mkdir -p "$dir"
  say "backup $name"
  if has app_backup; then app_backup "$dir" || { say "✗ the app's part of the backup didn't finish"; rm -rf "$work"; return 1; }
  else local v; for v in $VOLUMES; do in_volume "$v" ro -- "tar -C / --transform 's|^vol|$v|' -czf - vol" > "$dir/$v.tar.gz" 2>>"$LOG" </dev/null || { say "✗ volume $v didn't tar"; rm -rf "$work"; return 1; }; done; fi
  cp "$APP/.env" "$dir/env"
  printf 'package=%s\nbuild=%s\nversion=%s\nat=%s\n' "$PKG_NAME" "$BUILD" "$(has app_version && app_version || echo "")" "$(now)" > "$dir/MANIFEST"
  tar -C "$work" -cf "$APP/backups/$name.tar.tmp" "$name" && mv "$APP/backups/$name.tar.tmp" "$APP/backups/$name.tar" || { say "✗ the backup file didn't finish"; rm -rf "$work" "$APP/backups/$name.tar.tmp"; return 1; }
  rm -rf "$work"; chown "$HOST_UID:$HOST_GID" "$APP/backups/$name.tar" 2>/dev/null || true; chmod 640 "$APP/backups/$name.tar" 2>/dev/null || true
  say "✓ backup $name.tar ($(du -h "$APP/backups/$name.tar" | cut -f1))"; MADE="$name.tar"
}
record_backup() { printf '{"at":%s,"ok":%s,"name":%s}\n' "$(now)" "$1" "$(json "${2:-}")" > "$VAR/backup.last.tmp"; for_window "$VAR/backup.last"; }
prune_backups() {
  local keep count; keep=$(pref KEEP 14); count=$(ls "$APP"/backups/$PKG_NAME-*.tar 2>/dev/null | wc -l); (( count > 1 )) || return 0
  find "$APP/backups" -maxdepth 1 -name "$PKG_NAME-*.tar" -mtime +"$keep" -print -delete 2>/dev/null | while read -r f; do say "backup $(basename "$f") was older than $keep days and was removed"; done
}
nightly_backup() {   # due at 02:00; made on the first tick after, so a missed one is caught up
  local due last
  [[ "$(pref NIGHTLY 1)" == 1 && -z "$BUSY" && "$WIPED" == 0 ]] || return 0
  due=$(date -d "$(date +%Y-%m-%d) 02:00" +%s 2>/dev/null) || return 0
  (( $(now) < due )) && due=$(( due - 86400 ))
  last=$(cat "$VAR/backup.nightly" 2>/dev/null | tr -cd '0-9'); last=${last:-0}
  (( last < due )) || return 0
  echo "$(now)" > "$VAR/backup.nightly"
  BUSY=backup; write_status; say "the nightly backup"
  if make_backup nightly; then record_backup true "$MADE"; prune_backups; else record_backup false ""; notify backupfailed 12; fi
  BUSY=""; write_status; publish_log
}
restore_backup() {   # $BACKUP, validated
  local file="$APP/backups/$BACKUP" work dir name safety
  [[ -f "$file" ]] || { MSG="There's no backup called $BACKUP."; return 1; }
  name=${BACKUP%.tar}; work="$APP/backups/.restore"; dir="$work/$name"
  rm -rf "$work"; mkdir -p "$work"
  tar -C "$work" -xf "$file" 2>>"$LOG" || { MSG="That backup couldn't be unpacked."; rm -rf "$work"; return 1; }
  grep -qx "package=$PKG_NAME" "$dir/MANIFEST" 2>/dev/null || { MSG="That file isn't a $PKG_TITLE backup."; rm -rf "$work"; return 1; }
  say "restoring $BACKUP — first, a backup of how things are now"
  make_backup pre-restore || { MSG="Couldn't back up the current state first, so nothing was restored."; rm -rf "$work"; return 1; }
  safety=$MADE; record_backup true "$safety"
  say "stopping $PKG_TITLE while its data is put back"
  compose stop -t 60 >> "$LOG" 2>&1 || true
  if has app_restore; then app_restore "$dir" || { MSG=${MSG:-"The restore didn't finish; $PKG_TITLE is left stopped — the log says more. $safety has the state from just before."}; rm -rf "$work"; return 1; }
  else local v; for v in $VOLUMES; do [[ -f "$dir/$v.tar.gz" ]] || continue
      in_volume "$v" rw -- "find /vol -mindepth 1 -delete && tar -C /vol --strip-components=1 -xzf -" < "$dir/$v.tar.gz" 2>>"$LOG" || { MSG="Volume $v didn't restore; $PKG_TITLE is left stopped. $safety has the state from just before."; rm -rf "$work"; return 1; }; done; fi
  rm -rf "$work"
  say "starting $PKG_TITLE again"; compose up -d >> "$LOG" 2>&1 || true
  wait_ready 600 || { MSG="Restored, but $PKG_TITLE hasn't come back up yet — see the log."; return 1; }
  MSG="Restored from $BACKUP. The state from just before is in $safety."
}
leave_secret() {   # label value kind — a one-time secret for the window (api.cgi hands it over once)
  jq -n -c --arg email "$1" --arg password "$2" --arg kind "$3" --argjson at "$(now)" '{email: $email, password: $password, kind: $kind, at: $at}' > "$VAR/secret.json.tmp" && for_window "$VAR/secret.json"
}
expire_secret() { [[ -f "$VAR/secret.json" ]] && ! fresh "$VAR/secret.json" 900 && rm -f "$VAR/secret.json" && say "the one-time secret wasn't collected in 15 minutes and was discarded"; true; }

# ------------------------------------------------------------------ updates
check_updates() {
  local code release latest page spk
  UPDATE_AT=$(now)
  code=$(curl -sS --max-time 15 -o "$VAR/release.json" -w '%{http_code}' "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo 0)
  release=$(cat "$VAR/release.json" 2>/dev/null); rm -f "$VAR/release.json"
  if [[ "$code" == 404 ]]; then UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" '{checked: $at, error: "no release has been published yet"}')
  elif [[ "$code" != 200 ]]; then UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" --arg code "$code" '{checked: $at, error: ("GitHub could not be reached (" + $code + ")")}')
  else
    latest=$(jq -r '.tag_name // ""' <<< "$release" | sed -E 's/^v//' | tr -cd '0-9A-Za-z.-')
    page=$(jq -r '.html_url // ""' <<< "$release"); spk=$(jq -r '[.assets[]? | .browser_download_url | select(endswith(".spk"))][0] // ""' <<< "$release")
    [[ "$page" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/tag/[A-Za-z0-9_.-]+$ ]] || page=""
    [[ "$spk" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_./-]+\.spk$ ]] || spk=""
    UPDATE_JSON=$(jq -n -c --argjson at "$UPDATE_AT" --arg latest "$latest" --arg page "$page" --arg spk "$spk" --arg build "$BUILD" \
      '{checked: $at, latest: $latest, page: $page, spk: $spk, newer: ($latest != "" and $spk != "" and ([$latest, $build] | sort | .[1]) == $latest and $latest != $build)}')
  fi
  check_image_update
  say "looked for updates: package $(jq -r '.latest // "?"' <<< "$UPDATE_JSON") (this is $BUILD); image: $(jq -r 'if .available then "newer available" elif .error then .error else "current" end' <<< "$IMAGE_UPDATE")"
  has app_check_updates && app_check_updates || true
}
check_image_update() {   # the first image var is the app's: compare its Docker Hub digest with the local one
  local var img name tag token remote local_digest
  var=${IMAGE_VARS%% *}; img=$(env_get "$var"); [[ -n "$img" ]] || { IMAGE_UPDATE='null'; return 0; }
  name=${img%%:*}; tag=latest; [[ "$img" == *:* ]] && tag=${img##*:}
  [[ "$name" == */* ]] || name="library/$name"
  if [[ "$name" == *.*/* ]]; then IMAGE_UPDATE='{"error":"only Docker Hub images are checked"}'; return 0; fi
  token=$(curl -fsS --max-time 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$name:pull" 2>/dev/null | jq -r '.token // ""')
  remote=$(curl -fsSI --max-time 15 -H "Authorization: Bearer $token" -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/$name/manifests/$tag" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}' | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  local_digest=$(docker image inspect "$img" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  if [[ -z "$remote" ]]; then IMAGE_UPDATE='{"error":"the registry could not be reached"}'
  else IMAGE_UPDATE=$(jq -n -c --arg img "$img" --arg remote "$remote" --arg local "$local_digest" --argjson at "$(now)" '{checked: $at, image: $img, available: ($local != "" and $remote != $local), remote: $remote[:19], local: $local[:19]}'); fi
}
update_app() {
  say "updating $PKG_TITLE — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so $PKG_TITLE wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling the newest images"; compose pull 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="The updated containers didn't start — see the log."; return 1; }
  has app_after_up && app_after_up
  wait_ready 900 || { MSG="$PKG_TITLE was updated but hasn't answered yet — see the log."; return 1; }
  docker image prune -f >/dev/null 2>&1 || true; check_image_update
  MSG="$PKG_TITLE is updated$(has app_version && echo " to $(app_version)"). The state from before is in $MADE."
}
upgrade_package() {   # a newer package from the GitHub release, handed to DSM's installer by a helper container
  local url latest file got
  url=$(jq -r '.spk // ""' <<< "$UPDATE_JSON"); latest=$(jq -r '.latest // ""' <<< "$UPDATE_JSON")
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_./-]+\.spk$ && "$latest" =~ ^[0-9A-Za-z.-]+$ ]] || { MSG="There's no newer package to install — look for updates first."; return 1; }
  mkdir -p "$APP/$UPDATES"; rm -f "$APP/$UPDATES"/$PKG_NAME-*.spk "$APP/$UPDATES"/upgrade.*
  file="$APP/$UPDATES/$PKG_NAME-$latest.spk"
  say "downloading the $PKG_TITLE package $latest"
  curl -fsSL --max-time 600 -o "$file" "$url" || { rm -f "$file"; MSG="The download didn't finish."; return 1; }
  got=$(tar -xOf "$file" INFO 2>/dev/null | sed -n 's/^version="\([0-9A-Za-z.-]*\)"$/\1/p')
  if ! tar -xOf "$file" INFO 2>/dev/null | grep -qx "package=\"$PKG_NAME\"" || [[ -z "$got" || "$got" == "$BUILD" ]] || [[ "$(printf '%s\n%s\n' "$got" "$BUILD" | sort -V | tail -1)" != "$got" ]]; then
    rm -f "$file"; MSG="That download isn't a newer $PKG_TITLE package (${got:-no version}), so it wasn't installed."; return 1; fi
  printf '%s\n' "$BUILD" > "$APP/$UPDATES/upgrade.from"; printf '%s\n' "$got" > "$APP/$UPDATES/upgrade.to"
  say "handing $PKG_TITLE $got to Package Center — the package stops, and starts again with it"; publish_log
  docker rm -f "$PKG_NAME-upgrade" >/dev/null 2>&1 || true
  docker run -d --rm --privileged --pid=host --network=host --name "$PKG_NAME-upgrade" --entrypoint busybox docker:27-cli \
      nsenter -t 1 -m -u -i -n -p -- sh -c '/usr/syno/bin/synopkg install "$1" > "$2" 2>&1; echo "exit $?" >> "$2"' sh "$file" "$APP/$UPDATES/upgrade.log" >> "$LOG" 2>&1 \
    || { MSG="DSM's installer couldn't be started."; return 1; }
  MSG="Package Center is installing $PKG_TITLE $got; this window will go away and come back."
}
report_upgrade() {
  local from to result
  [[ -f "$APP/$UPDATES/upgrade.to" ]] || return 0
  docker ps -q --filter name="^$PKG_NAME-upgrade$" 2>/dev/null | grep -q . && return 0
  from=$(cat "$APP/$UPDATES/upgrade.from" 2>/dev/null); to=$(cat "$APP/$UPDATES/upgrade.to" 2>/dev/null); result=$(tail -n 20 "$APP/$UPDATES/upgrade.log" 2>/dev/null)
  if [[ "$BUILD" == "$to" ]]; then say "✓ updated from package $from to $to"; LAST=$(jq -n -c --argjson at "$(now)" '{action: "upgrade", ok: true, message: "The package was updated.", at: $at, by: ""}')
  else say "✗ updating to package $to didn't finish — DSM's installer said:"; printf '%s\n' "${result:-(nothing)}" | sed 's/^/    /' | tee -a "$LOG"
    LAST=$(jq -n -c --argjson at "$(now)" '{action: "upgrade", ok: false, message: "The package update did not finish, see the log.", at: $at, by: ""}'); fi
  rm -f "$APP/$UPDATES"/$PKG_NAME-*.spk "$APP/$UPDATES"/upgrade.*
}

# ------------------------------------------------------------ support report
redact() {   # addresses, email addresses and host names become stable stand-ins
  awk 'function swap(re, pre,   m, out) { out = ""; while (match($0, re)) { m = substr($0, RSTART, RLENGTH); if (!(m in seen)) seen[m] = pre "-" (++n[pre]); out = out substr($0, 1, RSTART - 1) seen[m]; $0 = substr($0, RSTART + RLENGTH) } $0 = out $0 }
       { swap("[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+", "email"); swap("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", "lan-ip"); swap("https?://[A-Za-z0-9.-]+(:[0-9]+)?", "site"); print }'
}
make_report() {
  local f="$VAR/report.txt.tmp" s
  {
    echo "$PKG_TITLE package support report — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "package: $BUILD; app: $(has app_version && app_version || echo "?"); images: $(for v in $IMAGE_VARS; do env_get "$v"; done | paste -sd' ')"
    echo "DSM: $(sed -n 's/^productversion="\(.*\)"$/\1/p' /etc.defaults/VERSION 2>/dev/null) build $(sed -n 's/^buildnumber="\(.*\)"$/\1/p' /etc.defaults/VERSION 2>/dev/null); model: $(sed -n 's/^upnpmodelname="\(.*\)"$/\1/p' /etc/synoinfo.conf 2>/dev/null)"
    echo "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null); setup runs as $(id -u):$(id -g)"
    echo; echo "== settings (.env, without secrets)"; grep -viE '(PASS|TOKEN|SECRET|KEY)' "$APP/.env" 2>/dev/null
    echo; echo "== status"; jq 'del(.app.users)' "$VAR/status.json" 2>/dev/null
    echo; echo "== containers"; docker ps -a --filter "name=$PKG_NAME-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    echo; echo "== disk"; df -Ph "$APP" 2>/dev/null; docker system df 2>/dev/null
    echo; echo "== memory"; free -m 2>/dev/null
    echo; echo "== package log (last 300 lines)"; tail -n 300 "$LOG"
    for s in $SERVICES; do echo; echo "== $(cname "$s") (last 120 lines)"; docker logs --tail 120 "$(cname "$s")" 2>&1; done
    has app_report && { echo; app_report; }
    :
  } 2>/dev/null | redact > "$f"
  [[ -s "$f" ]] && for_window "$VAR/report.txt"     # judged by the file, not by the pipeline's last stage
}

# ---------------------------------------------------------------- settings
apply_settings() {
  local changed=0 old_port; old_port=$(env_get HTTP_PORT)
  [[ -n "${APP_URL:-}" ]] && { env_set APP_URL "$APP_URL"; changed=1; }
  [[ -n "${HTTP_PORT:-}" ]] && { env_set HTTP_PORT "$HTTP_PORT"; changed=1; }
  [[ -n "${APP_TZ:-}" ]] && { env_set TZ "$APP_TZ"; export TZ=$APP_TZ; changed=1; }
  [[ -n "${SSL_PROXY:-}" ]] && { env_set SSL_PROXY "$SSL_PROXY"; changed=1; }
  has app_settings && app_settings && changed=1
  (( changed )) || { MSG="Nothing to change."; return 0; }
  say "settings: address $(env_get APP_URL), port $(env_get HTTP_PORT), time zone $(env_get TZ), behind HTTPS proxy: $(env_get SSL_PROXY)"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="$PKG_TITLE didn't restart with the new settings — see the log."; return 1; }
  [[ "$(env_get HTTP_PORT)" != "$old_port" ]] && sync_dsm
  wait_ready 300 || { MSG="Settings saved, but $PKG_TITLE hasn't answered yet — see the log."; return 1; }
  has app_after_settings && app_after_settings
  MSG="Settings saved; $PKG_TITLE is up at $(env_get APP_URL)."
}

# ------------------------------------------------------- removing everything
wipe_everything() {
  [[ "${CONFIRM:-}" == REMOVEEVERYTHING ]] || { MSG="Not confirmed — nothing was removed."; return 1; }
  local s v var
  say "REMOVING EVERYTHING, as ${BY:-?} asked"
  say "stopping and removing $PKG_TITLE's containers, network and volumes"
  compose down --remove-orphans -v -t 30 >> "$LOG" 2>&1 || true
  for s in $SERVICES; do docker rm -f "$(cname "$s")" >> "$LOG" 2>&1 || true; done
  for v in $VOLUMES; do docker volume rm "${PKG_NAME}_$v" >> "$LOG" 2>&1 || true; done
  docker network rm "${PKG_NAME}_default" >> "$LOG" 2>&1 || true
  say "removing $PKG_TITLE's images"; for var in $IMAGE_VARS; do docker image rm "$(env_get "$var")" >> "$LOG" 2>&1 || true; done
  has app_wipe && app_wipe
  say "emptying the shared folder"
  find "$APP" -mindepth 1 -maxdepth 1 ! -name 'package.log' -exec rm -rf {} + 2>>"$LOG" || true
  find "$VAR" -mindepth 1 -maxdepth 1 ! -name 'package.log' ! -name 'state' ! -name 'request*' -exec rm -rf {} + 2>/dev/null || true
  if [[ -f /etc.defaults/VERSION ]]; then
    say "handing the rest to DSM: uninstalling the package and deleting the $PKG_NAME shared folder"; publish_log
    docker rm -f "$PKG_NAME-remove" >/dev/null 2>&1 || true
    docker run -d --rm --privileged --pid=host --network=host --name "$PKG_NAME-remove" --entrypoint busybox docker:27-cli \
        nsenter -t 1 -m -u -i -n -p -- sh -c "sleep 5; { /usr/syno/bin/synopkg uninstall $PKG_NAME; /usr/syno/sbin/synoshare --del true $PKG_NAME; echo \"exit \$?\"; } > /tmp/$PKG_NAME-removed.log 2>&1" >> "$LOG" 2>&1 \
      || { MSG="$PKG_TITLE's data is gone, but DSM's uninstaller couldn't be started: uninstall the package in Package Center and delete the $PKG_NAME shared folder in Control Panel."; return 1; }
    MSG="$PKG_TITLE, its data and images are removed. Package Center is now uninstalling the package and deleting the $PKG_NAME shared folder; this window goes away."
  else MSG="$PKG_TITLE, its data and images are removed. This isn't a Synology, so the package and shared folder are left for you to remove."; fi
  set_state removed; WIPED=1
}

# ---------------------------------------------- a request from the window
act() {
  local f="$VAR/request" ok=true started log_from
  [[ -f "$f" ]] || return 0
  mv "$f" "$f.doing"; clear_request_vars; MSG=""
  if ! read_settings "$f.doing" $REQUEST_KEYS || [[ -z "${ACTION:-}" ]]; then say "✗ ignoring a request that wasn't in order"; rm -f "$f.doing"; return 0; fi
  rm -f "$f.doing"
  log_from=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  say "request from ${BY:-?}: $ACTION"
  BUSY=$ACTION; write_status; started=$(now)
  case "$ACTION" in
    restart)    compose restart 2>&1 | tee -a "$LOG" >/dev/null && wait_ready 300 && MSG="$PKG_TITLE was restarted." || { ok=false; MSG=${MSG:-"$PKG_TITLE didn't come back after the restart — see the log."}; } ;;
    backup)     if make_backup; then record_backup true "$MADE"; prune_backups; MSG="Backed up to $MADE."; else record_backup false ""; ok=false; MSG="The backup didn't finish — see the log."; fi ;;
    restore)    restore_backup || ok=false ;;
    delbackup)  if [[ -f "$APP/backups/$BACKUP" ]]; then rm -f "$APP/backups/$BACKUP"; say "backup $BACKUP was removed"; MSG="$BACKUP was removed."; else ok=false; MSG="There's no backup called $BACKUP."; fi ;;
    settings)   apply_settings || ok=false ;;
    updateapp)  update_app || ok=false ;;
    upgrade)    upgrade_package || ok=false ;;
    check)      check_updates || true; MSG="Looked for updates." ;;
    clearcache) if has app_clearcache; then app_clearcache && MSG="Caches cleared." || { ok=false; MSG=${MSG:-"Couldn't clear caches — see the log."}; }; else MSG="Nothing to clear for $PKG_TITLE."; fi ;;
    report)     make_report && MSG="The support report is ready to save." || { ok=false; MSG="The report couldn't be made."; } ;;
    wipe)       wipe_everything || ok=false ;;
    *)          if has app_act; then app_act "$ACTION" || ok=false; else ok=false; MSG="Unknown request."; fi ;;
  esac
  local detail=""
  [[ "$ok" == false ]] && detail=$(tail -n +"$(( log_from + 1 ))" "$LOG" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\010\013-\037' | grep -avE '^\s*$|^ Container ' | tail -n 60 | cut -c1-300 | head -c 6000)
  LAST=$(jq -n -c --arg action "$ACTION" --argjson ok "$ok" --arg message "$MSG" --argjson at "$(now)" --arg by "${BY:-}" --argjson took "$(( $(now) - started ))" --arg detail "$detail" \
    '{action: $action, ok: $ok, message: $message, at: $at, by: $by, took: $took, detail: $detail}')
  say "$([[ "$ok" == true ]] && echo ✓ || echo ✗) $ACTION: $MSG"
  [[ "$WIPED" == 0 ]] && refresh_rich
  BUSY=""; write_status; publish_log
}

stop() { say "package stopping: taking $PKG_TITLE down"; compose stop -t 30 >> "$LOG" 2>&1 || true; set_state stopped; write_status 2>/dev/null || true; publish_log; exit 0; }
trap 'STOPPING=1' TERM INT     # a handler that runs commands mid-parse crashes bash; the loop acts on the flag
unexpected_exit() { local rc=$?; case "$(cat "$VAR/state" 2>/dev/null)" in stopped|failed|removed) return 0 ;; esac
  say "✗ the setup container stopped unexpectedly (exit $rc). $PKG_TITLE may still be running, but nothing is watching it — Package Center → $PKG_TITLE → Run starts the watch again."; set_state failed; publish_log; }
trap unexpected_exit EXIT

# Compose's recreate (a package upgrade) can leave this container renamed <id>_<name>; Container Manager then can't find it.
heal_name() {
  local id name state
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$PKG_NAME-setup" --filter label=com.docker.compose.service=setup 2>/dev/null); do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||'); state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)
    [[ "$name" =~ ^[0-9a-f]{12}_$PKG_NAME-setup$ ]] || continue
    if [[ "$state" == running ]]; then docker rename "$id" "$PKG_NAME-setup" >> "$LOG" 2>&1 && say "this container had been left named $name by an interrupted recreate — renamed it back" || say "this container is named $name and couldn't be renamed: Package Center → Uninstall and install again puts it right; the data stays."
    else docker rm -f "$id" >/dev/null 2>&1 && say "removed a stopped leftover setup container ($name)"; fi
  done
}

# ------------------------------------------------------------------- start
[[ -f "$PKG/setup/tls.sh" ]] && . "$PKG/setup/tls.sh"   # HTTPS helpers an app may use (tls_*)
[[ -f "$PKG/setup/app.sh" ]] && . "$PKG/setup/app.sh"
[[ -f "$LOG" ]] && tail -n 3000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
set_state starting
BUILD=$(cat "$PKG/build-id")
echo >> "$LOG"
say "package started: $PKG_NAME $BUILD"
say "running as $(id -u):$(id -g) (groups $(id -G)); Docker's socket: $(stat -c 'owner %u:%g, mode %a' /var/run/docker.sock 2>/dev/null || echo 'not there')"
if v=$(docker version --format '{{.Server.Version}}' 2>&1); then say "Docker answers: $v"
else say "Docker doesn't answer: $v"; failed "The setup container can't use Docker. Container Manager ran it as $(id -u):$(id -g) — please send this log."; fi
[[ -d "$APP" && -w "$APP" ]] || failed "The $PKG_NAME shared folder isn't there. DSM makes it when the package is installed — reinstalling the package should bring it back."
heal_name

if [[ -f "$VAR/answers.env" ]]; then
  read_settings "$VAR/answers.env" $ANSWER_KEYS || failed "The install wizard's answers weren't in order — reinstalling the package asks them again."
  say "using the answers from the install wizard"
fi
HOST_UID=${HOST_UID:-$(env_get HOST_UID)}; HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-$(env_get HOST_GID)}; HOST_GID=${HOST_GID:-$HOST_UID}

if [[ "$(cat "$APP/.package-files" 2>/dev/null)" != "$BUILD" ]]; then
  say "putting this version's files in the shared folder"
  cp "$PKG/app/compose.yaml" "$APP/compose.yaml.tmp" && mv "$APP/compose.yaml.tmp" "$APP/compose.yaml" || failed "Couldn't put $PKG_TITLE's compose file in the shared folder."
  cp "$PKG/app/env.example" "$APP/env.example" 2>/dev/null || true
  echo "$BUILD" > "$APP/.package-files"
fi

if [[ ! -f "$APP/.env" ]]; then   # the first time: .env from the wizard's answers, with secrets made here
  [[ -n "${LAN_IP:-}" && -n "${HTTP_PORT:-}" ]] || failed "There's no .env in the $PKG_NAME shared folder and no answers from the install wizard — reinstalling the package asks them again."
  for v in $VOLUMES; do docker volume inspect "${PKG_NAME}_$v" >/dev/null 2>&1 && failed "There's a $PKG_TITLE volume (${PKG_NAME}_$v) from an earlier install, but no settings file (.env) in the shared folder, so its secrets are unknown. Either put the env file from a backup back as .env in the $PKG_NAME shared folder, or remove the ${PKG_NAME}_* volumes in Container Manager → Volume (that deletes the old data) and run the package again."; done
  say "first start: writing .env from the wizard's answers"
  : > "$APP/.env"; chmod 600 "$APP/.env"
  env_set HTTP_PORT "$HTTP_PORT"; env_set LAN_IP "$LAN_IP"; env_set TZ "${TZ:-UTC}"
  env_set APP_URL "http://$LAN_IP:$HTTP_PORT"; env_set SSL_PROXY 0
  env_set HOST_UID "$HOST_UID"; env_set HOST_GID "$HOST_GID"
  has app_first_env && app_first_env
fi
export TZ; TZ=$(env_get TZ); TZ=${TZ:-UTC}
has app_load_env && app_load_env
for d in backups "$UPDATES"; do mkdir -p "$APP/$d"; done; chown "$HOST_UID:$HOST_GID" "$APP/backups" "$APP/$UPDATES" 2>/dev/null || true
mkdir -p "$VAR/logs"; chown "$HOST_UID:$HOST_GID" "$VAR/logs" 2>/dev/null || true
say "$PKG_TITLE's address: $(env_get APP_URL) (port $(env_get HTTP_PORT), time zone $TZ)"

start_app || failed "$PKG_TITLE couldn't start — the lines above say why. Package Center → $PKG_TITLE → Run tries again."
set +eu   # from here a failing command is a condition to report, not a reason to die
sync_dsm; report_upgrade
phase "first look at $PKG_TITLE"
refresh_rich
set_state running; rm -f "$VAR/phase"; write_status; publish_log
say "✓ $PKG_TITLE$(has app_version && echo " $(app_version)") is up at $(env_get APP_URL)"

TICK=0
while true; do
  if fresh "$VAR/watching" 30; then sleep 10 & else sleep 60 & fi
  wait $! || true
  (( STOPPING )) && stop
  TICK=$(( TICK + 1 ))
  if (( WIPED )); then write_status; continue; fi
  act
  if (( WIPED )); then write_status; publish_log; continue; fi
  watchdog; nightly_backup; expire_secret
  has app_tick && app_tick
  (( $(now) - UPDATE_AT > 43200 )) && check_updates
  if fresh "$VAR/watching" 30; then refresh_rich; write_logs; fi
  write_status
  (( TICK % 10 == 0 )) && publish_log
  (( STOPPING )) && stop
done
