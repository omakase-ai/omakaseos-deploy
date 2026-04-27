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
