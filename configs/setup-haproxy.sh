#!/usr/bin/env bash

set -euo pipefail


##########################################################
# General configuration
##########################################################

DOMAIN="haproxy.gals.training"
EMAIL="admin@gals.training"

# Public IP
PUBLIC_IP="185.161.66.194"


##########################################################
# HAProxy nodes
##########################################################

HAPROXY01_IP="192.168.0.2"
HAPROXY02_IP="192.168.0.3"

HAPROXY01_HOST="haproxy01"
HAPROXY02_HOST="haproxy02"

# Keepalived VIP
HAPROXY_VIP="192.168.0.100"


##########################################################
# Certificate manager
##########################################################
#
# Let's Encrypt certificate is issued and renewed
# only on haproxy01.
#
##########################################################

CERT_MANAGER_IP="${HAPROXY01_IP}"
CERT_MANAGER_HOST="${HAPROXY01_HOST}"

# Certbot standalone listens locally on 8888.
#
# External Let's Encrypt HTTP-01 validation always comes
# to port 80.
#
# HAProxy forwards:
#
# /.well-known/acme-challenge/
#
# to:
#
# haproxy01:8888
#
##########################################################

CERTBOT_PORT="8888"


##########################################################
# Zabbix frontend nodes
##########################################################

ZABBIX_NODE1="192.168.0.10"
ZABBIX_NODE2="192.168.0.11"


##########################################################
# Grafana nodes
##########################################################

GRAFANA_NODE1="192.168.0.4"
GRAFANA_NODE2="192.168.0.5"


##########################################################
# PostgreSQL Patroni nodes
##########################################################

PG01="192.168.0.20"
PG02="192.168.0.21"
PG03="192.168.0.22"


##########################################################
# Certificate paths
##########################################################

CERT_DIR="/etc/haproxy/certs"

CERT_PEM="${CERT_DIR}/${DOMAIN}.pem"

LE_LIVE="/etc/letsencrypt/live/${DOMAIN}"


##########################################################
# SSH options
##########################################################
#
# BatchMode=yes
#   Не запрашивать SSH password.
#
# StrictHostKeyChecking=accept-new
#   Новый SSH fingerprint автоматически добавляется
#   в /root/.ssh/known_hosts.
#
#   Если fingerprint уже известного сервера изменится,
#   SSH остановит подключение.
#
##########################################################

SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new
)

SCP_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new
)


##########################################################
# Detect current HAProxy node
##########################################################

echo
echo "======================================================"
echo "Detecting HAProxy node"
echo "======================================================"

if ip -4 addr show | grep -qE "\b${HAPROXY01_IP}/"; then

    LOCAL_IP="${HAPROXY01_IP}"
    LOCAL_HOST="${HAPROXY01_HOST}"

    PEER_IP="${HAPROXY02_IP}"
    PEER_HOST="${HAPROXY02_HOST}"

    NODE_NAME="haproxy01"

elif ip -4 addr show | grep -qE "\b${HAPROXY02_IP}/"; then

    LOCAL_IP="${HAPROXY02_IP}"
    LOCAL_HOST="${HAPROXY02_HOST}"

    PEER_IP="${HAPROXY01_IP}"
    PEER_HOST="${HAPROXY01_HOST}"

    NODE_NAME="haproxy02"

else

    echo
    echo "ERROR:"
    echo
    echo "Эта нода не имеет ни одного из ожидаемых IP:"
    echo
    echo "  ${HAPROXY01_IP}"
    echo "  ${HAPROXY02_IP}"
    echo

    exit 1
fi


echo
echo "Node       : ${NODE_NAME}"
echo "Local host : ${LOCAL_HOST}"
echo "Local IP   : ${LOCAL_IP}"
echo "Peer host  : ${PEER_HOST}"
echo "Peer IP    : ${PEER_IP}"
echo "VIP        : ${HAPROXY_VIP}"


