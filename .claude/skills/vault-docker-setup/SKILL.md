---
name: vault-docker-setup
description: Set up HashiCorp Vault in Docker Desktop (macOS) with a local self-signed CA and a TLS server cert for vault.test.lan, built from vault_cert.conf. Use when asked to create the Vault folder structure, generate the CA/cert/key, trust the CA on the system, or start/reset/unseal the Vault container.
---

# Vault in Docker Desktop with local CA

All commands run from the **workspace root** (the folder containing `docker-compose.yml` and `vault_cert.conf`). Everything is relative to it; nothing is written to `/vault` on the host.

## 1. Folder structure
```bash
mkdir -p vault/{audit,config,data,file,logs,plugins,userconfig/tls,pki}
```
| Path | Purpose |
|---|---|
| `vault/config/vault-config.hcl` | Vault server config (see step 2) |
| `vault/userconfig/tls/` | `ca.crt`, `vault.crt` (leaf+CA chain), `vault.key`, mounted in container |
| `vault/pki/` | `ca.key`, `vault.csr`. **CA private key stays here; never mounted** |
| `vault/data`, `file`, `logs`, `audit`, `plugins` | Storage / logs / plugins |

## 2. Vault config (`vault/config/vault-config.hcl`)
```hcl
ui            = true
disable_mlock = true

storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/vault/userconfig/tls/vault.crt"
  tls_key_file    = "/vault/userconfig/tls/vault.key"
}

api_addr     = "https://vault.test.lan"
cluster_addr = "https://vault.test.lan:8201"
```

