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