##########################################################
# Non-interactive APT
##########################################################
#
# Важно:
#
# --force-confold
#
# сохраняет существующую локально изменённую конфигурацию,
# например:
#
# /etc/ssh/sshd_config
#
# Вместо появления диалога:
#
# "What do you want to do about modified configuration..."
#
##########################################################

echo
echo "======================================================"
echo "Installing packages"
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive

# Автоматически обработать возможный needrestart
export NEEDRESTART_MODE=a


apt-get update


apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    haproxy \
    certbot \
    ca-certificates \
    curl \
    dnsutils \
    openssl \
    openssh-client


##########################################################
# Allow HAProxy to bind Keepalived VIP on BACKUP
##########################################################

echo
echo "======================================================"
echo "Configuring ip_nonlocal_bind"
echo "======================================================"

cat > /etc/sysctl.d/99-haproxy.conf <<EOF
net.ipv4.ip_nonlocal_bind = 1
EOF


sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null


##########################################################
# Prepare SSH directory
##########################################################

mkdir -p /root/.ssh

chmod 700 /root/.ssh

touch /root/.ssh/known_hosts

chmod 600 /root/.ssh/known_hosts


##########################################################
# Certificate directory
##########################################################

mkdir -p "${CERT_DIR}"

chown root:haproxy "${CERT_DIR}"

chmod 750 "${CERT_DIR}"


##########################################################
# Backup HAProxy configuration
##########################################################

if [[ -f /etc/haproxy/haproxy.cfg ]]; then

    BACKUP_FILE="/etc/haproxy/haproxy.cfg.bak.$(date +%F-%H%M%S)"

    cp \
        /etc/haproxy/haproxy.cfg \
        "${BACKUP_FILE}"

    echo
    echo "Existing HAProxy configuration backup:"
    echo
    echo "  ${BACKUP_FILE}"
fi


##########################################################
# Create temporary certificate if necessary
##########################################################
#
# HAProxy requires certificate during config validation.
#
# Therefore we create temporary self-signed certificate
# before obtaining Let's Encrypt certificate.
#
##########################################################

if [[ ! -s "${CERT_PEM}" ]]; then

    echo
    echo "======================================================"
    echo "Creating temporary self-signed certificate"
    echo "======================================================"

    TMP_KEY="/tmp/${DOMAIN}.key"
    TMP_CERT="/tmp/${DOMAIN}.crt"

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -days 1 \
        -subj "/CN=${DOMAIN}" \
        -keyout "${TMP_KEY}" \
        -out "${TMP_CERT}"


    cat \
        "${TMP_CERT}" \
        "${TMP_KEY}" \
        > "${CERT_PEM}"


    chown root:haproxy "${CERT_PEM}"

    chmod 640 "${CERT_PEM}"


    rm -f \
        "${TMP_KEY}" \
        "${TMP_CERT}"
fi


##########################################################
# HAProxy configuration
##########################################################

echo
echo "======================================================"
echo "Creating HAProxy configuration"
echo "======================================================"

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice

    user haproxy
    group haproxy

    maxconn 5000
    daemon

    ssl-default-bind-options ssl-min-ver TLSv1.2


defaults
    log global

    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout check 3s


##########################################################
# HTTP frontend
##########################################################

frontend http_frontend
    bind *:80

    mode http

    option httplog

    # Let's Encrypt HTTP-01 challenge
    acl acme_challenge path_beg /.well-known/acme-challenge/

    use_backend acme_backend if acme_challenge

    # Everything except ACME challenge goes to HTTPS
    http-request redirect scheme https code 301 unless acme_challenge


##########################################################
# Let's Encrypt ACME backend
##########################################################

backend acme_backend
    mode http

    server certbot ${CERT_MANAGER_IP}:${CERTBOT_PORT}


##########################################################
# HTTPS frontend
##########################################################

