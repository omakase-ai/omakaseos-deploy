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
# On first install the operator is prompted for the backend region (us/jp).
# Set OMAKASE_REGION (or OMAKASE_API_URL) ahead of time to skip the prompt
# in scripted/CI installs.
#
# Environment overrides (rare):
#   OMAKASE_REGION          (us | jp — selects OMAKASE_API_URL; skips the prompt)
#   OMAKASE_API_URL         (overrides region selection; default derived from region)
#   OMAKASE_CONV_VERSION    (v1 | v2 | v3, default v3)
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
#   OMAKASE_NAV_STACK_REF   Branch / tag / commit to check out (default: master).

set -euo pipefail

# BASH_SOURCE is unset when bash reads the script from stdin (curl | bash),
# which trips set -u. Fall through to $0 — directory only matters for the
# local-override path, which can't fire in pipe mode anyway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
MODE="install"
CONV_VERSION="${OMAKASE_CONV_VERSION:-v3}"
# 1 if --version was passed on this invocation. Lets us decide whether
# to overwrite OMAKASE_CONV_VERSION in an existing runtime.env, or defer
# to the value already there.
EXPLICIT_CONV_VERSION=0
REQUESTED_TAG=""
SKIP_WIFI_SETUP="${OMAKASE_SKIP_WIFI_SETUP:-0}"
SKIP_NAV_STACK="${OMAKASE_SKIP_NAV_STACK:-0}"
NAV_STACK_DIR="/opt/omakase/nav-autonomy-deploy"
NAV_STACK_REPO="${OMAKASE_NAV_STACK_REPO:-https://github.com/iServeRobotics/nav-autonomy-deploy.git}"
NAV_STACK_REF="${OMAKASE_NAV_STACK_REF:-master}"
ASSUME_YES=0

OMAKASE_CONFIG_DIR="${OMAKASE_CONFIG_DIR:-/etc/omakase}"
OMAKASE_WIFI_SETUP_DIR="${OMAKASE_WIFI_SETUP_DIR:-/opt/omakase/wifi-setup}"
OMAKASE_BIN_DIR="${OMAKASE_BIN_DIR:-/opt/omakase/bin}"
SYSTEMD_DIR="/etc/systemd/system"

# Region → backend endpoint mapping. On first install the operator is
# prompted for the region unless OMAKASE_REGION (or OMAKASE_API_URL) is
# already set in the environment.
EXPLICIT_API_URL=0
[ -n "${OMAKASE_API_URL:-}" ] && EXPLICIT_API_URL=1
REGION="${OMAKASE_REGION:-}"

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
        -h|--help)     sed -n '2,55p' "$0"; exit 0;;
        *)             echo "Unknown argument: $1" >&2; exit 2;;
    esac
done

case "$CONV_VERSION" in
    v1|v2|v3) ;;
    *)
        echo "ERROR: --version expects v1, v2, or v3 (got '$CONV_VERSION')." >&2
        exit 2;;
esac

resolve_region_api_url() {
    case "$1" in
        us) echo "https://www.omakase.ai" ;;
        jp) echo "https://enterprise.jp.omakase.ai" ;;
        *)  return 1 ;;
    esac
}

# If OMAKASE_REGION was set in the environment, validate it now so a typo
# fails before we touch anything on the host. The interactive prompt below
# (first install only) handles the empty case.
if [ -n "$REGION" ]; then
    if ! REGION_API_URL="$(resolve_region_api_url "$REGION")"; then
        echo "ERROR: OMAKASE_REGION expects us or jp (got '$REGION')." >&2
        exit 2
    fi
    if [ "$EXPLICIT_API_URL" = "0" ]; then
        OMAKASE_API_URL="$REGION_API_URL"
    fi
fi

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
# (claiming v3 while the file still pins v1/v2, or vice versa).
if [ "$EXPLICIT_CONV_VERSION" = "0" ] && [ -n "${OMAKASE_CONV_VERSION:-}" ]; then
    case "$OMAKASE_CONV_VERSION" in
        v1|v2|v3) CONV_VERSION="$OMAKASE_CONV_VERSION" ;;
        *) ;; # malformed runtime.env — fall through with the default
    esac
