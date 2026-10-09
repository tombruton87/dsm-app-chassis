// The window's core (chassis): polls api.cgi, renders the common tabs, and
// offers the app's app.js a small API: Panel.register({tab, render, init}),
// Panel.act, Panel.el/cell/row/kv/chip/btn/tile, Panel.bytes/mb/ago/when, Panel.S, Panel.role.
window.Panel = (function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var S = null, role = "viewer", tab = "overview", lastShown = 0, secretShown = false, tabs = {};
  function token() { try { return window.parent.SYNO.SDS.Session.SynoToken || ""; } catch (e) { return ""; } }
  function withToken(url) { var k = token(); return k ? url + "&SynoToken=" + encodeURIComponent(k) : url; }
  function api(query, body) {
    var opts = { credentials: "same-origin", headers: { "X-SYNO-TOKEN": token() } };
    if (body) { opts.method = "POST"; opts.headers["Content-Type"] = "application/x-www-form-urlencoded"; opts.body = new URLSearchParams(body).toString(); }
    return fetch(withToken("api.cgi?" + query), opts).then(function (r) { var json = (r.headers.get("Content-Type") || "").indexOf("json") >= 0;
      return (json ? r.json() : r.text()).then(function (data) { if (!r.ok) throw new Error((data && data.error) || ("No answer (" + r.status + ")")); return data; }); });
  }
  function el(tag, text, cls) { var e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; }
  function cell(value, cls) { var td = el("td", null, cls); if (value instanceof Node) td.appendChild(value); else td.textContent = value == null ? "" : value; return td; }
  function row(tbody, cells) { var tr = el("tr"); cells.forEach(function (c) { tr.appendChild(c instanceof Node && c.tagName === "TD" ? c : cell(c)); }); tbody.appendChild(tr); return tr; }
  function kv(tbody, label, value, num) { return row(tbody, [cell(label, "k"), cell(value, num ? "n" : "")]); }
  function chip(text, cls) { var s = el("span", null, "chip " + (cls || "")); s.appendChild(el("i")); s.appendChild(el("span", text)); return s; }
  function btn(text, cls, onclick) { var b = el("button", text, "btn " + (cls || "")); b.onclick = onclick; b.disabled = busy() || role !== "admin"; return b; }
  function tile(parent, value, label) { var d = el("div", null, "tile"); d.appendChild(el("b", value)); d.appendChild(el("span", label)); parent.appendChild(d); }
  function bytes(n) { if (n == null) return "–"; var u = ["B", "KB", "MB", "GB", "TB"], i = 0, b = n; while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; } return (b >= 10 || i === 0 ? Math.round(b) : b.toFixed(1)) + " " + u[i]; }
  function mb(n) { return bytes((n || 0) * 1024 * 1024); }
  function when(ts) { if (!ts) return "never"; var d = new Date(ts * 1000); return d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + ", " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
  function ago(ts) { if (!ts) return "never"; var s = Math.max(0, Math.floor(Date.now() / 1000 - ts)); if (s < 90) return s + " s ago"; if (s < 5400) return Math.round(s / 60) + " min ago"; if (s < 172800) return Math.round(s / 3600) + " h ago"; return Math.round(s / 86400) + " days ago"; }
  function busy() { return !!(S && S.status && S.status.busy) || !!(S && S.pending); }
  function showErr(msg) { $("err").textContent = msg; $("err").hidden = !msg; }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function act(action, extra, confirmText) {
    if (confirmText && !window.confirm(confirmText)) return Promise.resolve();
    showErr("");
    return api("action=" + action, Object.assign({ action: action }, extra || {})).then(function () { $("busy").textContent = "Working on it…"; $("busy").hidden = false; poll(); }).catch(function (e) { showErr(e.message); });
  }
  document.querySelectorAll("[data-act]").forEach(function (b) { b.addEventListener("click", function () { act(b.dataset.act, null, b.dataset.confirm); }); });

  function showTab(name) {
    tab = name;
    document.querySelectorAll("#nav button").forEach(function (b) { b.setAttribute("aria-selected", b.dataset.tab === name ? "true" : "false"); });
    document.querySelectorAll("section[data-page]").forEach(function (s) { s.hidden = s.dataset.page !== name; });
    var nb = document.querySelector('#nav button[data-tab="' + name + '"]'); $("title").textContent = nb ? nb.firstChild.textContent : name;
    if (name === "overview") loadLog("setup", "setup-log");
    if (name === "maintenance") loadLog(current("maint-log-tabs"), "maint-log");
    if (name === "updates") api("action=changelog").then(function (t) { $("changelog").textContent = t || "(no changelog)"; }).catch(function () {});
    if (tabs[name] && tabs[name].show) tabs[name].show();
    render();
  }
  document.querySelectorAll("#nav button").forEach(function (b) { b.addEventListener("click", function () { showTab(b.dataset.tab); try { history.replaceState(null, "", "#" + b.dataset.tab); } catch (e) { /* fine */ } }); });
  function current(tabsId) { var b = document.querySelector("#" + tabsId + " button[aria-selected='true']"); return b ? b.dataset.log : ""; }
  function bindLogTabs(id, into) { document.querySelectorAll("#" + id + " button").forEach(function (b) { b.addEventListener("click", function () { document.querySelectorAll("#" + id + " button").forEach(function (o) { o.setAttribute("aria-selected", o === b ? "true" : "false"); }); loadLog(b.dataset.log, into); }); }); if (!current(id)) { var f = document.querySelector("#" + id + " button"); if (f) f.setAttribute("aria-selected", "true"); } }
  bindLogTabs("maint-log-tabs", "maint-log");
  function loadLog(part, into) {
    if (!S) return;
    if (role !== "admin") { $(into).textContent = "Only DSM administrators can read logs."; return; }
    api("action=log&part=" + part).then(function (t) { var pre = $(into), atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20; pre.textContent = t || "(empty)"; if (atEnd) pre.scrollTop = pre.scrollHeight; }).catch(function (e) { $(into).textContent = e.message; });
  }
  $("reload-setup-log").onclick = function () { loadLog("setup", "setup-log"); };
  $("last-log").onclick = function (e) { e.preventDefault(); showTab("maintenance"); document.querySelectorAll("#maint-log-tabs button").forEach(function (o) { o.setAttribute("aria-selected", o.dataset.log === "setup" ? "true" : "false"); }); loadLog("setup", "maint-log"); $("maint-log").scrollIntoView(); };

  function stateChip() {
    var st = S.status || {}, parts = st.parts || [], ok = parts.length && parts.every(function (p) { return p.state === "running" && p.health !== "unhealthy"; });
    if (busy()) return chip(st.busy ? "Busy: " + st.busy : "Busy", "warn");
    if (S.state === "failed") return chip("Failed — see the setup log", "bad");
    if (S.state === "removed") return chip("Removed — Package Center is uninstalling", "bad");
    if (S.state === "stopped") return chip("Stopped", "bad");
    if (S.state === "starting") return chip(S.phase ? "Starting: " + S.phase : "Starting…", "warn");
    return ok ? chip("Up", "ok") : chip("Not all running", "bad");
  }
  function render() {
    if (!S) return;
    var st = S.status || {};
    clear($("chip")); $("chip").appendChild(stateChip());
    $("busy").hidden = !busy(); if (busy()) $("busy").textContent = st.busy ? "Working on it: " + st.busy + "…" : "Working on it…";
    $("foot").textContent = "package " + (st.build || "–") + " · " + (S.user || "");
    $("brand-version").textContent = st.version ? "@TITLE@ " + st.version : "@TAGLINE@";
    document.querySelectorAll("button[data-act], #save-settings, #save-prefs, #wipe, button.btn[data-app]").forEach(function (b) { b.disabled = role !== "admin" || busy(); });
    $("readonly").hidden = role === "admin";
    var last = st.last;
    if (last && last.at && Date.now() / 1000 - last.at < 120) {
      $("last").className = "note " + (last.ok ? "good" : "bad"); $("last-text").textContent = (last.ok ? "✓ " : "✗ ") + (last.message || last.action); $("last").hidden = false;
      $("last-detail").textContent = last.detail || ""; $("last-detail").hidden = !(last.ok === false && last.detail); $("last-log").hidden = last.ok !== false;
      if (last.action === "report" && last.ok) $("report-link").hidden = false;
    } else $("last").hidden = true;
    if (st.secret && !secretShown && role === "admin") takeSecret();
    var bl = st.backup && st.backup.last; $("badge-backups").hidden = !(bl && bl.ok === false); $("badge-backups").textContent = "!";
    var up = (st.update && st.update.newer) || (st.image_update && st.image_update.available); $("badge-updates").hidden = !up; $("badge-updates").textContent = "1";
    if (tab === "overview") renderOverview(st); if (tab === "backups") renderBackups(st); if (tab === "site") renderSite(st);
    if (tab === "updates") renderUpdates(st); if (tab === "storage") renderStorage(st);
    if (tabs[tab] && tabs[tab].render) { try { tabs[tab].render(st, S); } catch (e) { showErr("The " + tab + " tab hit an error: " + e.message); } }
    Object.keys(tabs).forEach(function (k) { if (tabs[k].badge) { try { tabs[k].badge(st, S); } catch (e) { /* fine */ } } });
  }
  function renderOverview(st) {
    var parts = st.parts || [], ok = parts.length && parts.every(function (p) { return p.state === "running" && p.health !== "unhealthy"; });
    $("hero-dot").className = "dot " + (S.state === "failed" || S.state === "stopped" || S.state === "removed" ? "bad" : busy() || S.state === "starting" ? "warn" : ok ? "ok" : "bad");
    $("hero-title").textContent = S.state === "failed" ? "@TITLE@ didn't start" : S.state === "stopped" ? "@TITLE@ is stopped" : S.state === "removed" ? "@TITLE@ was removed" : S.state === "starting" ? "@TITLE@ is starting" + (S.phase ? ": " + S.phase : "") : ok ? "@TITLE@ is up" : "@TITLE@ isn't fully running";
    $("hero-sub").textContent = (st.url ? st.url + " · " : "") + (st.version ? "@TITLE@ " + st.version : "") + (st.at ? " · checked " + ago(st.at) : "");
    $("open-link").href = st.url || "#"; $("open-link").hidden = !st.url;
    var t = $("tiles"); clear(t); var dk = st.disk || {};
    tile(t, st.backup && st.backup.last && st.backup.last.at ? ago(st.backup.last.at) : "never", "last backup"); tile(t, dk.free_mb != null ? mb(dk.free_mb) : "–", "free on the volume");
    if (tabs.overview && tabs.overview.tiles) tabs.overview.tiles(t, st);
    var c = $("containers"); clear(c);
    parts.forEach(function (p) { var h = p.health && p.health !== "-" ? ", " + p.health : ""; row(c, ["@PKG@-" + p.name, chip(p.state + h, p.state === "running" && p.health !== "unhealthy" ? "ok" : p.state === "running" ? "warn" : "bad")]); });
  }
  function renderBackups(st) {
    var tb = $("backups"); clear(tb); var list = st.backups || [];
    if (!list.length) { var tr = el("tr"); var td = cell("No backups yet.", "empty"); td.colSpan = 4; tr.appendChild(td); tb.appendChild(tr); }
    list.forEach(function (b) { var acts = el("span", null, "row"); var a = el("a", "Save", "btn"); a.href = withToken("api.cgi?action=backup&name=" + encodeURIComponent(b.name)); acts.appendChild(a);
      acts.appendChild(btn("Restore", "", function () { act("restore", { name: b.name }, "Restore " + b.name + "?\n\nEverything goes back to that moment; everything since is lost. A backup of the current state is made first."); }));
      acts.appendChild(btn("Delete", "danger", function () { act("delbackup", { name: b.name }, "Delete " + b.name + "?"); }));
      row(tb, [b.name, cell(bytes(b.size), "n"), when(b.at), cell(acts, "n")]); });
    if (!$("pref-nightly").dataset.touched && st.backup) { $("pref-nightly").checked = !!st.backup.nightly; $("pref-keep").value = st.backup.keep || 14; }
  }
  ["pref-nightly", "pref-keep"].forEach(function (id) { $(id).addEventListener("input", function () { $("pref-nightly").dataset.touched = "1"; }); });
  $("save-prefs").onclick = function () { api("action=prefs", { action: "prefs", nightly: $("pref-nightly").checked ? 1 : 0, keep: $("pref-keep").value }).then(function () { $("pref-nightly").dataset.touched = ""; $("last").className = "note good"; $("last-text").textContent = "✓ Saved."; $("last").hidden = false; }).catch(function (e) { showErr(e.message); }); };
  function renderSite(st) {
    if (!$("set-url").dataset.touched) { $("set-url").value = st.url || ""; $("set-port").value = st.port || ""; $("set-tz").value = st.tz || ""; $("set-ssl").checked = !!st.ssl_proxy; if (tabs.site && tabs.site.fill) tabs.site.fill(st); }
    $("site-port").textContent = st.port || "";
  }
  ["set-url", "set-port", "set-tz", "set-ssl"].forEach(function (id) { $(id).addEventListener("input", function () { $("set-url").dataset.touched = "1"; }); });
  $("save-settings").onclick = function () { var extra = tabs.site && tabs.site.values ? tabs.site.values() : {}; act("settings", Object.assign({ url: $("set-url").value.trim(), port: $("set-port").value, ssl_proxy: $("set-ssl").checked ? 1 : 0, tz: $("set-tz").value.trim() }, extra), "Save and restart @TITLE@? It's away for a minute.").then(function () { $("set-url").dataset.touched = ""; }); };
  function renderUpdates(st) {
    var a = $("upd-app"); clear(a); var iu = st.image_update, pu = st.update;
    a.appendChild(el("p", "Installed: @TITLE@ " + (st.version || "?") + "."));
    if (iu && iu.available) { a.appendChild(el("p", "A newer image is available. Updating backs everything up first, pulls the new image and restarts @TITLE@. Away for a few minutes.", "muted small")); a.appendChild(btn("Update @TITLE@", "primary", function () { act("updateapp", null, "Update now? A backup is made first; @TITLE@ is away for a few minutes."); })); }
    else a.appendChild(el("p", iu && iu.error ? "Couldn't check the registry: " + iu.error : "The image is current" + (iu && iu.checked ? " (checked " + ago(iu.checked) + ")" : "") + ".", "muted small"));
    var p = $("upd-pkg"); clear(p); p.appendChild(el("p", "Installed: package " + (st.build || "?") + "."));
    if (pu && pu.newer) { p.appendChild(el("p", "Package " + pu.latest + " is out. Installing it hands the package to Package Center; this window goes away and comes back with the new version.", "muted small")); var l = el("a", "What's new", ""); l.href = pu.page; l.target = "_blank"; l.rel = "noopener"; p.appendChild(l); p.appendChild(el("span", " ")); p.appendChild(btn("Update the package", "primary", function () { act("upgrade", null, "Install package " + pu.latest + " now? @TITLE@ stops and starts again with it."); })); }
    else p.appendChild(el("p", pu && pu.error ? "Couldn't check GitHub: " + pu.error : "The package is current" + (pu && pu.checked ? " (checked " + ago(pu.checked) + ")" : "") + ".", "muted small"));
    p.appendChild(el("span", " ")); p.appendChild(btn("Look for updates now", "", function () { act("check"); }));
  }
  function renderStorage(st) {
    var s = st.storage, t = $("storage-tiles"); clear(t);
    if (!s) { tile(t, "–", "the report comes in a moment"); return; }
    var vols = s.volumes || {}, total = 0; Object.keys(vols).forEach(function (k) { total += vols[k]; });
    tile(t, mb(total), "all volumes"); tile(t, mb((st.disk || {}).backups_mb), "backups in the share"); tile(t, mb((st.disk || {}).free_mb), "free on the volume");
    var tb = $("storage-volumes"); clear(tb); Object.keys(vols).forEach(function (k) { kv(tb, "@PKG@_" + k, mb(vols[k]), true); });
    if (tabs.storage && tabs.storage.render) tabs.storage.render(s.app || {}, st, $("storage-app"));
  }
  function takeSecret() {
    secretShown = true;
    api("action=take_secret", { action: "take_secret" }).then(function (s) { $("secret-for").textContent = s.email || ""; $("secret").textContent = s.password || ""; $("secret-card").hidden = false; $("secret-note").textContent = (tabs.secretNote && tabs.secretNote(s)) || ""; if (s.kind && tabs[s.kind] ) showTab(s.kind); }).catch(function (e) { secretShown = false; showErr(e.message); });
  }
  $("copy-secret").onclick = function () { try { navigator.clipboard.writeText($("secret").textContent); $("copy-secret").textContent = "Copied"; } catch (e) { /* select by hand */ } };
  $("wipe").onclick = function () { if (!$("wipe-saved").checked) { showErr("Tick the box first — the backups go too."); return; } if ($("wipe-phrase").value.trim() !== "remove everything") { showErr("Type exactly: remove everything"); return; } act("wipe", { confirm: $("wipe-phrase").value.trim() }, "Last chance. @TITLE@, all of its data and backups, and the package will be removed. There is no undo.\n\nRemove everything?"); };

  var polling = false;
  function poll() { if (polling || document.hidden) return; polling = true; api("action=status").then(function (s) { var first = !S; S = s; role = s.role; showErr(""); if (first) showTab(tab); else render(); }).catch(function (e) { showErr(e.message); }).then(function () { polling = false; }); }
  var wanted = (location.hash || "").slice(1); if (wanted && document.querySelector('#nav button[data-tab="' + wanted + '"]')) tab = wanted;
  setTimeout(function () { poll(); setInterval(poll, 3000); setInterval(function () { if (tab === "overview") loadLog("setup", "setup-log"); if (tab === "maintenance") loadLog(current("maint-log-tabs"), "maint-log"); if (tabs[tab] && tabs[tab].tick) tabs[tab].tick(); }, 8000); }, 0);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) poll(); });
  return { register: function (name, def) { tabs[name] = def; if (def.init) def.init(); }, act: act, api: api, el: el, cell: cell, row: row, kv: kv, chip: chip, btn: btn, tile: tile, bytes: bytes, mb: mb, ago: ago, when: when, clear: clear, showErr: showErr, showTab: showTab, loadLog: loadLog, bindLogTabs: bindLogTabs, withToken: withToken, get S() { return S; }, get role() { return role; }, get busy() { return busy(); }, get tab() { return tab; } };
})();
