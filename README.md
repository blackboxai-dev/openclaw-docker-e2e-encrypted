# OpenClaw × BLACKBOX AI Encrypted Model — Docker POC

Run [OpenClaw](https://www.npmjs.com/package/openclaw) inside Docker, talking
transparently to a BLACKBOX AI **confidential / end-to-end-encrypted** model
endpoint through a local decrypting proxy — same UX as pointing OpenClaw at
`api.openai.com`, but every byte on the wire is AES-256-GCM sealed into a
GPU-attested enclave.

```
┌──────────────────────────── container ────────────────────────────┐
│                                                                    │
│   openclaw  ──► http://127.0.0.1:8080/v1  (plain OpenAI JSON)      │
│                        │                                           │
│                        ▼                                           │
│                bb-cc-proxy                                         │
│                        │   ECDH + AES-256-GCM                      │
└────────────────────────┼───────────────────────────────────────────┘
                         │
                         ▼
    https://{organisation}.blackbox.ai/enc/{provider}/{model}/{attestation,message,message_stream}
                         │
                         ▼
                 GPU enclave · vLLM
```

## One-command run

```bash
# 1. drop your org host (and optionally an API key) in .env
cp .env.example .env
$EDITOR .env      # set ENC_MODEL_URL=https://{your-org}.blackbox.ai
                  # optionally set BLACKBOX_API_KEY=sk-...
                  # (or leave it out and let each client supply its own key)

# 2. build
docker compose build openclaw

# 3. one-shot smoke test (recommended first run)
docker compose run --rm openclaw \
  openclaw agent --local --session-key poc:smoketest \
  --message "In one sentence, what model are you?"

# expected tail of output:
#   [provider-transport-fetch] start provider=bbenc … model=google/gemma-4-31b-it
#   POST /v1/chat/completions HTTP/1.1  200
#   Hello! I'm using the bbenc/google/gemma-4-31b-it model.
#   [agent] run … ended with stopReason=stop

# 4. interactive chat (default CMD)
docker compose run --rm openclaw
#   or drop into the container for debugging:
docker compose run --rm openclaw bash
```

Behind the scenes the container's entrypoint:

1. Starts `bb-cc-proxy --enc-endpoint $ENC_MODEL_URL --model $ENC_MODEL_ID`.
2. That performs `GET /enc/.../attestation`, does the ECDH key exchange, and
   binds the returned `session_id`.
3. Waits for `http://127.0.0.1:8080/health` to report ok.
4. Execs `openclaw` with a pre-baked `~/.openclaw/openclaw.json` that treats
   `http://127.0.0.1:8080/v1` as a normal OpenAI-compatible provider named
   `bbenc`.

OpenClaw's requests are OpenAI-shaped; the proxy converts each one into an
encrypted `/message` (or `/message_stream`) call and returns an OpenAI
`chat.completion` (or SSE stream) with the decrypted reply.

## Configuration

| Env var                | Default                                       | Purpose                                                  |
| ---------------------- | --------------------------------------------- | -------------------------------------------------------- |
| `ENC_MODEL_URL`        | `https://{organisation}.blackbox.ai`          | **Required.** Your org's confidential-compute host       |
| `ENC_MODEL_ID`         | `google/gemma-4-31b-it`                       | `provider/model` under `/enc/…`                          |
| `BLACKBOX_API_KEY`     | *(optional)*                                  | Default upstream bearer (used when client sends no key)  |
| `PROXY_PORT`           | `8080`                                        | Local port OpenClaw / other clients talk to              |
| `PASSTHROUGH_API_KEY`  | `1`                                           | `1` = forward client's `Authorization` header upstream; `0` = always use `BLACKBOX_API_KEY` |

### BYO API key (pass-through mode)

By default (`PASSTHROUGH_API_KEY=1`) the proxy forwards each caller's
`Authorization: Bearer <sk-...>` header **verbatim** upstream to the enclave —
so multiple users on the same proxy each use their own key end-to-end, and no
key needs to be baked into the image or `.env`.

```bash
# no BLACKBOX_API_KEY in .env — every request must supply its own:
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-YOUR-OWN-KEY' \
  -d '{"model":"google/gemma-4-31b-it",
       "messages":[{"role":"user","content":"hello"}]}'
```

Resolution order (per request): client `Authorization` header → client
`x-api-key` header → `BLACKBOX_API_KEY` default → `401`.

The pre-baked OpenClaw config lives at
[`openclaw/openclaw.json`](openclaw/openclaw.json) and is copied to
`/root/.openclaw/openclaw.json` inside the image. If you change the model, edit
both the env var **and** the model id in that JSON.

## Testing without Docker

You can exercise the exact same proxy on your host:

```bash
git clone https://github.com/blackboxai-dev/bb-cc-proxy.git
cd bb-cc-proxy
python3 -m venv .venv && .venv/bin/pip install -e .
BLACKBOX_API_KEY=sk-... .venv/bin/bb-cc-proxy \
  --enc-endpoint https://{organisation}.blackbox.ai \
  --model        google/gemma-4-31b-it \
  --insecure-skip-attestation

# in another terminal:
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-YOUR-KEY' \
  -d '{"model":"google/gemma-4-31b-it",
       "messages":[{"role":"user","content":"hello"}]}'
```

## Security notes

* **Attestation verification is disabled for this POC** (the public `/enc/…`
  attestation report layout differs from what the proxy's verifier was written
  for). The ECDH handshake and AES-GCM sealing still run — traffic between the
  proxy and the enclave stays end-to-end encrypted — but you are **not**
  cryptographically verifying that the far end is a real confidential GPU.
  Adding a public-endpoint attestation verifier is the natural next step; see
  the WARNING logged on startup and `cc_proxy/crypto.py`.
* The proxy holds the AES session key and sees plaintext. Run it only on a
  trusted machine (the container counts as your trust boundary here).
* `BLACKBOX_API_KEY` is read from your `.env` and passed into the container as
  an environment variable — never bake it into an image or commit it.

## Repo layout

```
.
├── openclaw/
│   ├── Dockerfile          # Node 24 + Python 3, both CLIs pre-installed
│   ├── entrypoint.sh       # starts proxy, waits for /health, execs openclaw
│   └── openclaw.json       # pre-baked config: bbenc provider → 127.0.0.1:8080
├── docker-compose.yml
├── .env.example
└── encrypted-model.md      # BLACKBOX AI encrypted-model API reference
```

The decrypting proxy (`bb-cc-proxy`) is cloned into the image at build time
from https://github.com/blackboxai-dev/bb-cc-proxy — pin a specific version
with `BB_CC_PROXY_REF=<sha|tag|branch> docker compose build openclaw`.
