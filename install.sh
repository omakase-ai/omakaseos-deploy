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
#   OMAKASE_NAV_STACK_REF   Branch / tag / commit to check out (default: master).

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
    v1|v2) ;;
    v3)
        echo "ERROR: conversation engine v3 is not implemented yet." >&2
        exit 2;;
    *)
        echo "ERROR: --version expects v1 or v2 (got '$CONV_VERSION')." >&2
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
# (claiming v2 while the file still pins v1, or vice versa).
if [ "$EXPLICIT_CONV_VERSION" = "0" ] && [ -n "${OMAKASE_CONV_VERSION:-}" ]; then
    case "$OMAKASE_CONV_VERSION" in
        v1|v2) CONV_VERSION="$OMAKASE_CONV_VERSION" ;;
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

# === Microphone preprocessing (ReSpeaker tuning) ===
# Defaults are calibrated for the ReSpeaker 4 Mic Array using audio-tester:
# raw stream sits ~12 dB below normal-speech target, quiet-room floor sits
# around -70 dBFS. Override per-robot if your environment is different.
# AUDIO_INPUT_GAIN_DB=12.0      # Digital gain applied after the gate. 0 = off.
# AUDIO_NOISE_GATE_DB=-64.0     # RMS gate on raw signal in dBFS. "off" disables.

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
# SEMANTIC_CAMERA_MODE=panorama
# SEMANTIC_CAMERA_SOURCE=/dev/video2

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
