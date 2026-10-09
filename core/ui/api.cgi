#!/bin/bash
#
# What the window asks (chassis core). DSM runs this as the package's user,
# which can't use Docker: reads come from files the setup container keeps
# fresh, writes become a request file it acts on — every value checked here,
# and again there. The app adds its own actions in ui/app-actions.sh (sourced).
#
#   GET  status | log&part=P | report | backup&name=N | changelog | app-get (via app hook)
#   POST restart | backup | restore | delbackup | settings | updateapp | upgrade | check | clearcache | report | wipe | prefs | take_secret | app actions
#
# For someone signed in to DSM: an administrator, for everything; any other
# DSM user the app has been granted to, to look.
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pkg.env"                                    # PKG_NAME, PKG_TITLE …
VAR=${CHASSIS_VAR:-/var/packages/$PKG_NAME/var}
SHARE=${CHASSIS_SHARE:-/var/packages/$PKG_NAME/shares/$PKG_NAME}
PKGDIR=${CHASSIS_PKG:-/var/packages/$PKG_NAME/target}
AUTH=${CHASSIS_AUTH_CGI:-/usr/syno/synoman/webman/modules/authenticate.cgi}
ADMINS=${CHASSIS_ADMINS:-administrators}

reply() { printf 'Status: %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\n\r\n%s' "$1" "$2" "$3"; exit 0; }
error() { reply "$1" application/json "{\"error\":\"$2\"}"; }
user=$("$AUTH" 2>/dev/null | head -1 | tr -cd 'A-Za-z0-9._@-')
[[ -n "$user" ]] || error "401 Unauthorized" "Sign in to DSM first."
if id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$ADMINS"; then role=admin; else role=viewer; fi
admin_only() { [[ "$role" == admin ]] || error "403 Forbidden" "Only DSM administrators can do that."; }
param() { sed -n "s/^\(.*&\)\{0,1\}$1=\([^&]*\).*$/\2/p" <<< "$2" | head -1; }
decode() { local v=${1//+/ }; printf '%b' "${v//%/\\x}"; }
listed_backup() { [[ "$1" =~ ^$PKG_NAME-[0-9]{8}-[0-9]{4}(-[a-z]{1,12})?\.tar$ ]] && grep -qF "\"name\":\"$1\"" "$VAR/status.json" 2>/dev/null; }
[[ -f "$HERE/app-actions.sh" ]] && . "$HERE/app-actions.sh"   # app_cgi_get ACTION QUERY / app_cgi_post ACTION BODY → sets lines, or error

if [[ "${REQUEST_METHOD:-GET}" == GET ]]; then
  action=$(param action "${QUERY_STRING:-}")
  [[ "$action" == status || "$action" == changelog ]] || admin_only
  case "$action" in
    status)
      touch "$VAR/watching" 2>/dev/null
      state=$(tr -cd 'a-z' < "$VAR/state" 2>/dev/null); status=$(cat "$VAR/status.json" 2>/dev/null); status=${status:-null}
      [[ -f "$VAR/secret.json" || "$status" == null ]] || status=$(jq -c '.secret = false' <<< "$status" 2>/dev/null || echo "$status")   # the loop's copy may lag a take
      phase=$(head -c 160 "$VAR/phase" 2>/dev/null | tr -d '\000-\037"\\')
      reply "200 OK" application/json "{\"role\":\"$role\",\"user\":\"$user\",\"state\":\"${state:-unknown}\",\"phase\":\"$phase\",\"now\":$(date +%s),\"pending\":$([[ -f "$VAR/request" ]] && echo true || echo false),\"status\":$status}" ;;
    log)
      part=$(param part "${QUERY_STRING:-}")
      if [[ "$part" == setup || -z "$part" ]]; then reply "200 OK" "text/plain; charset=utf-8" "$(tail -n 400 "$VAR/package.log" 2>/dev/null)"
      elif [[ "$part" =~ ^[a-z0-9-]{1,30}$ && -f "$VAR/logs/$part.log" ]]; then reply "200 OK" "text/plain; charset=utf-8" "$(cat "$VAR/logs/$part.log")"
      elif [[ "$part" =~ ^[a-z0-9-]{1,30}$ ]]; then reply "200 OK" "text/plain; charset=utf-8" "Nothing here yet — it comes in a moment while the window is open."
      else error "400 Bad Request" "Unknown part."; fi ;;
    report)
      [[ -f "$VAR/report.txt" ]] || error "404 Not Found" "No report has been made yet."
      printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment; filename="%s-report-%s.txt"\r\n\r\n' "$PKG_NAME" "$(date -r "$VAR/report.txt" +%Y%m%d-%H%M)"; cat "$VAR/report.txt"; exit 0 ;;
    backup)
      name=$(param name "${QUERY_STRING:-}"); listed_backup "$name" && [[ -f "$SHARE/backups/$name" ]] || error "404 Not Found" "No such backup."
      printf 'Status: 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: %s\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$(stat -c %s "$SHARE/backups/$name")" "$name"; cat "$SHARE/backups/$name"; exit 0 ;;
    changelog) reply "200 OK" "text/plain; charset=utf-8" "$(cat "$PKGDIR/CHANGELOG.md" 2>/dev/null)" ;;
    *) declare -F app_cgi_get >/dev/null && app_cgi_get "$action" "${QUERY_STRING:-}"; error "400 Bad Request" "Unknown request." ;;
  esac
