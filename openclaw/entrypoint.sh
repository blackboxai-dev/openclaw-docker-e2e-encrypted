#!/usr/bin/env bash
# Bootstraps bb-cc-proxy inside the container, waits for it to establish the
# attested + encrypted session, then execs OpenClaw (or whatever CMD was passed).
#
# API-key modes (either or both may be active):
#   1. Baked-in default — set BLACKBOX_API_KEY. Every request without its own
#      Authorization header will use this key upstream.
#   2. Pass-through (default: ON) — the proxy forwards the client's own
#      Authorization: Bearer header upstream verbatim. Set PASSTHROUGH_API_KEY=0
#      to disable and force use of the baked-in default.
#
# Optional env (with defaults):
#   ENC_MODEL_URL         https://{organisation}.blackbox.ai
#   ENC_MODEL_ID          google/gemma-4-31b-it
#   PROXY_HOST            127.0.0.1
#   PROXY_PORT            8080
#   PASSTHROUGH_API_KEY   1  (set to 0 to disable BYO-key forwarding)

set -euo pipefail

PASSTHROUGH_API_KEY="${PASSTHROUGH_API_KEY:-1}"

if [[ -z "${BLACKBOX_API_KEY:-}" && "${PASSTHROUGH_API_KEY}" != "1" ]]; then
  echo "[entrypoint] ERROR: BLACKBOX_API_KEY is not set and PASSTHROUGH_API_KEY is disabled." >&2
  echo "             Either provide a default key (BLACKBOX_API_KEY=sk-...) or" >&2
  echo "             enable BYO-key mode (PASSTHROUGH_API_KEY=1 — the default)." >&2
  exit 2
fi

# --- Template openclaw.json so its `apiKey` field is the real BLACKBOX key ---
# OpenClaw sends its configured apiKey as `Authorization: Bearer <apiKey>` to
# the local proxy. In passthrough mode the proxy forwards that header upstream
# verbatim, so it MUST be a real sk-... key (not the "local" placeholder).
OPENCLAW_CONFIG="/root/.openclaw/openclaw.json"
if [[ -f "${OPENCLAW_CONFIG}" ]]; then
  if [[ -n "${BLACKBOX_API_KEY:-}" ]]; then
    sed -i "s|__BLACKBOX_API_KEY__|${BLACKBOX_API_KEY}|g" "${OPENCLAW_CONFIG}"
  elif grep -q "__BLACKBOX_API_KEY__" "${OPENCLAW_CONFIG}" 2>/dev/null; then
    # No default key configured — leave the placeholder as an obvious marker so
    # OpenClaw fails with a clear "Invalid API key" instead of a silent quirk.
    echo "[entrypoint] NOTE: BLACKBOX_API_KEY not set — OpenClaw's built-in config" >&2
    echo "             will send the literal placeholder upstream and fail auth." >&2
    echo "             Either set BLACKBOX_API_KEY, or edit ~/.openclaw/openclaw.json" >&2
    echo "             to put your real sk-... key in the 'apiKey' field." >&2
  fi
fi

# --- Also template the ENC_MODEL_ID into openclaw.json so the config actually
# matches the runtime model (the compose default is one thing; overriding
# ENC_MODEL_ID at run time should propagate everywhere).
if [[ -f "${OPENCLAW_CONFIG}" && -n "${ENC_MODEL_ID:-}" ]]; then
  sed -i "s|__ENC_MODEL_ID__|${ENC_MODEL_ID}|g" "${OPENCLAW_CONFIG}"
fi

echo "[entrypoint] starting bb-cc-proxy"
echo "[entrypoint]   upstream    : ${ENC_MODEL_URL}/enc/${ENC_MODEL_ID}"
echo "[entrypoint]   local       : http://${PROXY_HOST}:${PROXY_PORT}/v1"
echo "[entrypoint]   passthrough : ${PASSTHROUGH_API_KEY} (1=forward client Authorization header upstream)"
echo "[entrypoint]   default-key : $([[ -n "${BLACKBOX_API_KEY:-}" ]] && echo 'configured (fallback)' || echo 'none')"

