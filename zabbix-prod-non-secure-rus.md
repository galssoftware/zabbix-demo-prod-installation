# Обзор Zabbix Demo
В этом демо настроим работу Zabbix-сервер в отказоустойчивой конфигурации с автоматическим переключением на резервный сервер PostgreSQL. А еще подключим Grafana в оптимальной конфигурации (с использованием DirectDB connection). Окружение тестировалось на серверах Ubuntu 24.04.

В репозитории вы найдете:
* документацию по установке и настройке компонентов
* примеры конфигурационных файлов
* процедуры тестирования отказоустойчивости


## Что будем использовать

| Компонент           | Назначение                  |
| ------------- | --------------------------- |
| PostgreSQL 18.4 | БД      |
| Patroni 4.1.3 | Оркестрация PostgreSQL |
| ETCD 3.4.30 | Распределенное хранилище состояния кластера|
|PGBouncer 1.25.2|Пулер соединений для PostgreSQL|
| Zabbix 7.4.13    | Мониторинг         |
|Nginx 1.24.0| Веб-сервер|
|PHP-FPM 8.3.6| Менеджер процессов PHP|
| HAProxy 2.8.16 | Балансировщик нагрузки     |
| Grafana 13.1.1 | Визуализация данных |
|Keepalived 2.2.8|Балансировщик нагрузки L4|


## Как будет выглядеть архитектура
Так будет выглядеть итоговая архитектура демо-инсталляции.
![Architecture Diagram](images/demo-installation.svg)

В инфраструктуре используются два сервера HAProxy и Keepalived для обеспечения высокой доступности сервисов.

Схема:

```text
haproxy01   192.168.0.2
haproxy02   192.168.0.3

VIP         192.168.0.100

Public IP   185.161.66.194
FQDN        haproxy.gals.training
```

Keepalived обеспечивает автоматическое переключение виртуального IP-адреса `192.168.0.100` между двумя HAProxy-серверами, а HAProxy выполняет маршрутизацию и балансировку трафика между backend-сервисами.

В конфигурации используются два отдельных скрипта:

- [`setup-haproxy.sh`](configs/setup-haproxy.sh) — установка и настройка HAProxy;
- `setup-keepalived.sh` — установка и настройка Keepalived.

Сами скрипты и их описание приведено ниже в документации.

## Где будем разворачивать
Для работы окружения нам понадобится 9 серверов.

| Компонент          | Количество | Имя сервера | IP адреса |
| --------------------- | ----- | --------------------- | --------------------- | 
| PostgreSQL      | 3     | pg01, pg02, pg03 | 192.168.0.20, 192.168.0.21, 192.168.0.22|
| Zabbix сервер   | 2     | zbx01, zbx02     | 192.168.0.10, 192.168.0.11|
| HAProxy         | 2     | haproxy          | 192.168.0.2, 192.168.0.3 | 
| Grafana         | 2     | grafana          | 192.168.0.4, 192.168.0.5 | 



## Последовательность действий

Установку и настройку будем выполнять в следующем порядке:

1. Настройка сетевого подключения и разрешения имен хостов.
2. Установка и настройка кластера ETCD.
3. Установка и настройка PostgreSQL 18.
4. Настройка управления кластером Patroni
5. Настройка репликации и отказоустойчивости PostgreSQL.
6. Проверка высокой доступности PostgreSQL
7. Установка и настройка PGBouncer.
8. Установка и настройка haproxy и keepalived
8. Установка и настройка Zabbix-серверов.
9. Настройка Zabbix HA.
10. Настройка балансировки нагрузки на стороне фронтенда HAProxy.
11. Проверка отказоустойчивости.


# Настройка Zabbix Demo

## Настройка сетевого подключения и разрешения имен хостов
На каждом сервере обновим ```/etc/hosts```, добавив записи.

```
cat << EOF >> /etc/hosts
192.168.0.2    haproxy01
192.168.0.3    haproxy02
192.168.0.4    grafana01
192.168.0.5    grafana02
192.168.0.10   zbx01
192.168.0.11   zbx02
192.168.0.20   pg01
192.168.0.21   pg02
192.168.0.22   pg03
192.168.0.100  cluster
EOF
```
## Установка компонентов БД: etcd, PostgreSQL, Patroni, TimescaleDB, PGBouncer
### Установка и настройка кластера ETCD

