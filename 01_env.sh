#!/usr/bin/env bash
set -euo pipefail

# === Küme kimliği ve sürüm ===
export CLUSTER_NAME="frscluster"
export PGVER="15"

# === Node adı/IP eşleşmesi ===
export NODE_NAME="$(hostname -s)"
case "$NODE_NAME" in
  frspg01) export NODE_IP="10.10.100.54" ;;
  frspg02) export NODE_IP="10.10.100.55" ;;
  frspg03) export NODE_IP="10.10.100.56" ;;
  *) echo "NODE_NAME '$NODE_NAME' tanımsız; 01_env.sh içindeki case bloğunu güncelleyin." >&2; exit 1 ;;
esac

# === etcd eşleri ve client uçları ===
export ETCD_NODES="frspg01=10.10.100.54 frspg02=10.10.100.55 frspg03=10.10.100.56"
export ETCD_ENDPOINTS="10.10.100.54:2379,10.10.100.55:2379,10.10.100.56:2379"

# === Patroni/PG yolları ===
export PGDATA="/var/lib/pgsql/${PGVER}/data"
export PATRONI_DIR="/etc/patroni"
export PATRONI_ENV="/etc/patroni/env"

install -d -m 0755 /etc/patroni
cat >"$PATRONI_ENV" <<EOF
CLUSTER_NAME=${CLUSTER_NAME}
NODE_NAME=${NODE_NAME}
NODE_IP=${NODE_IP}
PGVER=${PGVER}
PGDATA=${PGDATA}
ETCD_NODES="${ETCD_NODES}"
ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
PATRONI_DIR=${PATRONI_DIR}
EOF
chmod 0644 "$PATRONI_ENV"

# Login shell’lere otomatik yüklensin
install -d -m 0755 /etc/profile.d
cat >/etc/profile.d/patroni_env.sh <<'EOSH'
[ -f /etc/patroni/env ] && . /etc/patroni/env
EOSH
chmod 0644 /etc/profile.d/patroni_env.sh

# Bu shell’e de al
. "$PATRONI_ENV"

echo "Aktif ortam:
  CLUSTER_NAME=$CLUSTER_NAME
  NODE_NAME=$NODE_NAME
  NODE_IP=$NODE_IP
  PGVER=$PGVER
  PGDATA=$PGDATA
  ETCD_ENDPOINTS=$ETCD_ENDPOINTS"
