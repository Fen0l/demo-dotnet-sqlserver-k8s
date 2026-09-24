#!/bin/bash
# SqlProbe container entrypoint — owns everything Kerberos so that a plain
# `docker run --env-file .env` works, and the Kubernetes kinit sidecar reuses it.
#
#   entrypoint.sh              app mode: kinit if configured, keep renewing, exec dotnet
#   entrypoint.sh kinit-loop   sidecar mode: kinit + renew forever, no app
#
# Env (all optional unless SQLPROBE_AUTH=integrated and you want this container to kinit):
#   KRB5_USER          principal, e.g. svc-sqlprobe@ITCS.LOCAL
#   KRB5_KEYTAB        keytab path (used if the file exists)             -> kinit -kt
#   KRB5_PASSWORD      password (used if no keytab); unset before the app starts
#   KRB5_KDC           KDC host/IP. If set and no KRB5_CONFIG file is mounted, a
#                      krb5.conf is generated in /tmp (realm = KRB5_REALM or the
#                      part after '@' in KRB5_USER)
#   KRB5_REALM         realm override
#   KRB5_CONFIG        path of a mounted krb5.conf (takes precedence over KRB5_KDC)
#   KRB5CCNAME         ticket cache (default FILE:/tmp/krb5cc; k8s uses the shared volume)
#   KRB5_RENEW_SECONDS re-kinit interval (default 14400 = 4 h, tickets last 10 h)
#
# If SQLPROBE_AUTH=sql, or no KRB5_USER, or neither keytab nor password is
# available (k8s app container: the sidecar owns the ticket), Kerberos is skipped.
set -uo pipefail
MODE="${1:-app}"
export KRB5CCNAME="${KRB5CCNAME:-FILE:/tmp/krb5cc}"
KRB5_KEYTAB="${KRB5_KEYTAB:-/krb5/keytab/svc-sqlprobe.keytab}"
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

do_kinit() {
  if [[ -s "$KRB5_KEYTAB" ]]; then
    kinit -kt "$KRB5_KEYTAB" "$KRB5_USER"
  elif [[ -n "${KRB5_PASSWORD:-}" ]]; then
    printf '%s' "$KRB5_PASSWORD" | kinit "$KRB5_USER"
  else
    return 2
  fi
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
  if [[ -s "$KRB5_KEYTAB" || -n "${KRB5_PASSWORD:-}" ]]; then want_kerberos=1
  else log "KRB5_USER set but no keytab/password — assuming a sidecar provides $KRB5CCNAME"; fi
fi

if [[ "$MODE" == "kinit-loop" ]]; then
  [[ $want_kerberos -eq 1 ]] || { log "kinit-loop: KRB5_USER + keytab/password required"; exit 1; }
  kinit_loop
fi

if [[ $want_kerberos -eq 1 ]]; then
  if do_kinit; then log "kinit OK for $KRB5_USER"; klist
  else log "kinit FAILED for $KRB5_USER — the app will start anyway and report errors on /readyz"; fi
  kinit_loop >/dev/null 2>&1 &     # background renewal (inherits KRB5_PASSWORD, main shell drops it)
fi
unset KRB5_PASSWORD
exec dotnet /app/SqlProbe.dll