frontend monitoring_https
    bind *:443 ssl crt ${CERT_PEM}

    mode http

    option httplog
    option forwardfor

    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port 443
    http-request set-header X-Forwarded-Host %[req.hdr(Host)]

    acl root_path path -i /

    acl zabbix_no_slash path -i /zabbix
    acl grafana_no_slash path -i /grafana

    acl path_zabbix path_beg -i /zabbix/
    acl path_grafana path_beg -i /grafana/

    # Default URL -> Zabbix
    http-request redirect location /zabbix/ code 302 if root_path

    # Add trailing slash
    http-request redirect location /zabbix/ code 301 if zabbix_no_slash
    http-request redirect location /grafana/ code 301 if grafana_no_slash

    use_backend zabbix_servers if path_zabbix
    use_backend grafana_servers if path_grafana

    default_backend unknown_endpoint


##########################################################
# Zabbix frontend cluster
##########################################################

backend zabbix_servers
    mode http

    balance roundrobin

    option httpchk GET /
    http-check expect status 200

    default-server inter 5s fall 3 rise 2

    # /zabbix/index.php -> /index.php
    http-request set-path %[path,regsub(^/zabbix/,/)]

    http-request set-header X-Forwarded-Prefix /zabbix
    http-request set-header X-Forwarded-Proto https

    server zbx01 ${ZABBIX_NODE1}:80 check
    server zbx02 ${ZABBIX_NODE2}:80 check


##########################################################
# Grafana cluster
##########################################################

backend grafana_servers
    mode http

    balance roundrobin

    option httpchk GET /api/health
    http-check expect status 200

    default-server inter 5s fall 3 rise 2

    http-request set-header X-Forwarded-Prefix /grafana
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Host %[req.hdr(Host)]

    server grafana01 ${GRAFANA_NODE1}:3000 check
    server grafana02 ${GRAFANA_NODE2}:3000 check


##########################################################
# Unknown endpoint
##########################################################

backend unknown_endpoint
    mode http

    http-request return status 404 content-type text/plain string "Unknown monitoring endpoint\n"


##########################################################
# PostgreSQL replicas
##########################################################

listen postgres-replicas
    bind ${HAPROXY_VIP}:5433

    mode tcp

    option tcplog

    balance roundrobin

    option httpchk GET /replica
    http-check expect status 200

    default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions

    server pg01 ${PG01}:6432 check port 8008
    server pg02 ${PG02}:6432 check port 8008
    server pg03 ${PG03}:6432 check port 8008


##########################################################
# PostgreSQL Patroni leader
##########################################################

listen postgres-primary
    bind ${HAPROXY_VIP}:5432

    mode tcp

    option tcplog

    balance first

    option httpchk GET /primary
    http-check expect status 200

    default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions

    server pg01 ${PG01}:6432 check port 8008
    server pg02 ${PG02}:6432 check port 8008
    server pg03 ${PG03}:6432 check port 8008


##########################################################
# HAProxy statistics
##########################################################

listen stats
    bind 127.0.0.1:7000

    mode http

    stats enable
    stats uri /
    stats refresh 5s

    stats auth admin:admin

EOF


##########################################################
# Validate HAProxy configuration
##########################################################

echo
echo "======================================================"
echo "Validating HAProxy configuration"
echo "======================================================"

haproxy -c -f /etc/haproxy/haproxy.cfg


##########################################################
# Enable and start HAProxy
##########################################################

systemctl enable haproxy

systemctl restart haproxy


##########################################################
# Check HAProxy
##########################################################

if ! systemctl is-active --quiet haproxy; then

    echo
    echo "======================================================"
    echo "ERROR: HAProxy failed to start"
    echo "======================================================"

    journalctl \
        -u haproxy \
        -n 50 \
        --no-pager

    exit 1
fi


##########################################################
# SSH connection preparation
##########################################################

