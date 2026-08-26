# Nginx + SSL External Exit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the app's direct host-port exposure with a TLS-terminating nginx reverse proxy on `:8084`, leaving cert files as operator-supplied placeholders.

**Architecture:** New `nginx` service (`nginx:stable-alpine`) in `docker-compose.yml` takes over the external `8084` port, terminates TLS, and proxies to `app:${APP_PORT}` on the internal docker network. The `app` service no longer publishes a port. Nginx config uses the official image's `/etc/nginx/templates/*.template` envsubst mechanism so `${APP_PORT}` in the template is replaced at container start — port changes stay single-source in `.env`.

**Tech Stack:** Docker Compose v2, nginx:stable-alpine (1.28), official nginx envsubst template support, OpenSSL for smoke-test cert generation.

## Global Constraints

- External port remains `8084` (HTTPS only, no HTTP redirect, no port 80 listener).
- `APP_PORT` is the single source of truth for the exposed port, read from `.env`, defaults to `8084`.
- Certificates are **not** auto-generated or auto-renewed; operators supply `fullchain.pem` + `privkey.pem` in `deploy/nginx/certs/`.
- Certificates and private keys MUST NOT be committed to git (`.gitignore` enforced).
- `install.sh`, `docker-compose.single-node.yml`, and other compose variants are **out of scope**.
- All commit messages use Conventional Commits (`feat:`, `fix:`, `docs:`, …) with **no** attribution trailers.

## File Structure

| Action | Path | Responsibility |
|---|---|---|
| Create (new file) | `deploy/nginx/default.conf.template` | nginx server block: TLS termination, upstream proxy to `app:${APP_PORT}`, SSE/WebSocket support |
| Create (new file) | `deploy/nginx/certs/.gitkeep` | Keep cert directory tracked while empty |
| Create (new file) | `deploy/nginx/certs/README.md` | Operator instructions for dropping `fullchain.pem` + `privkey.pem` |
| Modify | `docker-compose.yml` | Add `nginx` service; delete `app.ports` block |
| Modify | `.gitignore` | Append patterns to skip cert files under `deploy/nginx/certs/` |

---

### Task 1: Scaffold certificate placeholder directory

**Files:**
- Create: `deploy/nginx/certs/.gitkeep`
- Create: `deploy/nginx/certs/README.md`

**Interfaces:**
- Consumes: nothing (standalone scaffolding).
- Produces: directory `deploy/nginx/certs/` tracked in git; README instructs operators on expected filenames.

- [ ] **Step 1: Create the placeholder file**

```bash
mkdir -p deploy/nginx/certs
: > deploy/nginx/certs/.gitkeep
```

`.gitkeep` is an empty file; its only purpose is to make the otherwise-empty directory trackable.

- [ ] **Step 2: Create operator README**

Write `deploy/nginx/certs/README.md` with this exact content:

````markdown
# TLS Certificates

This directory is mounted read-only into the `aether-nginx` container at `/etc/nginx/certs/`.

## Required files

| File | Purpose |
|---|---|
| `fullchain.pem` | Server certificate + full chain (no trailing newline required). |
| `privkey.pem` | Private key matching `fullchain.pem`. |

## Usage

1. Place the two files above in this directory.
2. Reload nginx:

   ```bash
   docker compose restart nginx
   ```

3. Verify:

   ```bash
   curl -v https://<host>:8084/ 2>&1 | grep -E 'SSL|subject|issuer'
   ```

## Notes

- Certificates and private keys in this directory are `.gitignore`-ed.
- `fullchain.pem` must include any intermediate CA certs; a bare leaf cert will cause nginx to refuse connections.
- If either file is missing, nginx will fail to start — check `docker compose logs nginx`.
````

- [ ] **Step 3: Verify directory structure**

```bash
ls -la deploy/nginx/certs/
```

Expected output includes `.gitkeep` and `README.md`.

- [ ] **Step 4: Commit**

```bash
git add deploy/nginx/certs/
git commit -m "feat: scaffold nginx TLS certificate placeholder directory"
```

---

### Task 2: Gitignore TLS material

**Files:**
- Modify: `.gitignore` (append-only)

**Interfaces:**
- Consumes: directory path `deploy/nginx/certs/` from Task 1.
- Produces: `.gitignore` entries that prevent accidental commit of any `.pem` / `.key` / `.csr` file dropped into that directory.

- [ ] **Step 1: Inspect existing `.gitignore`**

```bash
cat .gitignore
```

Confirm that cert-file patterns are not already present. If they are, skip to Step 3.

- [ ] **Step 2: Append cert patterns**

Append these lines to the end of `.gitignore`:

