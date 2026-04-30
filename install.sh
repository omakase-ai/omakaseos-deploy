#!/usr/bin/env bash
# Omakase Robot Stack — customer installer (single-file)
#
# Paste this script onto the robot and run ./install.sh. It is the ONLY file
# the customer ever touches. It owns:
#
#   - host dependency check (docker, docker compose, python3, systemd)
#   - robot credential prompt + license.json at /etc/omakase/
#   - embedded WiFi-setup Python package extracted to /opt/omakase/wifi-setup/
#   - two systemd system units:
#       omakase-robot.service      (supervises `docker compose`)
#       omakase-wifi-setup.service (fallback AP + WiFi config web UI)
#   - first ECR login against the backend (no AWS creds on the robot)
#   - `docker compose pull && up -d`
#
# Re-running install.sh with --upgrade does not re-prompt for credentials.
# Re-running with --uninstall stops the stack and removes the systemd units
# (kept: /etc/omakase/*, /opt/omakase/*, the docker image, the data volume).
# Re-running with --purge does --uninstall AND wipes the image, the
# `omakase-data` volume, /etc/omakase, /opt/omakase, and the omakase-ota
# symlink. Destructive — the operator must reissue license.json afterwards.
#
# Usage:
#   sudo ./install.sh                   # first-time install, prompts for robot creds
#   sudo ./install.sh --version v1      # pin to conversation engine v1
#   sudo ./install.sh --tag v1.4.2      # pin a specific image tag (first install)
#   sudo ./install.sh --upgrade         # re-render config + restart units (no re-prompt)
#   sudo ./install.sh --uninstall       # stop stack, remove systemd units
#   sudo ./install.sh --purge           # uninstall + wipe image, data volume, config
#   sudo ./install.sh --purge --yes     # purge without the confirmation prompt
#   sudo ./install.sh --no-wifi-setup   # skip the fallback-AP unit (workstation/dev hosts)
#   sudo ./install.sh --no-nav-stack    # skip the nav-autonomy-deploy clone + compose stack
#
# Environment overrides (rare):
#   OMAKASE_API_URL         (default: https://www.omakase.ai)
#   OMAKASE_CONV_VERSION    (v1 | v2, default v2)
#   OMAKASE_CONFIG_DIR      (default: /etc/omakase)
#   OMAKASE_WIFI_SETUP_DIR  (default: /opt/omakase/wifi-setup)
#   OMAKASE_BIN_DIR         (default: /opt/omakase/bin)
#   OMAKASE_RUNTIME_UID     UID whose /run/user/<uid>/pulse socket the
#                           container mounts for audio. Defaults to $SUDO_UID
#                           (the user that ran `sudo ./install.sh`), falling
#                           back to 1000. Override if the robot's audio user
#                           is neither the sudo invoker nor UID 1000.
#   OMAKASE_SKIP_NAV_STACK  Set to 1 to skip cloning + starting
#                           nav-autonomy-deploy (workstation/dev hosts that
#                           don't run the navigation autonomy stack).
#   OMAKASE_NAV_STACK_REPO  Git URL to clone for the nav stack
#                           (default: https://github.com/iServeRobotics/nav-autonomy-deploy.git).
#   OMAKASE_NAV_STACK_REF   Branch / tag / commit to check out (default: main).

set -euo pipefail

# BASH_SOURCE is unset when bash reads the script from stdin (curl | bash),
# which trips set -u. Fall through to $0 — directory only matters for the
# local-override path, which can't fire in pipe mode anyway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
MODE="install"
CONV_VERSION="${OMAKASE_CONV_VERSION:-v2}"
# 1 if --version was passed on this invocation. Lets us decide whether
# to overwrite OMAKASE_CONV_VERSION in an existing runtime.env, or defer
# to the value already there.
EXPLICIT_CONV_VERSION=0
REQUESTED_TAG=""
SKIP_WIFI_SETUP="${OMAKASE_SKIP_WIFI_SETUP:-0}"
SKIP_NAV_STACK="${OMAKASE_SKIP_NAV_STACK:-0}"
NAV_STACK_DIR="/opt/omakase/nav-autonomy-deploy"
NAV_STACK_REPO="${OMAKASE_NAV_STACK_REPO:-https://github.com/iServeRobotics/nav-autonomy-deploy.git}"
NAV_STACK_REF="${OMAKASE_NAV_STACK_REF:-main}"
ASSUME_YES=0

OMAKASE_CONFIG_DIR="${OMAKASE_CONFIG_DIR:-/etc/omakase}"
OMAKASE_WIFI_SETUP_DIR="${OMAKASE_WIFI_SETUP_DIR:-/opt/omakase/wifi-setup}"
OMAKASE_BIN_DIR="${OMAKASE_BIN_DIR:-/opt/omakase/bin}"
SYSTEMD_DIR="/etc/systemd/system"
OMAKASE_API_URL="${OMAKASE_API_URL:-https://www.omakase.ai}"
OMAKASE_RUNTIME_UID="${OMAKASE_RUNTIME_UID:-${SUDO_UID:-1000}}"

LICENSE_FILE="$OMAKASE_CONFIG_DIR/license.json"
ENV_FILE="$OMAKASE_CONFIG_DIR/robot.env"
RUNTIME_ENV_FILE="$OMAKASE_CONFIG_DIR/runtime.env"
COMPOSE_FILE="$OMAKASE_CONFIG_DIR/docker-compose.yml"
WIFI_ENV_FILE="$OMAKASE_CONFIG_DIR/wifi-setup.env"
ROBOT_UNIT="$SYSTEMD_DIR/omakase-robot.service"
WIFI_UNIT="$SYSTEMD_DIR/omakase-wifi-setup.service"

