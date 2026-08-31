#!/usr/bin/env bash

set -euo pipefail
umask 077

###############################################################################
# Gals Software PKI deployment
#
# Usage:
#
#   ./deploy-pki.sh /root/gals-pki
#
# Optional:
#
#   SSH_USER=root ./deploy-pki.sh /root/gals-pki
#
###############################################################################

PKI_DIR="${1:-$PWD/gals-pki}"
SSH_USER="${SSH_USER:-root}"

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

SCP_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
)

###############################################################################
# Hosts
###############################################################################

HAPROXY_HOSTS=(
    "haproxy01"
    "haproxy02"
)

GRAFANA_HOSTS=(
    "grafana01"
    "grafana02"
)

ZABBIX_HOSTS=(
    "zbx01"
    "zbx02"
)

POSTGRES_HOSTS=(
    "pg01"
    "pg02"
    "pg03"
)

###############################################################################
# Validate local PKI
###############################################################################

echo "===================================================================="
echo "Checking PKI directory: $PKI_DIR"
echo "===================================================================="

if [[ ! -d "$PKI_DIR" ]]; then
    echo "ERROR: PKI directory does not exist: $PKI_DIR"
    exit 1
fi

if [[ ! -f "$PKI_DIR/ca/internal-ca.crt" ]]; then
    echo "ERROR: CA certificate not found:"
    echo "       $PKI_DIR/ca/internal-ca.crt"
    exit 1
fi

for host in "${GRAFANA_HOSTS[@]}" \
            "${ZABBIX_HOSTS[@]}" \
            "${POSTGRES_HOSTS[@]}"
do
    if [[ ! -f "$PKI_DIR/certs/${host}.crt" ]]; then
        echo "ERROR: Certificate missing: $PKI_DIR/certs/${host}.crt"
        exit 1
    fi

    if [[ ! -f "$PKI_DIR/private/${host}.key" ]]; then
        echo "ERROR: Private key missing: $PKI_DIR/private/${host}.key"
        exit 1
    fi
done

ALL_HOSTS=(
    "${HAPROXY_HOSTS[@]}"
    "${GRAFANA_HOSTS[@]}"
    "${ZABBIX_HOSTS[@]}"
    "${POSTGRES_HOSTS[@]}"
)

for host in "${ALL_HOSTS[@]}"; do
    if [[ ! -f "$PKI_DIR/certs/${host}-agent.crt" ]]; then
        echo "ERROR: Agent certificate missing: $PKI_DIR/certs/${host}-agent.crt"
        exit 1
    fi

    if [[ ! -f "$PKI_DIR/private/${host}-agent.key" ]]; then
        echo "ERROR: Agent private key missing: $PKI_DIR/private/${host}-agent.key"
        exit 1
    fi
done

for host in "${ZABBIX_HOSTS[@]}"; do
    if [[ ! -f "$PKI_DIR/certs/${host}-frontend.crt" ]]; then
        echo "ERROR: Frontend certificate missing: $PKI_DIR/certs/${host}-frontend.crt"
        exit 1
    fi

    if [[ ! -f "$PKI_DIR/private/${host}-frontend.key" ]]; then
        echo "ERROR: Frontend private key missing: $PKI_DIR/private/${host}-frontend.key"
        exit 1
    fi
done

echo "PKI files OK."
echo

###############################################################################
# SSH check
###############################################################################

check_ssh()
{
    local host="$1"

    echo "Checking SSH -> $host"

    ssh "${SSH_OPTS[@]}" \
        "${SSH_USER}@${host}" \
        "true"
}

###############################################################################
# Secure temporary directory
###############################################################################

prepare_remote_tmp()
{
    local host="$1"

    ssh "${SSH_OPTS[@]}" \
        "${SSH_USER}@${host}" \
        '
        rm -rf /root/.gals-pki-deploy
        install -d -m 700 /root/.gals-pki-deploy
        '
}

###############################################################################
# Copy helper
###############################################################################

copy_file()
{
    local source="$1"
    local host="$2"
    local destination="$3"

    scp "${SCP_OPTS[@]}" \
        "$source" \
        "${SSH_USER}@${host}:${destination}"
}

###############################################################################
# Zabbix Agent 2 identity
#
# Every host gets a distinct certificate and key. The key is readable only by
# root and the zabbix group; no service-specific private key is reused.
#
# /etc/zabbix/tls/agent.crt
# /etc/zabbix/tls/agent.key
# /etc/zabbix/tls/internal-ca.crt
# /etc/zabbix/tls/ca.crt -> internal-ca.crt
###############################################################################

