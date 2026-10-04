#!/usr/bin/env bash
# Automates the Vault-in-Docker setup described in .claude/skills/vault-docker-setup/SKILL.md
# Usage: ./setup.sh [all|dirs|certs|trust|hosts|up|init|unseal|status|test|reset]
# Idempotent: existing certs / trust / hosts entries / init state are left alone.
set -euo pipefail

cd "$(dirname "$0")"
HOST=vault.test.lan
CONTAINER=vault-new
TLS=vault/userconfig/tls
PKI=vault/pki
INIT_FILE=$PKI/vault-init.json   # dev only; folder is gitignored, never mounted

log() { printf '\n==> %s\n' "$*"; }

dirs() {
  log "Creating folder structure"
  mkdir -p vault/{audit,config,data,file,logs,plugins} "$TLS" "$PKI"
  if [ ! -f vault/config/vault-config.hcl ]; then
    cat > vault/config/vault-config.hcl <<'HCL'
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
HCL
  fi
}

certs() {
  log "Creating CA and server certificate"
  [ -f vault_cert.conf ] || { echo "vault_cert.conf not found"; exit 1; }
  if [ -f "$TLS/vault.crt" ] && openssl verify -CAfile "$TLS/ca.crt" "$TLS/vault.crt" >/dev/null 2>&1 \
     && openssl x509 -in "$TLS/vault.crt" -noout -checkend 2592000 >/dev/null; then
    echo "Valid certs already exist (>30 days left), skipping. Delete $TLS/*.crt to regenerate."
    return
  fi
  if [ ! -f "$PKI/ca.key" ] || [ ! -f "$TLS/ca.crt" ]; then
    openssl genrsa -out "$PKI/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$PKI/ca.key" -sha256 -days 3650 \
      -subj "/CN=Vault Local Root CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -out "$TLS/ca.crt"
  fi
  openssl genrsa -out "$TLS/vault.key" 2048 2>/dev/null
  openssl req -new -key "$TLS/vault.key" -config vault_cert.conf -out "$PKI/vault.csr"
  openssl x509 -req -in "$PKI/vault.csr" -CA "$TLS/ca.crt" -CAkey "$PKI/ca.key" \
    -CAcreateserial -out "$TLS/vault.crt" -days 825 -sha256 \
    -extfile vault_cert.conf -extensions v3_req
  cat "$TLS/ca.crt" >> "$TLS/vault.crt"
  chmod 644 "$TLS"/*; chmod 600 "$PKI/ca.key"
  openssl verify -CAfile "$TLS/ca.crt" "$TLS/vault.crt"
}

trust() {
  log "Trusting CA on the system (sudo may prompt)"
  case "$(uname)" in
    Darwin)
      if security verify-cert -c "$TLS/ca.crt" >/dev/null 2>&1; then
        echo "CA already trusted"
      else
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$TLS/ca.crt"
      fi ;;
    Linux)
      sudo cp "$TLS/ca.crt" /usr/local/share/ca-certificates/vault-local-ca.crt
      sudo update-ca-certificates ;;
    *) echo "Unsupported OS: trust the CA manually"; return 1 ;;
  esac
}

hosts() {
  log "Ensuring /etc/hosts entry for $HOST"
  if grep -qE "^[^#]*[[:space:]]$HOST([[:space:]]|$)" /etc/hosts; then
    echo "Already present"
  else
    echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts >/dev/null
  fi
}

up() {
  log "Starting container"
  docker info >/dev/null 2>&1 || { echo "Docker is not running. Start Docker Desktop."; exit 1; }
  docker compose config -q
  docker compose up -d
  for _ in $(seq 1 30); do
    # any HTTP response (200/429/472/501/503) means the listener is up
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$TLS/ca.crt" \
           --resolve "$HOST:443:127.0.0.1" "https://$HOST/v1/sys/health" || true)
    [ "$code" != "000" ] && { echo "Vault is answering (HTTP $code)"; return; }
    sleep 1
  done
  echo "Vault did not come up; see: docker compose logs vault"; exit 1
}

is_initialized() { docker exec "$CONTAINER" vault status -format=json 2>/dev/null | grep -q '"initialized": true'; }
is_sealed()      { docker exec "$CONTAINER" vault status -format=json 2>/dev/null | grep -q '"sealed": true'; }

init() {
  log "Initializing Vault (1 share / 1 threshold, dev only)"
  if is_initialized; then echo "Already initialized"; return; fi
  ( umask 077; docker exec "$CONTAINER" vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_FILE" )
  chmod 600 "$INIT_FILE"
  echo "Unseal key and root token saved to $INIT_FILE (chmod 600, gitignored)."
  echo "Back it up somewhere safe; losing it means losing access to all secrets."
}

unseal() {
  log "Unsealing Vault"
  if ! is_sealed; then echo "Already unsealed"; return; fi
  if [ -f "$INIT_FILE" ]; then
    key=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["unseal_keys_b64"][0])' "$INIT_FILE")
    docker exec "$CONTAINER" vault operator unseal "$key" >/dev/null
  else
    docker exec -it "$CONTAINER" vault operator unseal
  fi
  is_sealed && { echo "Still sealed"; exit 1; } || echo "Unsealed"
}

status() {
  log "Status"
  docker exec "$CONTAINER" vault status || true
  curl -sS -o /dev/null -w "health http=%{http_code} ssl_verify=%{ssl_verify_result}\n" "https://$HOST/v1/sys/health" || true
}

test_kv() {
  log "KV round-trip test"
  if [ -f "$INIT_FILE" ]; then
    VAULT_TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' "$INIT_FILE")
    export VAULT_TOKEN
  fi
  command -v vault >/dev/null || { echo "vault CLI not installed on host (brew install hashicorp/tap/vault)"; return 1; }
  export VAULT_ADDR="https://$HOST"
  vault secrets list | grep -q '^secret/' || vault secrets enable -path=secret kv-v2
  vault kv put -mount=secret setup-test hello=world >/dev/null
  [ "$(vault kv get -mount=secret -field=hello setup-test)" = "world" ] && echo "PASS: secret written and read back over trusted TLS"
  vault kv metadata delete -mount=secret setup-test >/dev/null
}

reset() {
  read -r -p "This DELETES all Vault data and the saved init keys. Type 'yes': " a
  [ "$a" = yes ] || { echo "Aborted"; exit 1; }
  docker compose down
  rm -rf vault/data/* vault/file/* "$INIT_FILE"
}

case "${1:-all}" in
  all)    dirs; certs; trust; hosts; up; init; unseal; status; test_kv ;;
  dirs|certs|trust|hosts|up|init|unseal|status|reset) "$1" ;;
  test)   test_kv ;;
  *) sed -n '2,3p' "$0"; exit 1 ;;
esac
