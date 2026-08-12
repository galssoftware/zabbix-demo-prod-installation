#!/usr/bin/env bash

set -euo pipefail


##########################################################
# General configuration
##########################################################

HAPROXY01_IP="192.168.0.2"
HAPROXY02_IP="192.168.0.3"

HAPROXY01_HOST="haproxy01"
HAPROXY02_HOST="haproxy02"

# Keepalived VIP
VIP="192.168.0.100"

# Prefix
VIP_PREFIX="24"

# VRRP Virtual Router ID
VRID="51"

# HAProxy stats
HAPROXY_STATS_URL="http://127.0.0.1:7000/"
HAPROXY_STATS_USER="admin"
HAPROXY_STATS_PASSWORD="admin"


##########################################################
# Detect current node
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

    STATE="MASTER"
    PRIORITY="150"

elif ip -4 addr show | grep -qE "\b${HAPROXY02_IP}/"; then

    LOCAL_IP="${HAPROXY02_IP}"
    LOCAL_HOST="${HAPROXY02_HOST}"

    PEER_IP="${HAPROXY01_IP}"
    PEER_HOST="${HAPROXY01_HOST}"

    NODE_NAME="haproxy02"

    STATE="BACKUP"
    PRIORITY="100"

else

    echo
    echo "ERROR:"
    echo
    echo "Current node does not have:"
    echo
    echo "  ${HAPROXY01_IP}"
    echo "or"
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
echo "State      : ${STATE}"
echo "Priority   : ${PRIORITY}"
echo "VIP        : ${VIP}"


##########################################################
# Detect network interface
##########################################################

echo
echo "======================================================"
echo "Detecting network interface"
echo "======================================================"

INTERFACE="$(
    ip -o -4 addr show |
    awk -v ip="${LOCAL_IP}" '
        $4 ~ "^" ip "/" {
            print $2
            exit
        }
    '
)"


if [[ -z "${INTERFACE}" ]]; then

    echo
    echo "ERROR:"
    echo
    echo "Unable to detect network interface for:"
    echo
    echo "  ${LOCAL_IP}"
    echo

    exit 1
fi


echo
echo "Network interface:"
echo
echo "  ${INTERFACE}"


##########################################################
# Install Keepalived
##########################################################

echo
echo "======================================================"
echo "Installing Keepalived"
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a


apt-get update


apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    keepalived \
    curl


##########################################################
# Backup existing Keepalived configuration
##########################################################

echo
echo "======================================================"
echo "Backing up Keepalived configuration"
echo "======================================================"

mkdir -p /etc/keepalived


if [[ -f /etc/keepalived/keepalived.conf ]]; then

    BACKUP_FILE="/etc/keepalived/keepalived.conf.bak.$(date +%F-%H%M%S)"

    cp \
        /etc/keepalived/keepalived.conf \
        "${BACKUP_FILE}"


    echo
    echo "Backup created:"
    echo
    echo "  ${BACKUP_FILE}"
fi


##########################################################
# Create HAProxy health-check script
##########################################################
#
# Проверяем не только наличие процесса HAProxy,
# но и работу stats HTTP endpoint.
#
##########################################################

echo
echo "======================================================"
echo "Creating HAProxy health check"
echo "======================================================"

cat > /usr/local/bin/check-haproxy.sh <<EOF
#!/usr/bin/env bash

set -e

##########################################################
# First check systemd service
##########################################################

if ! systemctl is-active --quiet haproxy; then
    exit 1
fi


##########################################################
# Check HAProxy statistics HTTP endpoint
##########################################################

if ! curl \
    --silent \
    --show-error \
    --fail \
    --max-time 2 \
    --user "${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASSWORD}" \
    "${HAPROXY_STATS_URL}" \
    >/dev/null
then
    exit 1
fi


exit 0
EOF


chmod 755 /usr/local/bin/check-haproxy.sh


##########################################################
# Test HAProxy health check
##########################################################

echo
echo "======================================================"
echo "Testing HAProxy health check"
echo "======================================================"

if /usr/local/bin/check-haproxy.sh; then

    echo
    echo "HAProxy health check: OK"

else

    echo
    echo "WARNING:"
    echo
    echo "HAProxy health check currently fails."
    echo
    echo "Keepalived will not become MASTER until HAProxy"
    echo "is available."
    echo

fi


##########################################################
# Create Keepalived configuration
##########################################################

echo
echo "======================================================"
echo "Creating Keepalived configuration"
echo "======================================================"

cat > /etc/keepalived/keepalived.conf <<EOF
##########################################################
# Global configuration
##########################################################

global_defs {

    router_id ${NODE_NAME}

    enable_script_security

    script_user root
}


##########################################################
# HAProxy health check
##########################################################