# ---------------------------------------------------------------------------
# Embedded payload: WiFi-setup package + ota.sh + omakase-ecr-login.sh.
# Regenerate with distribution/build-installer.sh before publishing.
# ---------------------------------------------------------------------------
# BEGIN_OMAKASE_PAYLOAD_B64
OMAKASE_PAYLOAD_B64="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"
# END_OMAKASE_PAYLOAD_B64

while [ $# -gt 0 ]; do
    case "$1" in
        --version)     CONV_VERSION="$2"; EXPLICIT_CONV_VERSION=1; shift 2;;
        --version=*)   CONV_VERSION="${1#*=}"; EXPLICIT_CONV_VERSION=1; shift;;
        --tag)         REQUESTED_TAG="$2"; shift 2;;
        --tag=*)       REQUESTED_TAG="${1#*=}"; shift;;
        --upgrade)     MODE="upgrade"; shift;;
        --uninstall)   MODE="uninstall"; shift;;
        --purge)       MODE="purge"; shift;;
        --yes|-y)      ASSUME_YES=1; shift;;
        --no-wifi-setup) SKIP_WIFI_SETUP=1; shift;;
        --no-nav-stack) SKIP_NAV_STACK=1; shift;;
        -h|--help)     sed -n '2,49p' "$0"; exit 0;;
        *)             echo "Unknown argument: $1" >&2; exit 2;;
    esac
done

case "$CONV_VERSION" in
    v1|v2) ;;
    v3)
        echo "ERROR: conversation engine v3 is not implemented yet." >&2
        exit 2;;
    *)
        echo "ERROR: --version expects v1 or v2 (got '$CONV_VERSION')." >&2
        exit 2;;
esac

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: install.sh must run as root (try: sudo $0 $*)" >&2
    exit 1
fi

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }
}
need docker
need python3
need curl
need systemctl
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' plugin is required (Docker Engine 20.10+)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Uninstall / purge.
#   --uninstall: stop units, leave /etc/omakase + /opt/omakase + image +
#     data volume intact so a later reinstall is idempotent. We never wipe
#     license.json without the operator deliberately removing it.
#   --purge:     same as --uninstall, then remove the docker image, the
#     `omakase-data` named volume (robot logs/cache), the helper scripts,
#     the omakase-ota symlink, and the config dirs. Destructive: the
#     operator must reissue license.json before reinstalling.
# ---------------------------------------------------------------------------
if [ "$MODE" = "uninstall" ] || [ "$MODE" = "purge" ]; then
    if [ "$MODE" = "purge" ] && [ "$ASSUME_YES" != "1" ]; then
        echo "About to PURGE the Omakase stack from this host:"
        echo "  - stop and remove systemd units"
        echo "  - remove docker container, image, and the 'omakase-data' volume"
        echo "  - delete $OMAKASE_CONFIG_DIR (license.json, runtime.env, robot.env, compose)"
        echo "  - delete /opt/omakase (helper scripts, wifi-setup package)"
        echo "  - remove /usr/local/bin/omakase-ota symlink"
        echo
        printf "Type 'PURGE' to confirm: "
        read -r confirm
        if [ "$confirm" != "PURGE" ]; then
            echo "Aborted."
            exit 1
        fi
    fi

    systemctl disable --now omakase-robot.service omakase-wifi-setup.service 2>/dev/null || true

    # Capture the image ref before we delete robot.env, so purge can target it.
    IMAGE_REF=""
    if [ -f "$ENV_FILE" ]; then
        IMAGE_REF="$(awk -F= '$1=="OMAKASE_IMAGE_REF"{print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    fi

    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$MODE" = "purge" ]; then
            # `down -v` also removes the named `omakase-data` volume declared
            # in the compose file. Image removal is handled separately below
            # because compose's `--rmi` doesn't reach the pulled ECR tag
            # cleanly when env interpolation is missing.
            docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down -v 2>/dev/null || true
        else
            docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down 2>/dev/null || true
        fi
    fi

    # nav-autonomy-deploy is a separate compose stack we manage out of
    # $NAV_STACK_DIR. Take it down on both --uninstall and --purge so the
    # navigation containers don't outlive the omakase runtime.
    if [ -f "$NAV_STACK_DIR/docker-compose.yml" ]; then
        if [ "$MODE" = "purge" ]; then
            (cd "$NAV_STACK_DIR" && docker compose down -v 2>/dev/null) || true
        else
            (cd "$NAV_STACK_DIR" && docker compose down 2>/dev/null) || true
        fi
    fi

    rm -f "$ROBOT_UNIT" "$WIFI_UNIT"
    systemctl daemon-reload

    if [ "$MODE" = "uninstall" ]; then
        echo "Omakase stack stopped and systemd units removed."
        echo "Config retained at $OMAKASE_CONFIG_DIR and $OMAKASE_WIFI_SETUP_DIR."
        exit 0
    fi

    # --- purge-only: remove image, leftover volume, helpers, config -------
    if [ -n "$IMAGE_REF" ]; then
        docker image rm "$IMAGE_REF" 2>/dev/null || true
    fi
    # Belt-and-suspenders: if the volume survived (e.g. compose file was
    # already gone before --purge), drop it by name.
    docker volume rm omakase-data 2>/dev/null || true

    rm -f /usr/local/bin/omakase-ota
    # /opt/omakase contains both the wifi-setup venv and the nav-autonomy
    # checkout — both are recreated on a fresh install, so it's safe to wipe.
    rm -rf "$OMAKASE_CONFIG_DIR" /opt/omakase

    echo "Omakase stack purged."
    echo "  Image, data volume, config, and helper scripts removed."
    echo "  Reinstall requires a fresh license.json from the operator."
    exit 0
fi

mkdir -p "$OMAKASE_CONFIG_DIR" "$OMAKASE_WIFI_SETUP_DIR" "$OMAKASE_BIN_DIR"

