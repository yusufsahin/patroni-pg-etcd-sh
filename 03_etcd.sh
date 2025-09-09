#!/usr/bin/env bash
set -euo pipefail
[ -f /etc/patroni/env ] && . /etc/patroni/env || { echo "/etc/patroni/env yok; önce 01_env.sh"; exit 1; }
: "${CLUSTER_NAME:?}" "${NODE_NAME:?}" "${NODE_IP:?}" "${ETCD_NODES:?}" "${ETCD_ENDPOINTS:?}"

ETCD_VER="3.6.0"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) PKG_ARCH="amd64";; aarch64|arm64) PKG_ARCH="arm64";; *) echo "Mimari desteklenmiyor: $ARCH"; exit 1;; esac
URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-${PKG_ARCH}.tar.gz"

INSTALL_DIR="/usr/local/bin"
ETCD_CFG_DIR="/etc/etcd"
ETCD_ENV_FILE="${ETCD_CFG_DIR}/etcd.env"
ETCD_DATA_DIR="/var/lib/etcd-${NODE_NAME}.etcd"

LISTEN_CLIENT_URLS="http://${NODE_IP}:2379,http://127.0.0.1:2379"
ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
LISTEN_PEER_URLS="http://${NODE_IP}:2380"
INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"

build_initial_cluster() {
  local acc=""; for pair in ${ETCD_NODES}; do
    local name="${pair%%=*}"; local ip="${pair##*=}"
    local item="${name}=http://${ip}:2380"
    acc="${acc:+${acc},}${item}"
  done; printf '%s' "$acc"
}
ETCD_INITIAL_CLUSTER="$(build_initial_cluster)"

echo "[*] etcd v${ETCD_VER} kuruluyor..."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 --retry-delay 2 "$URL" -o "$tmp/etcd.tgz"
tar -xzf "$tmp/etcd.tgz" -C "$tmp"
install -m 0755 -o root -g root "$tmp/etcd-v${ETCD_VER}-linux-${PKG_ARCH}/etcd"    "${INSTALL_DIR}/etcd"
install -m 0755 -o root -g root "$tmp/etcd-v${ETCD_VER}-linux-${PKG_ARCH}/etcdctl" "${INSTALL_DIR}/etcdctl"

# İsteğe bağlı "etcdctl3" kısayolu (ETCDCTL_API export ETME)
cat > /usr/local/bin/etcdctl3 <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/bin/etcdctl "$@"
WRAP
chmod +x /usr/local/bin/etcdctl3

install -d -m 0755 "${ETCD_CFG_DIR}"
systemctl is-active --quiet etcd && systemctl stop etcd || true
install -d -m 0700 -o etcd -g etcd "${ETCD_DATA_DIR}"

# Firewalld
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  ZONE="$(firewall-cmd --get-active-zones | awk 'NR==1{print $1}')"; [ -n "${ZONE:-}" ] || ZONE="public"
  echo "[*] firewall-cmd (${ZONE}) 2379-2380 açılıyor..."
  firewall-cmd --zone="${ZONE}" --add-port=2379/tcp --permanent || true
  firewall-cmd --zone="${ZONE}" --add-port=2380/tcp --permanent || true
  firewall-cmd --reload || true
fi
command -v restorecon >/dev/null 2>&1 && restorecon -Rv "${ETCD_DATA_DIR}" >/dev/null 2>&1 || true

# Data boşsa 'new', doluysa 'existing'
INIT_STATE="existing"; [[ -z "$(ls -A "${ETCD_DATA_DIR}" 2>/dev/null || true)" ]] && INIT_STATE="new"

# Env-only konfig (etcd tüm ayarları ETCD_* ile kabul eder)
cat > "${ETCD_ENV_FILE}" <<EOF
ETCD_NAME=${NODE_NAME}
ETCD_DATA_DIR=${ETCD_DATA_DIR}

ETCD_LISTEN_CLIENT_URLS=${LISTEN_CLIENT_URLS}
ETCD_ADVERTISE_CLIENT_URLS=${ADVERTISE_CLIENT_URLS}

ETCD_LISTEN_PEER_URLS=${LISTEN_PEER_URLS}
ETCD_INITIAL_ADVERTISE_PEER_URLS=${INITIAL_ADVERTISE_PEER_URLS}

ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER}
ETCD_INITIAL_CLUSTER_STATE=${INIT_STATE}
ETCD_INITIAL_CLUSTER_TOKEN=${CLUSTER_NAME}-token

ETCD_AUTO_COMPACTION_MODE=periodic
ETCD_AUTO_COMPACTION_RETENTION=1
ETCD_SNAPSHOT_COUNT=10000
ETCD_QUOTA_BACKEND_BYTES=8589934592
EOF
chmod 0644 "${ETCD_ENV_FILE}"

# systemd unit (flag yok—yalnızca env’ler)
cat > /etc/systemd/system/etcd.service <<'UNIT'
[Unit]
Description=etcd (distributed key-value store)
Documentation=https://etcd.io
Wants=network-online.target
After=network-online.target

[Service]
User=etcd
Group=etcd
EnvironmentFile=-/etc/etcd/etcd.env
Type=simple
ExecStart=/usr/local/bin/etcd
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
TimeoutStartSec=0

# Hardening (makul)
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectClock=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
UNIT

command -v restorecon >/dev/null 2>&1 && restorecon -v /etc/systemd/system/etcd.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd

echo "== etcd hızlı kontrol =="
/usr/local/bin/etcdctl3 --endpoints="${ETCD_ENDPOINTS}" member list || true
/usr/local/bin/etcdctl3 --endpoints="${ETCD_ENDPOINTS}" endpoint status -w table || true
/usr/local/bin/etcdctl3 --endpoints="${ETCD_ENDPOINTS}" endpoint health || true