fi

[[ "${REQUEST_METHOD:-}" == POST ]] || error "405 Method Not Allowed" "Unknown request."
admin_only
[[ "${CONTENT_LENGTH:-0}" =~ ^[0-9]+$ ]] && (( CONTENT_LENGTH > 0 && CONTENT_LENGTH < 4096 )) || error "400 Bad Request" "Unknown request."
read -r -n "$CONTENT_LENGTH" body
action=$(param action "$body")
case "$action" in
  prefs)
    nightly=$(param nightly "$body"); keep=$(param keep "$body")
    [[ "$nightly" =~ ^[01]$ ]] || error "400 Bad Request" "Nightly is on or off."
    [[ "$keep" =~ ^[0-9]{1,3}$ ]] && (( keep >= 1 && keep <= 365 )) || error "400 Bad Request" "Keep backups for 1 to 365 days."
    printf "NIGHTLY='%s'\nKEEP='%s'\n" "$nightly" "$keep" > "$VAR/prefs.tmp" && mv "$VAR/prefs.tmp" "$VAR/prefs" || error "500 Internal Server Error" "Couldn't keep that."
    reply "200 OK" application/json '{"ok":true}' ;;
  take_secret)
    [[ -f "$VAR/secret.json" ]] || error "404 Not Found" "There's nothing waiting — it's shown once, and may have been collected already."
    secret=$(cat "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; reply "200 OK" application/json "$secret" ;;
esac
[[ -f "$VAR/request" ]] && error "409 Conflict" "$PKG_TITLE is still busy with the last request."
lines=""
case "$action" in
  restart|backup|updateapp|upgrade|check|clearcache|report) lines="ACTION='$action'" ;;
  restore|delbackup) name=$(param name "$body"); listed_backup "$name" || error "400 Bad Request" "Pick a backup from the list."; lines="ACTION='$action'
BACKUP='$name'" ;;
  settings)
    url=$(decode "$(param url "$body")"); port=$(param port "$body"); ssl=$(param ssl_proxy "$body"); tz=$(decode "$(param tz "$body")")
    [[ "$url" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{2,5})?$ ]] || error "400 Bad Request" "The address is http://name-or-ip:port or https://your.domain, with nothing after it."
    [[ "$port" =~ ^[0-9]{2,5}$ ]] && (( port >= 1024 && port <= 65535 )) || error "400 Bad Request" "The port is a number from 1024 to 65535."
    [[ "$ssl" =~ ^[01]$ ]] || error "400 Bad Request" "Behind HTTPS is on or off."
    [[ "$tz" =~ ^([A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$ ]] || error "400 Bad Request" "A time zone looks like Europe/London."
    lines="ACTION='settings'
APP_URL='$url'
HTTP_PORT='$port'
SSL_PROXY='$ssl'
APP_TZ='$tz'"
    declare -F app_cgi_settings >/dev/null && app_cgi_settings "$body" ;;   # may append to $lines or error
  wipe) phrase=$(decode "$(param confirm "$body")"); [[ "$phrase" == "remove everything" ]] || error "400 Bad Request" "Type exactly: remove everything"; lines="ACTION='wipe'
CONFIRM='REMOVEEVERYTHING'" ;;
  *) declare -F app_cgi_post >/dev/null && app_cgi_post "$action" "$body"; [[ -n "$lines" ]] || error "400 Bad Request" "Unknown request." ;;
esac
printf '%s\nBY=%s\n' "$lines" "'$user'" > "$VAR/request.tmp" && mv "$VAR/request.tmp" "$VAR/request" || error "500 Internal Server Error" "Couldn't pass the request on."
reply "202 Accepted" application/json '{"ok":true}'