fi

# If OMAKASE_REGION was set explicitly in the environment, sourcing
# runtime.env may have overwritten the region-derived OMAKASE_API_URL with
# the file's value — re-apply so the env override wins on --upgrade too.
if [ -n "${OMAKASE_REGION:-}" ] && [ "$EXPLICIT_API_URL" = "0" ]; then
    OMAKASE_API_URL="$REGION_API_URL"
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
        upsert_runtime_env "$key" "$value"
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

    # Welcome banner. install.sh is public (anyone who clones the repo can
    # run it), so a curious first-time visitor should see what they're
    # installing — and where to go if they don't have a robot yet.
    cat <<'BANNER'

================================================================
  OmakaseOS — autonomy stack for service robots

  Privileged Docker runtime that ships conversation,
  navigation, OTA updates, and remote management on a
  single customer-managed host.

  Learn more / get a robot:  https://www.omakase.ai/robotics
================================================================

BANNER

    # Gate the credential prompt behind a confirmation when neither
    # license.json nor env vars supplied creds — a curious visitor without
    # a Robot ID should land on the contact page, not a bare prompt.
    if [ -z "${ROBOT_ID:-}" ] || [ -z "${ROBOT_BOOTSTRAP_TOKEN:-}" ]; then
        cat <<'NEED_CREDS'
Installing OmakaseOS requires a Robot ID and bootstrap token issued
by Omakase with your robot license.

  - Have a license.json? Drop it next to install.sh and re-run.
  - Already know your credentials? Continue below.
  - Don't have credentials yet? Get in touch:
      https://www.omakase.ai/robotics

NEED_CREDS

        if [ -z "$prompt_input_fd" ] && [ ! -t 0 ]; then
            echo "ERROR: ROBOT_ID + ROBOT_BOOTSTRAP_TOKEN are required for a non-interactive install." >&2
            echo "       Set them as env vars, or place a license.json next to install.sh." >&2
            echo "       Don't have credentials? https://www.omakase.ai/robotics" >&2
            exit 1
        fi

        if [ -n "$prompt_input_fd" ]; then
            read -r -p "Do you have your Robot ID and bootstrap token? [y/N]: " has_creds <"$prompt_input_fd"
        else
            read -r -p "Do you have your Robot ID and bootstrap token? [y/N]: " has_creds
        fi
        case "${has_creds:-N}" in
            y|Y|yes|YES|Yes) ;;
            *)
                cat <<'NO_CREDS'

No problem — visit https://www.omakase.ai/robotics to talk to us about
getting an Omakase-powered robot. Re-run this installer once you have
your Robot ID and bootstrap token.
NO_CREDS
                exit 0
                ;;
        esac
    fi

    prompt_required_value ROBOT_ID "Robot ID"
    prompt_required_value ROBOT_BOOTSTRAP_TOKEN "Robot bootstrap token" 1

    # Region: ask which omakase backend this robot calls home to. Skipped
    # when OMAKASE_REGION (or OMAKASE_API_URL) was set ahead of time.
    if [ -z "$REGION" ] && [ "$EXPLICIT_API_URL" = "0" ]; then
        if [ -z "$prompt_input_fd" ] && [ ! -t 0 ]; then
            echo "Non-interactive install with no OMAKASE_REGION set — defaulting to 'us'."
            REGION="us"
        else
            while :; do
                if [ -n "$prompt_input_fd" ]; then
                    read -r -p "Region [us/jp] (default: us): " region_answer <"$prompt_input_fd"
                else
                    read -r -p "Region [us/jp] (default: us): " region_answer
                fi
                region_answer="${region_answer:-us}"
                case "$region_answer" in
                    us|jp) REGION="$region_answer"; break ;;
                    *) echo "Please enter 'us' or 'jp'." ;;
                esac
            done
        fi
        REGION_API_URL="$(resolve_region_api_url "$REGION")"
        OMAKASE_API_URL="$REGION_API_URL"
    fi
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