# ---------------------------------------------------------------------------
# Detect a migration from the old single-file layout (everything in
# robot.env) to the new split (robot.env: install metadata only,
# runtime.env: operator config). On first upgrade after the split we lift
# operator-managed keys from the legacy robot.env into the new runtime.env
# so provider keys, webhook URLs, anomaly flags, etc. don't disappear.
# Captured here, applied below where runtime.env is seeded.
# ---------------------------------------------------------------------------
LEGACY_RUNTIME_KEYS=""
if [ -f "$ENV_FILE" ] && [ ! -f "$RUNTIME_ENV_FILE" ]; then
    LEGACY_RUNTIME_KEYS="$(awk '
        /^[ \t]*#/ { next }
        /^[ \t]*$/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { next }
        {
            split($0, kv, "=")
            k = kv[1]
            # install metadata — owned by robot.env going forward
            if (k == "OMAKASE_IMAGE_REF" || k == "OMAKASE_IMAGE_TAG" || k == "OMAKASE_RUNTIME_UID") next
            # already emitted explicitly by the runtime.env seed template
            if (k == "ROBOT_ID" || k == "ROBOT_BOOTSTRAP_TOKEN") next
            if (k == "OMAKASE_API_URL" || k == "OMAKASE_CONV_VERSION") next
            if (k == "LOCALE" || k == "STATUS_SERVER_ENABLED" || k == "BOOTSTRAP_STRICT") next
            if (k == "AWS_IOT_CERT_PATH" || k == "AWS_IOT_KEY_PATH" || k == "AWS_IOT_CA_PATH") next
            print
        }
    ' "$ENV_FILE")"
fi

# ---------------------------------------------------------------------------
# Load existing robot.env + runtime.env on upgrade so we don't re-prompt.
# On first install we'll prompt and populate them at the end.
# ---------------------------------------------------------------------------
if [ -f "$RUNTIME_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$RUNTIME_ENV_FILE"; set +a
fi
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

# If --version wasn't passed on this invocation, defer to whatever the
# existing runtime.env had — otherwise the completion banner can lie
# (claiming v2 while the file still pins v1, or vice versa).
if [ "$EXPLICIT_CONV_VERSION" = "0" ] && [ -n "${OMAKASE_CONV_VERSION:-}" ]; then
    case "$OMAKASE_CONV_VERSION" in
        v1|v2) CONV_VERSION="$OMAKASE_CONV_VERSION" ;;
        *) ;; # malformed runtime.env — fall through with the default
    esac
fi

# Replace KEY=VALUE in $RUNTIME_ENV_FILE in place, or append it if absent.
upsert_runtime_env() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        BEGIN { found=0 }
        $0 ~ "^" k "=" { print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
    ' "$RUNTIME_ENV_FILE" >"$tmp"
    install -m 600 "$tmp" "$RUNTIME_ENV_FILE"
    rm -f "$tmp"
}

# Append a default only when the operator has not already set the key.
append_runtime_env_default_if_missing() {
    local key="$1" value="$2"
    if ! grep -Eq "^[[:space:]]*$key=" "$RUNTIME_ENV_FILE"; then
        printf '%s=%s\n' "$key" "$value" >>"$RUNTIME_ENV_FILE"
    fi
}

# If a license.json sits next to install.sh, lift robot_id + bootstrap_token
# out of it so we don't have to prompt. Accepts the canonical "bootstrap_token"
# key OR the legacy "api_key" key (both carry the same oma_robot_* token).
if [ -z "${ROBOT_ID:-}" ] || [ -z "${ROBOT_BOOTSTRAP_TOKEN:-}" ]; then
    if [ -f "$SCRIPT_DIR/license.json" ]; then
        eval "$(python3 - "$SCRIPT_DIR/license.json" <<'PY'
import json, shlex, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
rid = d.get("robot_id", "")
tok = d.get("bootstrap_token") or d.get("api_key") or ""
if rid:
    print(f"ROBOT_ID={shlex.quote(rid)}")
if tok:
    print(f"ROBOT_BOOTSTRAP_TOKEN={shlex.quote(tok)}")
PY
)"
        export ROBOT_ID ROBOT_BOOTSTRAP_TOKEN
    fi
fi

if [ "$MODE" = "install" ]; then
    # Pick an input source for prompts that works under `curl | sudo bash` —
    # in that pipe stdin carries the script body, so we read from /dev/tty
    # instead. Falls back to stdin when running locally with a tty already.
    prompt_input_fd=""
    if [ -t 0 ]; then
        prompt_input_fd=""
    elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
        prompt_input_fd="/dev/tty"
    fi

    prompt_required_value() {
        local var_name="$1" prompt_text="$2" secret="${3:-0}"
        local value="${!var_name:-}"
        [ -n "$value" ] && return 0
        if [ -z "$prompt_input_fd" ] && [ ! -t 0 ]; then
            echo "ERROR: $var_name is required. Re-run interactively, set it as an env var, or place a license.json next to install.sh." >&2
            exit 1
        fi
        while :; do
            if [ "$secret" = "1" ]; then
                if [ -n "$prompt_input_fd" ]; then
                    read -r -s -p "$prompt_text: " value <"$prompt_input_fd"; echo
                else
                    read -r -s -p "$prompt_text: " value; echo
                fi
            else
                if [ -n "$prompt_input_fd" ]; then
                    read -r -p "$prompt_text: " value <"$prompt_input_fd"
                else
                    read -r -p "$prompt_text: " value
                fi
            fi
            if [ -n "${value//[[:space:]]/}" ]; then
                printf -v "$var_name" '%s' "$value"
                export "$var_name"
                return 0
            fi
            echo "Value cannot be empty."
        done
    }

    prompt_required_value ROBOT_ID "Robot ID"
    prompt_required_value ROBOT_BOOTSTRAP_TOKEN "Robot bootstrap token" 1
