# OpenClaw + bb-cc-proxy, running side-by-side inside one container so the CLI
# transparently talks to the confidential encrypted model endpoint.
#
#   docker build -t openclaw-enc ./openclaw    (from repo root)
#   docker compose run --rm openclaw
#
# The container:
#   1. starts bb-cc-proxy on 127.0.0.1:8080 pointed at the confidential enclave
#   2. waits for the proxy's /health to come up (attestation + ECDH done)
#   3. execs `openclaw` (default: `openclaw agent`) with a pre-baked config
#      that treats http://127.0.0.1:8080/v1 as an OpenAI-compatible provider

FROM node:24-bookworm-slim

# --- system deps: Python 3 for the proxy, curl for the healthcheck --------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv curl ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# --- install bb-cc-proxy ---------------------------------------------------
# Cloned from its upstream repo at build time. Pin a specific version via
# --build-arg BB_CC_PROXY_REF=<branch|tag|sha>.
ARG BB_CC_PROXY_REPO=https://github.com/blackboxai-dev/bb-cc-proxy.git
ARG BB_CC_PROXY_REF=main
RUN git clone "${BB_CC_PROXY_REPO}" /opt/bb-cc-proxy \
 && cd /opt/bb-cc-proxy && git checkout "${BB_CC_PROXY_REF}"
WORKDIR /opt/bb-cc-proxy
RUN python3 -m venv /opt/bb-cc-proxy/.venv \
 && /opt/bb-cc-proxy/.venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/bb-cc-proxy/.venv/bin/pip install --no-cache-dir . \
 && ln -s /opt/bb-cc-proxy/.venv/bin/bb-cc-proxy /usr/local/bin/bb-cc-proxy

# --- install openclaw ------------------------------------------------------
RUN npm install -g openclaw@latest \
 && openclaw --version || true

# --- pre-baked openclaw config --------------------------------------------
# Points OpenClaw at the local proxy. Written into the workspace-owning user's
# home so `openclaw` picks it up automatically.
RUN mkdir -p /root/.openclaw
COPY openclaw/openclaw.json /root/.openclaw/openclaw.json

# --- entrypoint ------------------------------------------------------------
COPY openclaw/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default env; overridden by docker-compose / --env
ENV PROXY_HOST=127.0.0.1 \
    PROXY_PORT=8080 \
    ENC_MODEL_URL=https://{organisation}.blackbox.ai \
    ENC_MODEL_ID=google/gemma-4-31b-it

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default drops you into a shell with the proxy running in the background.
# From there, run e.g.:
#   openclaw agent --local --session-key poc:test --message "hi"
#   openclaw chat
#   curl -s http://127.0.0.1:8080/v1/chat/completions -d '...'
CMD ["bash"]