# Assemble the proxy command with optional flags.
PROXY_ARGS=(
    --enc-endpoint   "${ENC_MODEL_URL}"
    --model          "${ENC_MODEL_ID}"
    --host           "${PROXY_HOST}"
    --port           "${PROXY_PORT}"
    --insecure-skip-attestation
)
if [[ -n "${BLACKBOX_API_KEY:-}" ]]; then
    PROXY_ARGS+=(--upstream-api-key "${BLACKBOX_API_KEY}")
fi
if [[ "${PASSTHROUGH_API_KEY}" == "1" ]]; then
    PROXY_ARGS+=(--passthrough-api-key)
fi

bb-cc-proxy "${PROXY_ARGS[@]}" &
PROXY_PID=$!
GATEWAY_PID=""

# Ensure background children die if the container is stopped.
cleanup() {
  [[ -n "${GATEWAY_PID}" ]] && kill "${GATEWAY_PID}" 2>/dev/null || true
  kill "${PROXY_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait up to ~30s for the proxy's /health to report ok.
echo -n "[entrypoint] waiting for proxy /health "
for i in $(seq 1 60); do
  if curl -fsS "http://${PROXY_HOST}:${PROXY_PORT}/health" >/dev/null 2>&1; then
    echo "  ready."
    break
  fi
  if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo
    echo "[entrypoint] ERROR: proxy exited before becoming healthy." >&2
    wait "${PROXY_PID}" || true
    exit 1
  fi
  echo -n "."
  sleep 0.5
  if [[ "$i" -eq 60 ]]; then
    echo
    echo "[entrypoint] ERROR: proxy did not become healthy within 30s." >&2
    exit 1
  fi
done

# --- Start OpenClaw Gateway ------------------------------------------------
# Required for non-`--local` commands (agent, chat, crestodian, cron, ...).
#
# Config (openclaw.json) sets gateway.mode=local and gateway.auth.mode=none.
# Inside a container OpenClaw defaults to bind=auto (0.0.0.0) for port-forward
# compatibility and REFUSES to start with auth=none + bind=auto. We force
# --bind loopback so auth=none is safe. Port 18789 is not published to the host
# by default; see docker-compose.yml if you need host access (which requires
# switching to a token/password auth mode).
GATEWAY_LOG="/var/log/openclaw-gateway.log"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
mkdir -p "$(dirname "${GATEWAY_LOG}")"
echo "[entrypoint] starting openclaw gateway (ws://127.0.0.1:${GATEWAY_PORT})"
openclaw gateway run --bind loopback >"${GATEWAY_LOG}" 2>&1 &
GATEWAY_PID=$!

# Wait up to ~15s for the gateway to accept TCP connections on the WS port.
# `openclaw gateway status` exits 0 even when it can't connect, so we probe
# the port directly with bash's /dev/tcp (available in bash 3+).
echo -n "[entrypoint] waiting for gateway "
GATEWAY_READY=0
for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/"${GATEWAY_PORT}") 2>/dev/null; then
    echo "  ready."
    GATEWAY_READY=1
    break
  fi
  if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    echo
    echo "[entrypoint] WARNING: gateway exited before becoming ready." >&2
    echo "[entrypoint] --- last 20 lines of ${GATEWAY_LOG} ---" >&2
    tail -20 "${GATEWAY_LOG}" >&2 || true
    echo "[entrypoint] Continuing without gateway; --local commands still work." >&2
    GATEWAY_PID=""
    break
  fi
  echo -n "."
  sleep 0.5
done
if [[ "${GATEWAY_READY}" -ne 1 && -n "${GATEWAY_PID}" ]]; then
  echo
  echo "[entrypoint] WARNING: gateway did not become ready within 15s." >&2
  echo "[entrypoint] --- last 20 lines of ${GATEWAY_LOG} ---" >&2
  tail -20 "${GATEWAY_LOG}" >&2 || true
  echo "[entrypoint] Continuing; check ${GATEWAY_LOG} for details." >&2
fi

echo "[entrypoint] running: $*"
exec "$@"
