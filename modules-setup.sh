#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Instal·lador text per patch iRedMail (mode terminal)
# Components per defecte: Friendly Captcha, 2FA, Cleanup
# Característiques clau:
#     Captcha seleccionable: Friendly (default) o Google reCAPTCHA v2 Checkbox.
#     2FA amb comprovació i instal·lació de llibreries Python.
#     Integració permisos fail2ban (sudoers).
#     Integració de DomainOwnership.
#     Patch files copiats recursivament des de PATCH_URL o /tmp/iredadmin_patch/ a ROOT_PATH.
#     Rollback complet si l’instal·lador es cancel·la o falla.

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# Comprovar que s’executa com a root
if [[ $EUID -ne 0 ]]; then
    echo "Aquest script s’ha d’executar com a root o amb sudo."
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# -------------------- Globals --------------------
ROOT_PATH=""
COMPONENTS=()
COPIED_FILES=()
MODIFIED_FILES=()
PATCH_TMP="/tmp/iredadmin_patch"
CUSTOM_FILE=""
PATCH_URL="${PATCH_URL:-}"
BACKUP_TAR="/tmp/iredadmin_patch_backup.tar"
PATCH_FILE_LIST="/tmp/iredadmin_patch_files.list"
BACKUP_FILES_LIST="/tmp/iredadmin_patch_backup_files.list"
COMPONENTS_ENV="${COMPONENTS_ENV:-}"
CAPTCHA_PROVIDER="${CAPTCHA_PROVIDER:-friendly}"
NORMALIZE_OVERLAY_PERMS="${NORMALIZE_OVERLAY_PERMS:-y}"

# --- Fail2Ban sync cron ---
F2B_SYNC_TAG="# iRedAdmin-Patch-F2B-Sync"
F2B_SYNC_LOG="/var/log/iredadmin-f2b-sync.log"
ROOT_CRONTAB_BACKUP="/tmp/iredadmin_root_crontab.bak"

# -------------------- Continguts de fitxers --------------------
readonly INSTALL_BANNER="$(cat <<'EOF'
Aquest instal·lador farà les següents accions:
  - Copiar fitxers del patch (PATCH_URL si està definit, o /tmp/iredadmin_patch)
  - Configurar captcha (Friendly o Google reCAPTCHA v2 Checkbox)
  - Instal·lar 2FA (llibreries Python)
  - Activar Cron Cleanup
  - Configurar Domain Ownership
  - Permisos fail2ban per iredadmin
  - Sincronització periòdica Fail2Ban → BD (cada 2 min)
  - Desactivar el cron 'unban_db' de root (redundant amb el nostre sync)
  - Templates adaptades ('classic' i 'codyframe') que milloren l'interacció (amavisd, iredapd, fali2ban, 2FA, ...)
EOF
)"

readonly DOMAIN_OWNERSHIP_HEADER="$(cat <<'EOF'

# 👉 Domains ownership verification
EOF
)"

readonly DOMAIN_OWNERSHIP_EXPIRE_COMMENT="$(cat <<'EOF'
# How long should we remove verified or (inactive) unverified domain ownerships.
#
# iRedAdmin-Pro stores verified ownership in SQL database, if (same) admin
# removed the domain and re-adds it, no verification required.
#
# Usually normal domain admin won't frequently remove and re-add same domain
# name, so it's ok to remove saved ownership after X days.
EOF
)"

readonly DOMAIN_OWNERSHIP_PREFIX_COMMENT="$(cat <<'EOF'
# The string prefixed to verify code. Must be shorter than than 60 characters.
EOF
)"

readonly DOMAIN_OWNERSHIP_TIMEOUT_COMMENT="$(cat <<'EOF'
# Timeout (in seconds) while performing each verification.
EOF
)"

readonly CUSTOM_SETTINGS_SKELETON="$(cat <<'EOF'
SKIN = "codyframe"
#SKIN = "classic"
#SKIN = "tailwind"
BRAND_LOGO = 'logo.png'             # load file 'static/logo.png'
BRAND_FAVICON = 'favicon.ico'       # load file 'static/favicon.ico'

EOF
)"

readonly SET_CUSTOM_SETTING_PY="$(cat <<'PY'
import os
import re
import sys
import tempfile

path, key, value, raw = sys.argv[1:5]
raw = raw == "1"

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

pattern = re.compile(r"^" + re.escape(key) + r"=")
new_line = f"{key}={value}" if raw else f"{key}='{value}'"

for idx, line in enumerate(lines):
    if pattern.match(line):
        lines[idx] = new_line
        break
else:
    lines.append(new_line)

dir_name = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(prefix=".custom_settings.", dir=dir_name, text=True)
os.close(fd)
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
)"

readonly GET_CUSTOM_SETTING_PY="$(cat <<'PY'
import ast
import re
import sys

path, key = sys.argv[1:3]
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
value = ""

try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if pattern.match(line):
                raw = line.split("=", 1)[1].strip()
                raw = raw.split("#", 1)[0].strip()
                try:
                    parsed = ast.literal_eval(raw)
                    value = "" if parsed is None else str(parsed)
                except Exception:
                    value = raw.strip().strip("'").strip('"')
                break
except FileNotFoundError:
    pass

print(value)
PY
)"

readonly IREDADMIN_CLEANUP_SCRIPT="$(cat <<'EOF'
#!/usr/bin/env python3
#
# Author: Àngel <cuquet@gmail.com>
# Purpose: Purge expired records from SQL table "newsletter_subunsub_confirms"
#          to keep the confirmation queue clean.
# Notes: Token únic per mlid + subscriber + kind → no hi ha duplicats.
#
import os
import sys
import time

os.environ["LC_ALL"] = "C"

rootdir = os.path.abspath(os.path.dirname(__file__)) + "/../"
sys.path.insert(0, rootdir)

import web
from tools import ira_tool_lib

web.config.debug = ira_tool_lib.debug
logger = ira_tool_lib.logger
conn = ira_tool_lib.get_db_conn("iredadmin")

TABLE = "newsletter_subunsub_confirms"

def purge_expired():
    now = int(time.time())
    try:
        n = conn.delete(TABLE, where="expired < $now", vars={"now": now})
        logger.info(f"Purged {n} expired confirmation records from {TABLE}.")
    except Exception as e:
        logger.error(f"Error purging expired confirmations: {repr(e)}")

if __name__ == "__main__":
    purge_expired()
EOF
)"

readonly F2B_SUDOERS_TEMPLATE="$(cat <<'EOF'
# CONSULTA
Cmnd_Alias F2B_STATUS = @F2B@ status, @F2B@ status *
Cmnd_Alias F2B_GET    = @F2B@ get *

# CONTROL
Cmnd_Alias F2B_UNBAN  = @F2B@ set * unbanip *
Cmnd_Alias F2B_BAN    = @F2B@ set * banip *
Cmnd_Alias F2B_RELOAD = @F2B@ reload, @F2B@ reload *, @F2B@ reload --if-exists *, @F2B@ -d
Cmnd_Alias F2B_STOP   = @F2B@ stop *

# Assignació permisos
iredadmin ALL=(ALL) NOPASSWD: F2B_STATUS, F2B_GET, F2B_UNBAN, F2B_BAN, F2B_RELOAD, F2B_STOP
EOF
)"

# Bloc Python de seed de domain ownership, guardat en clar i codificat
# a base64 al vol per evitar problemes amb cometes i $ en passar-lo a python3.
readonly DOMAIN_OWNERSHIP_SEED_PY_B64="$(base64 -w0 <<'PY'
import os
import sys

root_path = sys.argv[1]
if not root_path:
    print("[warn] ROOT_PATH buit. S'omet seed de domain ownership.")
    sys.exit(0)

sys.path.insert(0, root_path)

import web
web.config.debug = False

import settings
from libs import iredutils
from libs.m_system.domain_ownership import DomainOwnershipManager
from tools import ira_tool_lib


