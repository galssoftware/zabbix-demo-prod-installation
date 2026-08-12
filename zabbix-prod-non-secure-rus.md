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
- [`setup-keepalived.sh`](configs/setup-keepalived.sh) — установка и настройка Keepalived.

Описание принципа работы скриптов приведено ниже в документации.

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

### Установка PostgreSQL

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
### Установка Patroni

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
### Установка TimescaleDB
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


### Установка PGBouncer
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

## Настройка балансировки нагрузки (HAProxy + Keepalived)

В этом разделе описаны принципы работы скриптов-установщиков и порядок действий для установки компонентов.

### Установка HAProxy
Выполните установку haproxy на обоих нодах haproxy: haproxy01 и haproxy02 при помощи скрипта [`setup-haproxy.sh`](configs/setup-haproxy.sh).

<details>
<summary>Детальное описание принципов работы скрипта</summary>
Скрипт `setup-haproxy.sh` предназначен для автоматизированной установки и настройки HAProxy на серверах:

```text
haproxy01 — 192.168.0.2
haproxy02 — 192.168.0.3
```

Один и тот же скрипт может запускаться на обеих нодах. Скрипт автоматически определяет текущий сервер по его IP-адресу и применяет соответствующие параметры.

HAProxy используется как единая точка доступа к следующим сервисам:

```text
Zabbix
Grafana
PostgreSQL / Patroni
```

---

#### Устанавливаемые компоненты

Скрипт устанавливает необходимые пакеты:

```text
haproxy
certbot
ca-certificates
curl
dnsutils
openssl
openssh-client
```

Установка выполняется в неинтерактивном режиме.

Для предотвращения перезаписи локально изменённых конфигурационных файлов, например:

```text
/etc/ssh/sshd_config
```

используются параметры:

```text
--force-confdef
--force-confold
```

Таким образом, существующие настройки SSH сохраняются.

---

#### Определение HAProxy-ноды

Скрипт автоматически определяет, на каком сервере он выполняется.

Для `haproxy01`:

```text
IP:       192.168.0.2
Hostname: haproxy01
Peer:     haproxy02
```

Для `haproxy02`:

```text
IP:       192.168.0.3
Hostname: haproxy02
Peer:     haproxy01
```

Определение выполняется по локальному IP-адресу интерфейса.

---

#### Работа с виртуальным IP

Для PostgreSQL HAProxy слушает виртуальный адрес Keepalived:

```text
192.168.0.100
```

Так как на BACKUP-сервере данный IP физически отсутствует до момента failover, скрипт включает системный параметр:

```text
net.ipv4.ip_nonlocal_bind = 1
```

Это позволяет HAProxy запускаться и заранее создавать listener'ы для VIP даже на резервной ноде.

Настройка сохраняется в:

```text
/etc/sysctl.d/99-haproxy.conf
```

---

#### HTTPS и сертификат Let's Encrypt

Для веб-интерфейсов используется FQDN:

```text
haproxy.gals.training
```

Публичная DNS-запись должна указывать на:

```text
185.161.66.194
```

Пример:

```text
haproxy.gals.training → 185.161.66.194
```

Публичный адрес должен быть NAT'ирован на Keepalived VIP:

```text
185.161.66.194:80
    ↓
192.168.0.100:80

185.161.66.194:443
    ↓
192.168.0.100:443
```

---

#### Получение сертификата

Получением и автоматическим продлением сертификата занимается только:

```text
haproxy01
```

Перед запросом сертификата скрипт проверяет наличие DNS-записи и соответствие IP:

```text
haproxy.gals.training → 185.161.66.194
```

Если DNS-запись отсутствует или указывает на другой IP, выполнение останавливается.

---

#### HTTP-01 challenge

Certbot используется в режиме:

```text
standalone
```

и локально слушает:

```text
192.168.0.2:8888
```

При этом Let's Encrypt обращается к серверу через стандартный HTTP-порт:

```text
haproxy.gals.training:80
```

HAProxy перехватывает запросы:

```text
/.well-known/acme-challenge/
```

и перенаправляет их на:

```text
haproxy01:8888
```

Схема:

```text
Let's Encrypt
      |
      | HTTP :80
      v
185.161.66.194
      |
      v
192.168.0.100
      |
      v
HAProxy MASTER
      |
      | /.well-known/acme-challenge/
      v
haproxy01:8888
      |
      v
Certbot
```

Преимущество такого подхода заключается в том, что HAProxy не требуется останавливать во время продления сертификата.

---

#### Временный сертификат

Для первичного запуска HAProxy скрипт автоматически создаёт временный self-signed сертификат.

Он необходим потому, что HAProxy проверяет наличие SSL-сертификата уже при запуске конфигурации.

После успешного получения сертификата Let's Encrypt временный сертификат заменяется на действующий.

Файл HAProxy PEM:

```text
/etc/haproxy/certs/haproxy.gals.training.pem
```

Он содержит:

```text
fullchain.pem
+
privkey.pem
```

---

#### Синхронизация сертификата между HAProxy

После получения или обновления сертификата на `haproxy01` он автоматически копируется на:

```text
haproxy02
```

Передача выполняется по SSH/SCP:

```text
haproxy01 → haproxy02
```

Используется существующая авторизация по SSH-ключу.

Скрипт самостоятельно SSH-ключи не создаёт.

---

#### Работа с known_hosts

Для автоматической обработки первого SSH-подключения используется:

```text
StrictHostKeyChecking=accept-new
```

Это означает:

- новый SSH host key автоматически добавляется в `/root/.ssh/known_hosts`;
- интерактивный запрос подтверждения не появляется;
- если ключ уже известного сервера неожиданно изменился, SSH завершит соединение с ошибкой.

Таким образом, скрипт может выполняться полностью автоматически без использования небезопасного `StrictHostKeyChecking=no`.

---

#### Автоматическое продление сертификата

На `haproxy01` включается:

```text
certbot.timer
```

На `haproxy02` автоматический Certbot отключается.

После успешного renewal запускается deploy hook:

```text
/etc/letsencrypt/renewal-hooks/deploy/haproxy.sh
```

Hook выполняет:

```text
1. Формирование нового HAProxy PEM
2. Проверку конфигурации HAProxy
3. Reload HAProxy на haproxy01
4. Копирование сертификата на haproxy02
5. Проверку HAProxy на haproxy02
6. Reload HAProxy на haproxy02
```

Таким образом, на обеих HAProxy-нодах всегда используется один и тот же сертификат.

---

#### Балансировка Zabbix

HAProxy балансирует HTTP-трафик между двумя Zabbix frontend:

```text
zbx01 — 192.168.0.10:80
zbx02 — 192.168.0.11:80
```

Используется алгоритм:

```text
roundrobin
```

Внешний URL:

```text
https://haproxy.gals.training/zabbix/
```

Путь:

```text
/zabbix/
```

удаляется перед передачей на backend.

Например:

```text
https://haproxy.gals.training/zabbix/index.php
```

преобразуется в:

```text
http://zbx01/index.php
```

или:

```text
http://zbx02/index.php
```

Для backend'ов передаются заголовки:

```text
X-Forwarded-Prefix: /zabbix
X-Forwarded-Proto: https
```

---

#### Health check Zabbix

HAProxy выполняет HTTP-проверку:

```text
GET /
```

Ожидаемый код ответа:

```text
200
```

Если Zabbix frontend несколько раз подряд не проходит проверку, он временно исключается из балансировки.

После восстановления сервер автоматически возвращается в пул.

---

#### Балансировка Grafana

Используются две Grafana-ноды:

```text
grafana01 — 192.168.0.4:3000
grafana02 — 192.168.0.5:3000
```

Алгоритм балансировки:

```text
roundrobin
```

Внешний URL:

```text
https://haproxy.gals.training/grafana/
```

Для проверки работоспособности Grafana используется:

```text
GET /api/health
```

Ожидаемый HTTP-код:

```text
200
```

При недоступности одной Grafana весь трафик автоматически направляется на оставшуюся рабочую ноду.

---

#### Балансировка PostgreSQL / Patroni

HAProxy предоставляет два отдельных endpoint'а для PostgreSQL.

##### Primary

```text
192.168.0.100:5432
```

Предназначен для подключения к текущему PostgreSQL Primary.

HAProxy проверяет Patroni REST API:

```text
GET /primary
```

на порту:

```text
8008
```

Если узел является текущим Primary, Patroni возвращает успешный ответ и HAProxy направляет PostgreSQL-соединения на его PgBouncer:

```text
6432
```

Backend'ы:

```text
pg01 — 192.168.0.20:6432
pg02 — 192.168.0.21:6432
pg03 — 192.168.0.22:6432
```

---

##### Replicas

Для read-only соединений используется:

```text
192.168.0.100:5433
```

HAProxy проверяет:

```text
GET /replica
```

и балансирует подключения между доступными PostgreSQL replica.

Алгоритм:

```text
roundrobin
```

---

#### HAProxy Statistics

Локально на каждой HAProxy-ноде включён web-интерфейс статистики:

```text
http://127.0.0.1:7000/
```

Он используется как для диагностики HAProxy, так и для health-check со стороны Keepalived.

Текущая Basic Authentication:

```text
admin:admin
```

В production рекомендуется заменить пароль.

---

#### Проверка конфигурации HAProxy

Перед применением конфигурации выполняется:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
```

Если обнаружена синтаксическая ошибка, скрипт прекращает выполнение.

Перед изменением существующего файла создаётся резервная копия:

```text
/etc/haproxy/haproxy.cfg.bak.<date-time>
```

---
</details>

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