fi

if [ -z "${ROBOT_ID:-}" ] || [ -z "${ROBOT_BOOTSTRAP_TOKEN:-}" ]; then
    echo "ERROR: ROBOT_ID and ROBOT_BOOTSTRAP_TOKEN must be set (run without --upgrade for first install)." >&2
    exit 1
fi

cat >"$LICENSE_FILE" <<EOF
{
  "robot_id": "${ROBOT_ID}",
  "bootstrap_token": "${ROBOT_BOOTSTRAP_TOKEN}"
}
EOF
chmod 600 "$LICENSE_FILE"

# ---------------------------------------------------------------------------
# Extract embedded payload (wifi-setup python + helper scripts).
# Skipped when OMAKASE_PAYLOAD_B64 is empty (dev convenience: source tree
# checkouts can run install.sh after running distribution/build-installer.sh,
# or point OMAKASE_WIFI_SETUP_SOURCE at the repo checkout).
# ---------------------------------------------------------------------------
extract_payload() {
    if [ -z "$OMAKASE_PAYLOAD_B64" ]; then
        if [ -n "${OMAKASE_WIFI_SETUP_SOURCE:-}" ] && [ -d "$OMAKASE_WIFI_SETUP_SOURCE" ]; then
            echo "Using OMAKASE_WIFI_SETUP_SOURCE=$OMAKASE_WIFI_SETUP_SOURCE (dev mode)"
            rsync -a --delete "$OMAKASE_WIFI_SETUP_SOURCE/" "$OMAKASE_WIFI_SETUP_DIR/src/"
            install -m 755 "$SCRIPT_DIR/ota.sh" "$OMAKASE_BIN_DIR/ota.sh"
            install -m 755 "$SCRIPT_DIR/omakase-ecr-login.sh" "$OMAKASE_BIN_DIR/omakase-ecr-login.sh"
            return 0
        fi
        echo "ERROR: embedded payload is empty. Regenerate this installer with distribution/build-installer.sh." >&2
        exit 1
    fi

    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    printf '%s' "$OMAKASE_PAYLOAD_B64" | base64 -d | tar -xzf - -C "$tmp"

    rsync -a --delete "$tmp/wifi-setup/" "$OMAKASE_WIFI_SETUP_DIR/src/"
    install -m 755 "$tmp/bin/ota.sh" "$OMAKASE_BIN_DIR/ota.sh"
    install -m 755 "$tmp/bin/omakase-ecr-login.sh" "$OMAKASE_BIN_DIR/omakase-ecr-login.sh"
    if [ -f "$tmp/wifi-setup/requirements.txt" ]; then
        cp "$tmp/wifi-setup/requirements.txt" "$OMAKASE_WIFI_SETUP_DIR/requirements.txt"
    fi
}

extract_payload

# Dev override: if omakase-ecr-login.sh / ota.sh sit next to install.sh, overlay
# them on top of whatever the payload shipped. Lets us iterate on those helpers
# without re-running build-installer.sh between every test.
if [ -f "$SCRIPT_DIR/omakase-ecr-login.sh" ]; then
    install -m 755 "$SCRIPT_DIR/omakase-ecr-login.sh" "$OMAKASE_BIN_DIR/omakase-ecr-login.sh"
    echo "Using local omakase-ecr-login.sh from $SCRIPT_DIR (override)."
fi
if [ -f "$SCRIPT_DIR/ota.sh" ]; then
    install -m 755 "$SCRIPT_DIR/ota.sh" "$OMAKASE_BIN_DIR/ota.sh"
    echo "Using local ota.sh from $SCRIPT_DIR (override)."
fi

# ---------------------------------------------------------------------------
# WiFi-setup venv (host-level, readable Python). Recreate only if missing or
# if requirements.txt changed since the last install.
# ---------------------------------------------------------------------------
WIFI_VENV="$OMAKASE_WIFI_SETUP_DIR/.venv"
WIFI_REQ="$OMAKASE_WIFI_SETUP_DIR/requirements.txt"
WIFI_REQ_STAMP="$OMAKASE_WIFI_SETUP_DIR/.requirements.sha256"
WIFI_DEFERRED_FLAG="$OMAKASE_WIFI_SETUP_DIR/.install-deferred"

need_venv_rebuild=0
if [ "$SKIP_WIFI_SETUP" = "1" ]; then
    echo "Skipping wifi-setup venv build (--no-wifi-setup)."
elif [ ! -x "$WIFI_VENV/bin/python" ]; then
    need_venv_rebuild=1
elif [ -f "$WIFI_DEFERRED_FLAG" ]; then
    # Previous install left the venv half-built (e.g. PyPI unreachable).
    # Retry the pip install this run.
    need_venv_rebuild=1
elif [ -f "$WIFI_REQ" ]; then
    current="$(sha256sum "$WIFI_REQ" | awk '{print $1}')"
    prev="$(cat "$WIFI_REQ_STAMP" 2>/dev/null || true)"
    [ "$current" != "$prev" ] && need_venv_rebuild=1
fi