def _collect_domains():
    domains = []

    if settings.backend in ("mysql", "pgsql"):
        conn_vmail = ira_tool_lib.get_db_conn("vmail")
        if not conn_vmail:
            return domains

        qr = conn_vmail.select("domain", what="domain")
        for r in qr:
            d = str(getattr(r, "domain", "")).strip().lower()
            if iredutils.is_domain(d):
                domains.append(d)

    elif settings.backend == "ldap":
        import ldap
        from libs.ldaplib.core import LDAPWrap

        wrap = LDAPWrap()
        conn = wrap.conn
        qr = conn.search_s(
            settings.ldap_basedn,
            ldap.SCOPE_ONELEVEL,
            "(objectClass=mailDomain)",
            ["domainName"],
        )
        qr = iredutils.bytes2str(qr)

        for _dn, attrs in qr:
            d = (attrs.get("domainName") or [""])[0]
            d = str(d).strip().lower()
            if iredutils.is_domain(d):
                domains.append(d)

    return sorted(set(domains))


def _collect_install_domains():
    domains = []
    raw_values = [
        os.getenv("FIRST_DOMAIN", ""),
        os.getenv("FIRST_MAIL_DOMAIN", ""),
    ]

    # Fallback: extreure el domini del webmaster de settings.py
    if not any(str(v).strip() for v in raw_values):
        try:
            import settings
            webmaster = getattr(settings, "webmaster", "") or ""
            webmaster = str(webmaster).strip().lower()
            if "@" in webmaster:
                domain_from_webmaster = webmaster.split("@", 1)[1].strip()
                if iredutils.is_domain(domain_from_webmaster):
                    raw_values.append(domain_from_webmaster)
                    print(f"[info] FIRST_DOMAIN no definit. Usant domini del webmaster: {domain_from_webmaster}")
        except Exception as e:
            print(f"[warn] No s'ha pogut detectar el domini del webmaster: {repr(e)}")

    for raw in raw_values:
        for item in str(raw).replace(";", ",").split(","):
            d = item.strip().lower()
            if iredutils.is_domain(d):
                domains.append(d)

    return sorted(set(domains))


conn_iredadmin = ira_tool_lib.get_db_conn("iredadmin")
if not conn_iredadmin:
    print("[warn] No s'ha pogut connectar a iredadmin DB. Ometent seed de domain ownership.")
    sys.exit(0)

web.conn_iredadmin = conn_iredadmin
domains = _collect_domains()
install_domains = set(_collect_install_domains())
mgr = DomainOwnershipManager()

created = 0
existing = 0
auto_verified = 0
errors = []

for d in domains:
    try:
        qr = conn_iredadmin.select(
            "domain_ownership",
            vars={"domain": d},
            what="id, verified",
            where="domain=$domain AND alias_domain=''",
            limit=1,
        )
        row_verified = False
        if qr:
            existing += 1
            row_verified = int(getattr(qr[0], "verified", 0) or 0) == 1
        else:
            result = mgr.set_verify_code_for_new_domain(primary_domain=d, alias_domains=[])
            ok = bool(result[0]) if isinstance(result, tuple) and result else False
            if ok:
                created += 1
            else:
                msg = result[1] if isinstance(result, tuple) and len(result) > 1 else "UNKNOWN_ERROR"
                errors.append(f"{d}: {msg}")
                continue

            qr = conn_iredadmin.select(
                "domain_ownership",
                vars={"domain": d},
                what="id, verified",
                where="domain=$domain AND alias_domain=''",
                limit=1,
            )
            if qr:
                row_verified = int(getattr(qr[0], "verified", 0) or 0) == 1

        if d in install_domains and not row_verified:
            conn_iredadmin.update(
                "domain_ownership",
                vars={"domain": d},
                verified=1,
                admin=f"postmaster@{d}",
                message="LAB_INSTALL_DOMAIN_AUTO_VERIFIED",
                last_verify=web.sqlliteral("NOW()"),
                where="domain=$domain AND alias_domain=''",
            )
            auto_verified += 1
    except Exception as e:
        errors.append(f"{d}: {repr(e)}")

print(
    f"[info] Domain ownership seed: domains={len(domains)}, created={created}, "
    f"existing={existing}, auto_verified={auto_verified}, errors={len(errors)}"
)
if errors:
    print("[warn] Domain ownership seed errors:")
    for e in errors:
        print(f"  - {e}")
PY
)"

# -------------------- Funcions --------------------

set_custom_file_owner() {
    local path="$1"
    [[ -n "$path" && -e "$path" ]] || return 0

    if id -u iredadmin >/dev/null 2>&1; then
        chown iredadmin:iredadmin "$path" 2>/dev/null || true
    fi
}

show_exit_message() {
    local msg="$1"
    if [[ -w /dev/tty ]]; then
        printf "%s\n" "$msg" >/dev/tty
    else
        printf "%s\n" "$msg" >&2
    fi
    stty sane 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

# Detectar gestor de paquets
detect_pkg_mgr() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL=(apt-get install -y)
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL=(dnf install -y)
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL=(yum install -y)
    else
        echo "No s'ha detectat gestor de paquets compatible"
        exit 1
    fi
}

initial_info() {
    printf '%s\n' "$INSTALL_BANNER" >&2
    if [[ -t 0 ]]; then
        printf "Vols continuar amb la instal·lació? (s/N): " >&2
        read -r answer
        case "$answer" in
            s|S|y|Y) return 0 ;;
            *) show_exit_message "Instal·lació cancel·lada. Aprofita per obtenir primer les claus de Friendly Captcha"; exit 0 ;;
        esac
    else
        show_exit_message "Instal·lació cancel·lada (cal terminal interactiu)."
        exit 1
    fi
}

# Selecció de ruta arrel d'iRedAdmin
select_root_path() {
    local default_path="/opt/www/iredadmin"
    if [[ -z "$ROOT_PATH" ]]; then
        if [[ -t 0 ]]; then
            printf "Introdueix la ruta arrel d'iRedAdmin [%s]: " "$default_path" >&2
            read -r ROOT_PATH
        fi
        ROOT_PATH=${ROOT_PATH:-$default_path}
    fi
    printf "Ruta arrel seleccionada: %s\n" "$ROOT_PATH" >&2
    if [[ ! -f "$ROOT_PATH/settings.py" ]]; then
        show_exit_message "No s'ha trobat settings.py a $ROOT_PATH. Sortint."
        clear
        exit 1
    fi
}

# Pantalla checklist de components a instal·lar
select_components() {
    local raw="${COMPONENTS_ENV:-}"
    if [[ -z "$raw" ]]; then
        COMPONENTS=("FriendlyCaptcha" "2FA" "Cleanup")
        printf "Components seleccionats (per defecte): %s\n" "${COMPONENTS[*]}" >&2
        return
    fi
    raw=${raw//,/ }
    IFS=' ' read -r -a COMPONENTS <<< "$raw"
    printf "Components seleccionats: %s\n" "${COMPONENTS[*]}" >&2
}

# Selector de captcha global del setup.
normalize_captcha_provider() {
    CAPTCHA_PROVIDER="$(printf '%s' "${CAPTCHA_PROVIDER:-friendly}" | tr '[:upper:]' '[:lower:]')"
    case "$CAPTCHA_PROVIDER" in
        friendly|google) ;;
        *)
            printf "AVÍS: CAPTCHA_PROVIDER='%s' no vàlid. S'usarà 'friendly'.\n" "$CAPTCHA_PROVIDER" >&2
            CAPTCHA_PROVIDER="friendly"
            ;;
    esac
    printf "[info] Captcha seleccionat: %s\n" "$CAPTCHA_PROVIDER" >&2
    if [[ "$CAPTCHA_PROVIDER" == "google" ]]; then
        printf "[info] Mode Google actiu: reCAPTCHA v2 Checkbox (widget visible).\n" >&2
    else
        printf "[info] Mode Friendly actiu: challenge visible amb token frc-captcha-response.\n" >&2
    fi
}