Установите компоненты etcd
```
apt update
apt install etcd-server etcd-client
```
Отредактируйте конфигурацию etcd на каждой ноде: pg01, pg02, pg03
```
nano /etc/default/etcd
```
На ноде pg01
```
cat << EOF >> /etc/default/etcd
ETCD_NAME="pg01"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.0.20:2380"
ETCD_LISTEN_PEER_URLS="http://192.168.0.20:2380"
ETCD_LISTEN_CLIENT_URLS="http://192.168.0.20:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.0.20:2379"
ETCD_INITIAL_CLUSTER="pg01=http://192.168.0.20:2380,pg02=http://192.168.0.21:2380,pg03=http://192.168.0.22:2380"
ETCD_INITIAL_CLUSTER_TOKEN="zabbix-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```
На ноде pg02
```
cat << EOF >> /etc/default/etcd
TCD_NAME="pg02"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.0.21:2380"
ETCD_LISTEN_PEER_URLS="http://192.168.0.21:2380"
ETCD_LISTEN_CLIENT_URLS="http://192.168.0.21:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.0.21:2379"
ETCD_INITIAL_CLUSTER="pg01=http://192.168.0.20:2380,pg02=http://192.168.0.21:2380,pg03=http://192.168.0.22:2380"
ETCD_INITIAL_CLUSTER_TOKEN="zabbix-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```
На ноде pg03
```
cat << EOF >> /etc/default/etcd
ETCD_NAME="pg03"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.0.22:2380"
ETCD_LISTEN_PEER_URLS="http://192.168.0.22:2380"
ETCD_LISTEN_CLIENT_URLS="http://192.168.0.22:2379,http://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.0.22:2379"
ETCD_INITIAL_CLUSTER="pg01=http://192.168.0.20:2380,pg02=http://192.168.0.21:2380,pg03=http://192.168.0.22:2380"
ETCD_INITIAL_CLUSTER_TOKEN="zabbix-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```
На каждой ноде добавьте etcd в автозагрузку и запустите его
```
systemctl enable --now etcd
```
Проверьте текущий статус etcd
```
etcdctl endpoint health --cluster=true
```
На этом установка etcd завершена.

#### Установка PostgreSQL

Все действия, описанные в этом разделе, выполняются на 3 серверах БД: pg01, pg02, pg03.
Начнем с установки БД PostgreSQL. Добавим репозиторий.

Для Ubuntu 24.04 LTS наиболее правильный способ установки PostgreSQL 18.4 — использовать официальный репозиторий PostgreSQL Global Development Group (PGDG). Он содержит актуальные версии PostgreSQL.

Установитн нужные пакеты
```
apt install -y curl ca-certificates postgresql-common
```
Подключите официальный репозиторий PostgreSQL (скрипт автоматом определит версию Ubuntu, добавит репозиторий, импортирует GPG-ключ, выполнит `apt update`)
```
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
```
Установите пакет БД
```
apt install -y postgresql-18
```
Проверьте установленную версию
```
psql --version
```
Так как для управления БД мы будем использовать Patroni, нужно остановить сервис СУБД, удалить его из автозагрузки и удалить созданный кластер.
```
systemctl disable postgresql --now
pg_dropcluster --stop 18 main
```
На этом установка БД завершена.
#### Установка Patroni

Все действия, описанные в этом разделе, выполняются на 3 серверах БД: pg01, pg02, pg03.
Установите Patroni
```
apt install -y patroni
```
Отредактируйте конфигурацию Patroni
```
nano /etc/patroni/config.yml
```
На ноде pg01
```
scope: postgres-cluster
namespace: /service/
name: pg01

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.0.20:8008

etcd3:
  hosts:
    - 192.168.0.20:2379
    - 192.168.0.21:2379
    - 192.168.0.22:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        shared_buffers: 1GB

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host all all 0.0.0.0/0 md5
    - host replication replicator 192.168.0.0/24 md5

  users:
    admin:
      password: 2tdxZ898D9MR
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.0.20:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin

  authentication:
    superuser:
      username: postgres
      password: 2tdxZ898D9MR
    replication:
      username: replicator
      password: 2tdxZ898D9MR

  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```
На ноде pg02
```
scope: postgres-cluster
namespace: /service/
name: pg02

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.0.21:8008

etcd3:
  hosts:
    - 192.168.0.20:2379
    - 192.168.0.21:2379
    - 192.168.0.22:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        shared_buffers: 1GB

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host all all 0.0.0.0/0 md5
    - host replication replicator 192.168.0.0/24 md5

  users:
    admin:
      password: 2tdxZ898D9MR
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.0.21:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin

  authentication:
    superuser:
      username: postgres
      password: 2tdxZ898D9MR
    replication:
      username: replicator
      password: 2tdxZ898D9MR

  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```