```
# TLS certificates (deploy/nginx/certs/)
deploy/nginx/certs/*.pem
deploy/nginx/certs/*.key
deploy/nginx/certs/*.csr
```

Use `>> .gitignore` or a text editor — do **not** overwrite the file.

- [ ] **Step 3: Validate ignore rules**

Generate a throwaway cert file and confirm it's ignored:

```bash
touch deploy/nginx/certs/test.pem
git status --short deploy/nginx/certs/
```

Expected: only `.gitkeep` and `README.md` appear; `test.pem` does not.

Then clean up:

```bash
rm deploy/nginx/certs/test.pem
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore TLS cert files under deploy/nginx/certs/"
```

---

### Task 3: Create nginx config template

**Files:**
- Create: `deploy/nginx/default.conf.template`

**Interfaces:**
- Consumes: `${APP_PORT}` env var (set by `docker-compose.yml` on the `nginx` service).
- Produces: a file that the official `nginx:stable-alpine` image's `docker-entrypoint.sh` will envsubst from `/etc/nginx/templates/*.template` into `/etc/nginx/conf.d/default.conf` at container start.

**Key invariants (verify in code review):**
- `${APP_PORT}` is the **only** `${…}` pattern in the file — the official image substitutes only env vars that are defined on the container, so nginx runtime vars like `$host`, `$remote_addr`, `$http_upgrade` are untouched.
- Template uses `http2 on;` (nginx ≥1.25 syntax; `nginx:stable-alpine` is currently 1.28).
- SSE streaming requires `proxy_buffering off;` and long `proxy_read_timeout`.
- WebSocket upgrade uses the `map $http_upgrade $connection_upgrade` pattern (declared in `http` context, which conf.d files are in).

- [ ] **Step 1: Create the template**

Create `deploy/nginx/default.conf.template` with this exact content:

```nginx
# Nginx reverse-proxy template for the Aether gateway.
# Mounted at /etc/nginx/templates/default.conf.template in the nginx:stable-alpine image.
# ${APP_PORT} is substituted by docker-entrypoint.sh at container start.

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${APP_PORT} ssl;
    http2 on;
    server_name _;

    # --- TLS ---------------------------------------------------------------
    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # --- Request body ------------------------------------------------------
    client_max_body_size 100m;   # large AI prompts / embedding batches

    # --- Upstream proxy ----------------------------------------------------
    location / {
        proxy_pass http://app:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # WebSocket / HTTP upgrade
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # SSE streaming: disable buffering so events flush byte-by-byte.
        proxy_buffering off;
        proxy_cache     off;
        chunked_transfer_encoding on;

        # LLM reasoning models can pause tens of seconds between tokens.
        proxy_connect_timeout 60s;
        proxy_read_timeout    3600s;
        proxy_send_timeout    3600s;
    }
}
```

- [ ] **Step 2: Static syntax check with the nginx image**

Run nginx's own config test against the template (after a one-shot envsubst to substitute `${APP_PORT}`):

```bash
APP_PORT=8084 docker run --rm \
  -v "$PWD/deploy/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
  nginx:stable-alpine \
  sh -c '/docker-entrypoint.sh nginx -T 2>&1 | tail -20'
```

Expected: the final line is `syntax is ok` and `test is successful`. If it says `emerg` or `unknown directive`, fix the template before moving on.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/default.conf.template
git commit -m "feat: add nginx reverse-proxy template for Aether gateway"
```

---

### Task 4: Wire nginx into `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`
  - Delete the `app.ports:` block (currently lines 102–103).
  - Append a new `nginx:` service after the `app:` service.

**Interfaces:**
- Consumes: `deploy/nginx/default.conf.template` (Task 3), `deploy/nginx/certs/` (Task 1).
- Produces: a `nginx` compose service that owns the external port; an `app` service that no longer publishes any port.

**Invariants:**
- The new `nginx.ports` value MUST mirror the existing `${APP_PORT:-8084}:${APP_PORT:-8084}` pattern so `.env` remains the single source of truth.
- `nginx.environment.APP_PORT` MUST be explicitly set (the official nginx image only envsubsts defined env vars).
- Both volumes are mounted `:ro` — nginx never writes to them.

- [ ] **Step 1: Remove the `app` ports block**

Open `docker-compose.yml`. Locate the `app:` service's `ports:` section:

```yaml
    ports:
      - "${APP_PORT:-8084}:${APP_PORT:-8084}"