if [ "$need_venv_rebuild" = "1" ]; then
    echo "Creating wifi-setup venv at $WIFI_VENV..."
    rm -rf "$WIFI_VENV"
    python3 -m venv "$WIFI_VENV"

    # pip pulls from PyPI; if the network is down / firewalled / mirror is out,
    # don't wedge the whole install. Leave a deferred-install flag, skip enabling
    # the wifi-setup unit below, and let the next `install.sh --upgrade` retry.
    # The docker runtime + ECR flow below is unaffected.
    venv_ok=1
    if ! "$WIFI_VENV/bin/pip" install --upgrade pip >/dev/null 2>&1; then
        venv_ok=0
    elif [ -f "$WIFI_REQ" ]; then
        if "$WIFI_VENV/bin/pip" install -r "$WIFI_REQ"; then
            sha256sum "$WIFI_REQ" | awk '{print $1}' >"$WIFI_REQ_STAMP"
        else
            venv_ok=0
        fi
    else
        "$WIFI_VENV/bin/pip" install \
            "fastapi>=0.115" "uvicorn[standard]>=0.30" "pydantic>=2.0" \
            "python-dotenv>=1.0" "jinja2>=3.1" || venv_ok=0
    fi

    if [ "$venv_ok" = "1" ]; then
        rm -f "$WIFI_DEFERRED_FLAG"
    else
        echo >&2
        echo "WARNING: wifi-setup pip install failed (PyPI unreachable?)." >&2
        echo "         The omakase-wifi-setup.service will NOT start this run." >&2
        echo "         Re-run 'sudo ./install.sh --upgrade' from a host with PyPI" >&2
        echo "         access to finish the wifi-setup daemon install." >&2
        echo >&2
        rm -f "$WIFI_REQ_STAMP"
        touch "$WIFI_DEFERRED_FLAG"
    fi
fi

# ---------------------------------------------------------------------------
# First ECR login — we need credentials before `docker compose pull` can
# reach the private registry. ota.sh repeats this step on each manual update.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
. "$OMAKASE_BIN_DIR/omakase-ecr-login.sh"

echo "Minting first ECR credentials from $OMAKASE_API_URL..."
omakase_ecr_login "$REQUESTED_TAG"

# ---------------------------------------------------------------------------
# Two env files now own different responsibilities:
#
#   robot.env    — install metadata. Compose interpolates ${OMAKASE_IMAGE_REF}
#                  etc. from here at YAML parse time. Overwritten on every
#                  install/upgrade. Operators should not edit it.
#
#   runtime.env  — everything the runtime container reads. Loaded into the
#                  container via compose's `env_file:` directive. Seeded by
#                  install.sh on first install and PRESERVED on --upgrade so
#                  operator-managed values (provider keys, feature flags,
#                  webhook URLs, anomaly preset, etc.) survive upgrades.
#
# Adding a new env var that the runtime reads? Just add it to runtime.env on
# the box. There is no compose-template list to keep in sync.
# ---------------------------------------------------------------------------
cat >"$ENV_FILE" <<ENV
# /etc/omakase/robot.env — install metadata. DO NOT EDIT.
# Overwritten on every install / upgrade / OTA. Operator-tunable knobs live
# in /etc/omakase/runtime.env, which is preserved across upgrades.
OMAKASE_IMAGE_REF=$OMAKASE_IMAGE_REF
OMAKASE_IMAGE_TAG=$OMAKASE_ECR_TAG
OMAKASE_RUNTIME_UID=$OMAKASE_RUNTIME_UID
ENV
chmod 600 "$ENV_FILE"

if [ ! -f "$RUNTIME_ENV_FILE" ]; then
    cat >"$RUNTIME_ENV_FILE" <<RUNTIME
# /etc/omakase/runtime.env — runtime config for the omakase container.
#
# install.sh seeds this file on first install and DOES NOT overwrite it on
# --upgrade. Edit and then:
#     sudo systemctl restart omakase-robot.service
#
# Whatever lives here is forwarded into the container by docker-compose's
# env_file directive — no compose-template edits are needed when you add
# new vars. Convention: one KEY=value per line, '#'-prefix to disable.

# === Identity (filled from license.json by install.sh) ===
ROBOT_ID=$ROBOT_ID
ROBOT_BOOTSTRAP_TOKEN=$ROBOT_BOOTSTRAP_TOKEN

# === Backend / runtime ===
OMAKASE_API_URL=$OMAKASE_API_URL
OMAKASE_CONV_VERSION=$CONV_VERSION
LOCALE=${LOCALE:-ja}
STATUS_SERVER_ENABLED=${STATUS_SERVER_ENABLED:-1}
STATUS_PUSH_ENABLED=1
BOOTSTRAP_STRICT=${BOOTSTRAP_STRICT:-1}
# Optional: surface a runtime version string in heartbeats / OTA reports.
# OMAKASE_RUNTIME_VERSION=

# === AWS IoT (write-only S3 upload role) ===
# Certs are baked into the image at build time from robot_stack/creds/.
# These paths are container-side. Comment out to disable S3 uploads, or
# set DISABLE_S3_UPLOADS=1.
AWS_IOT_CERT_PATH=/app/robot_stack/creds/certificate.pem.crt
AWS_IOT_KEY_PATH=/app/robot_stack/creds/private.pem.key
AWS_IOT_CA_PATH=/app/robot_stack/creds/amazon_root_ca.pem
# AWS_IOT_ROLE_ALIAS=
# AWS_IOT_ENDPOINT=
# AWS_S3_BUCKET_NAME=
# AWS_S3_PUBLIC_BASE_URL=
# DISABLE_S3_UPLOADS=0

# === Conversation engine providers ===
# Provider API keys (DASHSCOPE_API_KEY, GOOGLE_API_KEY) and the default
# model/provider selection (CONVERSATION_LLM_PROVIDER, STT_PROVIDER,
# QWEN_MODEL, VLM_MODEL, CONVERSATION_VLM_MODEL, DASHSCOPE_BASE_URL) are
# baked into the runtime image at build time from GitHub Actions secrets.
# Uncomment any of these to override on this specific robot — env_file
# values beat image ENV via compose's precedence rules.
# DASHSCOPE_API_KEY=
# GOOGLE_API_KEY=
# CONVERSATION_LLM_PROVIDER=qwen
# STT_PROVIDER=qwen
# QWEN_MODEL=qwen3-vl-flash
# VLM_MODEL=gemini-2.5-flash
# CONVERSATION_VLM_MODEL=gemini-2.5-flash-lite
# CONVERSATION_LISTEN_EARLY_MARGIN_S=0
# MAX_SESSION_DURATION_S=300