prepare_ssh_host()
{
    local TARGET_HOST="$1"

    echo
    echo "======================================================"
    echo "Checking SSH connection to ${TARGET_HOST}"
    echo "======================================================"

    mkdir -p /root/.ssh

    chmod 700 /root/.ssh

    touch /root/.ssh/known_hosts

    chmod 600 /root/.ssh/known_hosts


    if ! ssh \
        "${SSH_OPTS[@]}" \
        root@"${TARGET_HOST}" \
        "true"
    then

        echo
        echo "ERROR:"
        echo
        echo "SSH connection to ${TARGET_HOST} failed."
        echo
        echo "The script expects SSH key authentication"
        echo "to already be configured."
        echo
        echo "Check manually:"
        echo
        echo "  ssh root@${TARGET_HOST}"
        echo

        return 1
    fi


    echo
    echo "SSH connection to ${TARGET_HOST}: OK"
}


##########################################################
# Certificate synchronization
##########################################################

sync_certificate()
{
    local TARGET_HOST="$1"

    echo
    echo "======================================================"
    echo "Synchronizing certificate to ${TARGET_HOST}"
    echo "======================================================"

    prepare_ssh_host "${TARGET_HOST}"


    ######################################################
    # Prepare remote directory
    ######################################################

    ssh \
        "${SSH_OPTS[@]}" \
        root@"${TARGET_HOST}" \
        "
        mkdir -p '${CERT_DIR}'
        chown root:haproxy '${CERT_DIR}'
        chmod 750 '${CERT_DIR}'
        "


    ######################################################
    # Copy certificate
    ######################################################

    echo
    echo "Copying certificate to ${TARGET_HOST}..."


    scp \
        "${SCP_OPTS[@]}" \
        "${CERT_PEM}" \
        root@"${TARGET_HOST}":"${CERT_PEM}"


    ######################################################
    # Set permissions and reload HAProxy
    ######################################################

    ssh \
        "${SSH_OPTS[@]}" \
        root@"${TARGET_HOST}" \
        "
        chown root:haproxy '${CERT_PEM}'
        chmod 640 '${CERT_PEM}'

        if [ -f /etc/haproxy/haproxy.cfg ]; then

            if haproxy -c -f /etc/haproxy/haproxy.cfg; then

                if systemctl is-active --quiet haproxy; then

                    echo 'Reloading HAProxy on ${TARGET_HOST}...'

                    systemctl reload haproxy

                else

                    echo 'Starting HAProxy on ${TARGET_HOST}...'

                    systemctl start haproxy

                fi

            else

                echo 'ERROR: HAProxy config validation failed on ${TARGET_HOST}'

                exit 1

            fi

        else

            echo 'HAProxy configuration does not exist on ${TARGET_HOST}.'
            echo 'Certificate was copied successfully.'

        fi
        "


    echo
    echo "Certificate successfully synchronized to ${TARGET_HOST}."
}


##########################################################
# Let's Encrypt
##########################################################
#
# Certbot runs only on haproxy01
#
##########################################################

