# HashiCorp Vault on Docker Desktop

A local HashiCorp Vault running in Docker, served over TLS at `https://vault.test.lan` with a certificate signed by a local root CA that the host trusts.

See [docs/design.md](docs/design.md) for the architecture.

## Prerequisites
- Docker Desktop (running), with the workspace under a shared path (`/Users` by default)
- `openssl` (macOS ships LibreSSL; either works), `curl`, `python3`
- Optional: Vault CLI on the host (`brew install hashicorp/tap/vault`)
- `sudo` rights, to trust the CA and edit `/etc/hosts`
- Port 443 free on the host

## Quick start
Run in a regular Terminal (`sudo` needs a tty):
```bash
./setup.sh
```
This creates folders, certs, trusts the CA, adds the hosts entry, starts the container, initializes and unseals Vault, and runs a KV test. Then open <https://vault.test.lan>.

Individual steps: `./setup.sh <dirs|certs|trust|hosts|up|init|unseal|status|test|reset>`.

## Daily use
| Task | Command |
|---|---|
| Start | `docker compose up -d` |
| Unseal (needed after every restart) | `./setup.sh unseal` |
| Status | `./setup.sh status` |
| Logs | `docker compose logs -f vault` |
| Stop | `docker compose down` |
| Wipe all data | `./setup.sh reset` |

CLI access:
```bash
export VAULT_ADDR=https://vault.test.lan
vault login
vault kv put -mount=secret demo hello=world
vault kv get -mount=secret demo
```

## Layout
```
.
├── docker-compose.yml        # Vault service (Docker Desktop)
├── vault_cert.conf           # CN/SAN/usage for the server cert
├── setup.sh                  # Automated, idempotent setup
├── docs/design.md            # Architecture / design
├── .claude/skills/vault-docker-setup/SKILL.md   # Step-by-step skill
└── vault/                    # Created by setup.sh (mostly gitignored)
    ├── config/vault-config.hcl
    ├── userconfig/tls/       # ca.crt, vault.crt (chain), vault.key
    ├── pki/                  # ca.key, CSR, vault-init.json (never mounted)
    └── data, file, logs, audit, plugins
```

## Security notes
- This is a **local dev** setup: one unseal key share, file storage, and a root token.
- `setup.sh init` saves the unseal key and root token to `vault/pki/vault-init.json` (chmod 600, gitignored). Back it up, or delete it and unseal manually.
- Keys, certs, `vault/pki/` and Vault data are in `.gitignore`. Never commit them.
- Use limited-policy tokens for real work; avoid the root token.
- Fresh clones must regenerate certs (`./setup.sh certs`).

## Secret scanning (gitleaks)
GitHub's built-in secret scanning isn't available for private repos on the free plan, so this repo uses [gitleaks](https://github.com/gitleaks/gitleaks):
- **Local pre-commit hook** (blocks the commit if staged changes contain a secret). Enable once per clone:
  ```bash
  brew install gitleaks
  git config core.hooksPath .githooks
  ```
- **GitHub Action** (`.github/workflows/gitleaks.yml`) scans the full history on every push and PR.
- Config in `.gitleaks.toml` (default rules plus Vault tokens `hvs.`/`hvb.`/`hvr.`).
- Manual scans: `gitleaks git .` (history) and `gitleaks dir .` (working tree). The working-tree scan will report `vault/pki/ca.key` and `vault/userconfig/tls/vault.key`; they are gitignored and expected.

## Going to production
This repo is a **dev** setup. Do not run it in prod as is (single node, file storage, one key share, `latest` image, key material on disk). Summary of what changes; details and rationale are in [docs/design.md](docs/design.md#12-production-deployment).

1. **Platform:** 3 or 5 Vault nodes on separate hosts/AZs (VMs or Kubernetes with the official Helm chart), behind a load balancer. Docker Compose on one machine is not HA.
2. **Storage:** Integrated Storage (Raft) instead of `file`, with scheduled `vault operator raft snapshot save` backups stored off-host.
3. **TLS:** certificates from your organization's CA (or ACME), not this local CA. Distribute the real CA to clients. Do not trust the dev CA anywhere else.
4. **Seal:** auto-unseal with a cloud KMS / HSM / transit Vault, so restarts don't need humans. Recovery keys replace unseal keys.
5. **Init:** `vault operator init -key-shares=5 -key-threshold=3`, with each share PGP-encrypted to a different key holder (`-pgp-keys`). Never write keys to disk in plaintext.
6. **Audit:** enable at least two audit devices (file + syslog/socket) *before* anything else. Vault stops serving requests if all audit devices fail, so run more than one.
7. **Identity:** configure an auth method (OIDC/LDAP for humans, AppRole/Kubernetes/cloud IAM for workloads), write least-privilege policies, then **revoke the root token**.
8. **Harden:** pin the image to an exact version (not `latest`), run as non-root, no `privileged`, `mlock` enabled (or swap off), core dumps off, firewall to 8200/8201 only, telemetry to Prometheus, alerts on seal status and audit failures.
9. **Operate:** documented upgrade (standbys first), DR/performance replication if needed (Enterprise), and a tested restore from snapshot.

## Is the root token mandatory?
**No.** It is only needed for the first minutes of setup, and ideally is not kept at all.

- `vault operator init` returns an initial root token. Use it once to enable audit devices, an auth method and admin policies, then run `vault token revoke -self`.
- If you ever need root again (break-glass), generate a short-lived one with a quorum of key holders: `vault operator generate-root`. Use it, then revoke it.
- Day to day, humans and apps use tokens from auth methods with narrow policies and short TTLs.

**How to keep it from leaking**
- Never store it in files, shell history, chat, tickets, CI variables or `~/.vault-token` long term. (In this repo `setup.sh` saves it to `vault/pki/vault-init.json` for dev convenience only. Don't do that in prod.)
- Revoke it right after bootstrap, so a leak is harmless.
- Prefer `generate-root` tokens with a short TTL, issued under a witnessed process (multiple key holders).
- Split trust: PGP-encrypted unseal/recovery shares held by different people, so no one person can produce a root token.
- Turn on audit devices first, and alert on any use of a root-policy token.
- Use `vault login` or `VAULT_TOKEN` from a secure prompt, not on the command line, and clear it after use.
- Use `-format=json` outputs carefully: they print tokens. Don't run them in logged CI steps.
- Rotate: after any suspicion, `vault token revoke` it and, if the unseal/recovery keys were exposed, `vault operator rekey`.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `x509: unknown authority` | Run `./setup.sh trust`, or set `VAULT_CACERT=vault/userconfig/tls/ca.crt` |
| HTTP 503 from health | Vault is sealed: `./setup.sh unseal` |
| HTTP 501 from health | Not initialized: `./setup.sh init` |
| Can't resolve `vault.test.lan` | `./setup.sh hosts` |
| Port 443 in use | Change the mapping to `8443:8200` in `docker-compose.yml` and use `:8443` |
| Container exits at start | `docker compose logs vault` (bad path or unreadable cert/key) |
