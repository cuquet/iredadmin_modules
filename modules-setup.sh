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

# -------------------- Funcions --------------------

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
    cat >&2 <<'EOF'
Aquest instal·lador farà les següents accions:
  - Copiar fitxers del patch (PATCH_URL si està definit, o /tmp/iredadmin_patch)
  - Configurar captcha (Friendly o Google reCAPTCHA v2 Checkbox)
  - Instal·lar 2FA (llibreries Python)
  - Activar Cron Cleanup
  - Configurar Domain Ownership
  - Permisos fail2ban per iredadmin
  - Templates adaptades ('classic' i 'codyframe') que milloren l'interacció (amavisd, iredapd, fali2ban, 2FA, ...)
EOF
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
        cat <<'EOF' > "$CUSTOM_FILE"
SKIN = "codyframe"
#SKIN = "classic"
BRAND_LOGO = 'logo.png'             # load file 'static/logo.png'
BRAND_FAVICON = 'favicon.ico'       # load file 'static/favicon.ico'

EOF
        chmod 600 "$CUSTOM_FILE"
        COPIED_FILES+=("$CUSTOM_FILE")
        return
    fi

    # Pot arribar read-only des del patch; assegurem escriptura abans de modificar.
    chmod u+rw "$CUSTOM_FILE" 2>/dev/null || true

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
        if [[ -n "$orig_uid" && -n "$orig_gid" ]]; then
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

    python3 - "$CUSTOM_FILE" "$key" "$value" <<'PY'
import re
import sys

path, key, value = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

pattern = re.compile(r"^" + re.escape(key) + r"=")
new_line = f"{key}='{value}'"

for idx, line in enumerate(lines):
    if pattern.match(line):
        lines[idx] = new_line
        break
else:
    lines.append(new_line)

import os
import tempfile

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

    python3 - "$CUSTOM_FILE" "$key" "$value" <<'PY'
import re
import sys

path, key, value = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

pattern = re.compile(r"^" + re.escape(key) + r"=")
new_line = f"{key}={value}"

for idx, line in enumerate(lines):
    if pattern.match(line):
        lines[idx] = new_line
        break
else:
    lines.append(new_line)

import os
import tempfile

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
}

remove_custom_setting() {
    local key="$1"
    ensure_custom_file

    if [[ ! -f "${CUSTOM_FILE}.bak" ]]; then
        cp "$CUSTOM_FILE" "${CUSTOM_FILE}.bak"
        MODIFIED_FILES+=("${CUSTOM_FILE}.bak")
    fi

    sed -i "/^${key}[[:space:]]*=/d" "$CUSTOM_FILE"
}

get_custom_setting_value() {
    local key="$1"
    ensure_custom_file
    python3 - "$CUSTOM_FILE" "$key" <<'PY'
import ast
import re
import sys

path, key = sys.argv[1:3]
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
value = ""

with open(path, "r", encoding="utf-8") as f:
    for line in f:
        if pattern.match(line):
            raw = line.split("=", 1)[1].strip()
            try:
                parsed = ast.literal_eval(raw)
                value = "" if parsed is None else str(parsed)
            except Exception:
                value = raw.strip().strip("'").strip('"')
            break

print(value)
PY
}

