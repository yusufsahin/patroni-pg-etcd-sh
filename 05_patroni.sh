#!/usr/bin/env bash
set -euo pipefail
[ -f /etc/patroni/env ] && . /etc/patroni/env || { echo "/etc/patroni/env yok; önce 01_env.sh"; exit 1; }

: "${CLUSTER_NAME:?}" "${NODE_NAME:?}" "${NODE_IP:?}" "${PGVER:?}" "${PGDATA:?}" "${ETCD_ENDPOINTS:?}"
: "${PATRONI_DIR:=/etc/patroni}" "${PATRONI_ENV:=/etc/patroni/env}"
: "${CLUSTER_NET:=10.10.100.0/22}"

BIN_PATRONI="/usr/local/bin/patroni"
BIN_PATRONICTL="/usr/local/bin/patronictl"
PG_BIN_DIR="/usr/pgsql-${PGVER}/bin"
REST_PORT="8008"

echo "[*] Patroni kuruluyor..."
pip3 show patroni >/dev/null 2>&1 || pip3 install "patroni[etcd]"

# Psycopg (v3 veya psycopg2) – patronictl/patroni için
python3 -c "import psycopg" 2>/dev/null || python3 -c "import psycopg2" 2>/dev/null || \
  { echo "[*] psycopg kuruluyor..."; pip3 install "psycopg[binary]" || pip3 install psycopg2-binary; }

install -d -o root -g root -m 0755 "${PATRONI_DIR}"
chmod 0644 "${PATRONI_ENV}"

# postgres home & .pgpass
install -d -o postgres -g postgres -m 0750 /var/lib/pgsql
touch /var/lib/pgsql/.pgpass && chown postgres:postgres /var/lib/pgsql/.pgpass && chmod 0600 /var/lib/pgsql/.pgpass

# Patroni YAML (etcd3.hosts listesi ve listen alanları tam)
cat > "${PATRONI_DIR}/patroni.yml" <<YML
scope: ${CLUSTER_NAME}
name: ${NODE_NAME}

restapi:
  listen: ${NODE_IP}:${REST_PORT}
  connect_address: ${NODE_IP}:${REST_PORT}

etcd3:
  hosts:
    - 10.10.100.54:2379
    - 10.10.100.55:2379
    - 10.10.100.56:2379

postgresql:
  bin_dir: ${PG_BIN_DIR}
  data_dir: ${PGDATA}
  # Patroni'nin PG'ye bağlanacağı adres/port (zorunlu alanlar)
  listen: ${NODE_IP}:5432
  connect_address: ${NODE_IP}:5432
  pgpass: /var/lib/pgsql/.pgpass
  use_unix_socket: true
  parameters:
    # İstersen TCP üzerinden localhost'u da aç: listen_addresses='*'
    listen_addresses: '*'
    wal_level: replica
    hot_standby: "on"
    max_wal_senders: 16
    max_replication_slots: 16
    shared_buffers: "256MB"
    max_connections: 200
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      password: replicator_pass
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: 100M
    checkpoint: fast
  pg_hba:
    - "local   all             all                                     trust"
    - "host    all             all             127.0.0.1/32            trust"
    - "host    all             all             ${CLUSTER_NET}          md5"
    - "host    replication     all             ${CLUSTER_NET}          md5"

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    postgresql:
      use_pg_rewind: true
      parameters:
        archive_mode: "on"
        archive_command: "true"
  initdb:
    - encoding: UTF8
    - data-checksums
  users:
    replicator:
      password: replicator_pass
      options:
        - REPLICATION

watchdog:
  mode: off

log:
  level: INFO
YML

chown -R postgres:postgres "${PATRONI_DIR}"
chmod 0644 "${PATRONI_DIR}/patroni.yml"

# systemd unit – EnvironmentFile dosyamız "VAR=VALUE" (export YOK)
cat > /etc/systemd/system/patroni.service <<UNIT
[Unit]
Description=Patroni PostgreSQL HA
Wants=network-online.target
After=network-online.target etcd.service

[Service]
User=postgres
Group=postgres
EnvironmentFile=-${PATRONI_ENV}
ExecStart=${BIN_PATRONI} ${PATRONI_DIR}/patroni.yml
TimeoutStartSec=0
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
KillMode=process
Environment=PATH=${PG_BIN_DIR}:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
UNIT

command -v restorecon >/dev/null 2>&1 && restorecon -v /etc/systemd/system/patroni.service >/dev/null 2>&1 || true

# REST 8008
if command -v firewall-cmd >/dev/null 2>&1; then
  echo "[*] firewall-cmd: ${REST_PORT} açılıyor..."
  firewall-cmd --add-port=${REST_PORT}/tcp --permanent || true
  firewall-cmd --reload || true
fi

systemctl daemon-reload

echo
echo "NOT: Servis otomatik başlamadı."
echo "İlk bootstrap sırası:"
echo "  1) frspg01 (10.10.100.54): systemctl enable --now patroni"
echo "  2) frspg02 (10.10.100.55): systemctl enable --now patroni"
echo "  3) frspg03 (10.10.100.56): systemctl enable --now patroni"
echo
echo "Durum:"
echo "  curl http://${NODE_IP}:${REST_PORT}"
echo "  ${BIN_PATRONICTL} -c ${PATRONI_DIR}/patroni.yml list"
