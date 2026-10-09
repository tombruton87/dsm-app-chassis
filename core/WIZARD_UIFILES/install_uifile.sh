#!/bin/bash
# The install wizard (chassis): this Synology's address, a free port, its time
# zone — then the app's own pages, from wizard/pages.sh, built in below.
lan_ip=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
tz=""; syno=$(sed -n 's/^timezone="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/synoinfo.conf 2>/dev/null | head -1)
[ -n "$syno" ] && [ -d /usr/share/zoneinfo ] && tz=$(cd /usr/share/zoneinfo && ls -d */"$syno" 2>/dev/null | grep -vE '^(posix|right)/' | head -1)
tz=${tz:-UTC}
if command -v netstat >/dev/null 2>&1; then used=$(netstat -lntu 2>/dev/null | awk 'NR > 2 {print $4}'); else used=$(ss -Hlntu 2>/dev/null | awk '{print $5}'); fi
used=$(printf '%s\n' "$used" | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
in_use() { printf '%s\n' "$used" | grep -qx "$1"; }
first_free() { local p; for p in "$@"; do in_use "$p" || { echo "$p"; return; }; done; echo "$1"; }
http_port=$(first_free @PORTS@)
taken=$(printf '%s\n' "$used" | paste -sd'|' -)
port_expr="/^(?!(?:${taken:+$taken})\$)(102[4-9]|10[3-9][0-9]|1[1-9][0-9]{2}|[2-9][0-9]{3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])\$/"
lan_ip=$(printf '%s' "$lan_ip" | tr -cd '0-9.'); tz=$(printf '%s' "$tz" | tr -cd 'A-Za-z0-9_/+-')
cat > "$SYNOPKG_TEMP_LOGFILE" <<JSON
[{
    "step_title": "Welcome to @TITLE@",
    "items": [{ "desc": "@WELCOME@<br><br>It runs in Container Manager. The first start downloads its images and sets it up, which takes a few minutes — follow it in <b>Package Center → @TITLE@ → View log</b>, or open <b>@TITLE@</b> from DSM's main menu once it's installed.<br><br>Its backups and settings go in a new shared folder, <b>@PKG@</b>; its data lives in Container Manager volumes. Both stay if the package is removed. To see the backups in File Station, give yourself access: <b>Control Panel → Shared Folder → @PKG@ → Edit → Permissions</b>." }]
}, {
    "step_title": "Your network",
    "items": [{
        "type": "textfield", "desc": "The address this Synology has on your network. Reserve it in your router so it stays the same. The app's address will be http://this:port — it can be changed later in the @TITLE@ window, for instance to a domain behind DSM's reverse proxy.",
        "subitems": [{ "key": "wizard_lan_ip", "desc": "Address", "defaultValue": "$lan_ip", "validator": { "allowBlank": false, "regex": { "expr": "/^([0-9]{1,3}\\\\.){3}[0-9]{1,3}\$/", "errorText": "Looks like 192.168.1.10" } } }]
    }, {
        "type": "textfield", "desc": "The port for the web app. Suggested: one nothing here is using.",
        "subitems": [{ "key": "wizard_http_port", "desc": "Web port", "defaultValue": "$http_port", "validator": { "allowBlank": false, "regex": { "expr": "$port_expr", "errorText": "A number from 1024 to 65535 that isn't in use on this Synology" } } }]
    }, {
        "type": "textfield", "desc": "Time zone, for timestamps and schedules.",
        "subitems": [{ "key": "wizard_tz", "desc": "Time zone", "defaultValue": "$tz", "validator": { "allowBlank": false, "regex": { "expr": "/^[A-Za-z_]+(\\\\/[A-Za-z0-9_+-]+)*\$/", "errorText": "Looks like Europe/London" } } }]
    }]
}@APP_PAGES@]
JSON
exit 0
