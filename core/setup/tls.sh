# HTTPS helpers for apps that serve TLS themselves (sourced by run-core.sh before app.sh).
# An app keeps its certificate in one of its volumes, under tls/: fullchain.pem,
# privkey.pem and source (dsm or self). DSM's own certificate is the system
# default from Control Panel → Security → Certificate; it is read at start and
# daily, so a renewal follows by itself.

tls_dsm_cert() {   # → tar (fullchain.pem privkey.pem) of DSM's system-default certificate on stdout; 1 when there is none here
  docker run --rm -v /usr:/host-usr:ro --entrypoint sh "$PKG_NAME-setup:local" -c \
    'd=/host-usr/syno/etc/certificate/system/default; [ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ] && tar -C "$d" -chf - fullchain.pem privkey.pem' 2>/dev/null
}
tls_self_cert() {   # → tar of a fresh self-signed certificate for the app's address and the NAS's IP (ten years) on stdout
  local d host ip san; d=$(mktemp -d); host=$(sed -E 's#^https?://##; s#[:/].*$##' <<< "$(env_get APP_URL)"); ip=$(env_get LAN_IP)
  san="IP:$ip"; if [[ "$host" =~ ^[0-9.]+$ ]]; then [[ "$host" != "$ip" ]] && san="$san,IP:$host"; else san="$san,DNS:$host"; fi
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$d/privkey.pem" -out "$d/fullchain.pem" -subj "/CN=$PKG_TITLE on ${host:-$ip}" \
    -addext "subjectAltName=$san" -addext "basicConstraints=CA:FALSE" -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
  chmod 644 "$d/privkey.pem"   # the app's own user reads it inside its container; the volume is the boundary
  tar -C "$d" -cf - fullchain.pem privkey.pem; rm -rf "$d"
}
tls_store() {   # volume tarfile source → into the volume's tls/
  in_volume "$1" rw -- "mkdir -p /vol/tls && tar -C /vol/tls -xf - && chmod 644 /vol/tls/privkey.pem /vol/tls/fullchain.pem && echo $3 > /vol/tls/source" < "$2" 2>>"$LOG"
}
tls_source_in() { in_volume "$1" ro -- 'cat /vol/tls/source 2>/dev/null' </dev/null 2>/dev/null; }   # volume → dsm | self | nothing
tls_info() {   # volume → JSON about the certificate in it, kept in $VAR/cert.json for the window
  local pem subj iss exp days sans
  pem=$(in_volume "$1" ro -- 'cat /vol/tls/fullchain.pem 2>/dev/null' </dev/null 2>/dev/null)
  if [[ -z "$pem" ]]; then echo null > "$VAR/cert.json"; return 0; fi
  subj=$(openssl x509 -noout -subject -nameopt RFC2253 <<< "$pem" 2>/dev/null | sed 's/^subject=//'); iss=$(openssl x509 -noout -issuer -nameopt RFC2253 <<< "$pem" 2>/dev/null | sed 's/^issuer=//')
  exp=$(openssl x509 -noout -enddate <<< "$pem" 2>/dev/null | sed 's/^notAfter=//'); days=$(( ($(date -d "$exp" +%s 2>/dev/null || echo 0) - $(now)) / 86400 ))
  sans=$(openssl x509 -noout -ext subjectAltName <<< "$pem" 2>/dev/null | tail -n +2 | tr -d ' \n' | head -c 300)
  jq -n -c --arg s "$subj" --arg i "$iss" --arg e "$exp" --argjson d "$days" --arg san "$sans" --arg src "$(env_get TLS_SOURCE)" \
    '{subject: $s, issuer: $i, expires: $e, days_left: $d, names: $san, self_signed: ($s == $i), source: $src}' > "$VAR/cert.json.tmp" && mv "$VAR/cert.json.tmp" "$VAR/cert.json"
}
tls_prepare() {   # volume → puts the certificate for the chosen mode (TLS=dsm|self|off) in place; sets TLS_SOURCE; 0 unless it failed
  local vol=$1 mode source tarf="$VAR/.cert.tar"
  mode=$(env_get TLS); mode=${mode:-off}; source=$mode; : > "$tarf"
  if [[ "$mode" == off ]]; then env_set TLS_SOURCE off; rm -f "$tarf"; echo null > "$VAR/cert.json"; return 0; fi
  if [[ "$mode" == dsm ]]; then
    if ! { tls_dsm_cert > "$tarf" && [[ -s "$tarf" ]]; }; then
      [[ "$(env_get TLS_SOURCE)" == self ]] || say "DSM's certificate wasn't found here (no system-default certificate, or not a Synology) — a self-signed one is used instead"
      source=self; : > "$tarf"
    fi
  fi
  if [[ "$source" == self && "$(tls_source_in "$vol")" == self ]]; then rm -f "$tarf"   # keep it: a browser's exception for it survives restarts
  elif [[ "$source" == self ]]; then
    tls_self_cert > "$tarf" && [[ -s "$tarf" ]] || { MSG="Couldn't make a self-signed certificate — see the log."; rm -f "$tarf"; return 1; }
    say "a self-signed certificate was made for $(env_get APP_URL)"
  fi
  if [[ -s "$tarf" ]]; then tls_store "$vol" "$tarf" "$source" || { MSG="The certificate couldn't be stored — see the log."; rm -f "$tarf"; return 1; }; fi
  rm -f "$tarf"; env_set TLS_SOURCE "$source"; tls_info "$vol"
}
tls_refresh_dsm() {   # volume → CERT_REFRESH=changed|same|none; stores DSM's certificate when it changed
  local vol=$1 tarf="$VAR/.cert.tar" new old; CERT_REFRESH=none
  [[ "$(env_get TLS)" == dsm ]] || return 0
  tls_dsm_cert > "$tarf" && [[ -s "$tarf" ]] || { rm -f "$tarf"; return 0; }
  new=$(tar -xOf "$tarf" fullchain.pem | sha256sum | cut -c1-16); old=$(in_volume "$vol" ro -- 'sha256sum /vol/tls/fullchain.pem 2>/dev/null' </dev/null 2>/dev/null | cut -c1-16)
  if [[ "$new" != "$old" ]]; then tls_store "$vol" "$tarf" dsm && { env_set TLS_SOURCE dsm; tls_info "$vol"; CERT_REFRESH=changed; say "DSM's certificate changed (renewed, or chosen anew) and was picked up"; }
  else CERT_REFRESH=same; fi
  rm -f "$tarf"; return 0
}
tls_fix_scheme() {   # the address's scheme follows TLS (unless DSM's reverse proxy provides HTTPS) → 0 when it changed
  local url; url=$(env_get APP_URL)
  if [[ "$(env_get TLS)" =~ ^(dsm|self)$ && "$url" == http://* ]]; then env_set APP_URL "https://${url#http://}"; say "the address is https://${url#http://} — $PKG_TITLE serves HTTPS itself"
  elif [[ "$(env_get TLS)" == off && "$(env_get SSL_PROXY)" == 0 && "$url" == https://* ]]; then env_set APP_URL "http://${url#https://}"; say "the address is http://${url#https://} — HTTPS is off and nothing in front provides it"
  else return 1; fi
}
