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
        -h|--help)     sed -n '2,36p' "$0"; exit 0;;
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

cat <<DONE

Omakase robot stack installed.
  Engine version:    $CONV_VERSION
  Image:             $OMAKASE_IMAGE_REF
  Config:            $OMAKASE_CONFIG_DIR
  $WIFI_LINE
  $UNITS_LINE

Commands:
  Logs:              journalctl -u omakase-robot.service -f
  Status:            systemctl status omakase-robot.service
  Manual update:     sudo omakase-ota [--tag <version>]
  Uninstall:         sudo $0 --uninstall
  Purge (wipe all):  sudo $0 --purge
DONE