# === Business card hand / suction cup ===
# BUSINESS_CARD_CATCH_MOTION=business_card_catch_v5
# BUSINESS_CARD_SUCTION_OFF_MODE=arm_extended
# BUSINESS_CARD_SUCTION_OFF_AFTER_ARM_EXTENDED_S=1.0
# BUSINESS_CARD_SUCTION_OFF_MODE=before_arm_down
# BUSINESS_CARD_SUCTION_OFF_BEFORE_ARM_DOWN_S=1.0
# CONTROL_PLANE_BUSINESS_CARD_HAND_TIMEOUT_S=45
# SUCTION_CUP_SERIAL_PORT=/dev/ttyACM0
# SUCTION_CUP_RELAY_SCRIPT=/home/omakase1/Programs/manipulation/suction_cup/relayctl.py

# === Microphone preprocessing (ReSpeaker tuning) ===
# Defaults are calibrated for the ReSpeaker 4 Mic Array using audio-tester:
# raw stream sits ~12 dB below normal-speech target, quiet-room floor sits
# around -70 dBFS. Override per-robot if your environment is different.
# AUDIO_INPUT_GAIN_DB=12.0      # Digital gain applied after the gate. 0 = off.
# AUDIO_NOISE_GATE_DB=-64.0     # RMS gate on raw signal in dBFS. "off" disables.

# === Hosted conversation audio device pinning ===
# PortAudio index or device name substring. When set, these override the
# ReSpeaker profile defaults for the hosted voice worker.
# OMAKASE_VOICE_INPUT_DEVICE=
# OMAKASE_VOICE_OUTPUT_DEVICE=

# === Legacy hosted voice playback gain ===
# VOICE_OUTPUT_VOLUME is an attenuator (0.0-1.0). Use gain to boost quiet
# Daily/Vapi speaker audio above unity; clipping is applied if the signal peaks.
# VOICE_OUTPUT_GAIN=24
# VOICE_INITIAL_OUTPUT_GAIN=2.6
# VOICE_INITIAL_OUTPUT_GAIN_DURATION_S=2.0

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

# === Semantic vision ===
# SEMANTIC_API_ENABLED=true
# SEMANTIC_CAMERA_MODE=panorama
# SEMANTIC_CAMERA_SOURCE=/dev/video2
# Webcam mode (SEMANTIC_CAMERA_MODE=webcam) reads frames from the shared-
# memory channel that the MediaPipe vision loop publishes — V4L2 only
# allows one reader per device, so we never open the webcam twice. Set
# SEMANTIC_CAMERA_SOURCE to a /dev path or integer index only when running
# the semantic API standalone with no MediaPipe process to share frames.

# === Navigation stack integration ===
# Temporary Docker socket path: omakase-robot operates the host Docker daemon
# directly until this is replaced by an allowlisted host-side nav-control API.
NAV_STACK_DIR=$NAV_STACK_DIR
NAV_AUTONOMY_DOCKER_CONTAINER=nav_autonomy
# Leave unset while using Docker socket fallback. Future host-control mode:
# NAV_DEPLOY_DIR=        # legacy override; defaults to NAV_STACK_DIR.
# MAPS_DIR=              # optional override; defaults to NAV_STACK_DIR/maps.
# OMAKASE_NAV_CONTROL_URL=http://127.0.0.1:9082
# OMAKASE_NAV_CONTROL_TOKEN=

# === Patrol recording ===
# PATROL_RECORDING_DIR=recordings/patrol_video
# PATROL_RECORDING_SEGMENT_SECONDS=300
# PATROL_RECORDING_FPS=15