# === Notifications ===
# NOTIFICATIONS_ENABLED=0
# NOTIFICATIONS_CONFIG=robot_stack/config/notifications.yaml
# SLACK_WEBHOOK_ENABLED=0
# SLACK_WEBHOOK_URL=
# SLACK_WEBHOOK_INCLUDE_IMAGE=0
# CLIENT_NOTIFICATION_WEBHOOK_ENABLED=0
# CLIENT_NOTIFICATION_INCLUDE_IMAGE=1
# CLIENT_NOTIFICATION_WEBHOOK_URL=
# CLIENT_NOTIFICATION_WEBHOOK_TOKEN=

# === Anomaly engine ===
# ANOMALY_ENABLED=0
# ANOMALY_PRESET=hospital_patrol

# === Visualization ===
# FOXGLOVE_URL=

# === Navigation stack integration ===
# Temporary Docker socket path: omakase-robot operates the host Docker daemon
# directly until this is replaced by an allowlisted host-side nav-control API.
NAV_DEPLOY_DIR=/nav-autonomy-deploy
MAPS_DIR=/nav-autonomy-deploy/maps
# Leave unset while using Docker socket fallback. Future host-control mode:
# OMAKASE_NAV_CONTROL_URL=http://127.0.0.1:9082
# OMAKASE_NAV_CONTROL_TOKEN=

# === Patrol recording ===
# PATROL_RECORDING_DIR=recordings/patrol_video
# PATROL_RECORDING_SEGMENT_SECONDS=300
# PATROL_RECORDING_FPS=15
RUNTIME
    chmod 600 "$RUNTIME_ENV_FILE"
    if [ -n "$LEGACY_RUNTIME_KEYS" ]; then
        {
            echo ""
            echo "# === Migrated from legacy /etc/omakase/robot.env (single-file layout) ==="
            printf '%s\n' "$LEGACY_RUNTIME_KEYS"
        } >>"$RUNTIME_ENV_FILE"
        migrated_n="$(printf '%s\n' "$LEGACY_RUNTIME_KEYS" | wc -l | awk '{print $1}')"
        echo "Migrated $migrated_n operator-managed key(s) from legacy robot.env into $RUNTIME_ENV_FILE."
    fi
    echo "Seeded $RUNTIME_ENV_FILE — edit it to add provider API keys and feature flags."
else
    append_runtime_env_default_if_missing STATUS_PUSH_ENABLED 1
    if [ "$EXPLICIT_CONV_VERSION" = "1" ]; then
        upsert_runtime_env OMAKASE_CONV_VERSION "$CONV_VERSION"
        echo "Updated OMAKASE_CONV_VERSION in $RUNTIME_ENV_FILE → $CONV_VERSION."
    fi
    echo "Preserved existing $RUNTIME_ENV_FILE (operator-managed)."
fi

cat >"$WIFI_ENV_FILE" <<EOF
# WiFi-setup daemon overrides. Values shown are the defaults in
# robot_stack/wifi_setup/network.py — uncomment to override.
# FALLBACK_AP_SSID=OmakaseOS-Setup
# FALLBACK_AP_PASSWORD=omakase-setup
# FALLBACK_AP_IP_CIDR=192.168.50.1/24
# FALLBACK_AP_BAND=bg
# FALLBACK_AP_CHANNEL=1
# FALLBACK_AP_OFFLINE_GRACE_S=120
EOF
chmod 644 "$WIFI_ENV_FILE"

# ---------------------------------------------------------------------------
# docker-compose.yml — privileged + host network. We intentionally skip the
# hand-rolled device list because privileged + host mode already exposes the
# hardware USB/audio devices the runtime needs.
#
# env_file forwards everything in runtime.env into the container; the inline
# environment: block carries only install-mandatory constants the operator
# should not be able to override.
# ---------------------------------------------------------------------------
cat >"$COMPOSE_FILE" <<'COMPOSE'
# Generated by install.sh — re-run install.sh --upgrade to regenerate.
services:
  omakase:
    image: ${OMAKASE_IMAGE_REF}
    container_name: omakase-robot
    restart: unless-stopped
    privileged: true
    network_mode: host
    env_file:
      - /etc/omakase/runtime.env
    environment:
      - OMAKASE_IN_CONTAINER=1
      - OMAKASE_SKIP_HOST_SETUP=1
    volumes:
      - /etc/omakase/license.json:/var/lib/omakase/license.json:ro
      # Temporary nav-autonomy bridge: use host Docker directly until the
      # allowlisted host-side nav-control service replaces Docker socket access.
      - /opt/omakase/nav-autonomy-deploy:/nav-autonomy-deploy:rw
      - /var/run/docker.sock:/var/run/docker.sock
      - ${XDG_RUNTIME_DIR:-/run/user/${OMAKASE_RUNTIME_UID:-1000}}/pulse:/run/pulse:ro
      - omakase-data:/var/lib/omakase
      - omakase-logs:/var/log/omakase

volumes:
  omakase-data:
  omakase-logs:
COMPOSE

# ---------------------------------------------------------------------------
# systemd units (system-level, not user-level). Docker's restart policy owns
# container-level restarts; systemd only handles boot-time start + stop.
# ---------------------------------------------------------------------------
cat >"$ROBOT_UNIT" <<EOF
[Unit]
Description=Omakase Robot Stack (Docker Compose)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/docker compose --env-file $ENV_FILE -f $COMPOSE_FILE up -d --remove-orphans
ExecStop=/usr/bin/docker compose --env-file $ENV_FILE -f $COMPOSE_FILE down
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

if [ "$SKIP_WIFI_SETUP" = "1" ]; then
    # Tearing down any pre-existing wifi-setup unit so a previous run on this
    # host doesn't leave a fallback-AP service active in the background.
    systemctl disable --now omakase-wifi-setup.service 2>/dev/null || true
    rm -f "$WIFI_UNIT"