## 3. Create CA, key and certificate
`vault_cert.conf` defines CN `vault.test.lan` and SANs `*.test.lan`, `localhost`, `127.0.0.1`. Its `v3_req` section is used as the extension set when the CA signs the server cert. (A cert that is signed by itself and is not a CA can't be installed as a root CA, so we make a real CA first.)
```bash
cd vault
# 3a. Root CA (10 years)
openssl genrsa -out pki/ca.key 4096
openssl req -x509 -new -nodes -key pki/ca.key -sha256 -days 3650 \
  -subj "/CN=Vault Local Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out userconfig/tls/ca.crt

# 3b. Vault key + CSR (subject/SANs from vault_cert.conf)
openssl genrsa -out userconfig/tls/vault.key 2048
openssl req -new -key userconfig/tls/vault.key -config ../vault_cert.conf -out pki/vault.csr

# 3c. Sign the cert with the CA (825 days; macOS rejects longer for TLS certs)
openssl x509 -req -in pki/vault.csr -CA userconfig/tls/ca.crt -CAkey pki/ca.key \
  -CAcreateserial -out userconfig/tls/vault.crt -days 825 -sha256 \
  -extfile ../vault_cert.conf -extensions v3_req

# 3d. Append CA to make a chain, set permissions
cat userconfig/tls/ca.crt >> userconfig/tls/vault.crt
chmod 644 userconfig/tls/*; chmod 600 pki/ca.key
cd ..

# 3e. Verify
openssl verify -CAfile vault/userconfig/tls/ca.crt vault/userconfig/tls/vault.crt
openssl x509 -in vault/userconfig/tls/vault.crt -noout -ext subjectAltName
```
The `vault.key` must be readable by the container user (uid 100), hence 644 on this local-only dev key.

## 4. Install the CA as a trusted root on the host
Requires admin rights (sudo prompts; if running via Claude Code, ask the user to run it with `! `).

**macOS**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain vault/userconfig/tls/ca.crt
# verify
security verify-cert -c vault/userconfig/tls/ca.crt
# remove later
sudo security delete-certificate -c "Vault Local Root CA" /Library/Keychains/System.keychain
```
**Linux (Debian/Ubuntu)**
```bash
sudo cp vault/userconfig/tls/ca.crt /usr/local/share/ca-certificates/vault-local-ca.crt
sudo update-ca-certificates
```
Firefox uses its own store: import `ca.crt` under Settings > Certificates > Authorities.

**Inside the container**: handled by docker-compose, which mounts `ca.crt` into `/usr/local/share/ca-certificates/` and sets `VAULT_CACERT`.

## 5. Hostname resolution
`vault.test.lan` must resolve to the local machine:
```bash
grep -q vault.test.lan /etc/hosts || echo "127.0.0.1 vault.test.lan" | sudo tee -a /etc/hosts
```

## 6. Run (Docker Desktop must be running)
```bash
docker compose config -q      # validate
docker compose up -d
docker compose ps
docker compose logs -f vault
```
UI/API: `https://vault.test.lan` (host port 443 -> container 8200). Cluster port 8201 is published too.

### Initialize (first run only)
```bash
docker exec vault-new vault operator init -key-shares=1 -key-threshold=1
```
**Save the unseal key and root token somewhere safe**: they are shown only once. 1 share / 1 threshold is for local dev only. Do not paste them into chat or commit them.

### Unseal (first run AND after every container/Docker Desktop restart)
`restart: unless-stopped` brings the container back **sealed**. Unseal with an interactive prompt so the key stays out of shell history:
```bash
docker exec -it vault-new vault operator unseal
```
### Check status
```bash
docker exec vault-new vault status          # expect: Initialized true, Sealed false
curl -sS -o /dev/null -w "http=%{http_code} ssl_verify=%{ssl_verify_result}\n" \
  https://vault.test.lan/v1/sys/health       # expect: http=200 ssl_verify=0
```
HTTP 501 = not initialized, 503 = sealed. `ssl_verify=0` confirms the CA is trusted without `--cacert`.
If `Sealed` stays true after unsealing, the unseal didn't apply (wrong container, restart in between): check `docker ps`, `docker logs vault-new --tail 20`, and unseal again.

### Host CLI / curl
```bash
export VAULT_ADDR=https://vault.test.lan
# Only needed if the CA is not in the system trust store:
export VAULT_CACERT=$PWD/vault/userconfig/tls/ca.crt
curl $VAULT_ADDR/v1/sys/health
```
If `/etc/hosts` is not set yet: add `--resolve vault.test.lan:443:127.0.0.1` to curl.

### Login and KV secret test
Run `vault login` in your own terminal (prompts for the root token, stored in `~/.vault-token`). Never ask the user to paste tokens into chat; the CLI reuses the saved token.
```bash
export VAULT_ADDR=https://vault.test.lan
vault login
vault token lookup                                   # confirm auth
vault secrets list | grep -q '^secret/' || vault secrets enable -path=secret kv-v2
vault kv put -mount=secret test hello=world          # write
vault kv list -mount=secret /                        # expect: test
vault kv get -mount=secret test                      # expect: hello = world
vault kv delete -mount=secret test                   # optional cleanup
```
A successful `kv get` verifies TLS, auth, unseal and storage end to end. For anything beyond testing, create a limited policy/token instead of using the root token.

## 7. Reset / teardown
```bash
docker compose down
rm -rf vault/data/* vault/file/*     # DESTRUCTIVE: wipes all Vault secrets and init state
```

## Changes made to docker-compose.yml (and why)
- `/vault/...` absolute host paths -> `./vault/...`: absolute paths don't exist on macOS and aren't shared with Docker Desktop.
- `vault/userconfig` (no leading `./`) was a named volume that was never declared -> compose error. Now a bind mount.
- Removed `/etc/ssl/certs/ca-certificates.crt` mount: doesn't exist on macOS, and would have replaced the container's trust bundle. The CA is mounted into `/usr/local/share/ca-certificates/` instead.
- Removed `privileged: true`: unnecessary; `IPC_LOCK` plus `disable_mlock` in config is enough.
- Added `VAULT_ADDR=https://127.0.0.1:8200` so `vault` CLI inside the container uses TLS (default is http).
- Added the missing `vault-config.hcl` the command refers to.

## Troubleshooting
- `x509: certificate signed by unknown authority`: CA not trusted, or `VAULT_CACERT` unset.
- `x509: certificate is valid for ... not ...`: hostname isn't in the SANs from `vault_cert.conf`; edit it and redo step 3.
- Container exits at start: `docker compose logs vault` (usually a bad path or unreadable cert/key).
- Port 443 in use: change the mapping to `"8443:8200"` and use `https://vault.test.lan:8443`.

## Automated setup (`setup.sh`)
`./setup.sh` at the workspace root runs steps 1-6 plus the KV test. It is idempotent (skips existing certs, trust, hosts entry, init state).
```bash
./setup.sh            # everything: dirs, certs, trust, hosts, up, init, unseal, status, test
./setup.sh <step>     # one of: dirs certs trust hosts up init unseal status test reset
```
- `trust` and `hosts` use `sudo`, which needs a real terminal. Tell the user to run `./setup.sh` in Terminal (the `!` prefix has no tty).
- `init` saves the unseal key and root token to `vault/pki/vault-init.json` (chmod 600, gitignored, never mounted) so `unseal` and `test` work unattended. Dev convenience only; back it up, and never print or commit it. Delete it and use the interactive unseal for anything beyond local dev.
- After a restart of Docker Desktop, run `./setup.sh unseal`.
- `reset` wipes all Vault data and the saved keys, after a confirmation.

## Secret scanning with gitleaks
GitHub secret scanning isn't available on private repos on the free plan, so the repo uses gitleaks. Files: `.gitleaks.toml` (default rules + Vault tokens `hvs.`/`hvb.`/`hvr.`), `.githooks/pre-commit`, `.github/workflows/gitleaks.yml`.

**Enable on a fresh clone** (hooks and Homebrew installs are not stored in git):
```bash
brew install gitleaks
git config core.hooksPath .githooks
```
**Manual scans**
```bash
gitleaks git . --redact --config .gitleaks.toml    # full git history
gitleaks dir . --redact --config .gitleaks.toml    # working tree incl. gitignored files
```
Expected: the history scan is clean. The working-tree scan reports `vault/pki/ca.key` and `vault/userconfig/tls/vault.key`; they are gitignored and never committed, so that is fine.

**Verify the hook works** (use a realistic token: gitleaks ignores low-entropy fakes like `hvs.AAAA...`):
```bash
printf 'token = hvs.%s\n' "CAESIJx7Kq3mVnT9aBc2LdRfWz8YpHe4UtGsNoXi1QvMbJkE" > leaktest.txt
git add -f leaktest.txt && git commit -m test      # must fail (exit 1)
git reset -q leaktest.txt && rm leaktest.txt
```
Check `git log` afterwards to be sure no test commit landed.

**Limits and response**
- The hook only protects clones that ran the `core.hooksPath` command, and `git commit --no-verify` skips it. CI is the backstop but runs after the push.
- If CI or a scan finds a real secret, treat it as compromised and rotate it (revoke the Vault token, `vault operator rekey` for unseal keys). Deleting the commit is not enough.
- Check CI after a push: `gh run watch --exit-status "$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')"`.
