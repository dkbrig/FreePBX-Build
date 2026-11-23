#!/usr/bin/env bash
#
# Install the Let's Encrypt certificate for sip.chilimac.org into
# /etc/asterisk/keys and restart FreePBX/Asterisk, rolling back on failure.
# Run as root (via sudo).   Usage: install-sip-chilimac-cert [--force]

set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly DOMAIN="sip.chilimac.org"
readonly STAGING="/home/dbrig/certdeploy/cert-staging"
readonly DEST="/etc/asterisk/keys"
readonly CERT_DEST="${DEST}/${DOMAIN}.crt"
readonly KEY_DEST="${DEST}/${DOMAIN}.key"
readonly SERVICE="asterisk.service"
readonly LOCK="/run/lock/${DOMAIN}-deploy.lock"
FORCE=false
[[ ${1:-} == "--force" ]] && FORCE=true

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    ""|--force) ;;
    *) die "Usage: ${0##*/} [--force]" ;;
esac

WORK=""
KEEP_WORK=false
cleanup() {
    if $KEEP_WORK; then
        log "Leaving work directory for recovery: ${WORK}" >&2
    elif [[ -n $WORK && -d $WORK ]]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT
trap 'die "Unexpected failure at line ${LINENO}: ${BASH_COMMAND}"' ERR

# --- Preconditions ---------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Must be run as root."

for cmd in openssl install fwconsole asterisk systemctl flock cmp \
           cp mv rm mktemp sha256sum cut sleep id; do
    command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
done
id asterisk >/dev/null 2>&1 || die "User 'asterisk' does not exist."

exec 9>"$LOCK"
flock -n 9 || die "Another deployment is already running."

[[ -d $STAGING && ! -L $STAGING ]] || die "Staging directory missing or a symlink."
[[ -d $DEST    && ! -L $DEST    ]] || die "Destination directory missing or a symlink."

# Verify existing destination files are regular files, not symlinks.
for file in "$CERT_DEST" "$KEY_DEST"; do
    if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
        die "Destination exists but is not a regular file: $file"
    fi
done

# --- Snapshot staging files into a root-owned work dir ---------------------
# Everything below validates and installs the snapshot, never the originals.
WORK=$(mktemp -d "${DEST}/.deploy.XXXXXX")

snapshot() {   # snapshot <src> <dst>
    cp --no-dereference -- "$1" "$2" || die "Cannot read $1"
    [[ -f $2 && ! -L $2 ]] || die "$1 is not a regular file (symlink?)"
}
snapshot "${STAGING}/${DOMAIN}.fullchain.pem" "${WORK}/src.crt"
snapshot "${STAGING}/${DOMAIN}.key"           "${WORK}/src.key"

# --- Validate --------------------------------------------------------------
host_check=$(openssl x509 -in "${WORK}/src.crt" -noout -checkhost "$DOMAIN" 2>&1) || true
[[ $host_check == *"does match certificate"* ]] ||
    die "Certificate does not match hostname ${DOMAIN}."

openssl x509 -in "${WORK}/src.crt" -noout -checkend 86400 >/dev/null ||
    die "Certificate is expired or expires within 24 hours."

openssl verify -purpose sslserver \
    -untrusted "${WORK}/src.crt" "${WORK}/src.crt" >/dev/null 2>&1 ||
    die "Certificate chain failed verification."

openssl pkey -in "${WORK}/src.key" -noout </dev/null ||
    die "Private key validation failed."

cert_pub=$(openssl x509 -in "${WORK}/src.crt" -noout -pubkey \
           | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1) ||
    die "Could not hash certificate public key."
key_pub=$(openssl pkey -in "${WORK}/src.key" -pubout -outform DER </dev/null \
          | sha256sum | cut -d' ' -f1) ||
    die "Could not hash private key."
[[ $cert_pub == "$key_pub" ]] || die "Certificate and private key do not match."

# --- Skip if nothing changed -----------------------------------------------
if ! $FORCE && [[ -f $CERT_DEST && -f $KEY_DEST ]] \
   && cmp -s "${WORK}/src.crt" "$CERT_DEST" \
   && cmp -s "${WORK}/src.key" "$KEY_DEST"; then
    log "Installed certificate is already current; nothing to do (use --force to restart anyway)."
    exit 0
fi

# --- Stage new files, back up old ones -------------------------------------
install -o asterisk -g asterisk -m 0644 "${WORK}/src.crt" "${WORK}/new.crt"
install -o asterisk -g asterisk -m 0600 "${WORK}/src.key" "${WORK}/new.key"

for ext in crt key; do
    if [[ -f "${DEST}/${DOMAIN}.${ext}" ]]; then
        cp -p -- "${DEST}/${DOMAIN}.${ext}" "${WORK}/old.${ext}"
    fi
done

# --- Functions used under `if` (set -e is suspended inside them) -----------
swap_in() {
    mv -fT -- "${WORK}/new.key" "$KEY_DEST"  || return 1
    mv -fT -- "${WORK}/new.crt" "$CERT_DEST" || return 1
}

rollback() {
    local ext
    local failed=0

    for ext in crt key; do
        if [[ -f "${WORK}/old.${ext}" ]]; then
            mv -fT -- "${WORK}/old.${ext}" "${DEST}/${DOMAIN}.${ext}" ||
                failed=1
        else
            rm -f -- "${DEST}/${DOMAIN}.${ext}" ||
                failed=1
        fi
    done

    return "$failed"
}

wait_for_asterisk() {
    local i
    for ((i = 0; i < 30; i++)); do
        if systemctl is-active --quiet "$SERVICE" 9>&- \
           && asterisk -rx "core show uptime" >/dev/null 2>&1 9>&-; then
            return 0
        fi
        sleep 2 9>&-
    done
    return 1
}

restart_pbx() {
    fwconsole restart 9>&- || return 1
    wait_for_asterisk
}

# --- Deploy ----------------------------------------------------------------
log "Installing certificate and key..."
if swap_in && log "Restarting FreePBX/Asterisk..." && restart_pbx; then
    log "Deployment succeeded: ${CERT_DEST}"
    exit 0
fi

log "Deployment failed; rolling back to the previous certificate..." >&2
KEEP_WORK=true

if ! rollback; then
    die "Rollback file restoration failed. Manual intervention required."
fi

KEEP_WORK=false

if restart_pbx; then
    die "Deployment failed; previous certificate restored and PBX is running."
fi

KEEP_WORK=true
die "Deployment AND rollback restart failed. Manual intervention required."
