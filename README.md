# OmakaseOS Distribution

Single-file customer installer + manual OTA helper for OmakaseOS robots.

This folder is the operator-facing surface. Customers receive only:

- `install.sh` — first install + upgrade + uninstall
- `license.json` — their robot's `robot_id` + `bootstrap_token`

Everything else (`omakase-ecr-login.sh`, `ota.sh`, the wifi-setup Python
package) is embedded as a base64 tarball inside `install.sh` and extracted on
the robot at install time. The customer never touches this folder directly.

For the architectural picture (license states, bootstrap snapshot, OTA design
rationale), see `docs/DEVICE_RUNTIME_OVERVIEW.md` and
`docs/DEVICE_BOOTSTRAP_LICENSE_OTA.md`.

## What gets installed

`install.sh` installs into well-known host paths so reinstalls and OTAs are
idempotent:

| path | owner | clobbered on `--upgrade`? | purpose |
|---|---|---|---|
| `/etc/omakase/license.json` | install.sh | no (preserved) | `robot_id` + `bootstrap_token` (chmod 600) |
| `/etc/omakase/robot.env` | install.sh | **yes** | install metadata: `OMAKASE_IMAGE_REF`, `OMAKASE_IMAGE_TAG`, `OMAKASE_RUNTIME_UID`. **DO NOT EDIT** |
| `/etc/omakase/runtime.env` | operator | no (seeded once) | everything the container reads — provider keys, feature flags, webhooks. **EDIT THIS** for runtime config |
| `/etc/omakase/docker-compose.yml` | install.sh | yes | privileged + host-network compose for the runtime container |
| `/etc/omakase/wifi-setup.env` | install.sh | yes | optional fallback-AP overrides |
| `/opt/omakase/wifi-setup/` | install.sh | yes | host-side fallback-AP daemon (readable Python + venv) |
| `/opt/omakase/bin/ota.sh` | install.sh | yes | manual OTA helper, symlinked as `/usr/local/bin/omakase-ota` |
| `/opt/omakase/bin/omakase-ecr-login.sh` | install.sh | yes | shared ECR-login helper sourced by install.sh and ota.sh |
| `/etc/systemd/system/omakase-robot.service` | install.sh | yes | `Type=oneshot` `docker compose up -d` at boot |
| `/etc/systemd/system/omakase-wifi-setup.service` | install.sh | yes | host-side fallback AP on port 9081 (skipped with `--no-wifi-setup`) |

## Two env files, two responsibilities

| | `robot.env` | `runtime.env` |
|---|---|---|
| owner | install.sh / ota.sh | operator |
| audience | the host shell that runs `docker compose` | the runtime container |
| consumed by | systemd `EnvironmentFile=`, `docker compose --env-file` (interpolates `${OMAKASE_IMAGE_REF}` in compose YAML) | compose's `env_file:` directive (loaded directly into container env) |
| overwritten on `--upgrade`? | yes — it's pure install metadata | no — operator changes are preserved |
| what goes in it | `OMAKASE_IMAGE_REF`, `OMAKASE_IMAGE_TAG`, `OMAKASE_RUNTIME_UID` | everything else: provider API keys, feature flags, webhook URLs, anomaly preset, … |

### Adding a new env var the runtime reads

**Just add a line to `/etc/omakase/runtime.env`** and restart the unit. The
compose template loads `runtime.env` via `env_file:`, so any key in it
reaches the container automatically — there is no compose-template list to
keep in sync.

```bash
echo 'DASHSCOPE_API_KEY=sk-...' | sudo tee -a /etc/omakase/runtime.env
sudo systemctl restart omakase-robot.service
```

If you're a contributor adding a new env var to `robot_stack/`, also add a
**commented** placeholder to the `runtime.env` template inside
`distribution/install.sh` so first-install operators see the knob exists.

The runtime container itself is pulled from a private AWS ECR repository
(`omakaseos`). The robot never holds AWS credentials — the backend mints a
12-hour ECR auth token in exchange for the bootstrap token, on every install
and every `omakase-ota` run.

## Quick start (production robot)

### One-liner (preferred)

```bash
curl -fsSL https://raw.githubusercontent.com/omakase-ai/omakaseos-deploy/main/install.sh | sudo -E bash
```

The installer prompts for `Robot ID` and `Robot bootstrap token`. Pass
them on the `sudo` invocation to skip the prompts — the assignments must
be on `sudo` (not on `curl`), because in a pipeline `VAR=val cmd1 | cmd2`
binds `VAR` to `cmd1` only:

