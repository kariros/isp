#!/bin/bash
# hq-cli_setup.sh — исправленный (без chattr, с проверкой DNS)

set -e

# === 1. Установка Яндекс Браузера ===

SUDO_PASS="P@ssword"

run_sudo() {
    echo "$SUDO_PASS" | sudo -S bash -c "$1"
}

echo "=== Установка chrony ==="
dnf install -y chrony

echo "=== Настройка /etc/chrony.conf ==="
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
echo "server 172.16.2.1 iburst" >> /etc/chrony.conf

systemctl restart chronyd
systemctl enable chronyd

echo "=== Проверка синхронизации ==="
chronyc sources -v

echo "=== Готово ==="


echo "=== 1. Установка Яндекс Браузера ==="
    run_sudo "dnf install -y yandex-browser-stable"
	
	echo "=== 2. Вход в домен ==="
# Установка DNS и домена поиска через nmcli
nmcli con mod ens160.200 ipv4.dns "192.168.4.2 8.8.8.8"
nmcli con mod ens160.200 ipv4.dns-search "au-team.irpo"
nmcli con up ens160.200


echo "=== 4. Проверка разрешения домена ==="
if ! run_sudo "nslookup au-team.irpo 192.168.4.2" | grep -q "192.168.4.2"; then
    echo "ОШИБКА: не удаётся разрешить домен au-team.irpo. Проверьте DNS на BR-SRV (192.168.4.2)."
    exit 1
fi


echo "$SUDO_PASS" | sudo -S realm join --user=Administrator au-team.irpo || {
    echo "ОШИБКА: не удалось войти в домен. Проверьте работу Samba DC."
    exit 1
}

echo "=== 5. Sudo для группы sidehq ==="
run_sudo "echo '%sidehq ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id' > /etc/sudoers.d/sidehq"
run_sudo "chmod 440 /etc/sudoers.d/sidehq"

# === 6. Монтирование NFS (с проверкой) ===
echo "=== 6. Монтирование NFS ==="
run_sudo "mkdir -p /mnt/nfs"
run_sudo "chmod -R 777 /mnt/nfs"
if run_sudo "ping -c 2 192.168.1.2 &>/dev/null"; then
    run_sudo "echo '192.168.1.2:/raid1/nfs /mnt/nfs nfs defaults,_netdev 0 0' >> /etc/fstab"
    run_sudo "systemctl daemon-reload"
    run_sudo "mount -a"
else
    echo "NFS-сервер 192.168.1.2 недоступен. Монтирование пропущено."
fi

# Резервное копирование оригинального /etc/hosts
cp /etc/hosts /etc/hosts.bak

# Удаляем старые записи, если они есть (чтобы избежать дублей)
sed -i '/docker.au-team.irpo/d' /etc/hosts
sed -i '/web.au-team.irpo/d' /etc/hosts

# Добавляем новые записи
cat >> /etc/hosts <<EOF
172.16.2.1 docker.au-team.irpo
172.16.1.1 web.au-team.irpo
EOF

echo "Записи в /etc/hosts добавлены:"
cat /etc/hosts

echo "=== Настройка HQ-CLI завершена ==="







