#!/usr/bin/env bash
set -euo pipefail
[ -f /etc/patroni/env ] && . /etc/patroni/env || { echo "/etc/patroni/env yok; önce 01_env.sh"; exit 1; }

# RHEL 9 ailesi
if command -v dnf >/dev/null 2>&1; then
  dnf -y install chrony jq tar curl policycoreutils-python-utils python3-pip firewalld hostname
else
  yum -y install chrony jq tar curl policycoreutils-python-utils python3-pip firewalld hostname
fi

systemctl enable --now chronyd
systemctl enable --now firewalld

# etcd çalışma kullanıcısı
id -u etcd >/dev/null 2>&1 || useradd --system --home /var/lib/etcd --shell /sbin/nologin etcd

# Küme adları DNS’e bağlı kalmasın diye /etc/hosts’a sabitle (opsiyonel ama önerilir)
grep -q 'frspg0[1-3]' /etc/hosts || cat >>/etc/hosts <<'H'
10.10.100.54 frspg01
10.10.100.55 frspg02
10.10.100.56 frspg03
H

echo "Prereqs OK."