На ноде pg03
```
scope: postgres-cluster
namespace: /service/
name: pg03

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.0.22:8008

etcd3:
  hosts:
    - 192.168.0.20:2379
    - 192.168.0.21:2379
    - 192.168.0.22:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576

    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        shared_buffers: 1GB

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host all all 0.0.0.0/0 md5
    - host replication replicator 192.168.0.0/24 md5

  users:
    admin:
      password: 2tdxZ898D9MR
      options:
        - createrole
        - createdb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.0.22:5432
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin

  authentication:
    superuser:
      username: postgres
      password: 2tdxZ898D9MR
    replication:
      username: replicator
      password: 2tdxZ898D9MR

  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```
Перезагрузите Patroni
```
systemctl enable patroni --now
```
Убедитесь, что Patroni видит все ноды. В ответе вы должны увидеть 3 ноды кластера.
```
patronictl -c /etc/patroni/config.yml list
```
На этом установка Patroni завершена.
#### Установка TimescaleDB
Добавьте репозиторий TimescaleDB (выполните на 3 серверах БД: pg01, pg02, pg03)
```
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/timescaledb-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/timescaledb-archive-keyring.gpg] \
https://packagecloud.io/timescale/timescaledb/ubuntu/ noble main" | sudo tee /etc/apt/sources.list.d/timescaledb.list
apt update
apt install -y timescaledb-2-postgresql-18
```
Так как управление кластером происходит через Patroni, необходимо подключить расширение TimescaleDB. Отредактируйте конфигурацию Patroni и добавьте расширение TimescaleDB
```
patronictl -c /etc/patroni/config.yml edit-config
```
Нужно встроить в файл следующую конструкцию
```
postgresql:
  parameters:
    shared_preload_libraries: timescaledb
```
После этого перезагрузить последовательно ноды PostgreSQL. Начните с реплик и закончите лидером.
```
patronictl -c /etc/patroni/config.yml restart postgres-cluster pg02
patronictl -c /etc/patroni/config.yml restart postgres-cluster pg03
patronictl -c /etc/patroni/config.yml restart postgres-cluster pg01
```
После перезагрузки убедитесь, что расширение загрузилось
```
sudo -u postgres psql -h 127.0.0.1 -p 5432 -d postgres
SHOW shared_preload_libraries;
```


#### Установка PGBouncer
Установите PGBouncer (выполните на 3 серверах БД: pg01, pg02, pg03), добавьте его в автозагрузку и остановите
```
apt install -y pgbouncer
systemctl enable pgbouncer
systemctl stop pgbouncer
```

Создайте необходимые роли Zabbix и базы данных. Необходимо создать 2 базы (zabbix_server и grafana), а также 4 роли:
`zabbix_srv` будет использоваться для подключения Zabbix Server к БД Zabbix
`zabbix_web` будет использоваться для подключения Zabbix Frontend к БД Zabbix. Создайте отдельного пользователя Zabbix Frontend для упрощения диагностики работы БД в будущем.
`grafana_zabbix` будет использоваться для подключения Grafana к БД Zabbix
`grafana` будет использоваться для подключения Grafana к БД Grafana
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h 127.0.0.1 \
  -p 5432 \
  -U postgres

