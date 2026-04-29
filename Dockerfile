# syntax=docker/dockerfile:1
#
# distribution/Dockerfile — production image for customer robots.
#
# Unlike the root Dockerfile (which keeps the raw source tree for
# dev/debug parity), this image compiles robot_stack/* to .pyc and
# strips the .py originals. The customer image therefore does not ship
# source, just byte-compiled modules + shell entrypoints + assets.
#
# Build via `make dist-build`; push via `make dist-push`.

FROM python:3.10-slim-bookworm AS base

ENV PYTHONDONTWRITEBYTECODE=0 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_CACHE_DIR=/root/.cache/uv

# System deps for audio (PyAudio), OpenCV/MediaPipe, USB, crypto, and the
# Unitree SDK build (git + cmake to compile cyclonedds from source).
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      git \
      gnupg \
      libasound2-dev \
      portaudio19-dev \
      libegl1 \
      libgl1 \
      libgles2 \
      libglib2.0-0 \
      libusb-1.0-0 \
      libxml2-dev \
      libxmlsec1-dev \
      libffi-dev \
      libssl-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Temporary nav-autonomy integration: the runtime container can operate the
# host's Docker daemon via a mounted /var/run/docker.sock until the smaller
# host-side nav-control service is ready.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN pip install --upgrade --no-cache-dir uv && \
    uv venv /app/.venv && \
    uv pip install --python /app/.venv/bin/python --no-cache .

ENV VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:${PATH}"

# Unitree G1 SDK + its cyclonedds C dependency. cyclonedds isn't packaged in
# Debian at the version the SDK requires, and unitree_sdk2_python is not on
# PyPI — both are built from source. The cyclonedds recipe matches the
# Unitree FAQ at https://github.com/unitreerobotics/unitree_sdk2_python:
# track the `releases/0.10.x` branch and run cmake with only the install
# prefix (no BUILD_IDLC=NO — that flag tickles a 0.10.2 ddsperf bug).
#
# UNITREE_SDK2_PYTHON_REF is pinned to a commit; bump it by hand after
# vetting an upstream change.
ARG CYCLONEDDS_REF=releases/0.10.x
ARG UNITREE_SDK2_PYTHON_REF=db9b2d210081387fcd1e7ed9ac4c56a02983bb85
ENV CYCLONEDDS_HOME=/opt/cyclonedds
RUN git clone --depth=1 -b "$CYCLONEDDS_REF" \
        https://github.com/eclipse-cyclonedds/cyclonedds /tmp/cyclonedds \
    && cmake -S /tmp/cyclonedds -B /tmp/cyclonedds/build \
             -DCMAKE_INSTALL_PREFIX=$CYCLONEDDS_HOME \
    && cmake --build /tmp/cyclonedds/build --target install -j"$(nproc)" \
    && rm -rf /tmp/cyclonedds
RUN git clone https://github.com/unitreerobotics/unitree_sdk2_python.git \
        /opt/unitree_sdk2_python \
    && git -C /opt/unitree_sdk2_python checkout "$UNITREE_SDK2_PYTHON_REF" \
    && uv pip install --python /app/.venv/bin/python --no-cache \
           -e /opt/unitree_sdk2_python

# ---------------------------------------------------------------------------
# Compile stage: copy source, byte-compile with PEP 488-disabled names so the
# .pyc files sit next to their modules (compileall -b), then delete the .py
# originals. Shell scripts, YAML/CSV assets, and audio files stay intact.
#
# `.dockerignore` (repo root) keeps dev junk out of the build context.
# `robot_stack/creds/` IS copied when present — populated either by the
# build-image GitHub Action from `AWS_IOT_*_PEM` secrets, or manually on a
# dev host before `docker build`. Role is upload-only so embedding is OK.
# ---------------------------------------------------------------------------
FROM base AS compiled
COPY . .
RUN python -m compileall -b -q robot_stack \
 && find robot_stack -type f -name "*.py" -delete \
 && find robot_stack -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true \
 && rm -rf tests test_echo_audio.py run_tests.sh \
 && if [ -f /app/robot_stack/creds/private.pem.key ]; then \
        chmod 600 /app/robot_stack/creds/private.pem.key; \
        echo "Baked AWS IoT credentials into image"; \
    else \
        echo "WARNING: no robot_stack/creds/ in build context — S3 uploads will be disabled at runtime"; \
    fi

# Provider API keys come from CI build-args (sourced from GitHub secrets).
# Constants (model names, base URLs, provider selection) are plain ENV — they
# ship as the appliance's defaults. Anything in /etc/omakase/runtime.env on
# the robot still overrides these because compose's env_file directive has
# higher precedence than image ENV.
ARG DASHSCOPE_API_KEY=""
ARG GOOGLE_API_KEY=""
ENV DASHSCOPE_API_KEY=${DASHSCOPE_API_KEY} \
    GOOGLE_API_KEY=${GOOGLE_API_KEY} \
    DASHSCOPE_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1 \
    CONVERSATION_LLM_PROVIDER=qwen \
    STT_PROVIDER=qwen \
    QWEN_MODEL=qwen3-vl-flash \
    VLM_MODEL=gemini-2.5-flash \
    CONVERSATION_VLM_MODEL=gemini-2.5-flash-lite

ENV OMAKASE_API_URL=https://www.omakase.ai \
    OMAKASE_IN_CONTAINER=1 \
    OMAKASE_SKIP_HOST_SETUP=1
VOLUME ["/var/lib/omakase"]
CMD ["./start.sh"]
