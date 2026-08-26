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