CREATE ROLE zabbix_srv LOGIN PASSWORD '2tdxZ898D9MR';
CREATE ROLE zabbix_web LOGIN PASSWORD '2tdxZ898D9MR';
CREATE ROLE grafana_zabbix LOGIN PASSWORD '2tdxZ898D9MR';
CREATE ROLE grafana LOGIN PASSWORD '2tdxZ898D9MR';
CREATE DATABASE zabbix_server OWNER zabbix_srv;
CREATE DATABASE grafana OWNER 'grafana';
```
Получиnt SCRAM-секреты пользователей (понадобятся для работы PGBouncer)
SELECT rolname || '|' || rolpassword FROM pg_authid WHERE rolname IN ('zabbix_srv', 'zabbix_web', 'grafana', 'grafana_zabbix');

Добавьте записи в конфигурационный файл /etc/pgbouncer/userlist.txt (выполните на 3 серверах БД: pg01, pg02, pg03). В вашем случае хэши паролей будут отличаться.
```
nano /etc/pgbouncer/userlist.txt 
"zabbix_srv" "SCRAM-SHA-256$4096:Dt2pydTlGUvc9CckB8EGBw==$d6z6YYLy+A8B3bdxucXDVpg85gl84tIJehhIyHuVvwg=:R9NctBV2LcaXql3PsNDp3YuFjDVX2KftF9C2IENK3uE="
"zabbix_web" "SCRAM-SHA-256$4096:AR8hHO9nLBjrZitlANy8IQ==$0qABD5ghyOyc8dmMZblvVV+SC22FNJsHkqP42y+I2dw=:MhL0utZXPhspp+QjsOoSyDfSlkaXM4vRkg31Zz5VCxA="
"grafana_zabbix" "SCRAM-SHA-256$4096:vOLwdJq2iQlAErxB/tmr3Q==$aGsEz/IDYGMWpircIyLuXJ5iZSKZqv1eFRQW7rgA2FA=:Gh+NhWMdjFPlgjo94WcB8bamojLi3vN4Jyf/RG10MKU="
"grafana" "SCRAM-SHA-256$4096:kHvnLIdYr4iXTNNpvxlOxQ==$T9fv3QwJEgpHf5geLicCJX5CO+lln/7AC29ev8GinKU=:xSoqpjhYH/nkHuvWH7R5cSHFaE29HOL3ekwLEB6pAg0="
```
Установите права на конфигурационный файл (выполните на 3 серверах БД: pg01, pg02, pg03)
```
chown postgres:postgres /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt
```

Модифицируйте файл /etc/pgbouncer/pgbouncer.ini (выполните на 3 серверах БД: pg01, pg02, pg03), добавив/изменив значения в соответствующих секциях
```
nano /etc/pgbouncer/pgbouncer.ini
[databases]
zabbix_server = host=127.0.0.1 port=5432 dbname=zabbix_server
grafana = host=127.0.0.1 port=5432 dbname=grafana pool_mode=session
[pgbouncer]
listen_addr = 0.0.0.0
auth_type = scram-sha-256
pool_mode = transaction
max_client_conn = 500
default_pool_size = 100
```
 
Перезагрузите PGBouncer (выполните на 3 серверах БД: pg01, pg02, pg03)
```
systemctl restart pgbouncer
```
Проверьте подключение (выполните на 3 серверах БД: pg01, pg02, pg03)
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h 127.0.0.1 \
  -p 6432 \
  -U zabbix_srv \
  -d zabbix_server \
  -c "SELECT current_user, pg_is_in_recovery();"
```
На репликах в столбце pg_is_in_recovery получите t, а на лидере f.

## Настройка балансировки нагрузки



### Установка Haproxy
Выполните установку haproxy на обоих нодах haproxy: haproxy01 и haproxy02. Скрипт установит и запустит haproxy, создаст сертификаты Let's Encrypt, применит необходимую конфигурацию и перенесет сертификаты Let's Encrypt на сервер haproxy02.
```
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
```
На этом установка и настройка haproxy завершена. Просмотрите вывод скрипта на предмет наличия ошибок выполнения.

### Установка keepalived

Выполните установку keepalived на обоих нодах haproxy: haproxy01 и haproxy02
```
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
```
На этом установка и настройка keepalived завершена. Проверьте вывод скрипта на предмет наличия ошибок.

### Установка Zabbix Server, Zabbix Frontend

Установите клиент PostgreSQL и утилиту curl на обоих серверах Zabbix (zbx01, zbx02). Они нам пригодятся при дальнейшем тестировании подключения.
```
apt update
apt install -y curl postgresql-common
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
apt install -y postgresql-client-18
```
Добавьте репозиторий Zabbix (выполните на zbx01, zbx02)
```
wget https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest+ubuntu24.04_all.deb
apt update
```
Установите компоненты Zabbix
```
apt install -y \
  zabbix-server-pgsql \
  zabbix-frontend-php \
  zabbix-nginx-conf \
  zabbix-sql-scripts \
  zabbix-agent2 \
  php8.3-pgsql
```
Первичное создание базы и импорт лучше выполнять напрямую через порт PostgreSQL 5432 текущего Leader, а не через PgBouncer. Это исключает влияние пула и смену backend во время длительного импорта. Проверьте кто сейчас является лидером
```
patronictl -c /etc/patroni/config.yml list
```
Проверьте прямое подключение к БД через haproxy с обоих Zabbix-серверов
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -p 5432 \
  -U zabbix_srv \
  -d zabbix_server \
  -c "SELECT current_user, current_database(), pg_is_in_recovery();"
```
Импортируйте основную схему Zabbix
```
zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz \
| PGPASSWORD='2tdxZ898D9MR' \
  psql \
    -h "haproxy" \
    -p 5432 \
    -U zabbix_srv \
    -d zabbix_server \
    -v ON_ERROR_STOP=1
```
Убедитесь, что схема была создана:
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -U zabbix_srv \
  -d zabbix_server \
  -c "\dt"
```
Создайте расширение TimescaleDB на Leader:
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h haproxy \
  -d zabbix_server \
  -v ON_ERROR_STOP=1 \
  -U postgres \
  -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
