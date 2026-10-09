#!/usr/bin/env bash
#
# Builds a DSM package from an app folder on this chassis:
#   chassis/build.sh <app dir> [build number]  →  <app dir>/dist/<pkg>-<version>-<build>.spk
#
# The app folder holds package.conf, VERSION, CHANGELOG.md, app/compose.yaml,
# app/env.example, setup/app.sh, ui/app.html, ui/app.js, ui/app-actions.sh,
# ui/strings (optional), wizard/pages.json + wizard/answers.sh (optional),
# icon.png (optional) — see the chassis README for the contract.
set -euo pipefail
CH=$(cd "$(dirname "$0")" && pwd)
APPDIR=$(cd "${1:?app dir}" && pwd); BUILD=${2:-1}
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "The build number is a number" >&2; exit 2; }
. "$APPDIR/package.conf"     # PKG_NAME PKG_TITLE PKG_DESC APP_ID REPO SERVICES VOLUMES IMAGE_VARS PORT PORTS TAGLINE WELCOME BACKUP_WHAT SITE_NOTE ICON_TOP ICON_BOTTOM ICON_LETTER …
VERSION=$(tr -d ' \n' < "$APPDIR/VERSION"); SPK_VERSION="$VERSION-$BUILD"
NS=${APP_ID%%.*}; APPID_WIN="${NS}.AppWindow"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
spk=$work/spk; target=$work/target; mkdir -p "$spk" "$target/app" "$target/setup" "$target/ui" "$APPDIR/dist"

# Tokens in chassis files.
sub() { sed -e "s|@PKG@|$PKG_NAME|g" -e "s|@TITLE@|$PKG_TITLE|g" -e "s|@DESC@|$PKG_DESC|g" -e "s|@APPID@|$APP_ID|g" -e "s|@APPID_WIN@|$APPID_WIN|g" -e "s|@NS@|$NS|g" \
             -e "s|@PORT@|$PORT|g" -e "s|@PORTS@|${PORTS:-$PORT}|g" -e "s|@TAGLINE@|${TAGLINE:-}|g" -e "s|@WELCOME@|${WELCOME:-}|g" -e "s|@BACKUP_WHAT@|${BACKUP_WHAT:-}|g" -e "s|@SITE_NOTE@|${SITE_NOTE:-}|g" "$@"; }
# A file's contents spliced at a marker line (the marker is replaced).
splice() {   # file marker source-file-or-empty
  local f=$1 m=$2 src=${3:-}
  if [[ -n "$src" && -f "$src" ]]; then python3 - "$f" "$m" "$src" <<'PY'
import sys; f,m,src=sys.argv[1:]; s=open(f).read(); s=s.replace(m, open(src).read()); open(f,'w').write(s)
PY
  else sed -i "s|$m||" "$f"; fi
}

# app/: the compose project, as the app wrote it.
cp "$APPDIR/app/compose.yaml" "$APPDIR/app/env.example" "$target/app/"
# setup/: the chassis core + the app's hooks + pkg.env.
cp "$CH/core/setup/run-core.sh" "$CH/core/setup/run.sh" "$CH/core/setup/tls.sh" "$target/setup/"
sub "$CH/core/setup/Dockerfile" > "$target/setup/Dockerfile"; sub "$CH/core/setup/compose.yaml" > "$target/setup/compose.yaml"
[[ -d "$APPDIR/setup" ]] && cp -r "$APPDIR/setup/." "$target/setup/"   # app.sh and anything it uses (scripts it runs in its containers…)
{ echo "PKG_NAME='$PKG_NAME'"; echo "PKG_TITLE='$PKG_TITLE'"; echo "APP_ID='$APP_ID'"; echo "REPO='$REPO'"; echo "SERVICES='$SERVICES'"; echo "VOLUMES='$VOLUMES'"; echo "IMAGE_VARS='$IMAGE_VARS'"
  echo "HEALTH_PATH='${HEALTH_PATH:-/}'"; echo "APP_ACTIONS='${APP_ACTIONS:-none}'"; echo "APP_ANSWER_KEYS='${APP_ANSWER_KEYS:-}'"; echo "APP_REQUEST_KEYS='${APP_REQUEST_KEYS:-}'"; } > "$target/setup/pkg.env"
cp "$target/setup/pkg.env" "$target/ui/pkg.env"
# ui/: the window core with the app's parts spliced in.
sub "$CH/core/ui/panel.html" > "$target/ui/panel.html"
for m in APP_CSS APP_NAV_EARLY APP_NAV APP_SETTINGS_FIELDS APP_SECTIONS APP_MAINT_TOP LOG_TABS; do
  splice "$target/ui/panel.html" "@$m@" "$APPDIR/ui/$(tr 'A-Z_' 'a-z-' <<< "$m").html"; done
