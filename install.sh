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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