deploy_zabbix_agent()
{
    local host="$1"

    echo
    echo "===================================================================="
    echo "Deploying Zabbix Agent 2 identity -> $host"
    echo "===================================================================="

    prepare_remote_tmp "$host"

    copy_file \
        "$PKI_DIR/certs/${host}-agent.crt" \
        "$host" \
        "/root/.gals-pki-deploy/agent.crt"

    copy_file \
        "$PKI_DIR/private/${host}-agent.key" \
        "$host" \
        "/root/.gals-pki-deploy/agent.key"

    copy_file \
        "$PKI_DIR/ca/internal-ca.crt" \
        "$host" \
        "/root/.gals-pki-deploy/internal-ca.crt"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" '
        set -e

        getent passwd zabbix >/dev/null || {
            echo "ERROR: zabbix user does not exist; install Zabbix Agent 2 first"
            exit 1
        }

        getent group zabbix >/dev/null || {
            echo "ERROR: zabbix group does not exist; install Zabbix Agent 2 first"
            exit 1
        }

        install -d \
            -o root \
            -g root \
            -m 755 \
            /etc/zabbix/tls

        install \
            -o root \
            -g zabbix \
            -m 644 \
            /root/.gals-pki-deploy/agent.crt \
            /etc/zabbix/tls/agent.crt

        install \
            -o root \
            -g zabbix \
            -m 640 \
            /root/.gals-pki-deploy/agent.key \
            /etc/zabbix/tls/agent.key

        install \
            -o root \
            -g root \
            -m 644 \
            /root/.gals-pki-deploy/internal-ca.crt \
            /etc/zabbix/tls/internal-ca.crt

        ln -sfn \
            /etc/zabbix/tls/internal-ca.crt \
            /etc/zabbix/tls/ca.crt

        runuser -u zabbix -- test -r /etc/zabbix/tls/agent.crt
        runuser -u zabbix -- test -r /etc/zabbix/tls/agent.key
        runuser -u zabbix -- test -r /etc/zabbix/tls/ca.crt

        rm -rf /root/.gals-pki-deploy
    '

    echo "Installed:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'ls -la /etc/zabbix/tls/agent.crt /etc/zabbix/tls/agent.key /etc/zabbix/tls/ca.crt'
}

###############################################################################
# HAProxy
#
# HAProxy only needs the CA certificate to verify Grafana/Zabbix backend
# certificates.
###############################################################################

deploy_haproxy()
{
    local host="$1"

    echo
    echo "===================================================================="
    echo "Deploying CA certificate -> $host"
    echo "===================================================================="

    prepare_remote_tmp "$host"

    copy_file \
        "$PKI_DIR/ca/internal-ca.crt" \
        "$host" \
        "/root/.gals-pki-deploy/internal-ca.crt"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" '
        set -e

        install -d \
            -o root \
            -g root \
            -m 755 \
            /etc/haproxy/ca

        install \
            -o root \
            -g root \
            -m 644 \
            /root/.gals-pki-deploy/internal-ca.crt \
            /etc/haproxy/ca/internal-ca.crt

        rm -rf /root/.gals-pki-deploy
    '

    echo "Installed:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'ls -l /etc/haproxy/ca/internal-ca.crt'
}

###############################################################################
# Grafana
#
# /etc/grafana/tls/server.crt
# /etc/grafana/tls/server.key
# /etc/grafana/tls/internal-ca.crt
# /etc/grafana/tls/postgres-ca.crt -> internal-ca.crt
###############################################################################

deploy_grafana()
{
    local host="$1"

    echo
    echo "===================================================================="
    echo "Deploying Grafana certificate -> $host"
    echo "===================================================================="

    prepare_remote_tmp "$host"

    copy_file \
        "$PKI_DIR/certs/${host}.crt" \
        "$host" \
        "/root/.gals-pki-deploy/server.crt"

    copy_file \
        "$PKI_DIR/private/${host}.key" \
        "$host" \
        "/root/.gals-pki-deploy/server.key"

    copy_file \
        "$PKI_DIR/ca/internal-ca.crt" \
        "$host" \
        "/root/.gals-pki-deploy/internal-ca.crt"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" '
        set -e

        getent group grafana >/dev/null || {
            echo "ERROR: grafana group does not exist"
            exit 1
        }

        install -d \
            -o root \
            -g grafana \
            -m 750 \
            /etc/grafana/tls

        install \
            -o root \
            -g grafana \
            -m 644 \
            /root/.gals-pki-deploy/server.crt \
            /etc/grafana/tls/server.crt

        install \
            -o root \
            -g grafana \
            -m 640 \
            /root/.gals-pki-deploy/server.key \
            /etc/grafana/tls/server.key

        install \
            -o root \
            -g grafana \
            -m 644 \
            /root/.gals-pki-deploy/internal-ca.crt \
            /etc/grafana/tls/internal-ca.crt

        ln -sfn \
            /etc/grafana/tls/internal-ca.crt \
            /etc/grafana/tls/postgres-ca.crt

        rm -rf /root/.gals-pki-deploy
    '

    echo "Installed:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'ls -la /etc/grafana/tls/'
}