```

Настройте Zabbix на использование гипертаблиц. Скрипт timescaledb/schema.sql создает hypertable и настраивает параметры housekeeping и сжатия. Предупреждения TimescaleDB 2.9+ о несоблюдении некоторых best practices при выполнении этого скрипта можно игнорировать — Zabbix указывает, что настройка при этом завершается успешно.
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -p 5432 \
  -U zabbix_srv \
  -d zabbix_server \
  -v ON_ERROR_STOP=1 \
  -f /usr/share/zabbix/sql-scripts/postgresql/timescaledb/schema.sql
```
Убедитесь, что гипертаблицы были созданы
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -U zabbix_srv \
  -d zabbix_server \
  -c "
SELECT hypertable_schema,
       hypertable_name,
       num_dimensions
FROM timescaledb_information.hypertables
ORDER BY hypertable_name;
"
```
Выдайте права учетной записи `zabbix_web` на все созданные таблицы
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -U postgres \
  -d zabbix_server
GRANT CONNECT ON DATABASE zabbix_server TO zabbix_web;
GRANT USAGE ON SCHEMA public TO zabbix_web;
GRANT ALL ON ALL TABLES IN SCHEMA public TO zabbix_web;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO zabbix_web;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO zabbix_web;
GRANT ALL ON ALL PROCEDURES IN SCHEMA public TO zabbix_web;
```
Выдайте права на чтение исторических таблиц для `grafana_zabbix`
```
PGPASSWORD='2tdxZ898D9MR' \
psql \
  -h "haproxy" \
  -U postgres \
  -d zabbix_server
GRANT CONNECT ON DATABASE zabbix_server TO grafana_zabbix;
GRANT USAGE ON SCHEMA public TO grafana_zabbix;
GRANT SELECT ON TABLE history TO grafana_zabbix;
GRANT SELECT ON TABLE history_uint TO grafana_zabbix;
GRANT SELECT ON TABLE history_str TO grafana_zabbix;
GRANT SELECT ON TABLE history_text TO grafana_zabbix;
GRANT SELECT ON TABLE history_log TO grafana_zabbix;
GRANT SELECT ON TABLE trends TO grafana_zabbix;
GRANT SELECT ON TABLE trends_uint TO grafana_zabbix;
```
Настройте конфигурацию Zabbix сервер на обоих нодах
```
nano /etc/zabbix/zabbix_server.conf
DBHost=haproxy
DBName=zabbix_server
DBUser=zabbix_srv
DBPassword=2tdxZ898D9MR
```
На ноде zbx01 дополнительно настройте
```
HANodeName=zbx01
NodeAddress=192.168.0.10:10051
```
На ноде zbx02 дополнительно настройте
```
HANodeName=zbx02
NodeAddress=192.168.0.11:10051
```

#### Настройка Nginx
На нодах zbx01 и zbx02 проверьте настройки Nginx на предмет сайтов по умолчанию
```
grep -R "listen .*80" \
  /etc/nginx/nginx.conf \
  /etc/nginx/sites-enabled \
  /etc/nginx/conf.d \
  /etc/zabbix 2>/dev/null
```
При необходимости, удалите сайт по умолчанию:
```
rm -f /etc/nginx/sites-enabled/default
```
Отредактируйте конфигурацию Zabbix (раскомментируйте строки)
```
nano /etc/nginx/conf.d/zabbix.conf
    listen          80;
    server_name     _;
```

### Установка Grafana 

Подготовьте сервер:
```
apt update
apt upgrade -y
apt install -y \
  apt-transport-https \
  ca-certificates \
  wget \
  gnupg
```
Добавьте репозиторий, добавьте Grafana в автозагрузку и установите плагин Zabbix
```
apt-get install -y adduser libfontconfig1 musl
wget https://dl.grafana.com/grafana/release/13.1.1/grafana_13.1.1_29761037902_linux_amd64.deb
dpkg -i grafana_13.1.1_29761037902_linux_amd64.deb
systemctl daemon-reload
systemctl enable grafana-server
grafana cli plugins install alexanderzobnin-zabbix-app
```
Настройте Grafana
```
nano /etc/grafana/grafana.ini
[server]
root_url = https://haproxy.gals.training/grafana/
serve_from_sub_path = true
[database]
type = postgres
host = haproxy:5432
name = grafana
user = grafana
password = 2tdxZ898D9MR


```
Запустите Grafana
```
systemctl start grafana-server
```

Включите плагин Zabbix


Настройте источник данных PostgreSQL (БД Zabbix)


Настройте источник данных Zabbix