download_and_prepare_patch() {
    local url="${PATCH_URL}"
    if [[ -z "$url" ]]; then
        show_exit_message "No hi ha URL de patch configurada (PATCH_URL buida). S'omet la descàrrega."
        return 1
    fi
    # Netejar patch anterior per evitar barreja de fitxers
    if [[ -d "$PATCH_TMP" ]]; then
        rm -rf "$PATCH_TMP"
    fi
    mkdir -p "$PATCH_TMP"
    printf "Baixant patch...\n" >&2
    sleep 1
    # Baixa l'arxiu temporalment
    tmpfile=$(mktemp)
    if [[ -f "$url" ]]; then
        cp "$url" "$tmpfile"
    else
        if command -v curl &>/dev/null; then
            if ! curl --fail --location --retry 3 --connect-timeout 10 --max-time 60 -o "$tmpfile" "$url"; then
                show_exit_message "No s'ha pogut descarregar el patch després de 3 intents."
                rm -f "$tmpfile"
                return 1
            fi
        elif command -v wget &>/dev/null; then
            if ! wget -O "$tmpfile" "$url"; then
                show_exit_message "No s'ha pogut descarregar el patch amb wget."
                rm -f "$tmpfile"
                return 1
            fi
        else
            show_exit_message "Falten curl o wget per descarregar el patch."
            rm -f "$tmpfile"
            return 1
        fi
    fi

    printf "Descomprimint patch...\n" >&2
    sleep 1
    # Detectar tipus d'arxiu i descomprimir segons contingut
    if unzip -tq "$tmpfile" >/dev/null 2>&1; then
        unzip -o "$tmpfile" -d "$PATCH_TMP" >/dev/null
    elif tar -tf "$tmpfile" --auto-compress >/dev/null 2>&1; then
        tar -xf "$tmpfile" --auto-compress -C "$PATCH_TMP"
    else
        show_exit_message "Format d'arxiu desconegut o corrupte: $tmpfile"
        rm -f "$tmpfile"
        return 1
    fi
    rm -f "$tmpfile"
}

ensure_custom_file() {
    CUSTOM_FILE="$ROOT_PATH/custom_settings.py"
    if [[ ! -f "$CUSTOM_FILE" ]]; then
        printf '%s' "$CUSTOM_SETTINGS_SKELETON" > "$CUSTOM_FILE"
        chmod 600 "$CUSTOM_FILE"
        set_custom_file_owner "$CUSTOM_FILE"
        COPIED_FILES+=("$CUSTOM_FILE")
        return
    fi

    # Pot arribar read-only des del patch; assegurem escriptura abans de modificar.
    chmod u+rw "$CUSTOM_FILE" 2>/dev/null || true
    set_custom_file_owner "$CUSTOM_FILE"

    # Assegurar capçalera SKIN al principi del fitxer
    local first_two
    first_two=$(head -n 2 "$CUSTOM_FILE" 2>/dev/null || true)
    if [[ "$first_two" != $'SKIN = "codyframe"\n#SKIN = "classic"' ]]; then
        if [[ ! -f "${CUSTOM_FILE}.bak" ]]; then
            cp "$CUSTOM_FILE" "${CUSTOM_FILE}.bak"
            MODIFIED_FILES+=("${CUSTOM_FILE}.bak")
        fi
        local orig_uid=""
        local orig_gid=""
        local orig_mode=""
        if stat -c "%u %g %a" "$CUSTOM_FILE" >/dev/null 2>&1; then
            read -r orig_uid orig_gid orig_mode < <(stat -c "%u %g %a" "$CUSTOM_FILE")
        fi
        local tmpfile
        tmpfile=$(mktemp)
        {
            printf 'SKIN = "codyframe"\n#SKIN = "classic"\n\n'
            sed -e '/^[#]*SKIN[[:space:]]*=/d' "$CUSTOM_FILE"
        } > "$tmpfile"
        mv "$tmpfile" "$CUSTOM_FILE"
        if [[ -n "$orig_mode" ]]; then
            chmod "$orig_mode" "$CUSTOM_FILE" 2>/dev/null || true
        fi
        if id -u iredadmin >/dev/null 2>&1; then
            set_custom_file_owner "$CUSTOM_FILE"
        elif [[ -n "$orig_uid" && -n "$orig_gid" ]]; then
            chown "$orig_uid:$orig_gid" "$CUSTOM_FILE" 2>/dev/null || true
        fi
    fi
}

set_custom_setting() {
    local key="$1"
    local value="$2"
    ensure_custom_file
    # Fem backup abans de modificar per al rollback
    if [[ ! -f "${CUSTOM_FILE}.bak" ]]; then
        cp "$CUSTOM_FILE" "${CUSTOM_FILE}.bak"
        MODIFIED_FILES+=("${CUSTOM_FILE}.bak")
    fi

    printf '%s' "$SET_CUSTOM_SETTING_PY" | python3 - "$CUSTOM_FILE" "$key" "$value" "0"
    set_custom_file_owner "$CUSTOM_FILE"
}

set_custom_setting_raw() {
    local key="$1"
    local value="$2"
    ensure_custom_file

    # Backup consistent per al rollback
    if [[ ! -f "${CUSTOM_FILE}.bak" ]]; then
        cp "$CUSTOM_FILE" "${CUSTOM_FILE}.bak"
        MODIFIED_FILES+=("${CUSTOM_FILE}.bak")
    fi

    printf '%s' "$SET_CUSTOM_SETTING_PY" | python3 - "$CUSTOM_FILE" "$key" "$value" "1"
    set_custom_file_owner "$CUSTOM_FILE"
}

remove_custom_setting() {
    local key="$1"
    ensure_custom_file

    if [[ ! -f "${CUSTOM_FILE}.bak" ]]; then
        cp "$CUSTOM_FILE" "${CUSTOM_FILE}.bak"
        MODIFIED_FILES+=("${CUSTOM_FILE}.bak")
    fi

    sed -i "/^${key}[[:space:]]*=/d" "$CUSTOM_FILE"
    set_custom_file_owner "$CUSTOM_FILE"
}

get_custom_setting_value() {
    local key="$1"
    ensure_custom_file
    printf '%s' "$GET_CUSTOM_SETTING_PY" | python3 - "$CUSTOM_FILE" "$key"
}

install_domain_ownership_settings() {
    # Configuració de verificació de propietat de dominis
    ensure_custom_file

    if ! grep -q "Domains ownership verification" "$CUSTOM_FILE"; then
        printf '%s' "$DOMAIN_OWNERSHIP_HEADER" >> "$CUSTOM_FILE"
    fi
    set_custom_setting_raw "REQUIRE_DOMAIN_OWNERSHIP_VERIFICATION" "True"

    if ! grep -q "DOMAIN_OWNERSHIP_EXPIRE_DAYS" "$CUSTOM_FILE"; then
        printf '%s\n' "$DOMAIN_OWNERSHIP_EXPIRE_COMMENT" >> "$CUSTOM_FILE"
    fi
    set_custom_setting_raw "DOMAIN_OWNERSHIP_EXPIRE_DAYS" "30"

    if ! grep -q "DOMAIN_OWNERSHIP_VERIFY_CODE_PREFIX" "$CUSTOM_FILE"; then
        printf '%s\n' "$DOMAIN_OWNERSHIP_PREFIX_COMMENT" >> "$CUSTOM_FILE"
    fi
    set_custom_setting "DOMAIN_OWNERSHIP_VERIFY_CODE_PREFIX" "iredmail-domain-verification-"

    if ! grep -q "DOMAIN_OWNERSHIP_VERIFY_TIMEOUT" "$CUSTOM_FILE"; then
        printf '%s\n' "$DOMAIN_OWNERSHIP_TIMEOUT_COMMENT" >> "$CUSTOM_FILE"
    fi
    set_custom_setting_raw "DOMAIN_OWNERSHIP_VERIFY_TIMEOUT" "10"
}