```bash
curl -fsSL https://raw.githubusercontent.com/omakase-ai/omakaseos-deploy/main/install.sh \
  | sudo ROBOT_ID=... ROBOT_BOOTSTRAP_TOKEN=oma_robot_... bash
```

To pin a specific image tag, append it as a flag (note the `--` so bash
forwards args to the script):

```bash
curl -fsSL https://raw.githubusercontent.com/omakase-ai/omakaseos-deploy/main/install.sh \
  | sudo -E bash -s -- --tag v1.4.2
```

### Local file (operator with a downloaded installer)

Drop `install.sh` and `license.json` on the robot, then:

```bash
sudo ./install.sh
```

You'll be prompted for `Robot ID` and `Robot bootstrap token` only if
`license.json` is missing or `ROBOT_ID` / `ROBOT_BOOTSTRAP_TOKEN` aren't
already set in `/etc/omakase/runtime.env`.

To pin a specific runtime image tag on first install:

```bash
sudo ./install.sh --tag v1.4.2
```

To upgrade later (re-render config, restart units, no re-prompt):

```bash
sudo ./install.sh --upgrade
```

To stop the stack and remove the systemd units (keeps `/etc/omakase/*` and
`/opt/omakase/*` so a later reinstall is idempotent):

```bash
sudo ./install.sh --uninstall
```

### Region

On first install, the operator is prompted for the backend region:

```
Region [us/jp] (default: us): jp
```

| answer | resolves `OMAKASE_API_URL` to       |
|--------|-------------------------------------|
| `us`   | `https://www.omakase.ai`            |
| `jp`   | `https://enterprise.jp.omakase.ai`  |

For scripted / CI installs (no tty), set `OMAKASE_REGION=us|jp` ahead of
time to skip the prompt:

```bash
sudo OMAKASE_REGION=jp ./install.sh
```

`OMAKASE_API_URL` set in the environment still wins over the region
selection, which is the escape hatch for staging hosts. To switch an
already-installed robot to a different backend, edit
`/etc/omakase/runtime.env` directly and `sudo systemctl restart
omakase-robot.service` — or re-run `sudo OMAKASE_REGION=jp ./install.sh
--upgrade`, which upserts the new `OMAKASE_API_URL` into `runtime.env`
without re-prompting.

## license.json

`install.sh` and the runtime container both read `license.json`. The
canonical schema is:

```json
{
  "robot_id":        "e7d261a2-...-...-...-...",
  "bootstrap_token": "oma_robot_..."
}
```

The runtime container loads this via `robot_stack/device/license.py` from
the first matching path: `OMAKASE_LICENSE_PATH` → `/var/lib/omakase/license.json`
→ `/etc/omakase/license.json` → `./license.json`.

`install.sh` will also lift `robot_id` and `bootstrap_token` out of a
`license.json` sitting **next to install.sh**, so you can avoid the
interactive prompt:

```bash
ls install.sh license.json
sudo ./install.sh         # no prompts; values come from ./license.json
```

For backwards compatibility, install.sh's auto-loader also accepts the
legacy `api_key` field as a synonym for `bootstrap_token`. The runtime
container still requires the canonical `bootstrap_token` name, so prefer
that on disk.

## Workstation / dev mode (`--no-wifi-setup`)

The `omakase-wifi-setup.service` daemon flips the host's WiFi adapter into
fallback-AP mode via NetworkManager when no WiFi is configured. That's
correct for a freshly-unboxed customer robot but **destructive on a
developer workstation that's already on WiFi.**

When testing the install on a workstation, always pass:

```bash
sudo ./install.sh --no-wifi-setup
```

This skips the wifi-setup venv build, doesn't write
`omakase-wifi-setup.service`, and tears down any pre-existing one — leaving
your WiFi alone. The runtime container itself (`omakase-robot.service`)
installs and runs normally.

You can also set `OMAKASE_SKIP_WIFI_SETUP=1` in the environment instead of
the flag.

## WiFi setup overrides

`/etc/omakase/wifi-setup.env` is read by `omakase-wifi-setup.service`.
These values affect only the host-side fallback AP daemon, not the runtime
container. The installer regenerates this file on `--upgrade`, so re-apply
local tuning after upgrading if needed.

Useful knobs:

- `FALLBACK_AP_OFFLINE_GRACE_S` defaults to `120`. The watchdog waits this
  many seconds after managed WiFi first appears offline before switching the
  radio into fallback AP mode.
- `FALLBACK_AP_CHECK_INTERVAL_S` defaults to `15`. This is the watchdog poll
  interval.