###############################################################################
# Zabbix
#
# The zbxNN certificate has serverAuth and clientAuth EKUs because Zabbix
# server accepts TLS connections and initiates passive checks to agents.
# The PHP frontend receives a separate client-only identity below.
#
# /etc/zabbix/tls/server.crt
# /etc/zabbix/tls/server.key
# /etc/zabbix/tls/frontend.crt
# /etc/zabbix/tls/frontend.key
# /etc/zabbix/tls/internal-ca.crt
# /etc/zabbix/tls/postgres-ca.crt -> internal-ca.crt
###############################################################################

deploy_zabbix()
{
    local host="$1"

    echo
    echo "===================================================================="
    echo "Deploying Zabbix certificate -> $host"
    echo "===================================================================="

    prepare_remote_tmp "$host"

    copy_file \
        "$PKI_DIR/certs/${host}.crt" \
        "$host" \
        "/root/.gals-pki-deploy/server.crt"

    copy_file \
        "$PKI_DIR/private/${host}.key" \
        "$host" \
        "/root/.gals-pki-deploy/server.key"

    copy_file \
        "$PKI_DIR/certs/${host}-frontend.crt" \
        "$host" \
        "/root/.gals-pki-deploy/frontend.crt"

    copy_file \
        "$PKI_DIR/private/${host}-frontend.key" \
        "$host" \
        "/root/.gals-pki-deploy/frontend.key"

    copy_file \
        "$PKI_DIR/ca/internal-ca.crt" \
        "$host" \
        "/root/.gals-pki-deploy/internal-ca.crt"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" '
        set -e

        getent passwd zabbix >/dev/null || {
            echo "ERROR: zabbix user does not exist"
            exit 1
        }

        getent group www-data >/dev/null || {
            echo "ERROR: www-data group does not exist"
            exit 1
        }

        install -d \
            -o root \
            -g root \
            -m 755 \
            /etc/zabbix/tls

        #
        # nginx master process starts as root, therefore the TLS key
        # does not need to be readable by www-data.
        #

        install \
            -o zabbix \
            -g zabbix \
            -m 644 \
            /root/.gals-pki-deploy/server.crt \
            /etc/zabbix/tls/server.crt

        install \
            -o zabbix \
            -g zabbix \
            -m 600 \
            /root/.gals-pki-deploy/server.key \
            /etc/zabbix/tls/server.key

        #
        # PHP-FPM uses a dedicated TLS client identity when the frontend tests
        # items through Zabbix server. It never receives access to server.key.
        #

        install \
            -o root \
            -g www-data \
            -m 644 \
            /root/.gals-pki-deploy/frontend.crt \
            /etc/zabbix/tls/frontend.crt

        install \
            -o root \
            -g www-data \
            -m 640 \
            /root/.gals-pki-deploy/frontend.key \
            /etc/zabbix/tls/frontend.key

        #
        # CA is required by Zabbix Server and Zabbix frontend
        # for PostgreSQL verify-full.
        #

        install \
            -o zabbix \
            -g zabbix \
            -m 644 \
            /root/.gals-pki-deploy/internal-ca.crt \
            /etc/zabbix/tls/internal-ca.crt

        ln -sfn \
            /etc/zabbix/tls/internal-ca.crt \
            /etc/zabbix/tls/postgres-ca.crt

        runuser -u www-data -- test -r /etc/zabbix/tls/frontend.crt
        runuser -u www-data -- test -r /etc/zabbix/tls/frontend.key
        runuser -u www-data -- test -r /etc/zabbix/tls/internal-ca.crt

        rm -rf /root/.gals-pki-deploy
    '

    echo "Installed:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'ls -la /etc/zabbix/tls/'
}

###############################################################################
# PostgreSQL
#
# /etc/postgresql/tls/server.crt
# /etc/postgresql/tls/server.key
# /etc/postgresql/tls/internal-ca.crt
# /etc/postgresql/tls/ca.crt -> internal-ca.crt
###############################################################################