if [[ "${LOCAL_IP}" == "${CERT_MANAGER_IP}" ]]; then

    echo
    echo "======================================================"
    echo "This node is certificate manager"
    echo "======================================================"

    echo
    echo "Certificate manager:"
    echo
    echo "  ${CERT_MANAGER_HOST}"


    ######################################################
    # DNS verification
    ######################################################

    echo
    echo "======================================================"
    echo "Checking public DNS"
    echo "======================================================"

    DNS_IP="$(dig +short A "${DOMAIN}" | head -n1 || true)"


    if [[ -z "${DNS_IP}" ]]; then

        echo
        echo "ERROR:"
        echo
        echo "DNS A record for ${DOMAIN} does not exist."
        echo
        echo "Required record:"
        echo
        echo "  ${DOMAIN} -> ${PUBLIC_IP}"
        echo

        exit 1
    fi


    echo
    echo "${DOMAIN} -> ${DNS_IP}"


    if [[ "${DNS_IP}" != "${PUBLIC_IP}" ]]; then

        echo
        echo "ERROR:"
        echo
        echo "${DOMAIN} resolves to:"
        echo
        echo "  ${DNS_IP}"
        echo
        echo "Expected:"
        echo
        echo "  ${PUBLIC_IP}"
        echo

        exit 1
    fi


    ######################################################
    # Obtain Let's Encrypt certificate
    ######################################################

    echo
    echo "======================================================"
    echo "Obtaining Let's Encrypt certificate"
    echo "======================================================"

    certbot certonly \
        --standalone \
        --http-01-port "${CERTBOT_PORT}" \
        --preferred-challenges http \
        --non-interactive \
        --agree-tos \
        --email "${EMAIL}" \
        -d "${DOMAIN}"


    ######################################################
    # Build HAProxy PEM
    ######################################################

    echo
    echo "======================================================"
    echo "Creating HAProxy PEM"
    echo "======================================================"

    cat \
        "${LE_LIVE}/fullchain.pem" \
        "${LE_LIVE}/privkey.pem" \
        > "${CERT_PEM}"


    chown root:haproxy "${CERT_PEM}"

    chmod 640 "${CERT_PEM}"


    ######################################################
    # Display certificate
    ######################################################

    echo
    echo "Certificate information:"
    echo

    openssl x509 \
        -in "${CERT_PEM}" \
        -noout \
        -subject \
        -issuer \
        -dates


    ######################################################
    # Validate local HAProxy
    ######################################################

    haproxy -c -f /etc/haproxy/haproxy.cfg


    ######################################################
    # Reload local HAProxy
    ######################################################

    systemctl reload haproxy


    ######################################################
    # Synchronize certificate to haproxy02
    ######################################################

    sync_certificate "${HAPROXY02_HOST}"


    ######################################################
    # Create Certbot deploy hook
    ######################################################

    echo
    echo "======================================================"
    echo "Creating Certbot deploy hook"
    echo "======================================================"

    mkdir -p \
        /etc/letsencrypt/renewal-hooks/deploy


    cat > /etc/letsencrypt/renewal-hooks/deploy/haproxy.sh <<EOF
#!/usr/bin/env bash

set -euo pipefail


DOMAIN="${DOMAIN}"

CERT_DIR="${CERT_DIR}"
CERT_PEM="${CERT_PEM}"

PEER_HOST="${HAPROXY02_HOST}"


SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new
)


SCP_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new
)


##########################################################
# Build HAProxy PEM
##########################################################

cat \
    "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" \
    "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem" \
    > "\${CERT_PEM}"


chown root:haproxy "\${CERT_PEM}"

chmod 640 "\${CERT_PEM}"


##########################################################
# Validate local HAProxy
##########################################################

haproxy -c -f /etc/haproxy/haproxy.cfg


##########################################################
# Reload local HAProxy
##########################################################

systemctl reload haproxy


##########################################################
# Prepare known_hosts
##########################################################

mkdir -p /root/.ssh

chmod 700 /root/.ssh

touch /root/.ssh/known_hosts

chmod 600 /root/.ssh/known_hosts


##########################################################
# Check SSH connection
##########################################################

if ! ssh \
    "\${SSH_OPTS[@]}" \
    root@"\${PEER_HOST}" \
    "true"
then

    echo
    echo "ERROR:"
    echo "SSH connection to \${PEER_HOST} failed."
    echo

    exit 1
fi


##########################################################
# Prepare remote certificate directory
##########################################################

ssh \
    "\${SSH_OPTS[@]}" \
    root@"\${PEER_HOST}" \
    "
    mkdir -p '${CERT_DIR}'
    chown root:haproxy '${CERT_DIR}'
    chmod 750 '${CERT_DIR}'
    "


##########################################################
# Copy certificate
##########################################################