install_domain_ownership_settings() {
    # Configuració de verificació de propietat de dominis
    ensure_custom_file
    if ! grep -q "Domains ownership verification" "$CUSTOM_FILE"; then
        cat <<'EOF' >> "$CUSTOM_FILE"

# 👉 Domains ownership verification
EOF
    fi
    set_custom_setting_raw "REQUIRE_DOMAIN_OWNERSHIP_VERIFICATION" "True"
    if ! grep -q "DOMAIN_OWNERSHIP_EXPIRE_DAYS" "$CUSTOM_FILE"; then
        cat <<'EOF' >> "$CUSTOM_FILE"
# How long should we remove verified or (inactive) unverified domain ownerships.
#
# iRedAdmin-Pro stores verified ownership in SQL database, if (same) admin
# removed the domain and re-adds it, no verification required.
#
# Usually normal domain admin won't frequently remove and re-add same domain
# name, so it's ok to remove saved ownership after X days.
EOF
    fi
    set_custom_setting_raw "DOMAIN_OWNERSHIP_EXPIRE_DAYS" "30"
    if ! grep -q "DOMAIN_OWNERSHIP_VERIFY_CODE_PREFIX" "$CUSTOM_FILE"; then
        cat <<'EOF' >> "$CUSTOM_FILE"
# The string prefixed to verify code. Must be shorter than than 60 characters.
EOF
    fi
    set_custom_setting "DOMAIN_OWNERSHIP_VERIFY_CODE_PREFIX" "iredmail-domain-verification-"
    if ! grep -q "DOMAIN_OWNERSHIP_VERIFY_TIMEOUT" "$CUSTOM_FILE"; then
        cat <<'EOF' >> "$CUSTOM_FILE"
# Timeout (in seconds) while performing each verification.
EOF
    fi
    set_custom_setting_raw "DOMAIN_OWNERSHIP_VERIFY_TIMEOUT" "10"
}

seed_existing_domains_domain_ownership() {
    # NOTE: Seed inicial idempotent:
    # - Quan l'iRedMail base ja té dominis creats (ex: FIRST_MAIL_DOMAIN),
    #   els inserim a domain_ownership si encara no hi són.
    # - Així apareixen a la UI de "Domain ownership verification" des del primer setup.
    local py_out
    if ! py_out="$(python3 - "$ROOT_PATH" <<'PY'
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
)"; then
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
    if [[ " ${COMPONENTS[*]} " == *"2FA"* ]]; then
        # Generar clau AES per a l'encriptació del 2FA
        AES_KEY=$(openssl rand -base64 32)
        set_custom_setting "AES_SECRET_KEY" "$AES_KEY"
    fi
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
            cat <<'EOF' > "$script_path"
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

os.environ['LC_ALL'] = 'C'

rootdir = os.path.abspath(os.path.dirname(__file__)) + '/../'
sys.path.insert(0, rootdir)

import web
from tools import ira_tool_lib

# Setup
web.config.debug = ira_tool_lib.debug
logger = ira_tool_lib.logger
conn = ira_tool_lib.get_db_conn('iredadmin')

# Constants
TABLE = 'newsletter_subunsub_confirms'

def purge_expired():
    now = int(time.time())
    try:
        n = conn.delete(TABLE, where="expired < $now", vars={'now': now})
        logger.info(f"Purged {n} expired confirmation records from {TABLE}.")
    except Exception as e:
        logger.error(f"Error purging expired confirmations: {repr(e)}")

if __name__ == '__main__':
    purge_expired()
EOF
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
    # Escriure permisos mínims per consulta i ban/unban
    cat <<EOF > "$sudoers_file"
# CONSULTA
Cmnd_Alias F2B_STATUS = $f2b_bin status, $f2b_bin status *
Cmnd_Alias F2B_GET    = $f2b_bin get *

# CONTROL
Cmnd_Alias F2B_UNBAN  = $f2b_bin set * unbanip *
Cmnd_Alias F2B_BAN    = $f2b_bin set * banip *
Cmnd_Alias F2B_RELOAD = $f2b_bin reload, $f2b_bin reload *, $f2b_bin reload --if-exists *, $f2b_bin -d
Cmnd_Alias F2B_STOP   = $f2b_bin stop *

# Assignació permisos
iredadmin ALL=(ALL) NOPASSWD: F2B_STATUS, F2B_GET, F2B_UNBAN, F2B_BAN, F2B_RELOAD, F2B_STOP
EOF
    # Assegurar permisos correctes del sudoers
    chmod 440 "$sudoers_file"
    # Verificar accés bàsic (no fallar si no hi ha jails actius)
    sudo -u iredadmin sudo "$f2b_bin" status >/dev/null 2>&1 || true
    # Afegir al rollback si s'ha creat
    if [[ -f "$sudoers_file" ]]; then
        COPIED_FILES+=("$sudoers_file")
    fi
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
    install_cleanup_cron
    install_fail2ban_perms
    ensure_uwsgi_single_interpreter
    restart_iredadmin_service

    cleanup
    finish_install
    trap - EXIT INT TERM ERR
}

main