else
    cat >"$WIFI_UNIT" <<EOF
[Unit]
Description=Omakase WiFi Setup / Fallback AP
After=network.target NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
WorkingDirectory=$OMAKASE_WIFI_SETUP_DIR/src
EnvironmentFile=-$WIFI_ENV_FILE
ExecStart=$WIFI_VENV/bin/python -m robot_stack.wifi_setup.fallback_ap --host 0.0.0.0 --port 9081
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable omakase-robot.service >/dev/null
if [ "$SKIP_WIFI_SETUP" = "1" ]; then
    : # wifi-setup unit intentionally not installed
elif [ -f "$WIFI_DEFERRED_FLAG" ]; then
    # Venv is incomplete — don't let systemd crash-loop the unit.
    systemctl disable omakase-wifi-setup.service 2>/dev/null || true
else
    systemctl enable omakase-wifi-setup.service >/dev/null
fi

# ---------------------------------------------------------------------------
# First pull happens here (not inside the systemd unit) so operator sees any
# auth / image errors interactively. Subsequent boots reuse the cached image.
# ---------------------------------------------------------------------------
echo "Pulling $OMAKASE_IMAGE_REF..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull

# ---------------------------------------------------------------------------
# Navigation autonomy stack (iServeRobotics/nav-autonomy-deploy).
#
# We clone it next to /opt/omakase so the omakase-robot container can drive
# it via the docker socket + bind-mount declared in the compose file above.
# The .env is rendered from the robot's vendor / robot_model (queried from
# the backend with bootstrap auth) and is preserved on --upgrade so operator
# edits to LIDAR_INTERFACE etc. survive.
#
# The directory is created unconditionally so the bind mount in the omakase
# compose file always has a target — even when the operator opts out of the
# nav stack (--no-nav-stack) or the clone fails (network down etc.).
# ---------------------------------------------------------------------------
mkdir -p "$NAV_STACK_DIR"

if [ "$SKIP_NAV_STACK" = "1" ]; then
    echo "Skipping nav-autonomy-deploy (--no-nav-stack / OMAKASE_SKIP_NAV_STACK=1)."
elif ! command -v git >/dev/null 2>&1; then
    echo "WARN: 'git' is not installed — skipping nav-autonomy-deploy clone." >&2
    echo "      Install git and re-run 'sudo $0 --upgrade' to bring up the nav stack." >&2
else
    fetch_nav_config() {
        local out body http_code
        out="$(mktemp)" || return 1
        # shellcheck disable=SC2064
        trap "rm -f '$out'" RETURN

        body="$(python3 - "$ROBOT_BOOTSTRAP_TOKEN" <<'PY'
import json, sys
print(json.dumps({"bootstrap_token": sys.argv[1]}))
PY
)" || return 1

        http_code="$(curl -sS --connect-timeout 10 --max-time 30 \
            -o "$out" -w '%{http_code}' \
            -X POST -H "Content-Type: application/json" \
            --data "$body" \
            "$OMAKASE_API_URL/api/v1/robots/$ROBOT_ID/nav-config")" || {
                echo "ERROR: failed to reach $OMAKASE_API_URL/api/v1/robots/$ROBOT_ID/nav-config" >&2
                return 1
            }

        if [ "$http_code" != "200" ]; then
            echo "ERROR: nav-config endpoint returned HTTP $http_code" >&2
            sed -n '1,5p' "$out" >&2
            return 1
        fi

        eval "$(python3 - "$out" <<'PY'
import json, shlex, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
v = d.get("vendor", "")
m = d.get("robot_model", "")
print(f"OMAKASE_ROBOT_VENDOR={shlex.quote(v)}")
print(f"OMAKASE_ROBOT_MODEL={shlex.quote(m)}")
PY
)"
        export OMAKASE_ROBOT_VENDOR OMAKASE_ROBOT_MODEL
        if [ -z "${OMAKASE_ROBOT_VENDOR:-}" ] || [ -z "${OMAKASE_ROBOT_MODEL:-}" ]; then
            echo "ERROR: nav-config response missing vendor or robot_model" >&2
            return 1
        fi
    }

    write_nav_stack_env() {
        local vendor="$1" model="$2" target="$3"
        local config_path="$vendor/${vendor}_${model}"
        local use_unitree="false"
        local robot_ip=""
        local unitree_block="# (vendor-specific Unitree settings: not applicable for $vendor)"
        case "$vendor" in
            unitree)
                use_unitree="true"
                robot_ip="192.168.123.161"
                unitree_block="UNITREE_IP=192.168.123.161
UNITREE_CONN=LocalAP"
                ;;
        esac

        cat >"$target" <<NAV_ENV
# Generated by omakase install.sh from backend-reported vendor/model.
# Preserved on --upgrade — edit and then:
#   cd $NAV_STACK_DIR && docker compose up -d --remove-orphans

# === ROS / robot ===
ROS_DOMAIN_ID=42
ROBOT_CONFIG_PATH=$config_path
ROBOT_IP=$robot_ip
USE_UNITREE=$use_unitree
$unitree_block

# === Mid-360 lidar ===
LIDAR_INTERFACE=enp86s0
LIDAR_COMPUTER_IP=192.168.123.5
LIDAR_GATEWAY=192.168.123.1
LIDAR_IP=192.168.123.120

# === Motor controller ===
MOTOR_SERIAL_DEVICE=/dev/ttyACM1

# === Network ===
ENABLE_WIFI_BUFFER=false

# === Vision / SLAM ===
USE_REALSENSE=false
AUTO_VOXEL_SIZE=false
MAPPING_LINE_RESOLUTION=0.02
MAPPING_PLANE_RESOLUTION=0.02
VOXEL_RESOLUTION=0.05

