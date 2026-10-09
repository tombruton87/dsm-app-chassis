# DSM app chassis

The reusable part of a Synology DSM 7 package for a Docker Compose app:
the privileged setup container that installs and watches the app, a DSM
window with the common tabs (Overview, Backups, Site address, Updates,
Storage, Maintenance with a complete removal), the CGI behind DSM's own
sign-in with administrator/read-only roles, the lifecycle scripts, the install
wizard, the build script and a test harness. An app repository adds only
what is its own.

Born from [freescout-dsm](https://github.com/tombruton87/freescout-dsm);
first used by [vaultwarden-dsm](https://github.com/tombruton87/vaultwarden-dsm).

## An app on the chassis

```
myapp-dsm/
  chassis/            this repository, as a git submodule
  package.conf        name, title, DSM app id, services, volumes, images, port …
  VERSION, CHANGELOG.md, README.md
  app/compose.yaml    the app's compose project (container_name: <pkg>-<service>, volumes named)
  app/env.example     what .env holds
  setup/app.sh        hooks for the setup container (see below); anything else in setup/ ships beside it
  ui/app.html         sections for the app's own tabs   ui/app-nav.html  their nav buttons
  ui/app.js           Panel.register("tab", {render, …})  ui/app-actions.sh  CGI validation of app actions
  ui/strings          extra DSM notification strings     ui/preload.txt   their keys for ui/config
  wizard/pages.json   extra wizard pages (JSON fragment) wizard/answers.sh  postinst lines for their answers
  icon.png            the app's mark (optional)
  tests/e2e-app.sh    app_e2e_answers / app_e2e_act for chassis/tests/e2e.sh
  dist/               built packages (ignored)
```

Build: `chassis/build.sh . N` → `dist/<pkg>-<version>-N.spk`. Test: `chassis/tests/test-api.sh <target/ui>` and `chassis/tests/e2e.sh . up|act|wipe|down|clean`.

## package.conf

```
PKG_NAME=vaultwarden            # package, share, volume prefix, container prefix
PKG_TITLE="Vaultwarden"         PKG_DESC="…"   APP_ID="Vaultwarden.AppInstance"
REPO=tombruton87/vaultwarden-dsm
SERVICES="server"               # compose services: containers are <pkg>-<service>
VOLUMES="data"                  # compose volumes: <pkg>_<volume>; backed up and wiped
IMAGE_VARS="VW_IMAGE"           # .env vars holding images; the first is checked for updates
PORT=8222  PORTS="8222 8223 8224"   HEALTH_PATH=/alive
APP_ACTIONS="admintoken|signups"    # extra request actions (regex alternatives)
APP_ANSWER_KEYS="…"  APP_REQUEST_KEYS="…"   # names app_validate accepts
TAGLINE WELCOME BACKUP_WHAT SITE_NOTE ICON_TOP ICON_BOTTOM ICON_LETTER BETA
```

## Hooks in setup/app.sh (all optional)

| Hook | When | Does |
|---|---|---|
| `app_validate KEY VALUE` | reading answers.env / request | return 0 if VALUE has KEY's shape |
| `app_first_env` | first start, after the core .env keys | `env_set` the app's own keys, make secrets |
| `app_load_env` | every start | read .env values the hooks need |
| `app_before_up` / `app_after_up` | around `compose up` | prepare / fix up |
| `app_health` | readiness and watchdog | return 0 when the app answers |
| `app_version` | status | print the app's version |
| `app_status` | rich refresh (window open) | print a JSON object → status.app |
| `app_logs` | rich refresh | write `$VAR/logs/<name>.log` files (use `for_window`) |
| `app_backup DIR` / `app_restore DIR` | backups | put files in DIR / put them back (containers are stopped for restore) |
| `app_storage` | storage report | print a JSON object → status.storage.app |
| `app_settings` | settings action | apply app keys from the request; return 0 if something changed |
| `app_after_settings` | after a settings restart | e.g. clear caches |
| `app_act ACTION` | any action not core | do it; set MSG; return 0/1 |
| `app_clearcache` | clearcache action | |
| `app_report` | support report | print extra sections |
| `app_check_updates` | twice a day | |
| `app_tick` | every loop tick | |
| `app_wipe` | removal | extra cleanup before the share is emptied |
| `app_extra_ports` | firewall .sc | print extra `[name] … dst.ports` blocks |

Core helpers available to hooks: `say`, `env_get`, `env_set`, `rand N`, `compose …`, `in_volume VOL ro|rw -- CMD` (stdin/stdout streaming, no host mounts; makes the volume with compose's labels if it doesn't exist yet), `cname SERVICE`, `svc_up SERVICE`, `leave_secret LABEL VALUE KIND` (one-time secret for the window), `notify KEY HOURS ARGS…`, `MSG`.

HTTPS helpers (`setup/tls.sh`, for apps that serve TLS themselves; the
certificate lives in one of the app's volumes under `tls/`, and `.env` holds
`TLS=dsm|self|off` and `TLS_SOURCE`, what's really in use):

| Helper | Does |
|---|---|
| `tls_prepare VOL` | puts the certificate for the chosen mode in place: DSM's system-default certificate, or a self-signed one (kept across restarts), falling back to self-signed when DSM has none; writes `$VAR/cert.json` |
| `tls_refresh_dsm VOL` | re-reads DSM's certificate; sets `CERT_REFRESH=changed|same|none` (call it daily from `app_tick`, restart or reload the app on `changed`) |
| `tls_fix_scheme` | makes the address `https://` or `http://` to match the mode (unless DSM's reverse proxy provides HTTPS) |
| `tls_info VOL`, `tls_dsm_cert`, `tls_self_cert`, `tls_store VOL TAR SOURCE` | the parts, for apps that need them |

## The window's app.js

```js
Panel.register("admin", { render: function (st, S) { … }, badge: function (st) { … }, tiles: function (tilesEl, st) { … } });
Panel.act("admintoken", {}, "Make a new admin token?");   // POST → app-actions.sh → request file → app_act
```
`Panel` exposes `el, cell, row, kv, chip, btn, tile, bytes, mb, ago, when, clear, showErr, showTab, loadLog, bindLogTabs, api, withToken, S, role, busy`. Buttons made with `Panel.btn` are disabled for non-administrators and while busy. Secret kinds: `leave_secret LABEL VALUE KIND` opens the tab named KIND.

## What the chassis guarantees

The things learned the hard way on real DSM: the app's data in Docker volumes (a share's ACLs admit only the package user); helper containers never mount share paths (DSM's share is a symlink with ACLs); a compose-renamed setup container is healed on start; the stop signal is a flag; failed actions carry their log lines; images pulled only when missing; start-up phases shown; nightly backups caught up; a removal that finishes through DSM's own uninstaller.