seed_existing_domains_domain_ownership() {
    # NOTE: Seed inicial idempotent:
    # - Quan l'iRedMail base ja té dominis creats (ex: FIRST_MAIL_DOMAIN),
    #   els inserim a domain_ownership si encara no hi són.
    # - Així apareixen a la UI de "Domain ownership verification" des del primer setup.
    local py_out
    if ! py_out="$(printf '%s' "$DOMAIN_OWNERSHIP_SEED_PY_B64" | base64 -d | python3 - "$ROOT_PATH")"; then
        printf "AVÍS: Error executant el seed inicial de domain ownership.\n" >&2
        return
    fi

    printf "%s\n" "$py_out" >&2
}

# Activació de la REST API d'iRedAdmin
install_rest_api_settings() {
    ensure_custom_file
    set_custom_setting_raw "ENABLE_RESTFUL_API" "True"
    printf "[info] custom_settings.py actualitzat: ENABLE_RESTFUL_API=True (REST API activa).\n" >&2
}

# Configuració de captcha (Friendly o Google v2 checkbox)
install_captcha_settings() {
    if [[ " ${COMPONENTS[*]} " != *"FriendlyCaptcha"* ]]; then
        printf "[info] Component FriendlyCaptcha no seleccionat. Ometent configuració de captcha.\n" >&2
        return
    fi

    # Notes internes:
    # - provider=friendly -> valida token 'frc-captcha-response'
    # - provider=google   -> valida token 'g-recaptcha-response' (reCAPTCHA v2 checkbox)
    local friendly_pub friendly_api google_pub google_api

    friendly_pub="${FC_PUBLIC_KEY:-$(get_custom_setting_value "FRIENDLY_CAPTCHA_PUBLIC_KEY")}"
    friendly_api="${FC_API_KEY:-$(get_custom_setting_value "FRIENDLY_CAPTCHA_API_KEY")}"
    google_pub="${RECAPTCHA_PUBLIC_KEY:-${GC_PUBLIC_KEY:-$(get_custom_setting_value "RECAPTCHA_PUBLIC_KEY")}}"
    google_api="${RECAPTCHA_API_KEY:-${GC_API_KEY:-$(get_custom_setting_value "RECAPTCHA_API_KEY")}}"

    if [[ -t 0 ]]; then
        if [[ "$CAPTCHA_PROVIDER" == "friendly" ]]; then
            printf "Friendly Captcha seleccionat. Claus a https://friendlycaptcha.com\n" >&2
            if [[ -z "$friendly_pub" ]]; then
                printf "Introdueix la clau pública Friendly Captcha (enter per saltar): " >&2
                read -r friendly_pub
            fi
            if [[ -z "$friendly_api" ]]; then
                printf "Introdueix la clau API Friendly Captcha (enter per saltar): " >&2
                read -r friendly_api
            fi
        else
            printf "Google reCAPTCHA v2 Checkbox seleccionat. Claus a https://www.google.com/recaptcha/admin\n" >&2
            printf "[info] IMPORTANT: usa claus de tipus v2 Checkbox (site key + secret key).\n" >&2
            if [[ -z "$google_pub" ]]; then
                printf "Introdueix la clau pública reCAPTCHA (enter per saltar): " >&2
                read -r google_pub
            fi
            if [[ -z "$google_api" ]]; then
                printf "Introdueix la clau secreta reCAPTCHA (enter per saltar): " >&2
                read -r google_api
            fi
        fi
    fi

    if [[ "$CAPTCHA_PROVIDER" == "friendly" ]]; then
        if [[ -z "$friendly_pub" || -z "$friendly_api" ]]; then
            printf "AVÍS: FriendlyCaptcha sense claus completes. Caldrà editar custom_settings.py manualment.\n" >&2
        fi
        printf "[info] FriendlyCaptcha: clau pública %s, API key %s.\n" \
            "$([[ -n "$friendly_pub" ]] && echo "detectada" || echo "NO detectada")" \
            "$([[ -n "$friendly_api" ]] && echo "detectada" || echo "NO detectada")" >&2
    else
        if [[ -z "$google_pub" || -z "$google_api" ]]; then
            printf "AVÍS: reCAPTCHA v2 sense claus completes. Caldrà editar custom_settings.py manualment.\n" >&2
        fi
        printf "[info] reCAPTCHA v2: site key %s, secret key %s.\n" \
            "$([[ -n "$google_pub" ]] && echo "detectada" || echo "NO detectada")" \
            "$([[ -n "$google_api" ]] && echo "detectada" || echo "NO detectada")" >&2
    fi

    ensure_custom_file
    if ! grep -q "friendlycaptcha.com" "$CUSTOM_FILE"; then
        echo "# 👉 https://friendlycaptcha.com" >> "$CUSTOM_FILE"
    fi
    if grep -q "google.com/recaptcha" "$CUSTOM_FILE"; then
        sed -i "s|^# 👉 https://www.google.com/recaptcha.*|# 👉 https://www.google.com/recaptcha (v2 checkbox)|" "$CUSTOM_FILE"
    else
        echo "# 👉 https://www.google.com/recaptcha (v2 checkbox)" >> "$CUSTOM_FILE"
    fi

    set_custom_setting_raw "CAPTCHA_PROVIDER" "'${CAPTCHA_PROVIDER}'  # google|friendly: proveidor de captcha del login"
    set_custom_setting "FRIENDLY_CAPTCHA_PUBLIC_KEY" "$friendly_pub"
    set_custom_setting "FRIENDLY_CAPTCHA_API_KEY" "$friendly_api"
    set_custom_setting "RECAPTCHA_PUBLIC_KEY" "$google_pub"
    set_custom_setting "RECAPTCHA_API_KEY" "$google_api"
    remove_custom_setting "RECAPTCHA_ACTION"
    remove_custom_setting "RECAPTCHA_MIN_SCORE"

    printf "[info] custom_settings.py actualitzat: CAPTCHA_PROVIDER='%s'.\n" "$CAPTCHA_PROVIDER" >&2
}