- `FALLBACK_AP_SSID`, `FALLBACK_AP_PASSWORD`, `FALLBACK_AP_IP_CIDR`,
  `FALLBACK_AP_BAND`, and `FALLBACK_AP_CHANNEL` customize the setup network.

## Manual OTA

```bash
sudo omakase-ota              # pull the latest image for the robot's policy
sudo omakase-ota --tag v1.4.2 # pin a specific tag
```

`ota.sh`:
1. loads `/etc/omakase/robot.env`
2. mints a fresh ECR token via the backend
3. `docker login` against the returned registry
4. rewrites `OMAKASE_IMAGE_REF` / `OMAKASE_IMAGE_TAG` in `robot.env`
5. `docker compose pull` and `systemctl restart omakase-robot.service`

There is no auto-update loop on the robot. OTA is operator-initiated only.

## Installer environment overrides

These are read by `install.sh` itself (export before invoking it). They
control where the installer writes files and which conversation engine
gets seeded into `runtime.env` on first install.

| variable | default | when to set |
|---|---|---|
| `OMAKASE_REGION` | prompted on first install | `us` / `jp` — skips the region prompt and selects `OMAKASE_API_URL` |
| `OMAKASE_API_URL` | derived from `OMAKASE_REGION` | staging/local backend (overrides region selection) |
| `OMAKASE_CONV_VERSION` | `v3` | pin to v1/v2 conversation engines |
| `OMAKASE_CONFIG_DIR` | `/etc/omakase` | non-default install layout |
| `OMAKASE_WIFI_SETUP_DIR` | `/opt/omakase/wifi-setup` | non-default install layout |
| `OMAKASE_BIN_DIR` | `/opt/omakase/bin` | non-default install layout |
| `OMAKASE_RUNTIME_UID` | `$SUDO_UID` (else `1000`) | audio user differs from sudo invoker |
| `OMAKASE_SKIP_WIFI_SETUP` | `0` | `1` is equivalent to `--no-wifi-setup` |

## Runtime environment (`/etc/omakase/runtime.env`)

After install, edit `/etc/omakase/runtime.env` and `sudo systemctl restart
omakase-robot.service` to apply. These are forwarded into the runtime
container by docker-compose's `env_file:` directive, which beats the
image-baked defaults.

The seeded file ships with every key listed below pre-filled or commented
out — uncomment and set what you need.