sub "$CH/core/ui/panel.js" > "$target/ui/panel.js"
[[ -f "$APPDIR/ui/app.js" ]] && sub "$APPDIR/ui/app.js" > "$target/ui/app.js" || echo "// no app tabs" > "$target/ui/app.js"
cp "$CH/core/ui/api.cgi" "$target/ui/api.cgi"
[[ -f "$APPDIR/ui/app-actions.sh" ]] && cp "$APPDIR/ui/app-actions.sh" "$target/ui/app-actions.sh"
sub "$CH/core/ui/config" > "$target/ui/config"; splice "$target/ui/config" "@APP_PRELOAD@" "$APPDIR/ui/preload.txt"
sed -i "s/\"version\": \"1\"/\"version\": \"$SPK_VERSION\"/" "$target/ui/config"
sub "$CH/core/ui/app-window.js" > "$target/ui/$PKG_NAME.js"
mkdir -p "$target/ui/texts/enu"; sub "$CH/core/ui/texts/enu/strings" > "$target/ui/texts/enu/strings"; splice "$target/ui/texts/enu/strings" "@APP_STRINGS@" "$APPDIR/ui/strings"
# Extra app files (catalogues, docs) under target/<name>.
[[ -d "$APPDIR/extra" ]] && cp -r "$APPDIR/extra/." "$target/"
cp "$APPDIR/CHANGELOG.md" "$target/CHANGELOG.md" 2>/dev/null || true
echo "$SPK_VERSION" > "$target/build-id"
printf '[%s_web]\ntitle="%s: web app"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/tcp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_DESC" "$PORT" > "$target/$PKG_NAME.sc"
# Icons: the app's mark if it has one, else its letter.
if [[ -f "$APPDIR/icon.png" ]]; then python3 "$CH/core/icon.py" "$spk" --ui "$target/ui/images" --mark "$APPDIR/icon.png" --top "${ICON_TOP:-#2f8be6}" --bottom "${ICON_BOTTOM:-#1659a8}"
else python3 "$CH/core/icon.py" "$spk" --ui "$target/ui/images" --letter "${ICON_LETTER:-${PKG_TITLE:0:1}}" --top "${ICON_TOP:-#2f8be6}" --bottom "${ICON_BOTTOM:-#1659a8}"; fi

find "$target" -type d -exec chmod 755 {} +; find "$target" -type f -exec chmod 644 {} +
chmod 755 "$target/ui/api.cgi" "$target/setup/run.sh" "$target/setup/run-core.sh"
tar -C "$target" --owner=0 --group=0 --numeric-owner -czf "$spk/package.tgz" .

# scripts, conf, wizard: chassis files with the app's answers and pages spliced in.
mkdir -p "$spk/scripts" "$spk/conf" "$spk/WIZARD_UIFILES"
for s in "$CH"/core/scripts/*; do sub "$s" > "$spk/scripts/$(basename "$s")"; done
splice "$spk/scripts/postinst" "# @APP_ANSWERS@" "$APPDIR/wizard/answers.sh"
for c in privilege resource; do sub "$CH/core/conf/$c" > "$spk/conf/$c"; done
sub "$CH/core/WIZARD_UIFILES/install_uifile.sh" > "$spk/WIZARD_UIFILES/install_uifile.sh"; splice "$spk/WIZARD_UIFILES/install_uifile.sh" "@APP_PAGES@" "$APPDIR/wizard/pages.json"
sub "$CH/core/WIZARD_UIFILES/uninstall_uifile" > "$spk/WIZARD_UIFILES/uninstall_uifile"
chmod 755 "$spk"/scripts/* "$spk"/WIZARD_UIFILES/*.sh; chmod 644 "$spk/scripts/common" "$spk"/conf/* "$spk/WIZARD_UIFILES/uninstall_uifile"
{ echo "package=\"$PKG_NAME\""; echo "version=\"$SPK_VERSION\""; echo "os_min_ver=\"7.2.1-69057\""; echo "install_dep_packages=\"ContainerManager>=20.10.23-1432\""
  echo "displayname=\"$PKG_TITLE\""; echo "description=\"$PKG_DESC\""; echo "maintainer=\"$PKG_NAME-dsm\""; echo "maintainer_url=\"https://github.com/$REPO\""; echo "support_url=\"https://github.com/$REPO/issues\""
  echo "arch=\"noarch\""; echo "thirdparty=\"yes\""; echo "beta=\"${BETA:-no}\""; echo "dsmuidir=\"ui\""; echo "dsmappname=\"$APP_ID\""
  echo "extractsize=\"$(du -sk "$target" | cut -f1)\""; echo "checksum=\"$(md5sum "$spk/package.tgz" | cut -d' ' -f1)\""; } > "$spk/INFO"
out="$APPDIR/dist/$PKG_NAME-$SPK_VERSION.spk"
tar -C "$spk" --owner=0 --group=0 --numeric-owner -cf "$out" INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
echo "$out ($(du -h "$out" | cut -f1))"