deploy_postgresql()
{
    local host="$1"

    echo
    echo "===================================================================="
    echo "Deploying PostgreSQL certificate -> $host"
    echo "===================================================================="

    prepare_remote_tmp "$host"

    copy_file \
        "$PKI_DIR/certs/${host}.crt" \
        "$host" \
        "/root/.gals-pki-deploy/server.crt"

    copy_file \
        "$PKI_DIR/private/${host}.key" \
        "$host" \
        "/root/.gals-pki-deploy/server.key"

    copy_file \
        "$PKI_DIR/ca/internal-ca.crt" \
        "$host" \
        "/root/.gals-pki-deploy/internal-ca.crt"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" '
        set -e

        getent passwd postgres >/dev/null || {
            echo "ERROR: postgres user does not exist"
            exit 1
        }

        install -d \
            -o postgres \
            -g postgres \
            -m 750 \
            /etc/postgresql/tls

        install \
            -o postgres \
            -g postgres \
            -m 644 \
            /root/.gals-pki-deploy/server.crt \
            /etc/postgresql/tls/server.crt

        install \
            -o postgres \
            -g postgres \
            -m 600 \
            /root/.gals-pki-deploy/server.key \
            /etc/postgresql/tls/server.key

        install \
            -o postgres \
            -g postgres \
            -m 644 \
            /root/.gals-pki-deploy/internal-ca.crt \
            /etc/postgresql/tls/internal-ca.crt

        ln -sfn \
            /etc/postgresql/tls/internal-ca.crt \
            /etc/postgresql/tls/ca.crt

        rm -rf /root/.gals-pki-deploy
    '

    echo "Installed:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'ls -la /etc/postgresql/tls/'
}

###############################################################################
# Verify certificate against internal CA
###############################################################################

verify_certificate()
{
    local host="$1"
    local cert="$2"
    local ca="$3"

    echo
    echo "Checking certificate on $host"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "openssl verify -CAfile '$ca' '$cert'"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "openssl x509 -in '$cert' \
            -noout \
            -subject \
            -issuer \
            -dates \
            -ext extendedKeyUsage"
}

###############################################################################
# Main
###############################################################################

echo
echo "===================================================================="
echo "Checking SSH connectivity"
echo "===================================================================="

for host in "${ALL_HOSTS[@]}"; do
    check_ssh "$host"
done

echo
echo "All hosts reachable."
echo

###############################################################################
# HAProxy
###############################################################################

for host in "${HAPROXY_HOSTS[@]}"; do
    deploy_haproxy "$host"
done

###############################################################################
# Grafana
###############################################################################

for host in "${GRAFANA_HOSTS[@]}"; do
    deploy_grafana "$host"

    verify_certificate \
        "$host" \
        "/etc/grafana/tls/server.crt" \
        "/etc/grafana/tls/internal-ca.crt"
done

###############################################################################
# Zabbix
###############################################################################

for host in "${ZABBIX_HOSTS[@]}"; do
    deploy_zabbix "$host"

    verify_certificate \
        "$host" \
        "/etc/zabbix/tls/server.crt" \
        "/etc/zabbix/tls/internal-ca.crt"

    verify_certificate \
        "$host" \
        "/etc/zabbix/tls/frontend.crt" \
        "/etc/zabbix/tls/internal-ca.crt"
done

###############################################################################
# PostgreSQL
###############################################################################

for host in "${POSTGRES_HOSTS[@]}"; do
    deploy_postgresql "$host"

    verify_certificate \
        "$host" \
        "/etc/postgresql/tls/server.crt" \
        "/etc/postgresql/tls/internal-ca.crt"
done

###############################################################################
# Zabbix Agent 2 identities on every environment host
###############################################################################

for host in "${ALL_HOSTS[@]}"; do
    deploy_zabbix_agent "$host"

    verify_certificate \
        "$host" \
        "/etc/zabbix/tls/agent.crt" \
        "/etc/zabbix/tls/internal-ca.crt"
done

echo
echo "===================================================================="
echo "PKI deployment completed successfully"
echo "===================================================================="
echo
echo "IMPORTANT:"
echo "  CA private key was NOT copied to any host:"
echo
echo "  $PKI_DIR/ca/internal-ca.key"
echo
echo "Configure Zabbix Agent 2 on every host with:"
echo "  TLSConnect=cert"
echo "  TLSAccept=cert"
echo "  TLSCAFile=/etc/zabbix/tls/ca.crt"
echo "  TLSCertFile=/etc/zabbix/tls/agent.crt"
echo "  TLSKeyFile=/etc/zabbix/tls/agent.key"
echo
echo "Configure Zabbix frontend on zbx01 and zbx02 with:"
echo "  CA_FILE=/etc/zabbix/tls/internal-ca.crt"
echo "  CERT_FILE=/etc/zabbix/tls/frontend.crt"
echo "  KEY_FILE=/etc/zabbix/tls/frontend.key"
echo
