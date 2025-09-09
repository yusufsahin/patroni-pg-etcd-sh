#!/usr/bin/env bash
set -euo pipefail
[ -f /etc/patroni/env ] && . /etc/patroni/env || { echo "/etc/patroni/env yok; önce 01_env.sh"; exit 1; }
: "${PGVER:?}" "${PGDATA:?}"

echo "[*] PGDG repo ve PostgreSQL ${PGVER} kuruluyor..."
rpm -q pgdg-redhat-repo >/dev/null 2>&1 || dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
dnf -qy module disable postgresql || true
dnf -y install "postgresql${PGVER}" "postgresql${PGVER}-server"

# Stok systemd servisini etkisiz bırak—Patroni yönetecek
systemctl disable --now "postgresql-${PGVER}" 2>/dev/null || true

# PGDATA Patroni için hazırlanır (initdb’yi Patroni yapar)
umask 0077
install -d -o postgres -g postgres -m 0700 "${PGDATA}"
install -d -o postgres -g postgres -m 0750 "$(dirname "${PGDATA}")"

# 5432 firewall
if command -v firewall-cmd >/dev/null 2>&1; then
  echo "[*] firewall-cmd: 5432 açılıyor..."
  firewall-cmd --add-port=5432/tcp --permanent || true
  firewall-cmd --reload || true
fi

command -v restorecon >/dev/null 2>&1 && { restorecon -Rv "$(dirname "${PGDATA}")" >/dev/null 2>&1 || true; restorecon -Rv "${PGDATA}" >/dev/null 2>&1 || true; }

echo "PostgreSQL paketleri ve dizin hazır."
