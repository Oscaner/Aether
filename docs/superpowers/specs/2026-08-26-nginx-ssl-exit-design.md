# Nginx + SSL External Exit Design

- **Date:** 2026-08-26
- **Scope:** `docker-compose.yml` + new `deploy/nginx/` directory (nginx config + cert placeholders)
- **Out of scope:** `install.sh`, `docker-compose.single-node.yml`, other compose variants

## Goal

Replace the app's direct host-port exposure with a TLS-terminating nginx reverse proxy.
The external port remains `8084` (HTTPS). Certificates are placeholder for now and will be supplied later.

## Architecture

```
client ──HTTPS──> host:8084 ──> [nginx container] ──HTTP──> [app container :8084 (internal network only)]
                                        │
                                 deploy/nginx/certs/
                                 (fullchain.pem / privkey.pem)
```

## Changes

### 1. `docker-compose.yml`

- **`app` service:** delete the entire `ports:` block. The app stays on the internal docker network, reachable by service name.
- **Add `nginx` service:**
  - image: `nginx:stable-alpine`
  - container name: `aether-nginx`
  - `environment: APP_PORT: ${APP_PORT:-8084}` — makes `${APP_PORT}` substitutable in the template
  - `ports: ["${APP_PORT:-8084}:${APP_PORT:-8084}"]` — preserves existing host-port semantics
  - volumes:
    - `./deploy/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro`
    - `./deploy/nginx/certs:/etc/nginx/certs:ro`
  - `depends_on: [app]`
  - logging + restart policy matching the existing `app` style
  - no healthcheck (nginx has no dependents)

The official nginx image envsubsts `${VAR}` patterns only against defined container environment variables, so nginx runtime variables (`$host`, `$remote_addr`, etc.) are preserved untouched.

### 2. `deploy/nginx/default.conf.template`

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen ${APP_PORT} ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100m;

    location / {
        proxy_pass http://app:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        # AI gateway specifics
        proxy_buffering    off;           # SSE streaming passthrough
        proxy_read_timeout 3600s;         # long reasoning models may pause
        proxy_send_timeout 3600s;
    }
}
```

Rationale for the AI-gateway-specific directives:
- `proxy_buffering off` ensures server-sent events flush to the client byte-by-byte.
- Long `proxy_read_timeout` / `proxy_send_timeout` keep reasoning-heavy LLM responses alive.
- WebSocket upgrade headers support any future streaming upgrade protocol.
- `client_max_body_size 100m` accommodates large prompts/embedding batches without hitting 413s.

### 3. Certificate placeholders

- `deploy/nginx/certs/.gitkeep` — keeps the directory tracked
- `deploy/nginx/certs/README.md` — instructs operators to drop `fullchain.pem` + `privkey.pem` here, then `docker compose restart nginx`
- `.gitignore`: append entries to prevent accidental cert commits
  ```
  deploy/nginx/certs/*.pem
  deploy/nginx/certs/*.key
  deploy/nginx/certs/*.csr
  ```

Startup behavior: if cert files are missing, nginx exits with a clear error — visible via `docker compose logs nginx`. This is the desired fail-fast behavior for the placeholder phase; once real certs land in the directory the container starts normally.

### 4. `install.sh` compatibility

Not modified in this iteration. `install.sh` reads `APP_PORT` from `.env` and prints informational URLs — the external-port semantics don't change, so existing messages remain accurate. Call out in follow-up work if install messages should reference HTTPS explicitly.

## Verification

1. `docker compose config` — YAML + env-substitution sanity check.
2. Smoke test with a throwaway self-signed cert (generated locally, never committed):
   ```bash
   openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
     -keyout deploy/nginx/certs/privkey.pem \
     -out    deploy/nginx/certs/fullchain.pem \
     -subj '/CN=localhost'
   docker compose up -d nginx
   curl -k https://127.0.0.1:8084/    # expect app response, not 502/connection error
   ```
3. `docker compose logs nginx` — should show the envsubstituted `listen 8084 ssl;` and no warnings.

## Risks & trade-offs

- **Cert-less start fails:** intentional fail-fast. Mitigated by README.
- **Single-port HTTPS, no 80 redirect:** user-confirmed choice. If Let's Encrypt HTTP-01 is needed later, port 80 will need to be opened; out of scope today.
- **Static config:** no dynamic server_name or multi-domain support. The placeholder is for a single TLS endpoint; multi-tenant / multi-domain can be layered on later by extending the template.
- **No cert auto-renewal:** user plans to supply certs manually for now. Certbot / ACME integration is a separate change.

## Non-goals

- HTTP-to-HTTPS redirect (no port 80 listener).
- Let's Encrypt / ACME integration.
- Changes to `install.sh`, `docker-compose.single-node.yml`, or other compose variants.
- Cert generation or renewal automation.
