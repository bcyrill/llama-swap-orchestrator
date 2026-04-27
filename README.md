# llama-swap with vLLM, SGLang, and llama.cpp on rootful Podman

A working setup for running [llama-swap] on a Linux + NVIDIA host where
every model backend runs as a rootful Podman container with a
**dedicated subuid range per model**, gated by an allowlist-only
[podman-socket-proxy] in front of the rootful podman API socket.

The orchestrator (llama-swap) runs in its own Quadlet-managed
container. It cannot pull arbitrary images, run privileged containers,
mount `/etc/shadow`, or do anything outside the policy in
[`socket-proxy/config.yaml`](socket-proxy/config.yaml). A compromise of
the orchestrator process is bounded by exactly that policy, not by
"root on the host."

[llama-swap]: https://github.com/mostlygeek/llama-swap
[podman-socket-proxy]: https://github.com/bcyrill/podman-socket-proxy

## Accuracy notice

This project — code, Containerfiles, Quadlets, scripts, the
socket-proxy policy YAML, and this documentation — was created with
substantial assistance from [Anthropic's Claude]. LLM-generated work
can carry inaccuracies, subtle logic errors, and stale assumptions
about upstream behaviour (podman protocol quirks, wire shapes, edge
cases the test suite doesn't reach).

[Anthropic's Claude]: https://www.anthropic.com/claude

The socket-proxy is a security boundary. A permissive misconfiguration
hands the orchestrator more privilege than intended; a wrong
assumption baked into a body decoder lets through something the
operator believes is denied. **Before deploying this in front of a
production rootful podman socket, validate it independently.** That
means at minimum:

- Read [`socket-proxy/config.yaml`](socket-proxy/config.yaml) and
  confirm every `endpoints:` entry, the `body_policies` /
  `pull_policies` rules, and each allowlist matches your threat
  model. The shipped policy is exactly what llama-swap's commands in
  [`llama-swap/config.yaml`](llama-swap/config.yaml) need — nothing
  more — but the surface it permits (three model images, a single
  bind-source prefix, the NVIDIA CDI device, `--ipc=host`,
  `--security-opt=label=disable`) is yours to accept.
- Read the upstream
  [podman-socket-proxy](https://github.com/bcyrill/podman-socket-proxy)
  README, especially its own "Accuracy notice." That project is the
  parser doing the actual gating, and it carries the same caveats
  about LLM authorship.
- Exercise the stack end-to-end against the real podman version you
  intend to run. Watch the proxy log; any 403 you didn't expect is
  either a legitimate gating decision or a policy mistake — both
  deserve attention before going live. The included
  `scripts/dev-stack.sh` makes a rootless dry-run cheap.
- Re-run the upstream proxy's
  `scripts/audit/apiv2-coverage.sh` on every podman upgrade. Podman
  occasionally adds top-level fields to the libpod create body; the
  proxy's strict `DisallowUnknownFields` will fail closed (good), but
  you'll need a rebuild to recognise the new field.
- Treat the validate-script + 12-case end-to-end smoke test the repo
  ships as a starting point, not as proof of safety. They catch the
  obvious shapes, not every possible malicious body. A real audit
  walks every field of `libpodCreateRequest` against the threat
  model.

If something here doesn't match the production posture you want,
edit the policy and re-run `./scripts/validate-proxy-config.sh`
before pushing it live. Report mistakes as issues; tightening the
allowlist in response to a real deny log is exactly the workflow
this is designed for.

## What runs where

```
              ┌────────────────────────────┐
   external ─▶│  Traefik (TLS, :443)       │
              └─────────────┬──────────────┘
                            │ http :9292   (traefik-internal network)
                            ▼
              ┌────────────────────────────┐
              │  llama-swap                │  chooses + (un)loads models
              │  (Quadlet container)       │
              │  host UID 900000-965535    │  ← UidMap=, no host root
              └─────────────┬──────────────┘
                            │ unix socket (named volume; mode 0666)
                            ▼
              ┌────────────────────────────┐
              │  podman-socket-proxy       │  allowlist gate, default-deny
              │  (Quadlet container)       │
              │  host UID 0 (compensated   │  ← only piece needing host root,
              │   by ReadOnly, NoNewPrivs, │    so we keep the surface tiny
              │   DropCapability=ALL)      │
              └─────────────┬──────────────┘
                            │ /run/podman/podman.sock (rootful)
                            ▼
              ┌────────────────────────────┐
              │  host podman daemon        │  spawns model containers as
              └─────────────┬──────────────┘  siblings, each with its own
                            │                  UID range (--uidmap …)
                            ▼
   llamacpp-qwen2.5-7b   vllm-llama3.1-8b   sglang-qwen2.5-14b   llamacpp-bge-reranker
   (UID 500000-565535)   (UID 700000-…)     (UID 800000-…)        (UID 600000-…)
                            │
                            │  http on llama-swap-internal network
                            │  (DNS name = model id, e.g. http://vllm-llama3.1-8b:8000)
                            ▼
                     llama-swap proxies HTTP back to the caller
```

The orchestrator runs under its own UID range too (900000–965535) —
without the proxy that wouldn't be possible (the rootful podman socket
is `0660 root:root`), but with the proxy in the loop llama-swap only
needs to reach the proxy's listen socket, not the rootful API socket.
Host root is concentrated on the proxy alone, which is a much smaller
surface to keep privileged.

| Container               | Host UID range  |
|-------------------------|-----------------|
| `llama-swap` (orchestrator) | 900000 – 965535 |
| `llamacpp-qwen2.5-7b`   | 500000 – 565535 |
| `llamacpp-bge-reranker` | 600000 – 665535 |
| `vllm-llama3.1-8b`      | 700000 – 765535 |
| `sglang-qwen2.5-14b`    | 800000 – 865535 |
| `podman-socket-proxy`   | 0 (host root, by necessity) |

`scripts/uid-ranges.env` is the single source of truth for the
orchestrator + model rows. Edit it (and the matching `UidMap=` /
`--uidmap` / `--gidmap` lines in `llama-swap/llama-swap.container` and
`llama-swap/config.yaml`) to slot these around your existing services.

## Threat model: why the socket proxy?

Without the proxy, the orchestrator container needs the host's rootful
`/run/podman/podman.sock` bind-mounted in. That gives it unconditional
access to every podman API: pulling arbitrary images, running
privileged containers, mounting any path on the host, attaching to
other people's pods, etc. A compromise of the llama-swap process is,
at that point, indistinguishable from full root on the box.

The proxy turns that into a default-deny allowlist. It parses every
HTTP request the orchestrator sends and:

- refuses anything outside a small list of `(method, path)` pairs;
- decodes the `POST /libpod/containers/create` body as a podman
  SpecGenerator and rejects fields outside the policy
  (`privileged: true`, `cap_add: [SYS_ADMIN]`, `mounts: [/etc/shadow]`,
  any image not on the allowlist, `--network host`, …).

The blast radius drops from "root on the host" to "the four model
containers llama-swap is already configured to run." If a future
release of llama-swap adds a new podman call, the proxy denies it and
the operator gets a deny log line — a deliberate signal, not a silent
privilege escalation.

### What the policy allows

The shipped `socket-proxy/config.yaml` lets the llama-swap container
do exactly this and nothing else:

- ping, version, info — what podman-remote calls on every connection;
- list / inspect / get-logs of containers (read-only introspection);
- inspect / exists on images (so podman can decide "is this image
  already local?" before the create call);
- `POST /libpod/containers/create` for one of three exact images:
  - `ghcr.io/ggml-org/llama.cpp:server-cuda`
  - `docker.io/vllm/vllm-openai:latest`
  - `docker.io/lmsysorg/sglang:latest`

  with bind sources confined to `/srv/llama-models` (matches
  `LLAMA_MODELS_DIR` in `.env.example`), the NVIDIA CDI device,
  `--security-opt=label=disable`, the `llama-swap-internal` bridge
  network, and `--ipc=host` for vLLM/SGLang;
- `start`, `stop`, `wait`, `attach`, `resize`, and `DELETE` on those
  containers (the lifecycle calls `podman run --rm` and `podman stop`
  go through).

### What the policy denies (verified end-to-end with a 12-case smoke test)

| Attempt                                | Result          |
|----------------------------------------|-----------------|
| `--privileged`                         | 403             |
| `--cap-add SYS_ADMIN`                  | 403             |
| `--network host`                       | 403             |
| Bind `/etc/shadow:/shadow`             | 403             |
| Image not in the three-entry allowlist | 403             |
| `POST /v1.41/containers/create` (docker-compat) | 403    |
| `POST /libpod/images/pull` for an unlisted image | 403    |
| `POST /libpod/build`                   | 403             |
| Custom seccomp / apparmor profiles     | 403             |
| Anything that touches networks, volumes, secrets, pods, exec, kube, manifests, quadlets, system prune, … | 403 |

## Layout

```
llama_swap_universal/
├── .env.example                     # copy to /etc/llama-swap/llama-swap.env
├── scripts/
│   ├── setup-podman-gpu.sh          # Podman CDI for NVIDIA GPUs (one-shot)
│   ├── pull-images.sh               # pre-pull vllm/sglang/llama.cpp images
│   ├── uid-ranges.env               # single source of truth for per-model UIDs
│   ├── init-cache-dirs.sh           # chown per-model cache subdirs
│   └── validate-proxy-config.sh     # sanity-check socket-proxy/config.yaml
├── llama-swap/
│   ├── Containerfile                # builds the orchestrator image
│   ├── build-image.sh
│   ├── llama-swap-internal.network  # private bridge: orchestrator ↔ models
│   ├── llama-swap.container         # the orchestrator Quadlet
│   └── config.yaml                  # llama-swap policy (model commands)
├── socket-proxy/                    # the API gate in front of podman
│   ├── Containerfile                # builds localhost/podman-socket-proxy:latest
│   ├── build-image.sh               # finds ../../socket_proxy/socket-proxy/
│   ├── config.yaml                  # the allowlist policy
│   ├── podman-socket-proxy.volume   # named volume for the listen socket
│   └── podman-socket-proxy.container
└── README.md                        # this file
```

## Prerequisites

- Linux + NVIDIA GPU with a working driver (`nvidia-smi` runs on the host).
- Podman 4.5+.
- `nvidia-container-toolkit` (provides `nvidia-ctk`).
- A local checkout of the proxy source at `~/Research/socket_proxy/socket-proxy/`
  (override the path with `SOURCE=` when running the proxy's
  `build-image.sh`).
- Root access on the host.

## Deploy

```bash
cd ~/Research/llama_swap_universal
chmod +x scripts/*.sh socket-proxy/build-image.sh llama-swap/build-image.sh

# 1. Host-side prep — GPU CDI + cache dirs.
sudo ./scripts/setup-podman-gpu.sh
sudo install -d -m 0755 /etc/llama-swap
sudo install -m 0640 .env.example /etc/llama-swap/llama-swap.env
sudoedit /etc/llama-swap/llama-swap.env       # set LLAMA_MODELS_DIR + HF_TOKEN
sudo ENV_FILE=/etc/llama-swap/llama-swap.env ./scripts/init-cache-dirs.sh

# 2. Pre-pull model backend images. The proxy will not let llama-swap
#    pull at runtime — that is the point.
sudo ./scripts/pull-images.sh

# 3. Build images.
sudo ./socket-proxy/build-image.sh
sudo ./llama-swap/build-image.sh

# 4. Drop policies + env.
sudo install -d -m 0755 /etc/podman-socket-proxy
sudo install -m 0644 socket-proxy/config.yaml /etc/podman-socket-proxy/config.yaml
sudo install -m 0644 llama-swap/config.yaml      /etc/llama-swap/config.yaml

# 5. Sanity-check the proxy policy before pushing it live.
./scripts/validate-proxy-config.sh

# 6. Drop Quadlets and start.
sudo install -m 0644 socket-proxy/podman-socket-proxy.volume    /etc/containers/systemd/
sudo install -m 0644 socket-proxy/podman-socket-proxy.container /etc/containers/systemd/
sudo install -m 0644 llama-swap/llama-swap-internal.network        /etc/containers/systemd/
sudo install -m 0644 llama-swap/llama-swap.container               /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl enable --now podman.socket
sudo systemctl start podman-socket-proxy.service
sudo systemctl start llama-swap.service

journalctl -u podman-socket-proxy -f &
journalctl -u llama-swap -f
```

You should see the proxy log a `policy compiled: 17 endpoints, 1 body
policy` line within a couple of seconds, followed by silence (no
requests yet). The named volume is created on first reference; verify
with `sudo podman volume ls`. If `journalctl` reports `bind: address
already in use`, the volume's `_data` directory has a stale socket
file — `sudo podman volume rm systemd-podman-socket-proxy` then
restart the unit.

llama-swap is reachable at `http://llama-swap:9292` from anything on
the `traefik-internal` network. Add a Traefik file-provider route
pointing at it.

## Get some models

GGUF for llama.cpp — world-readable, mounted `:ro`:

```bash
sudo huggingface-cli download bartowski/Qwen2.5-7B-Instruct-GGUF \
  Qwen2.5-7B-Instruct-Q5_K_M.gguf \
  --local-dir /srv/llama-models/gguf --local-dir-use-symlinks False
sudo chmod -R a+rX /srv/llama-models/gguf
```

vLLM/SGLang HF cache is populated on first model start. Each model writes
into its own subdir (chowned by `init-cache-dirs.sh`).

## Test it

```bash
# From Traefik or any container on traefik-internal:
curl http://llama-swap:9292/v1/models

curl -sN -H 'Content-Type: application/json' \
  -d '{"model":"llamacpp-qwen2.5-7b","messages":[{"role":"user","content":"Hello!"}]}' \
  http://llama-swap:9292/v1/chat/completions

# Confirm the spawned containers actually dropped privileges:
sudo podman top llamacpp-qwen2.5-7b user pid
# every row should show '500000', not 'root'

# Confirm the proxy is in the loop. Every spawn produces 200/204 lines on
#   /libpod/containers/create + start + attach + wait
# anything outside the policy 403s with the offending field named.
journalctl -u podman-socket-proxy -n 50
```

### Talking to the proxy directly

Useful for sanity-checking the policy from the host without going
through llama-swap:

```bash
# Resolve the volume's underlying directory on the host. The basename
# is whatever Quadlet generated — usually "systemd-podman-socket-proxy".
SOCK="$(sudo podman volume inspect systemd-podman-socket-proxy \
        --format '{{.Mountpoint}}')/podman.sock"

# Ping should work.
sudo curl --unix-socket "$SOCK" http://d/v5.0.0/libpod/_ping
# -> "OK"

# Pull should not.
sudo curl --unix-socket "$SOCK" \
     -X POST 'http://d/v5.0.0/libpod/images/pull?reference=docker.io/library/busybox:latest'
# -> 403, "method/path not allowlisted"
```

## Image pulls and the `podman run` lifecycle

Image pulls run out-of-band before the proxy is in the loop, via
`scripts/pull-images.sh` on the host. That script uses the host's
podman directly, not the proxy.

The proxy does allow `POST /libpod/images/pull`, but **only for the
three listed images**. This isn't a way to enable runtime fetches —
it's a podman 5.x quirk. In modern podman the libpod client uses
`POST /libpod/images/pull` as the *unified* image-resolution endpoint,
parameterised by `?policy=<never|missing|always|newer>`. Even
`podman run --pull=never` round-trips through here with `?policy=never`
to ask the daemon "do you have this image, yes or no?" — no fetch
happens, but the URL still says `/pull`. Denying the endpoint outright
breaks every spawn, even when the image is already local. So we allow
the endpoint and gate it by the same image allowlist the create body
uses (see `pull_policies.llama_swap_pull` in `socket-proxy/config.yaml`).

**Will `podman run` try to update the image at runtime?** No.
`podman run` defaults to `--pull=missing` (only fetch when the image
is absent), so a re-run against an already-local `image:latest` keeps
using the local copy even after the upstream tag has moved. Every
model command in `llama-swap/config.yaml` also passes `--pull=never`
explicitly so the daemon-side resolver short-circuits with "yes I have
it" without checking remote.

**What happens if an image isn't pre-pulled?** With `--pull=never`:

1. `POST /libpod/images/pull?reference=<image>&policy=never` →
   - if the image is on the proxy's allowlist: forwarded to daemon →
     daemon returns 404 because the image isn't local → podman
     surfaces `Error: <ref>: image not known`.
   - if the image is *not* on the allowlist: proxy 403s with
     `image=<ref> not in allowlist`.

The first case is "operator forgot to pre-pull a known model"; the
second is "config drift, the policy hasn't been updated for a new
model." Both fail closed; the deny reason makes which one obvious.

A new model image therefore needs to be pre-pulled before its first
run AND added to the proxy's image allowlist:

```bash
sudo ./scripts/pull-images.sh    # or `sudo podman pull <ref>` for one
# then edit socket-proxy/config.yaml to add the new image to BOTH
# body_policies.llama_swap_create.image.allow AND
# pull_policies.llama_swap_pull.image.allow, and bounce the proxy.
```

Same workflow as before the proxy existed; the proxy just makes the
"forgot to pre-pull" mistake fail closed instead of silently widening
the surface to whatever the runtime pull would have brought.

## Adding a new model

1. Pick a fresh non-overlapping base UID (e.g. `1000000`).
2. Add it to `scripts/uid-ranges.env`.
3. Re-run `sudo ./scripts/init-cache-dirs.sh`.
4. Add the model block to `llama-swap/config.yaml` with matching
   `--uidmap 0:<BASE>:65536 --gidmap 0:<BASE>:65536` and
   `--pull=never`.
5. Add a var letter to `matrix.vars` and update `matrix.sets`.
6. **Add the new image reference to BOTH allowlists in
   `socket-proxy/config.yaml`** — the create body's
   `body_policies.llama_swap_create.image.allow` *and* the pull
   resolver's `pull_policies.llama_swap_pull.image.allow`. Both gates
   have to know about the new image or the spawn 403s. Re-run
   `./scripts/validate-proxy-config.sh` and bounce the proxy:

   ```bash
   sudo install -m 0644 socket-proxy/config.yaml /etc/podman-socket-proxy/config.yaml
   sudo systemctl restart podman-socket-proxy.service
   ```
7. Pre-pull the image: `sudo podman pull <ref>` (or extend
   `scripts/pull-images.sh` and re-run it).
8. `--watch-config` reloads llama-swap automatically.

## Tightening the policy from a deny log

Whenever the proxy logs a 403 for something a caller you trust is
trying to do, the answer is one of:

1. The call belongs in the policy → add the matching `endpoint:` /
   `body:` rule.
2. The call doesn't belong → leave it denied; treat the log line as
   the audit trail.

Common edits as the orchestrator config evolves:

- **Another image.** Append to
  `body_policies.llama_swap_create.image.allow`. Use a digest pin
  (`registry/repo@sha256:*`) for production-grade immutability.
- **A different host model directory.** Append to
  `body_policies.llama_swap_create.binds.allowed_sources` (path is a
  prefix, matched by component — `/srv/llama-models` matches
  `/srv/llama-models/anything` but not `/srv/llama-models-evil`).
- **A new mount option.** Append to `binds.allowed_options`. The
  shipped list (`ro`, `rw`, `Z`, `U`) covers `llama-swap/config.yaml`
  exactly; if you start using `:z` (lower-case shared SELinux relabel)
  or `nosuid`, add them.
- **A new namespace mode.** Append to `namespaces.<name>.allow`.
  Treat any `host` mode with skepticism.
- **A new GPU.** Append to `devices.allow_paths`.

After every edit, re-run the validator, then push it live:

```bash
./scripts/validate-proxy-config.sh
sudo install -m 0644 socket-proxy/config.yaml /etc/podman-socket-proxy/config.yaml
sudo systemctl restart podman-socket-proxy.service
```

The proxy does **not** reload on file change — it re-reads the policy
only at startup.

## Why llama-swap runs under a UID range

The shipped `llama-swap/llama-swap.container` carries
`UIDMap=0:900000:65536` and `GIDMap=0:900000:65536` — the orchestrator's
in-container UID 0 maps to host UID 900000, just like the model
containers map their UID 0 to 500000/600000/700000/800000. This is
*because* the proxy is in the loop:

- Without the proxy, llama-swap had to bind-mount the rootful
  `/run/podman/podman.sock` (mode `0660 root:root`) and so had to run
  as host root.
- With the proxy, llama-swap only needs to reach the proxy's listen
  socket. The proxy is configured with `listen_socket_mode: "0666"`
  so a non-root in-container UID can `connect()`.

Verify after install:

```bash
sudo podman top llama-swap user pid
# every row should show 900000, not root
```

If you want llama-swap back as host root for some reason — e.g. to
debug a privileged operation — drop both `UIDMap=`/`GIDMap=` lines
from `llama-swap/llama-swap.container` and `listen_socket_mode` from
`"0666"` back to `"0660"` in `socket-proxy/config.yaml`, then bounce
both units.

### Why `0666` is fine here

Reachability of the listen socket is gated by *two* things on the
host: the directory the socket lives in, and the socket file's own
mode. With the named-volume layout, the directory is the volume's
underlying `_data` path, e.g.:

```
/var/lib/containers/storage/volumes/systemd-podman-socket-proxy/_data/
```

`/var/lib/containers/storage/` is `0700 root:root` by default on every
podman install we've looked at. Non-root host processes can't even
`stat()` it, let alone the socket inside. The file's mode is therefore
only relevant to processes that *already* have an inode reference to
the socket — in practice, containers whose Quadlet explicitly mounts
the volume in (`Volume=podman-socket-proxy.volume:…`). The mount is
performed by podman/systemd as root before the consumer container
drops privileges, so the consumer never has to traverse the host
directory itself.

What `0666` controls, then, is whether the *consumer container's*
process can `connect()` once it sees the volume-mounted inode. With
`UidMap=0:900000:65536` on `llama-swap.container`, the in-container
UID 0 is host UID 900000, which is not the file owner (root) and not
in the file's group (root), so `0660` denies. `0666` permits the
connect because of the world-rwx bit, but only consumers the operator
deliberately gave a `Volume=` line on the named volume can use it.

## Why the proxy itself runs as root

The host's rootful podman socket is `0660 root:root`. The proxy needs
to `connect()` to it, which requires UID 0 or membership in the root
group. `socket-proxy/podman-socket-proxy.container` runs the proxy as
host UID 0 (no UidMap). It is the *only* container in this stack that
runs as host root — llama-swap and every model container have their
own UID range.

Compensating controls on the proxy Quadlet:

- `ReadOnly=true` — root filesystem is immutable; only `/tmp` (16 MiB
  tmpfs) is writable.
- `NoNewPrivileges=true` — even if a child process did get spawned
  (it doesn't; this is one Go binary), it couldn't gain capabilities.
- `DropCapability=ALL` — `connect()` to a Unix socket and `bind()`
  one on a writable mount need no Linux capability beyond what the
  default user namespace already has.

If you want to drop privilege further on the proxy itself, podman v5.7+
ships a TCP+mTLS service the proxy can sit in front of with a UID
range and no rootful socket access at all — out of scope here.

## Limits and caveats

- **The proxy policy mirrors `llama-swap/config.yaml`.** If you edit the
  orchestrator config to add a `--privileged`, a new image, a different
  `LLAMA_MODELS_DIR`, etc., update `socket-proxy/config.yaml` to match
  — otherwise the new model fails closed at the create step.
- **No image pull, no build, no exec, no networks/volumes/secrets
  writes.** That's the point. Pre-pull images via the host's
  `pull-images.sh`. If you ever want runtime pulls back, add a
  `pull_policies:` block (see the upstream socket-proxy
  `examples/permissive/config.yaml` for a worked example) and reference
  it from a `POST /libpod/images/pull` endpoint.
- **Image names use an exact-match allowlist.** A bare
  `docker.io/vllm/vllm-openai:latest` matches; a digest pin
  (`docker.io/vllm/vllm-openai@sha256:abc…`) doesn't unless you add
  it. For supply-chain hardening, swap each `:tag` entry for the
  digest of the image you've actually inspected.
- **The proxy is upstream-version-sensitive.** Podman occasionally
  adds new top-level fields to the libpod create body. The proxy
  decodes with `DisallowUnknownFields`, so a podman upgrade can start
  denying every create call until the proxy is rebuilt against the
  new wire shape. Re-run the upstream socket-proxy's
  `scripts/audit/apiv2-coverage.sh` on each podman upgrade.
- **The proxy is a security-sensitive component generated with
  substantial LLM assistance** (see the upstream socket-proxy README's
  "Accuracy notice"). The policy here was end-to-end verified with a
  12-case smoke test against representative llama-swap requests, but
  that is not the same as an exhaustive audit. Read every rule before
  trusting it in front of a production rootful socket.

## Troubleshooting

**`Error: invalid argument "0:500000:65536" for "--uidmap"`** — Podman
too old; need 4.5+.

**Container starts but writes fail with EACCES** — per-model cache
subdir wasn't chowned. Re-run `init-cache-dirs.sh`.

**`Error: <ref>: image not known` in llama-swap logs** — image isn't
pre-pulled. Run `sudo podman pull <ref>` (or `scripts/pull-images.sh`).
The proxy denies runtime pulls by design.

**Proxy 403 in `journalctl -u podman-socket-proxy`** — the deny line
names the field that failed. See "Tightening the policy from a deny
log" above for what to do with it.

**Model containers can't be reached by name from llama-swap** — confirm
both the orchestrator and the spawned containers are on
`llama-swap-internal`. `sudo podman network inspect llama-swap-internal`
shows attached containers and resolved IPs.

**`Error: setting up CDI devices: unresolvable CDI devices nvidia.com/gpu=all`** —
re-run `setup-podman-gpu.sh`. CDI specs need regeneration after a
driver upgrade.

**OOM after a model swap** — bump `cmdStop -t 30` → `-t 60`, raise
`healthCheckTimeout`, or lower `--gpu-memory-utilization` /
`--mem-fraction-static`.

**Health check times out** — vLLM/SGLang first-load can JIT-compile
kernels for several minutes. `healthCheckTimeout: 600` is the default
here; raise if needed.

**Proxy logs `bind: address already in use`** — the volume's `_data`
directory has a stale socket file from a previous run. Fix:

```bash
sudo systemctl stop podman-socket-proxy.service
sudo podman volume rm systemd-podman-socket-proxy
sudo systemctl start podman-socket-proxy.service
```

## References

- llama-swap: https://github.com/mostlygeek/llama-swap
- llama-swap config schema: https://raw.githubusercontent.com/mostlygeek/llama-swap/refs/heads/main/config-schema.json
- podman-socket-proxy: https://github.com/bcyrill/podman-socket-proxy
- Podman Quadlet: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- Podman CDI for NVIDIA: https://podman-desktop.io/docs/podman/gpu