# === Data collection (training / analysis) ===
# Local-only capture of camera/audio streams for later manual S3 upload.
# DATA_COLLECTION_ENABLED=0
# DATA_COLLECTION_DIR=recordings/datasets
# DATA_COLLECTION_SESSION_DIR=
# DATA_COLLECTION_FPS=15
# DATA_COLLECTION_SEGMENT_SECONDS=0
# DATA_COLLECTION_RECORD_PRIMARY=1
# DATA_COLLECTION_RECORD_REALSENSE=1
# DATA_COLLECTION_DETAILED_TIMING=0
# DATA_COLLECTION_AUDIO_ENABLED=1
# DATA_COLLECTION_AUDIO_DEVICE=
# DATA_COLLECTION_AUDIO_SAMPLE_RATE=16000
# DATA_COLLECTION_AUDIO_CHANNELS=1
# DATA_COLLECTION_AUDIO_CHUNK_MS=100
# DATA_COLLECTION_AUDIO_INPUT_CHANNEL=0
# DATA_COLLECTION_AUDIO_INPUT_GAIN_DB=0
# DATA_COLLECTION_AUDIO_NOISE_GATE_DB=off
# DATA_COLLECTION_INTENT_FPS=5
# DATA_COLLECTION_SEMANTIC_FPS=0
# DATA_COLLECTION_S3_BUCKET=
# DATA_COLLECTION_S3_PREFIX=datasets
# DATA_COLLECTION_S3_AUTH=auto
# DATA_COLLECTION_S3_PROFILE=
# DATA_COLLECTION_S3_REGION=
# DATA_COLLECTION_RUNTIME_STATE_PATH=
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
    if ! grep -Eq "^[[:space:]]*NAV_STACK_DIR=" "$RUNTIME_ENV_FILE"; then
        if [ -n "${NAV_DEPLOY_DIR:-}" ] && [ "${NAV_DEPLOY_DIR:-}" != "/nav-autonomy-deploy" ]; then
            upsert_runtime_env NAV_STACK_DIR "$NAV_DEPLOY_DIR"
            NAV_STACK_DIR="$NAV_DEPLOY_DIR"
            echo "Migrated NAV_DEPLOY_DIR in $RUNTIME_ENV_FILE → NAV_STACK_DIR=$NAV_DEPLOY_DIR."
        else
            upsert_runtime_env NAV_STACK_DIR "$NAV_STACK_DIR"
            echo "Added NAV_STACK_DIR to $RUNTIME_ENV_FILE → $NAV_STACK_DIR."
        fi
    fi
    append_runtime_env_default_if_missing NAV_AUTONOMY_DOCKER_CONTAINER nav_autonomy
    if [ "$EXPLICIT_CONV_VERSION" = "1" ]; then
        upsert_runtime_env OMAKASE_CONV_VERSION "$CONV_VERSION"
        echo "Updated OMAKASE_CONV_VERSION in $RUNTIME_ENV_FILE → $CONV_VERSION."
    fi
    if [ -n "${OMAKASE_REGION:-}" ] && [ "$EXPLICIT_API_URL" = "0" ]; then
        upsert_runtime_env OMAKASE_API_URL "$OMAKASE_API_URL"
        echo "Updated OMAKASE_API_URL in $RUNTIME_ENV_FILE → $OMAKASE_API_URL (OMAKASE_REGION=$OMAKASE_REGION)."
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
      # Keep the primary path identical inside the container and on the host so
      # docker compose bind mount sources resolve correctly through docker.sock.
      - /opt/omakase/nav-autonomy-deploy:/opt/omakase/nav-autonomy-deploy:rw
      # Compatibility mount for older operator configs that still reference the
      # previous container-side path.
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

# Directory inside nav_autonomy containing traverse_poses.txt
MAP_PATH=/ros2_ws/maps/current_best_map

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
ROBOT_STATUS_PORT=8081
SEMANTIC_TAG_WRITEBACK=false
NAV_ENV
        chmod 644 "$target"
    }

    write_nav_stack_key_file() {
        local target="$1"
        cat >"$target" <<'KEY_ENV'
# Omakase Cloud API credentials
# This file is gitignored — do not commit
CLOUD_API_KEY=
CLOUD_ROBOT_ID=robot-01
KEY_ENV
        chmod 600 "$target"
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

        if [ -f "$NAV_STACK_DIR/key.txt" ]; then
            echo "Preserved existing $NAV_STACK_DIR/key.txt."
        else
            echo "Seeding $NAV_STACK_DIR/key.txt."
            write_nav_stack_key_file "$NAV_STACK_DIR/key.txt"
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