```

Delete those two lines. The `app:` service now has no `ports:` key — it's still reachable inside the docker network at `app:${APP_PORT}`.

- [ ] **Step 2: Append the `nginx` service**

After the `app:` service block (but before the top-level `volumes:` key), insert:

```yaml
  nginx:
    image: nginx:stable-alpine
    container_name: aether-nginx
    environment:
      APP_PORT: ${APP_PORT:-8084}
    ports:
      - "${APP_PORT:-8084}:${APP_PORT:-8084}"
    volumes:
      - ./deploy/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro
      - ./deploy/nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - app
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "10"
    restart: unless-stopped
```

Indentation: 2-space, same as existing services (`postgres`, `redis`, `mysql`, `app`). The new `nginx:` key sits at the same indent as `app:`.

- [ ] **Step 3: Validate compose syntax**

```bash
docker compose config --quiet
```

Expected: exit 0, no output. If it errors, inspect the reported line and fix.

- [ ] **Step 4: Inspect rendered config**

```bash
docker compose config
```

Expected:
- `app` service has no `ports:` key.
- `nginx` service has `ports: ["8084:8084"]` (default) and two volume mounts.
- `nginx.environment.APP_PORT` is `"8084"` (default) or whatever `.env` sets.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: route external traffic through nginx with TLS termination"
```

---

### Task 5: End-to-end smoke test

**Files:**
- Transient (do not commit): `deploy/nginx/certs/fullchain.pem`, `deploy/nginx/certs/privkey.pem` — generated locally for the test only.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: confidence that the stack starts and the TLS proxy path works; no new committed files.

**Invariants:**
- The test cert MUST be removed after the test — cert files are `.gitignore`-ed but the operator's real certs will go here.
- The `app` service must actually be reachable through the nginx proxy, not just that nginx starts.

- [ ] **Step 1: Generate a throwaway self-signed cert**

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout deploy/nginx/certs/privkey.pem \
  -out    deploy/nginx/certs/fullchain.pem \
  -subj '/CN=localhost'
```

- [ ] **Step 2: Bring up just `app` + `nginx`**

```bash
docker compose up -d postgres redis app nginx
```

Wait until both `postgres` and `redis` healthchecks pass, then:

```bash
docker compose ps
```

Expected: all four services `Up`. If `nginx` restarts in a loop, check:

```bash
docker compose logs --tail 50 nginx
```

Common failure modes:
- `no "ssl_certificate"` — template wasn't envsubstituted; check volume mount.
- `no resolver defined to resolve app` — `depends_on: app` should have ensured the container exists; restart nginx.
- `SSL_CTX_use_certificate` — cert file unreadable; check it's at `deploy/nginx/certs/fullchain.pem`.

- [ ] **Step 3: Hit the HTTPS endpoint**

```bash
curl -kv https://127.0.0.1:8084/ 2>&1 | head -30
```

Expected:
- `SSL connection using TLSv1.3` (or TLSv1.2).
- HTTP/1.1 200 (or whatever the app's root returns).
- The response body is from the Aether gateway, not nginx's default welcome page.

Also verify the plaintext path is closed:

```bash
curl -v http://127.0.0.1:8084/ 2>&1 | head -5
```

Expected: `Failed to connect` or empty reply — no HTTP listener on 8084.

- [ ] **Step 4: Verify the app's port is no longer published**

```bash
docker compose port app 8084
```

Expected: nothing printed (exit 1). The `app` container has no published ports.

Also confirm the internal path still works from inside the network:

```bash
docker compose exec nginx wget -qO- http://app:8084/ 2>&1 | head -3
```

Expected: a response from the app (wget exits 0 with body).

- [ ] **Step 5: Tear down and clean up**

```bash
docker compose down
rm deploy/nginx/certs/fullchain.pem deploy/nginx/certs/privkey.pem
```

Confirm nothing is staged:

```bash
git status --short
```

Expected: only the `.gitkeep` and `README.md` remain in `deploy/nginx/certs/`. The test certs are gone and `.gitignore` prevented them from appearing.

- [ ] **Step 6: Final commit (only if any unexpected file was touched)**

Normally this task has **nothing to commit** — smoke test files are transient. Only commit if a fix was required during the test (e.g., template tweak discovered in Step 2).

---

## Self-Review Checklist (implementer)

Before declaring the plan complete, the implementer should verify:

1. `docker compose config` passes with no warnings.
2. `docker compose up -d postgres redis app nginx` starts all four services cleanly.
3. `curl -k https://127.0.0.1:8084/` returns the Aether gateway response over TLS.
4. `curl http://127.0.0.1:8084/` does **not** connect.
5. `git ls-files deploy/nginx/certs/` shows only `.gitkeep` and `README.md`.
6. `.env` changes to `APP_PORT` propagate to both compose and nginx (verified by re-running `docker compose config`).
7. Commit history is clean conventional-commits, no attribution trailers.