# Dependències Python obligatòries per als mòduls del patch
install_python_runtime_deps() {
    local allow_pip_fallback="${ALLOW_PIP_FALLBACK:-n}"
    local apt_updated=0
    local failed_imports=()
    local pkg import_name pip_name

    declare -A import_names=(
        ["python3-pyotp"]="pyotp"
        ["python3-cryptography"]="cryptography"
        ["python3-yaml"]="yaml"
        ["python3-qrcode"]="qrcode"
        ["python3-pycurl"]="pycurl"
        ["python3-geoip2"]="geoip2.database"
    )
    declare -A pip_names=(
        ["python3-pyotp"]="pyotp"
        ["python3-cryptography"]="cryptography"
        ["python3-yaml"]="PyYAML"
        ["python3-qrcode"]="qrcode"
        ["python3-pycurl"]="pycurl"
        ["python3-geoip2"]="geoip2"
    )
    local required_pkgs=(
        "python3-pyotp"
        "python3-cryptography"
        "python3-yaml"
        "python3-qrcode"
        "python3-pycurl"
        "python3-geoip2"
    )

    for pkg in "${required_pkgs[@]}"; do
        import_name="${import_names[$pkg]}"
        pip_name="${pip_names[$pkg]}"
        if python3 -c "import ${import_name}" &>/dev/null; then
            printf "La llibreria %s ja està instal·lada. Ometent.\n" "${import_name}" >&2
            continue
        fi

        printf "Instal·lant dependència Python obligatòria: %s (%s)...\n" "${pkg}" "${import_name}" >&2

        if [[ "${PKG_MANAGER:-}" == "apt" && $apt_updated -eq 0 ]]; then
            apt-get update &>/dev/null || true
            apt_updated=1
        fi

        if [[ ${#PKG_INSTALL[@]} -gt 0 ]]; then
            "${PKG_INSTALL[@]}" "$pkg" &>/dev/null || true
        fi

        if ! python3 -c "import ${import_name}" &>/dev/null; then
            if [[ "$allow_pip_fallback" =~ ^([yY]|yes|YES)$ ]]; then
                python3 -m pip install "${pip_name}" --break-system-packages 2>/dev/null || \
                python3 -m pip install "${pip_name}" --break-system-packages || true
            fi
        fi

        if ! python3 -c "import ${import_name}" &>/dev/null; then
            failed_imports+=("${import_name}")
        fi
    done

    if [[ ${#failed_imports[@]} -gt 0 ]]; then
        show_exit_message "Error: Dependències Python obligatòries no disponibles (${failed_imports[*]})."
        show_exit_message "Solució: comprova DNS/xarxa del contenidor i relança modules-setup.sh."
        return 1
    fi
}

# Configuració 2FA opcional
install_2fa() {
    if [[ " ${COMPONENTS[*]} " != *"2FA"* ]]; then
        return
    fi

    ensure_custom_file

    local existing_key=""
    local source=""

    # 1) custom_settings.py (prioritari)
    existing_key="$(get_custom_setting_value "AES_SECRET_KEY" 2>/dev/null || true)"

    # 2) Fallback: settings.py, reutilitzant el mateix parser
    if [[ -z "$existing_key" && -f "$ROOT_PATH/settings.py" ]]; then
        existing_key="$(printf '%s' "$GET_CUSTOM_SETTING_PY" | python3 - "$ROOT_PATH/settings.py" "AES_SECRET_KEY" 2>/dev/null || true)"
        [[ -n "$existing_key" ]] && source="settings.py"
    else
        [[ -n "$existing_key" ]] && source="custom_settings.py"
    fi

    # Validació mínima
    if [[ -n "$existing_key" && ${#existing_key} -ge 32 ]]; then
        printf "[info] 2FA: AES_SECRET_KEY ja present a %s (%d chars). Es conserva.\n" \
            "$source" "${#existing_key}" >&2

        if [[ "$source" == "settings.py" ]]; then
            printf "[info] 2FA: copiant AES_SECRET_KEY de settings.py a custom_settings.py.\n" >&2
            set_custom_setting "AES_SECRET_KEY" "$existing_key"
        fi
        return
    fi

    if [[ -n "$existing_key" ]]; then
        printf "AVÍS: 2FA: AES_SECRET_KEY present a %s però massa curta (%d chars). Es regenerarà.\n" \
            "${source:-?}" "${#existing_key}" >&2
    else
        printf "[info] 2FA: no s'ha trobat AES_SECRET_KEY. Generant-ne una de nova.\n" >&2
    fi

    local aes_key
    aes_key="$(openssl rand -base64 32)"
    set_custom_setting "AES_SECRET_KEY" "$aes_key"
    printf "[info] 2FA: AES_SECRET_KEY generada i desada a custom_settings.py.\n" >&2
}

# Afegir import de custom_settings.py a settings.py
ensure_settings_import() {
    SETTINGS_FILE="$ROOT_PATH/settings.py"
    TOKEN="from custom_settings import *"
    if ! grep -q "$TOKEN" "$SETTINGS_FILE"; then
        cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
        MODIFIED_FILES+=("${SETTINGS_FILE}.bak")
        printf "\n%s\n" "$TOKEN" >> "$SETTINGS_FILE"
    fi
    set_custom_file_owner "$SETTINGS_FILE"
}

ensure_patch_available() {
    # Prioritzar la descàrrega si hi ha URL definida
    if [[ -n "$PATCH_URL" ]]; then
        if ! download_and_prepare_patch; then
            show_exit_message "No s'ha pogut preparar el patch descarregat."
            rollback_all
            exit 1
        fi
        return
    fi
    # Si no hi ha URL o falla la descàrrega, usar patch local si existeix
    if [[ -d "$PATCH_TMP" ]] && find "$PATCH_TMP" -type f | grep -q .; then
        return
    fi
    show_exit_message "No s'han trobat fitxers de patch a $PATCH_TMP i no s'ha pogut descarregar cap patch."
    rollback_all
    exit 1
}

normalize_patch_permissions() {
    local dest_root="$1"

    case "$(printf '%s' "${NORMALIZE_OVERLAY_PERMS:-y}" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off)
            printf "[info] Normalització de permisos desactivada (NORMALIZE_OVERLAY_PERMS=%s).\n" "${NORMALIZE_OVERLAY_PERMS}" >&2
            return 0
            ;;
    esac

    if [[ ! -f "$PATCH_FILE_LIST" ]]; then
        return 0
    fi

    local touched_dirs
    touched_dirs="$(mktemp)"

    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue

        local dest="$dest_root/$rel"
        if [[ -f "$dest" ]]; then
            case "$dest" in
                *.sh)
                    chmod 755 "$dest" 2>/dev/null || true
                    ;;
                *)
                    chmod 644 "$dest" 2>/dev/null || true
                    ;;
            esac
        fi

        local dir_rel
        dir_rel="$(dirname "$rel")"
        while [[ "$dir_rel" != "." && -n "$dir_rel" ]]; do
            printf '%s\n' "$dir_rel" >> "$touched_dirs"
            dir_rel="$(dirname "$dir_rel")"
        done
    done < "$PATCH_FILE_LIST"

    if [[ -s "$touched_dirs" ]]; then
        sort -u "$touched_dirs" | while IFS= read -r dir_rel; do
            [[ -n "$dir_rel" ]] || continue
            local dir_path="$dest_root/$dir_rel"
            if [[ -d "$dir_path" ]]; then
                chmod 755 "$dir_path" 2>/dev/null || true
            fi
        done
    fi

    rm -f "$touched_dirs"
    printf "[info] Permisos de lectura/traversal normalitzats per als fitxers del patch.\n" >&2
}

# Copiar fitxers del patch de /tmp al path de iRedAdmin
# comprova si el fitxer ja existeix al destí. Si existeix, 
# en fa una còpia .bak abans de trepitjar-lo.
copy_patch_files() {
    if [[ ! -d "$PATCH_TMP" ]]; then
        show_exit_message "No s'han trobat fitxers de patch a $PATCH_TMP"
        return
    fi

    # Mode prova: copiar a un directori temporal en lloc del ROOT_PATH real
    local dest_root="$ROOT_PATH"
    if [[ -n "${TEST_COPY_DIR:-}" ]]; then
        dest_root="${TEST_COPY_DIR}"
        mkdir -p "$dest_root"
    fi

    : > "$PATCH_FILE_LIST"
    : > "$BACKUP_FILES_LIST"
    # Preparar llista de fitxers del patch (rutes relatives)
    find "$PATCH_TMP" -type f -printf '%P\n' > "$PATCH_FILE_LIST"
    local total
    total=$(wc -l < "$PATCH_FILE_LIST" | tr -d ' ')
    if [[ $total -eq 0 ]]; then
        show_exit_message "No s'han trobat fitxers per copiar dins $PATCH_TMP"
        return 1
    fi

    # Backup dels fitxers existents abans d'aplicar el patch (evita avisos de fitxers inexistents)
    local backup_list
    backup_list=$(mktemp)
    while IFS= read -r rel; do
        if [[ -e "$dest_root/$rel" ]]; then
            printf "%s\n" "$rel" >> "$backup_list"
        fi
    done < "$PATCH_FILE_LIST"

    rm -f "$BACKUP_TAR"
    if [[ -s "$backup_list" ]]; then
        if ! tar -C "$dest_root" -cf "$BACKUP_TAR" -T "$backup_list"; then
            show_exit_message "Error creant backup abans d'aplicar el patch."
            rollback_all
            exit 1
        fi
        tar -tf "$BACKUP_TAR" > "$BACKUP_FILES_LIST" 2>/dev/null || true
    else
        : > "$BACKUP_TAR"
        : > "$BACKUP_FILES_LIST"
    fi
    rm -f "$backup_list"

    # Copiar patch amb barra de progrés text
    local progress_target="/dev/stderr"
    if [[ -w /dev/tty ]]; then
        progress_target="/dev/tty"
    fi
    local bar_width=30
    local use_color=0
    local bar_filled=""
    local bar_empty=""
    local reset=""
    local green_bg=""
    local gray_bg=""
    if [[ "$progress_target" == "/dev/tty" ]]; then
        use_color=1
        reset=$'\033[0m'
        green_bg=$'\033[42m'
        gray_bg=$'\033[100m'
    fi
    bar_empty=$(printf "%*s" "$bar_width" "" | tr ' ' '-')
    if (( use_color == 1 )); then
        bar_empty=$(printf "%*s" "$bar_width" "" | tr ' ' ' ')
        bar_empty="${gray_bg}${bar_empty}${reset}"
    fi
    printf "Copiant patch: [%s]   0%% (0/%s)" "$bar_empty" "$total" >"$progress_target"
    local count=0
    local last_pct=-1
    while IFS= read -r rel; do
        count=$((count + 1))
        local src="$PATCH_TMP/$rel"
        local dest="$dest_root/$rel"
        mkdir -p "$(dirname "$dest")"
        if ! cp -a "$src" "$dest"; then
            printf "\n" >&2
            show_exit_message "Error copiant patch (fitxer: $rel)."
            rollback_all
            exit 1
        fi
        local pct=$((count * 100 / total))
        if (( pct != last_pct )); then
            local filled=$((pct * bar_width / 100))
            local empty=$((bar_width - filled))
            if (( use_color == 1 )); then
                local seg_filled=""
                local seg_empty=""
                if (( filled > 0 )); then
                    seg_filled=$(printf "%*s" "$filled" "" | tr ' ' ' ')
                    seg_filled="${green_bg}${seg_filled}${reset}"
                fi
                if (( empty > 0 )); then
                    seg_empty=$(printf "%*s" "$empty" "" | tr ' ' ' ')
                    seg_empty="${gray_bg}${seg_empty}${reset}"
                fi
                printf "\rCopiant patch: [%s%s] %3d%% (%s/%s)" "$seg_filled" "$seg_empty" "$pct" "$count" "$total" >"$progress_target"
            else
                bar_filled=$(printf "%*s" "$filled" "" | tr ' ' '#')
                bar_empty=$(printf "%*s" "$empty" "" | tr ' ' '-')
                printf "\rCopiant patch: [%s%s] %3d%% (%s/%s)" "$bar_filled" "$bar_empty" "$pct" "$count" "$total" >"$progress_target"
            fi
            last_pct=$pct
        fi
    done < "$PATCH_FILE_LIST"
    printf "\n" >"$progress_target"
    normalize_patch_permissions "$dest_root"
    printf "Patch aplicat correctament.\n" >&2
}

# Crear Cron Cleanup automàtic si s'ha seleccionat
install_cleanup_cron() {
    if [[ " ${COMPONENTS[*]} " == *"Cleanup"* ]]; then
        if ! command -v crontab &>/dev/null; then
            printf "No s'ha trobat crontab al sistema. S'omet la configuració del cron.\n" >&2
            return
        fi
        local tools_dir="$ROOT_PATH/tools"
        local script_path="$tools_dir/purge_expired_confirms.py"
        local cron_tag="# iRedAdmin-Patch-Cleanup"
        local cron_cmd="0 */24 * * * /usr/bin/python3 $script_path >/dev/null 2>&1"
        local full_line="$cron_cmd $cron_tag"

        mkdir -p "$tools_dir"
        if [[ ! -f "$script_path" ]]; then
            printf '%s' "$IREDADMIN_CLEANUP_SCRIPT" > "$script_path"
            chmod 755 "$script_path"
            COPIED_FILES+=("$script_path")
        fi

        # Preferim crontab de l'usuari iredadmin si existeix
        if id -u iredadmin &>/dev/null; then
            if ! crontab -u iredadmin -l 2>/dev/null | grep -Fq "$cron_tag"; then
                ({ crontab -u iredadmin -l 2>/dev/null || true; echo "$full_line"; }) | crontab -u iredadmin -
                printf "Cron job afegit a l'usuari iredadmin.\n" >&2
            else
                printf "El cron job ja existeix per iredadmin. Ometent.\n" >&2
            fi
        else
            if ! crontab -l 2>/dev/null | grep -Fq "$cron_tag"; then
                ({ crontab -l 2>/dev/null || true; echo "$full_line"; }) | crontab -
                printf "Cron job afegit a root.\n" >&2
            else
                printf "El cron job ja existeix per root. Ometent.\n" >&2
            fi
        fi
    fi
}

install_fail2ban_perms() {
    # Comprovar que fail2ban-client existeix
    if ! command -v fail2ban-client &>/dev/null; then
        printf "No s'ha trobat fail2ban-client. Instal·la fail2ban abans.\n" >&2
        return
    fi
    # Comprovar que l'usuari iredadmin existeix
    if ! id -u iredadmin &>/dev/null; then
        printf "No s'ha trobat l'usuari iredadmin. Crea'l abans d'aplicar permisos.\n" >&2
        return
    fi
    # Definir el fitxer de sudoers i el binari de fail2ban
    local sudoers_file="/etc/sudoers.d/iredadmin_fail2ban"
    local f2b_bin="/usr/bin/fail2ban-client"
    local tmp_sudoers

    # Escriure en un temporal dins de /etc/sudoers.d/ (sudo ignora fitxers
    # amb un punt al nom), validar, i moure atòmicament.
    tmp_sudoers="$(mktemp /etc/sudoers.d/.iredadmin_fail2ban.XXXXXX)"

    if ! printf '%s' "$F2B_SUDOERS_TEMPLATE" | sed "s|@F2B@|$f2b_bin|g" > "$tmp_sudoers"; then
        rm -f "$tmp_sudoers"
        show_exit_message "Error escrivint el sudoers temporal."
        return 1
    fi

    if ! visudo -c -f "$tmp_sudoers" >/dev/null 2>&1; then
        show_exit_message "Error: el fitxer sudoers generat té errors de sintaxi. S'ha descartat."
        rm -f "$tmp_sudoers"
        return 1
    fi

    chmod 440 "$tmp_sudoers"

    if ! mv "$tmp_sudoers" "$sudoers_file"; then
        rm -f "$tmp_sudoers"
        show_exit_message "Error movent el sudoers a $sudoers_file."
        return 1
    fi

    sudo -u iredadmin sudo "$f2b_bin" status >/dev/null 2>&1 || true
    # Afegir al rollback si s'ha creat
    if [[ -f "$sudoers_file" ]]; then
        COPIED_FILES+=("$sudoers_file")
    fi
}

# Instal·la el cron de sincronització Fail2Ban → BD
install_fail2ban_sync_cron() {
    if ! command -v crontab &>/dev/null; then
        printf "No s'ha trobat crontab al sistema. S'omet la configuració del cron de fail2ban.\n" >&2
        return
    fi

    local py_module_dir="$ROOT_PATH"
    local py_code="import sys; sys.path.insert(0, '${py_module_dir}'); from libs.m_fail2ban.fail2ban import F2BManager; F2BManager().sync_banned_to_db_with_lock()"

    local cron_user="root"
    if id -u iredadmin &>/dev/null; then
        cron_user="iredadmin"
    fi

    if [[ ! -w "$(dirname "$F2B_SYNC_LOG")" ]]; then
        printf "AVÍS: %s no és escrivible. El cron de fail2ban no podrà escriure el log.\n" "$(dirname "$F2B_SYNC_LOG")" >&2
    fi

    if [[ ! -f "$F2B_SYNC_LOG" ]]; then
        touch "$F2B_SYNC_LOG" 2>/dev/null || true
    fi
    if [[ -f "$F2B_SYNC_LOG" ]]; then
        if [[ "$cron_user" == "iredadmin" ]]; then
            chown iredadmin:iredadmin "$F2B_SYNC_LOG" 2>/dev/null || true
        fi
        chmod 640 "$F2B_SYNC_LOG" 2>/dev/null || true
    fi

    local cron_cmd="*/2 * * * * /usr/bin/python3 -c \"${py_code}\" >> ${F2B_SYNC_LOG} 2>&1"
    local full_line="${cron_cmd} ${F2B_SYNC_TAG}"

    if [[ "$cron_user" == "iredadmin" ]]; then
        if ! crontab -u iredadmin -l 2>/dev/null | grep -Fq "$F2B_SYNC_TAG"; then
            ({ crontab -u iredadmin -l 2>/dev/null || true; echo "$full_line"; }) | crontab -u iredadmin -
            printf "Cron de sincronització Fail2Ban afegit a l'usuari iredadmin.\n" >&2
        else
            printf "El cron de sincronització Fail2Ban ja existeix per iredadmin. Ometent.\n" >&2
        fi
    else
        if ! crontab -l 2>/dev/null | grep -Fq "$F2B_SYNC_TAG"; then
            ({ crontab -l 2>/dev/null || true; echo "$full_line"; }) | crontab -
            printf "Cron de sincronització Fail2Ban afegit a root.\n" >&2
        else
            printf "El cron de sincronització Fail2Ban ja existeix per root. Ometent.\n" >&2
        fi
    fi
}

# Comenta el cron `unban_db` de root. El nostre F2BManager.sync_banned_to_db_with_lock()
# ja gestiona l'unban directament, així que el cron original d'iRedMail és redundant
# i envia correu cada minut.
disable_root_unban_db_cron() {
    if ! command -v crontab &>/dev/null; then
        printf "No s'ha trobat crontab al sistema. S'omet la desactivació del cron unban_db.\n" >&2
        return
    fi

    local marker="fail2ban_banned_db unban_db"
    local current

    current="$(crontab -l 2>/dev/null || true)"

    if ! printf '%s\n' "$current" | grep -Fq "$marker"; then
        printf "El cron 'unban_db' no existeix al crontab de root. Ometent.\n" >&2
        return
    fi

    if printf '%s\n' "$current" | grep -Eq "^[[:space:]]*#.*${marker}"; then
        printf "El cron 'unban_db' ja està comentat al crontab de root. Ometent.\n" >&2
        return
    fi

    printf '%s\n' "$current" > "$ROOT_CRONTAB_BACKUP"

    printf '%s\n' "$current" \
        | sed "/${marker}/s/^/# /" \
        | crontab -

    printf "Cron 'unban_db' comentat al crontab de root (evita correu cada minut).\n" >&2
    printf "Backup del crontab guardat a: %s\n" "$ROOT_CRONTAB_BACKUP" >&2
}

install_disclaimer_sync() {
    local dump_script="$ROOT_PATH/tools/dump_disclaimer.py"
    local disclaimer_dir="/etc/postfix/disclaimer"
    local cron_tag="# iRedAdmin-Patch-Disclaimer-Sync"
    local log_file="/var/log/iredadmin-disclaimer-sync.log"

    # 1. Comprovar que l'script existeix
    if [[ ! -f "$dump_script" ]]; then
        printf "AVÍS: No s'ha trobat %s. S'omet la sincronització de disclaimer.\n" "$dump_script" >&2
        return
    fi

    # 2. Assegurar que el directori destí existeix
    mkdir -p "$disclaimer_dir"

    # 3. Assegurar que el fitxer de log és escrivible
    touch "$log_file" 2>/dev/null || true
    if id -u iredadmin >/dev/null 2>&1; then
        chown iredadmin:iredadmin "$log_file" 2>/dev/null || true
    fi
    chmod 640 "$log_file" 2>/dev/null || true

    # 4. Determinar l'usuari del cron (preferim iredadmin)
    local cron_user="root"
    if id -u iredadmin >/dev/null 2>&1; then
        cron_user="iredadmin"
    fi

    # 5. Construir la comanda del cron
    local cron_cmd="1 2 * * * * /usr/bin/python3 $dump_script $disclaimer_dir >> $log_file 2>&1"
    local full_line="${cron_cmd} ${cron_tag}"

    # 6. Afegir al crontab
    if [[ "$cron_user" == "iredadmin" ]]; then
        if ! crontab -u iredadmin -l 2>/dev/null | grep -Fq "$cron_tag"; then
            ({ crontab -u iredadmin -l 2>/dev/null || true; echo "$full_line"; }) | crontab -u iredadmin -
            printf "Cron de sincronització Disclaimer afegit a l'usuari iredadmin.\n" >&2
        else
            printf "El cron de sincronització Disclaimer ja existeix. Ometent.\n" >&2
        fi
    else
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_tag"; then
            ({ crontab -l 2>/dev/null || true; echo "$full_line"; }) | crontab -
            printf "Cron de sincronització Disclaimer afegit a root.\n" >&2
        else
            printf "El cron de sincronització Disclaimer ja existeix. Ometent.\n" >&2
        fi
    fi

    # 7. Executar una vegada immediatament perquè els avisos existents facin efecte
    printf "Executant sincronització inicial de disclaimer...\n" >&2
    if [[ "$cron_user" == "iredadmin" ]]; then
        su -s /bin/bash iredadmin -c "/usr/bin/python3 $dump_script $disclaimer_dir >> $log_file 2>&1" || true
    else
        /usr/bin/python3 "$dump_script" "$disclaimer_dir" >> "$log_file" 2>&1 || true
    fi
}

install_disclaimer_amavis_config() {
    local amavis_conf="/etc/amavis/conf.d/50-user"
    
    # Comprovar que el fitxer existeix
    if [[ ! -f "$amavis_conf" ]]; then
        printf "AVÍS: No s'ha trobat %s. S'omet la configuració d'Amavis.\n" "$amavis_conf" >&2
        return
    fi

    # Backup abans de modificar (per al rollback)
    if [[ ! -f "${amavis_conf}.bak" ]]; then
        cp "$amavis_conf" "${amavis_conf}.bak"
        MODIFIED_FILES+=("${amavis_conf}.bak")
        printf "Backup creat: %s.bak\n" "$amavis_conf" >&2
    fi

    # 1. Activar disclaimer: treure el comentari de $defang_maps_by_ccat
    if grep -q '^#\$defang_maps_by_ccat{+CC_CATCHALL} = \[ .disclaimer. \];' "$amavis_conf"; then
        sed -i 's/^#\(\$defang_maps_by_ccat{+CC_CATCHALL} = \[ .disclaimer. \];\)/\1/' "$amavis_conf"
        printf "  -> Activada la signatura de disclaimer.\n" >&2
    elif grep -q '^\$defang_maps_by_ccat{+CC_CATCHALL} = \[ .disclaimer. \];' "$amavis_conf"; then
        printf "  -> La signatura de disclaimer ja estava activada.\n" >&2
    else
        printf "AVÍS: No s'ha trobat la línia \$defang_maps_by_ccat per activar.\n" >&2
    fi

    # 2. Assegurar que @disclaimer_options_bysender_maps té l'entrada '.' => 'default'
    if ! grep -q "'\.' => 'default'" "$amavis_conf"; then
        # Afegir configuració per domini si no existeix el bloc
        # Nota: això assumeix que el bloc @disclaimer_options_bysender_maps ja existeix
        # (iRedMail el proporciona per defecte, només comentat o amb exemples)
        printf "AVÍS: No s'ha trobat l'entrada '.' => 'default' a @disclaimer_options_bysender_maps.\n" >&2
        printf "      Cal afegir-la manualment o verificar el fitxer.\n" >&2
    else
        printf "  -> Entrada catch-all '.' => 'default' ja present.\n" >&2
    fi

    # 3. Verificar @altermime_args_disclaimer
    if ! grep -q "@altermime_args_disclaimer" "$amavis_conf"; then
        printf "AVÍS: No s'ha trobat @altermime_args_disclaimer. Cal verificar manualment.\n" >&2
    else
        printf "  -> @altermime_args_disclaimer ja configurat.\n" >&2
    fi

    printf "[info] Configuració d'Amavis per disclaimer revisada/actualitzada.\n" >&2
}

# Rollback complet en cas d'error o cancel·lació
# Aquesta funció ara restaura els originals i 
# després esborra els fitxers/directoris que hem creat des de zero.
rollback_all() {
    trap - INT TERM ERR # Desactiva traps per evitar recursivitat
    echo "Iniciant rollback de seguretat..."

    # 1. Restaurar fitxers modificats des dels seus .bak
    for bak in "${MODIFIED_FILES[@]}"; do
        if [[ -f "$bak" ]]; then
            local original="${bak%.bak}"
            mv "$bak" "$original"
            echo "Restaurat: $original"
        fi
    done

    # 2. Esborrar fitxers que eren completament nous
    for f in "${COPIED_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            echo "Esborrat fitxer nou: $f"
        fi
    done

    # 3. Restaurar backup tar si existeix
    if [[ -f "$BACKUP_TAR" ]]; then
        tar -C "$ROOT_PATH" -xf "$BACKUP_TAR" || true
    fi

    # 4. Esborrar fitxers nous creats pel patch (els que no són al backup)
    if [[ -f "$PATCH_FILE_LIST" ]]; then
        while IFS= read -r rf; do
            if [[ -f "$ROOT_PATH/$rf" ]]; then
                if ! grep -Fxq "$rf" "$BACKUP_FILES_LIST" 2>/dev/null; then
                    rm -f "$ROOT_PATH/$rf"
                fi
            fi
        done < "$PATCH_FILE_LIST"
    fi

    # 5. Eliminar el cron de sincronització Fail2Ban si l'hem afegit
    local cron_user="root"
    if id -u iredadmin &>/dev/null; then
        cron_user="iredadmin"
    fi
    if [[ "$cron_user" == "iredadmin" ]]; then
        crontab -u iredadmin -l 2>/dev/null | grep -Fv "$F2B_SYNC_TAG" | crontab -u iredadmin - 2>/dev/null || true
    else
        crontab -l 2>/dev/null | grep -Fv "$F2B_SYNC_TAG" | crontab - 2>/dev/null || true
    fi

    # 6. Eliminar el cron de sincronització Disclaimer si l'hem afegit
    if [[ "$cron_user" == "iredadmin" ]]; then
        crontab -u iredadmin -l 2>/dev/null | grep -Fv "# iRedAdmin-Patch-Disclaimer-Sync" | crontab -u iredadmin - 2>/dev/null || true
    else
        crontab -l 2>/dev/null | grep -Fv "# iRedAdmin-Patch-Disclaimer-Sync" | crontab - 2>/dev/null || true
    fi
    rm -f /var/log/iredadmin-disclaimer-sync.log


    # 7. Restaurar el crontab de root si l'hem modificat (unban_db)
    if [[ -f "$ROOT_CRONTAB_BACKUP" ]]; then
        if crontab "$ROOT_CRONTAB_BACKUP" 2>/dev/null; then
            echo "Restaurat crontab de root des de $ROOT_CRONTAB_BACKUP"
        fi
        rm -f "$ROOT_CRONTAB_BACKUP"   # neteja: evita restaurar un backup obsolet en futures execucions
    fi
}

# Missatge final d'instal·lació correcta
finish_install() {
    printf "Instal·lació completada amb èxit! 🚀 \n" >&2
}

restart_iredadmin_service() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart iredadmin >/dev/null 2>&1; then
            printf "Servei iredadmin reiniciat correctament.\n" >&2
        else
            printf "AVÍS: No s'ha pogut reiniciar iredadmin amb systemctl.\n" >&2
        fi
        return
    fi

    if command -v service >/dev/null 2>&1; then
        if service iredadmin restart >/dev/null 2>&1; then
            printf "Servei iredadmin reiniciat correctament.\n" >&2
        else
            printf "AVÍS: No s'ha pogut reiniciar iredadmin amb service.\n" >&2
        fi
        return
    fi

    printf "AVÍS: No s'ha trobat systemctl/service per reiniciar iredadmin.\n" >&2
}

ensure_uwsgi_single_interpreter() {
    local uwsgi_ini="$ROOT_PATH/rc_scripts/uwsgi/debian.ini"
    local line="single-interpreter = true"

    if [[ ! -f "$uwsgi_ini" ]]; then
        printf "AVÍS: No s'ha trobat %s. Ometent ajust d'uWSGI.\n" "$uwsgi_ini" >&2
        return
    fi

    if [[ ! -f "${uwsgi_ini}.bak" ]]; then
        cp "$uwsgi_ini" "${uwsgi_ini}.bak"
        MODIFIED_FILES+=("${uwsgi_ini}.bak")
    fi

    if grep -Eq '^[[:space:]]*single-interpreter[[:space:]]*=' "$uwsgi_ini"; then
        sed -i -E 's/^[[:space:]]*single-interpreter[[:space:]]*=.*/single-interpreter = true/' "$uwsgi_ini"
    else
        if grep -Eq '^[[:space:]]*enable-threads[[:space:]]*=' "$uwsgi_ini"; then
            sed -i '/^[[:space:]]*enable-threads[[:space:]]*=/a single-interpreter = true' "$uwsgi_ini"
        else
            printf "\n%s\n" "$line" >> "$uwsgi_ini"
        fi
    fi

    printf "uWSGI ajustat: single-interpreter=true (compatible amb cryptography/PyO3).\n" >&2
}

finalize_settings_permissions() {
    local settings_file="$ROOT_PATH/settings.py"
    local custom_file="$ROOT_PATH/custom_settings.py"

    if [[ ! -f "$settings_file" ]]; then
        return 0
    fi

    # Ensure iredadmin owns both files
    set_custom_file_owner "$settings_file"
    set_custom_file_owner "$custom_file"

    # Make them read-only (400: només lectura per al propietari, res per a grup/altres)
    if id -u iredadmin >/dev/null 2>&1; then
        chmod 400 "$settings_file" 2>/dev/null || true
        if [[ -f "$custom_file" ]]; then
            chmod 400 "$custom_file" 2>/dev/null || true
        fi
        printf "[info] Permisos finalitzats: settings.py i custom_settings.py són només lectura per a iredadmin (400).\n" >&2
    fi
}

cleanup() {
    printf "Netejant fitxers temporals...\n" >&2
    rm -rf "$PATCH_TMP" "$BACKUP_TAR" "$PATCH_FILE_LIST" "$BACKUP_FILES_LIST"
}

# -------------------- Programa principal --------------------
main() {
    trap 'rollback_all; show_exit_message "Instal·lació cancel·lada o error. Tot restaurat."; exit 1' INT TERM ERR

    detect_pkg_mgr
    initial_info
    select_root_path
    select_components
    normalize_captcha_provider

    # Comprovació d'espai abans de començar (ex: 100MB lliures)
    local free_space
    free_space=$(df -m /tmp | awk 'NR==2 {print $4}')
    if [[ $free_space -lt 100 ]]; then
        show_exit_message "Error: Menys de 100MB lliures a /tmp. Allibera espai."
        exit 1
    fi

    install_domain_ownership_settings
    ensure_settings_import
    install_rest_api_settings
    install_captcha_settings
    install_python_runtime_deps
    install_2fa
    ensure_patch_available
    copy_patch_files
    # Domain ownership seed requires the patched module tree (libs.m_system).
    seed_existing_domains_domain_ownership
    install_disclaimer_sync
    install_disclaimer_amavis_config
    install_cleanup_cron
    install_fail2ban_perms
    install_fail2ban_sync_cron
    disable_root_unban_db_cron
    ensure_uwsgi_single_interpreter
    restart_iredadmin_service

    finalize_settings_permissions
    cleanup
    finish_install
    trap - EXIT INT TERM ERR
}

main