# === Goal tolerance ===
GOAL_REACHED_THRESHOLD=0.3
GOAL_YAW_THRESHOLD=0.15
STOP_DIS_THRESHOLD=0.2

# === Monitoring ===
TARGET_CONTAINER=nav_autonomy
MONITOR_INTERVAL=1.0
SUMMARY_INTERVAL=60

# === Navigation speed ===
AUTONOMY_SPEED=0.5

# === Cloud sender (omakase) ===
CLOUD_API_URL=$OMAKASE_API_URL
CLOUD_ROBOT_NAME=$ROBOT_ID
CLOUD_VENDOR=$vendor
CLOUD_ZONE=default

# === Vision semantic API ===
ROBOT_HOST=localhost
ROBOT_STATUS_PORT=8080
SEMANTIC_TAG_WRITEBACK=false
NAV_ENV
        chmod 644 "$target"
    }

    nav_ready=0
    if fetch_nav_config; then
        echo "Backend reported robot vendor/model: $OMAKASE_ROBOT_VENDOR/$OMAKASE_ROBOT_MODEL."

        if [ -d "$NAV_STACK_DIR/.git" ]; then
            echo "Updating $NAV_STACK_DIR (git fetch $NAV_STACK_REF)..."
            if git -C "$NAV_STACK_DIR" fetch --depth=1 origin "$NAV_STACK_REF" >/dev/null 2>&1 \
                && git -C "$NAV_STACK_DIR" reset --hard FETCH_HEAD >/dev/null; then
                nav_ready=1
            else
                echo "WARN: git fetch/reset failed in $NAV_STACK_DIR." >&2
            fi
        elif [ -n "$(ls -A "$NAV_STACK_DIR" 2>/dev/null)" ]; then
            echo "WARN: $NAV_STACK_DIR is non-empty but not a git checkout — leaving it alone." >&2
        else
            echo "Cloning $NAV_STACK_REPO ($NAV_STACK_REF) into $NAV_STACK_DIR..."
            if git clone --depth=1 --branch "$NAV_STACK_REF" "$NAV_STACK_REPO" "$NAV_STACK_DIR"; then
                nav_ready=1
            else
                echo "WARN: clone failed for $NAV_STACK_REPO." >&2
            fi
        fi
    else
        echo "WARN: skipping nav-autonomy-deploy install (backend unreachable)." >&2
        echo "      Re-run 'sudo $0 --upgrade' once the backend is reachable." >&2
    fi

    if [ "$nav_ready" = "1" ]; then
        if [ -f "$NAV_STACK_DIR/.env" ]; then
            echo "Preserved existing $NAV_STACK_DIR/.env."
        else
            echo "Seeding $NAV_STACK_DIR/.env from $OMAKASE_ROBOT_VENDOR/$OMAKASE_ROBOT_MODEL..."
            write_nav_stack_env "$OMAKASE_ROBOT_VENDOR" "$OMAKASE_ROBOT_MODEL" "$NAV_STACK_DIR/.env"
        fi

        if [ -f "$NAV_STACK_DIR/docker-compose.yml" ]; then
            echo "Pulling nav-autonomy-deploy images..."
            (cd "$NAV_STACK_DIR" && docker compose pull) || \
                echo "WARN: docker compose pull failed in $NAV_STACK_DIR." >&2
            echo "Bringing up nav-autonomy-deploy (docker compose up -d)..."
            (cd "$NAV_STACK_DIR" && docker compose up -d --remove-orphans) || \
                echo "WARN: docker compose up failed in $NAV_STACK_DIR." >&2
        else
            echo "WARN: $NAV_STACK_DIR/docker-compose.yml missing — nav stack not started." >&2
        fi
    fi
fi

systemctl restart omakase-robot.service
if [ "$SKIP_WIFI_SETUP" != "1" ] && [ ! -f "$WIFI_DEFERRED_FLAG" ]; then
    systemctl restart omakase-wifi-setup.service
fi

# Convenience symlink so operators can just type `omakase-ota` on the host.
ln -sf "$OMAKASE_BIN_DIR/ota.sh" /usr/local/bin/omakase-ota 2>/dev/null || true

if [ "$SKIP_WIFI_SETUP" = "1" ]; then
    WIFI_LINE="WiFi setup:        DISABLED (--no-wifi-setup)"
    UNITS_LINE="systemd units:     omakase-robot.service"
else
    WIFI_LINE="WiFi setup:        $OMAKASE_WIFI_SETUP_DIR  (AP web UI on :9081)"
    UNITS_LINE="systemd units:     omakase-robot.service, omakase-wifi-setup.service"
fi

if [ "$SKIP_NAV_STACK" = "1" ]; then
    NAV_LINE="Nav stack:         DISABLED (--no-nav-stack)"
elif [ -f "$NAV_STACK_DIR/docker-compose.yml" ]; then
    NAV_LINE="Nav stack:         $NAV_STACK_DIR  (vendor=${OMAKASE_ROBOT_VENDOR:-?} model=${OMAKASE_ROBOT_MODEL:-?})"
else
    NAV_LINE="Nav stack:         NOT INSTALLED  (re-run --upgrade once the backend is reachable)"
fi

cat <<DONE

Omakase robot stack installed.
  Engine version:    $CONV_VERSION
  Image:             $OMAKASE_IMAGE_REF
  Config:            $OMAKASE_CONFIG_DIR
  $WIFI_LINE
  $NAV_LINE
  $UNITS_LINE

Commands:
  Logs:              journalctl -u omakase-robot.service -f
  Status:            systemctl status omakase-robot.service
  Manual update:     sudo omakase-ota [--tag <version>]
  Uninstall:         sudo $0 --uninstall
  Purge (wipe all):  sudo $0 --purge
DONE
