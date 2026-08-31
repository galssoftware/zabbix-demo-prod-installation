#!/usr/bin/env bash
set -euo pipefail

umask 077

OUT="${1:-$PWD/gals-pki}"
mkdir -p "$OUT"/{ca,certs,private,csr}

CA_KEY="$OUT/ca/internal-ca.key"
CA_CERT="$OUT/ca/internal-ca.crt"

# Keep an existing CA when the script is run again to add or renew leaf
# certificates. Replacing it silently would invalidate every deployed
# certificate in the environment.
if [[ -f "$CA_KEY" && -f "$CA_CERT" ]]; then
  echo "Reusing existing CA: $CA_CERT"
elif [[ ! -e "$CA_KEY" && ! -e "$CA_CERT" ]]; then
  # Offline/internal CA. For a larger environment, use an offline root and an
  # intermediate issuing CA instead of signing leaf certificates with the root.
  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$CA_KEY" \
    -out "$CA_CERT" \
    -subj "/O=Gals Software/CN=Gals Infrastructure CA"
else
  echo "ERROR: only one CA file exists; refusing to replace the CA." >&2
  echo "Expected both $CA_KEY and $CA_CERT." >&2
  exit 1
fi

openssl x509 -in "$CA_CERT" -noout >/dev/null
openssl pkey -in "$CA_KEY" -noout -check >/dev/null

issue_certificate() {
  local artifact_name="$1"
  local common_name="$2"
  local host_dns="$3"
  local ip_address="$4"
  local extended_key_usage="$5"
  local extra_dns="${6:-}"
  local san="DNS:${host_dns},IP:${ip_address}"

  [[ -n "$extra_dns" ]] && san="${san},DNS:${extra_dns}"

  openssl genrsa -out "$OUT/private/${artifact_name}.key" 3072
  openssl req -new -sha256 \
    -key "$OUT/private/${artifact_name}.key" \
    -out "$OUT/csr/${artifact_name}.csr" \
    -subj "/O=Gals Software/CN=${common_name}" \
    -addext "subjectAltName=${san}"

  cat > "$OUT/csr/${artifact_name}.ext" <<EOT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=${extended_key_usage}
subjectAltName=${san}
EOT

  openssl x509 -req -sha256 -days 825 \
    -in "$OUT/csr/${artifact_name}.csr" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAcreateserial \
    -out "$OUT/certs/${artifact_name}.crt" \
    -extfile "$OUT/csr/${artifact_name}.ext"

  openssl verify -CAfile "$CA_CERT" "$OUT/certs/${artifact_name}.crt"
}

# Service certificates. The Zabbix server nodes also initiate TLS connections
# to agents during passive checks, so their certificates need clientAuth in
# addition to serverAuth. Other component certificates remain server-only.
issue_certificate grafana01 grafana01 grafana01 192.168.0.4 serverAuth
issue_certificate grafana02 grafana02 grafana02 192.168.0.5 serverAuth
issue_certificate zbx01 zbx01 zbx01 192.168.0.10 serverAuth,clientAuth
issue_certificate zbx02 zbx02 zbx02 192.168.0.11 serverAuth,clientAuth
issue_certificate pg01 pg01 pg01 192.168.0.20 serverAuth postgres.gals.training
issue_certificate pg02 pg02 pg02 192.168.0.21 serverAuth postgres.gals.training
issue_certificate pg03 pg03 pg03 192.168.0.22 serverAuth postgres.gals.training

# A distinct certificate and private key for Zabbix Agent 2 on every server.
# Agents act as TLS servers for passive checks and TLS clients for active checks.
issue_certificate haproxy01-agent zabbix-agent-haproxy01 haproxy01 192.168.0.2 serverAuth,clientAuth
issue_certificate haproxy02-agent zabbix-agent-haproxy02 haproxy02 192.168.0.3 serverAuth,clientAuth
issue_certificate grafana01-agent zabbix-agent-grafana01 grafana01 192.168.0.4 serverAuth,clientAuth
issue_certificate grafana02-agent zabbix-agent-grafana02 grafana02 192.168.0.5 serverAuth,clientAuth
issue_certificate zbx01-agent zabbix-agent-zbx01 zbx01 192.168.0.10 serverAuth,clientAuth
issue_certificate zbx02-agent zabbix-agent-zbx02 zbx02 192.168.0.11 serverAuth,clientAuth
issue_certificate pg01-agent zabbix-agent-pg01 pg01 192.168.0.20 serverAuth,clientAuth
issue_certificate pg02-agent zabbix-agent-pg02 pg02 192.168.0.21 serverAuth,clientAuth
issue_certificate pg03-agent zabbix-agent-pg03 pg03 192.168.0.22 serverAuth,clientAuth

# The PHP frontend is a TLS client of Zabbix server when testing items. It gets
# its own identity so www-data never needs access to the Zabbix server key.
issue_certificate zbx01-frontend zabbix-frontend-zbx01 zbx01 192.168.0.10 clientAuth
issue_certificate zbx02-frontend zabbix-frontend-zbx02 zbx02 192.168.0.11 clientAuth

chmod 600 "$CA_KEY" "$OUT"/private/*.key
chmod 644 "$CA_CERT" "$OUT"/certs/*.crt

echo "PKI generated in: $OUT"
echo "Agent identities: $OUT/certs/*-agent.crt"
echo "Frontend identities: $OUT/certs/*-frontend.crt"
echo "DO NOT copy $CA_KEY to application servers."