scp \
    "\${SCP_OPTS[@]}" \
    "\${CERT_PEM}" \
    root@"\${PEER_HOST}":"\${CERT_PEM}"


##########################################################
# Validate and reload peer HAProxy
##########################################################

ssh \
    "\${SSH_OPTS[@]}" \
    root@"\${PEER_HOST}" \
    "
    chown root:haproxy '\${CERT_PEM}'

    chmod 640 '\${CERT_PEM}'

    haproxy -c -f /etc/haproxy/haproxy.cfg

    if systemctl is-active --quiet haproxy; then

        systemctl reload haproxy

    else

        systemctl start haproxy

    fi
    "


echo
echo "Let's Encrypt certificate successfully deployed:"
echo
echo "  haproxy01"
echo "  \${PEER_HOST}"

EOF


    chmod 755 \
        /etc/letsencrypt/renewal-hooks/deploy/haproxy.sh


    ######################################################
    # Enable Certbot timer
    ######################################################

    echo
    echo "======================================================"
    echo "Enabling Certbot timer"
    echo "======================================================"

    systemctl enable --now certbot.timer || true


else

    ######################################################
    # Disable Certbot on haproxy02
    ######################################################

    echo
    echo "======================================================"
    echo "This node is not certificate manager"
    echo "======================================================"

    echo
    echo "Certbot automatic renewal disabled on:"
    echo
    echo "  ${NODE_NAME}"

    systemctl disable --now certbot.timer 2>/dev/null || true
fi


##########################################################
# Final HAProxy validation
##########################################################

echo
echo "======================================================"
echo "Final HAProxy validation"
echo "======================================================"

haproxy -c -f /etc/haproxy/haproxy.cfg


##########################################################
# Final status
##########################################################

echo
echo "======================================================"
echo "HAProxy setup completed"
echo "======================================================"

echo
echo "Node:"
echo "  ${NODE_NAME}"

echo
echo "Local IP:"
echo "  ${LOCAL_IP}"

echo
echo "Peer:"
echo "  ${PEER_HOST} (${PEER_IP})"

echo
echo "Keepalived VIP:"
echo "  ${HAPROXY_VIP}"

echo
echo "Public IP:"
echo "  ${PUBLIC_IP}"

echo
echo "FQDN:"
echo "  ${DOMAIN}"


echo
echo "------------------------------------------------------"

echo
echo "Zabbix:"
echo
echo "  https://${DOMAIN}/zabbix/"

echo
echo "Zabbix backends:"
echo
echo "  zbx01 ${ZABBIX_NODE1}:80"
echo "  zbx02 ${ZABBIX_NODE2}:80"


echo
echo "------------------------------------------------------"

echo
echo "Grafana:"
echo
echo "  https://${DOMAIN}/grafana/"

echo
echo "Grafana backends:"
echo
echo "  grafana01 ${GRAFANA_NODE1}:3000"
echo "  grafana02 ${GRAFANA_NODE2}:3000"


echo
echo "------------------------------------------------------"

echo
echo "PostgreSQL primary:"
echo
echo "  ${HAPROXY_VIP}:5432"

echo
echo "PostgreSQL replicas:"
echo
echo "  ${HAPROXY_VIP}:5433"


echo
echo "------------------------------------------------------"

echo
echo "HAProxy service:"
echo

systemctl status haproxy \
    --no-pager \
    --lines=10 || true


echo
echo "------------------------------------------------------"

echo
echo "Listeners:"
echo

ss -lntp | \
    grep -E ':80|:443|:5432|:5433|:7000' || true


echo
echo "------------------------------------------------------"

echo
echo "Certificate:"
echo

if [[ -s "${CERT_PEM}" ]]; then

    openssl x509 \
        -in "${CERT_PEM}" \
        -noout \
        -subject \
        -issuer \
        -dates
fi


echo
echo "======================================================"
echo "Done"
echo "======================================================"