#!/bin/bash
# SqlProbe container entrypoint — owns everything Kerberos so that a plain
# `docker run --env-file .env` works and the Kubernetes pod needs no sidecar.
#
#   entrypoint.sh              app mode: kinit if configured, keep renewing, exec dotnet
#   entrypoint.sh kinit-loop   kinit + renew forever, no app (optional sidecar use)
#
# Credentials (SQLPROBE_AUTH=integrated):
#   KRB5_CREDS_DIR     directory with files KRB5_USER and KRB5_PASSWORD — the Secret
#                      sqlprobe-ad-credentials mounted as a volume. Files are re-read at
#                      EVERY kinit, and Kubernetes updates mounted Secret files in place,
#                      so a CyberArk/Vault/ESO password rotation is picked up at the next
#                      renewal without restarting the pod. (default /krb5/creds)
#   KRB5_USER / KRB5_PASSWORD   env alternative (docker run --env-file). The password is
#                      removed from the app's environment after the first kinit.
#   KRB5_KEYTAB        optional keytab path; used instead of a password if the file exists
#
# Other:
#   KRB5_KDC           KDC host/IP. If set and no KRB5_CONFIG file is mounted, a krb5.conf
#                      is generated in /tmp (realm = KRB5_REALM or the part after '@')
#   KRB5_REALM         realm override
#   KRB5_CONFIG        path of a mounted krb5.conf (takes precedence over KRB5_KDC)
#   KRB5CCNAME         ticket cache (default FILE:/tmp/krb5cc)
#   KRB5_RENEW_SECONDS re-kinit interval (default 14400 = 4 h; tickets last 10 h)
#
# Renewal is atomic: kinit writes a new cache file, then it is renamed over the live
# one, so the app (which reads the cache on every NEW SQL connection) never sees an
# empty or half-written cache. Already-open pooled connections are not affected:
# Kerberos is only used at login.
#
# If SQLPROBE_AUTH=sql, or no principal, or no credential source, Kerberos is skipped.
set -uo pipefail
MODE="${1:-app}"
export KRB5CCNAME="${KRB5CCNAME:-FILE:/tmp/krb5cc}"
KRB5_KEYTAB="${KRB5_KEYTAB:-/krb5/keytab/svc-sqlprobe.keytab}"
KRB5_CREDS_DIR="${KRB5_CREDS_DIR:-/krb5/creds}"
CC_FILE="${KRB5CCNAME#FILE:}"
# principal: mounted file wins over env
if [[ -s "$KRB5_CREDS_DIR/KRB5_USER" ]]; then KRB5_USER="$(tr -d '\r\n' < "$KRB5_CREDS_DIR/KRB5_USER")"; fi
log() { echo "$(date -Is) entrypoint: $*"; }

gen_krb5_conf() {
  [[ -n "${KRB5_CONFIG:-}" && -f "${KRB5_CONFIG:-}" ]] && return 0
  [[ -n "${KRB5_KDC:-}" ]] || return 0
  local realm="${KRB5_REALM:-${KRB5_USER##*@}}"
  local domain; domain="$(tr '[:upper:]' '[:lower:]' <<<"$realm")"
  export KRB5_CONFIG=/tmp/krb5.conf
  cat > "$KRB5_CONFIG" <<CONF
[libdefaults]
    default_realm = $realm
    dns_lookup_kdc = false
    dns_lookup_realm = false
    rdns = false
    dns_canonicalize_hostname = false
    ticket_lifetime = 10h
    renew_lifetime = 7d
    forwardable = false
    udp_preference_limit = 1
    default_ccache_name = $KRB5CCNAME
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
[realms]
    $realm = {
        kdc = $KRB5_KDC
        admin_server = $KRB5_KDC
    }
[domain_realm]
    .$domain = $realm
    $domain  = $realm
CONF
  log "generated $KRB5_CONFIG (realm $realm, kdc $KRB5_KDC)"
}

# Password source, evaluated at every call: mounted file (live-updated) > env.
current_password() {
  if [[ -s "$KRB5_CREDS_DIR/KRB5_PASSWORD" ]]; then tr -d '\r\n' < "$KRB5_CREDS_DIR/KRB5_PASSWORD"
  elif [[ -n "${KRB5_PASSWORD:-}" ]]; then printf '%s' "$KRB5_PASSWORD"
  else return 1; fi
}
have_credentials() { [[ -s "$KRB5_KEYTAB" ]] || current_password >/dev/null 2>&1; }

# kinit into a fresh cache, then atomically replace the live one.
do_kinit() {
  local tmp="${CC_FILE}.new.$$" rc pw
  if [[ -s "$KRB5_KEYTAB" ]]; then
    kinit -c "FILE:$tmp" -kt "$KRB5_KEYTAB" "$KRB5_USER"; rc=$?
  elif pw="$(current_password)"; then
    printf '%s' "$pw" | kinit -c "FILE:$tmp" "$KRB5_USER"; rc=$?
  else
    return 2
  fi
  if [[ $rc -eq 0 ]]; then mv -f "$tmp" "$CC_FILE"; else rm -f "$tmp"; fi
  return $rc
}

kinit_loop() {
  while true; do
    if do_kinit; then log "kinit OK for $KRB5_USER (next in ${KRB5_RENEW_SECONDS:-14400}s)"; klist
    else log "kinit FAILED for $KRB5_USER (rc=$?) — retry in 30s"; sleep 30; continue; fi
    sleep "${KRB5_RENEW_SECONDS:-14400}"
  done
}

want_kerberos=0
if [[ "${SQLPROBE_AUTH:-integrated}" != "sql" && -n "${KRB5_USER:-}" ]]; then
  gen_krb5_conf
  if have_credentials; then want_kerberos=1
    [[ -s "$KRB5_CREDS_DIR/KRB5_PASSWORD" ]] && log "credentials from $KRB5_CREDS_DIR (re-read at every renewal)"
  else log "KRB5_USER set but no credentials — assuming something else provides $KRB5CCNAME"; fi
fi

if [[ "$MODE" == "kinit-loop" ]]; then
  [[ $want_kerberos -eq 1 ]] || { log "kinit-loop: KRB5_USER + keytab/password required"; exit 1; }
  kinit_loop
fi

if [[ $want_kerberos -eq 1 ]]; then
  if do_kinit; then log "kinit OK for $KRB5_USER"; klist
  else log "kinit FAILED for $KRB5_USER — the app will start anyway and report errors on /readyz"; fi
  kinit_loop >/dev/null 2>&1 &     # background renewal (inherits KRB5_PASSWORD env if used; main shell drops it)
fi
unset KRB5_PASSWORD
exec dotnet /app/SqlProbe.dll