vrrp_script check_haproxy {

    script "/usr/local/bin/check-haproxy.sh"

    interval 2
    timeout 2

    fall 3
    rise 2

    weight 0
}


##########################################################
# HAProxy VRRP instance
##########################################################

vrrp_instance VI_HAPROXY {

    state ${STATE}

    interface ${INTERFACE}

    virtual_router_id ${VRID}

    priority ${PRIORITY}

    advert_int 1


    ######################################################
    # Unicast VRRP
    ######################################################

    unicast_src_ip ${LOCAL_IP}

    unicast_peer {
        ${PEER_IP}
    }


    ######################################################
    # VRRP authentication
    ######################################################

    authentication {
        auth_type PASS
        auth_pass GalsHA51
    }


    ######################################################
    # Virtual IP
    ######################################################

    virtual_ipaddress {
        ${VIP}/${VIP_PREFIX} dev ${INTERFACE}
    }


    ######################################################
    # HAProxy tracking
    ######################################################

    track_script {
        check_haproxy
    }
}
EOF


chmod 600 /etc/keepalived/keepalived.conf


##########################################################
# Show generated configuration
##########################################################

echo
echo "======================================================"
echo "Generated Keepalived configuration"
echo "======================================================"

cat /etc/keepalived/keepalived.conf


##########################################################
# Validate Keepalived configuration
##########################################################

echo
echo "======================================================"
echo "Validating Keepalived configuration"
echo "======================================================"

KEEPALIVED_HELP="$(keepalived --help 2>&1 || true)"


if echo "${KEEPALIVED_HELP}" | grep -q -- "--config-test"; then

    echo
    echo "Using:"
    echo
    echo "  keepalived --config-test"
    echo

    if ! keepalived --config-test; then

        echo
        echo "ERROR:"
        echo
        echo "Keepalived configuration validation failed."
        echo

        exit 1
    fi


elif echo "${KEEPALIVED_HELP}" | grep -qE '(^|[[:space:],])-t([[:space:],]|$)'; then

    echo
    echo "Using:"
    echo
    echo "  keepalived -t"
    echo

    if ! keepalived -t; then

        echo
        echo "ERROR:"
        echo
        echo "Keepalived configuration validation failed."
        echo

        exit 1
    fi


else

    echo
    echo "WARNING:"
    echo
    echo "This Keepalived version does not expose"
    echo "--config-test or -t."
    echo
    echo "Configuration will be validated during service start."
    echo

fi


##########################################################
# Enable Keepalived
##########################################################

echo
echo "======================================================"
echo "Enabling Keepalived"
echo "======================================================"

systemctl enable keepalived


##########################################################
# Restart Keepalived
##########################################################

echo
echo "======================================================"
echo "Starting Keepalived"
echo "======================================================"

systemctl restart keepalived


##########################################################
# Verify service
##########################################################

sleep 2


if ! systemctl is-active --quiet keepalived; then

    echo
    echo "======================================================"
    echo "ERROR: Keepalived failed to start"
    echo "======================================================"

    echo
    echo "Keepalived logs:"
    echo

    journalctl \
        -u keepalived \
        -n 100 \
        --no-pager

    exit 1
fi


##########################################################
# Final status
##########################################################

echo
echo "======================================================"
echo "Keepalived setup completed"
echo "======================================================"

echo
echo "Node:"
echo
echo "  ${NODE_NAME}"

echo
echo "State:"
echo
echo "  ${STATE}"

echo
echo "Priority:"
echo
echo "  ${PRIORITY}"

echo
echo "Local IP:"
echo
echo "  ${LOCAL_IP}"

echo
echo "Peer:"
echo
echo "  ${PEER_HOST} (${PEER_IP})"

echo
echo "Interface:"
echo
echo "  ${INTERFACE}"

echo
echo "VIP:"
echo
echo "  ${VIP}/${VIP_PREFIX}"


echo
echo "------------------------------------------------------"
echo "Keepalived service"
echo "------------------------------------------------------"
echo

systemctl status keepalived \
    --no-pager \
    --lines=20 || true


echo
echo "------------------------------------------------------"
echo "HAProxy health check"
echo "------------------------------------------------------"
echo

if /usr/local/bin/check-haproxy.sh; then

    echo "HAProxy: HEALTHY"

else

    echo "HAProxy: UNHEALTHY"

fi


echo
echo "------------------------------------------------------"
echo "VIP on this node"
echo "------------------------------------------------------"
echo

ip -4 addr show "${INTERFACE}" |
    grep "${VIP}" || true


echo
echo "------------------------------------------------------"
echo "Keepalived logs"
echo "------------------------------------------------------"
echo

journalctl \
    -u keepalived \
    -n 30 \
    --no-pager


echo
echo "======================================================"
echo "Done"
echo "======================================================"