| variable | default | when to set |
|---|---|---|
| `OMAKASE_API_URL` | `https://www.omakase.ai` | staging/local backend |
| `OMAKASE_CONV_VERSION` | `v3` | `v1` or `v2` to pin an older conversation engine |
| `LOCALE` | `ja` | conversation locale (`ja` / `en` / …) |
| `STATUS_SERVER_ENABLED` | `1` | `0` to disable the local status HTTP server |
| `STATUS_PUSH_ENABLED` | `1` | `0` to stop pushing robot status to omakase.ai |
| `BOOTSTRAP_STRICT` | `1` | `0` to tolerate a missing bootstrap snapshot |
| `OMAKASE_RUNTIME_VERSION` | unset | surface a custom version string in heartbeats / OTA reports |
| `DASHSCOPE_API_KEY` | image-baked | per-robot override of the Qwen STT/LLM key |
| `GOOGLE_API_KEY` | image-baked | per-robot override of the Gemini VLM key |
| `CONVERSATION_LLM_PROVIDER` | `qwen` | swap LLM provider on this robot |
| `STT_PROVIDER` | `qwen` | swap STT provider on this robot |
| `QWEN_MODEL` | `qwen3-vl-flash` | pin a different Qwen model |
| `VLM_MODEL` | `gemini-2.5-flash` | pin a different VLM model |
| `CONVERSATION_VLM_MODEL` | `gemini-2.5-flash-lite` | pin a different conversation VLM |
| `CONVERSATION_LISTEN_EARLY_MARGIN_S` | `0` | tweak conversation barge-in margin |
| `MAX_SESSION_DURATION_S` | `300` | cap a single conversation session in seconds |
| `AUDIO_INPUT_GAIN_DB` | `12.0` (v2) / `0.0` (v1/v3) | digital gain (dB) on captured mic frames after the noise gate. v2 default tuned for the ReSpeaker 4 Mic Array; raise/lower per environment |
| `AUDIO_NOISE_GATE_DB` | `-64.0` (v2) / off (v1/v3) | RMS gate threshold (dBFS) on raw mic frames; quieter frames are zeroed so steady fan/handling noise can't trigger VAD or be amplified. Set to `off` to disable |
| `VOICE_OUTPUT_VOLUME` | `1.0` | playback attenuator (0.0–1.0). Also runtime-overridable from the dashboard via the volume slider |
| `VOICE_OUTPUT_GAIN` | `24.0` | **v1/v3 only** (hosted Daily/Vapi bridge). Above-unity gain on speaker audio; clips on peaks. v2 ignores this knob |
| `VOICE_INITIAL_OUTPUT_GAIN` | `2.6` | **v1/v3 only**. Extra opening-reply boost (clamped to be ≥ `VOICE_OUTPUT_GAIN`, so the default of 24 effectively disables the extra opening boost) |
| `VOICE_INITIAL_OUTPUT_GAIN_DURATION_S` | `2.0` | **v1/v3 only**. How long the opening-reply boost stays active after bot audio starts |
| `NOTIFICATIONS_ENABLED` | `0` | `1` to enable the notifications subsystem |
| `NOTIFICATIONS_CONFIG` | `robot_stack/config/notifications.yaml` | alternate notifications config path |
| `SLACK_WEBHOOK_ENABLED` | `0` | `1` to relay anomalies to Slack |
| `SLACK_WEBHOOK_URL` | unset | Slack incoming-webhook URL (required when enabled) |
| `SLACK_WEBHOOK_INCLUDE_IMAGE` | `0` | `1` to attach the trigger image to Slack posts |
| `CLIENT_NOTIFICATION_WEBHOOK_ENABLED` | `0` | `1` to POST anomalies to the customer's webhook |
| `CLIENT_NOTIFICATION_WEBHOOK_URL` | unset | customer-side webhook endpoint |
| `CLIENT_NOTIFICATION_WEBHOOK_TOKEN` | unset | bearer token sent with the customer webhook |
| `CLIENT_NOTIFICATION_INCLUDE_IMAGE` | `1` | `0` to omit the trigger image |
| `ANOMALY_ENABLED` | `0` | `1` to turn on the anomaly engine |
| `ANOMALY_PRESET` | unset | named preset, e.g. `hospital_patrol` |
| `FOXGLOVE_URL` | unset | Foxglove visualization URL |
| `NAV_DEPLOY_DIR` | `/nav-autonomy-deploy` | container-side path for the mounted `nav-autonomy-deploy` checkout |
| `MAPS_DIR` | `/nav-autonomy-deploy/maps` | container-side path for nav map listing and current-best-map sync |
| `NAV_AUTONOMY_DOCKER_CONTAINER` | `nav_autonomy` | override only if the deployed nav-autonomy compose file uses a different `container_name` |
| `OMAKASE_NAV_CONTROL_URL` | unset | future host nav-control API; leave unset while using the temporary Docker socket fallback |
| `PATROL_RECORDING_DIR` | `recordings/patrol_video` | container-side patrol video output |
| `PATROL_RECORDING_SEGMENT_SECONDS` | `300` | patrol video segment length |
| `PATROL_RECORDING_FPS` | `15` | patrol video framerate |
| `DISABLE_S3_UPLOADS` | `0` | `1` to disable S3 telemetry uploads |
| `AWS_IOT_ROLE_ALIAS` / `AWS_IOT_ENDPOINT` / `AWS_S3_BUCKET_NAME` / `AWS_S3_PUBLIC_BASE_URL` | unset | AWS IoT / S3 wiring (set together; certs are image-baked) |

## Temporary nav-autonomy Docker socket integration

The runtime compose currently bind-mounts:

```yaml
- /opt/omakase/nav-autonomy-deploy:/nav-autonomy-deploy:rw
- /var/run/docker.sock:/var/run/docker.sock
```

This is a temporary bridge so the local UI and omakase.ai commands can reuse
the existing allowlisted nav scripts from inside `omakase-robot`:

```text
/api/scripts/restart-nav-stack -> restart_nav_stack.sh -> docker compose up/down
/api/scripts/stop-nav-stack    -> stop_nav_stack.sh    -> docker compose down
```

For new installs, `runtime.env` is seeded with:

```env
NAV_DEPLOY_DIR=/nav-autonomy-deploy
MAPS_DIR=/nav-autonomy-deploy/maps
NAV_AUTONOMY_DOCKER_CONTAINER=nav_autonomy
```

For existing robots, `runtime.env` is operator-managed and is not overwritten
on `--upgrade`. Recent installers add the nav container default when it is
missing; to patch it manually, add the missing lines and restart:

```bash
sudo tee -a /etc/omakase/runtime.env >/dev/null <<'EOF'
NAV_DEPLOY_DIR=/nav-autonomy-deploy
MAPS_DIR=/nav-autonomy-deploy/maps
NAV_AUTONOMY_DOCKER_CONTAINER=nav_autonomy
EOF
sudo systemctl restart omakase-robot.service
```

Leave `OMAKASE_NAV_CONTROL_URL` unset for this temporary path. Once the
host-side nav-control service is shipped, set that URL and remove the Docker
socket dependency from the compose template.

## Rebuilding the embedded payload (`build-installer.sh`)

`install.sh` ships the wifi-setup Python package + `ota.sh` +
`omakase-ecr-login.sh` as a base64 tarball spliced between
`# BEGIN_OMAKASE_PAYLOAD_B64` / `# END_OMAKASE_PAYLOAD_B64` markers. Run
the rebuilder whenever any of those source files change:

```bash
./build-installer.sh
```

It picks up `robot_stack/wifi_setup/` from the repo root one level up, and
`ota.sh` / `omakase-ecr-login.sh` from this directory. If you're building
from a non-standard location (e.g. iterating in a copied-out folder),
override the source paths:

```bash
OMAKASE_REPO_ROOT=/path/to/omakaseos \
OMAKASE_WIFI_SRC=/path/to/omakaseos/robot_stack/wifi_setup \
  ./build-installer.sh
```

The output is deterministic (sorted paths, fixed mtime, uid/gid 0) so a
rebuild over unchanged inputs produces an identical base64 blob — keeps
the `install.sh` diff minimal in code review.

### Local override (no rebuild during dev)

If `omakase-ecr-login.sh` or `ota.sh` sit next to `install.sh` at run
time, install.sh overlays them on top of the extracted payload. This lets
you iterate on the helper scripts without rebuilding the payload between
every test:

```
Using local omakase-ecr-login.sh from /home/shu/Programs/omakaseos-deploy (override).
Using local ota.sh from /home/shu/Programs/omakaseos-deploy (override).
```

When you're ready to ship, run `build-installer.sh` so the embedded
payload picks up the changes.

## Troubleshooting

### `ERROR: ECR credentials endpoint returned HTTP 401` `{"error":"Missing bootstrap token"}`

The bootstrap token must be sent in the JSON body
(`{"bootstrap_token": "..."}`), **not** in `Authorization: Bearer ...`.
The Bearer header on `/api/v1/robots/:id/ecr-credentials` is reserved for
the JWT device access token issued by `/authenticate`. If you see this
401, the helper script is out of date — rebuild the payload (or use the
local-override mechanism above).

### `ERROR: ECR credentials endpoint returned HTTP 403`

Every path on the host returns 403 with no `WWW-Authenticate` and an
`x-amzn-errortype: ForbiddenException` header. That's an upstream WAF /
API-Gateway resource-policy block — the network you're calling from
isn't whitelisted, or the API host is wrong. Confirm `OMAKASE_API_URL`
points to the right backend (`https://www.omakase.ai` for production)
and that your egress IP is on the allowlist.

### `ERROR: ECR credentials endpoint returned HTTP 500` (empty body)

The auth check passed; the failure is inside `EcrCredentialsService` on
the backend. Most common cause is `OMAKASE_ROBOT_ECR_ROLE_ARN` not being
set on the Rails host, or the Rails task role lacking `sts:AssumeRole`
on the target role. Capture `x-request-id` from the response headers and
hand it to whoever runs the backend.

### `tar: unrecognized option '--uid'` while running `build-installer.sh`

You're on GNU tar; the original script used BSD-only flags. The current
`build-installer.sh` autodetects GNU tar and uses `--owner=0 --group=0`
instead. If you see this, you're running an older copy.

### Wifi-setup pip install fails on the robot

`install.sh` doesn't fail the whole install when the wifi-setup venv can't
be built (PyPI unreachable / firewalled). It writes
`/opt/omakase/wifi-setup/.install-deferred` and skips enabling the
wifi-setup unit. Re-run `sudo ./install.sh --upgrade` from a host with
PyPI access to finish the wifi-setup install. The `omakase-robot.service`
runtime is unaffected.

## Files in this folder

| file | role |
|---|---|
| `install.sh` | the single file customers run; embeds payload + drives systemd |
| `omakase-ecr-login.sh` | shared `omakase_ecr_login` helper, sourced by install.sh and ota.sh |
| `ota.sh` | `omakase-ota` — manual update helper |
| `build-installer.sh` | rebuilds the base64 payload spliced into install.sh |
| `Dockerfile` | runtime container image (built + pushed to ECR by CI; not used on the robot) |
