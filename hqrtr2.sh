#!/bin/bash
# hq-rtr_setup.sh

set -e


# Отключение SELinux (требует перезагрузки, но для текущей сессии можно setenforce 0)
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

# Включение IP-форвардинга
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Установка nftables
dnf install -y nftables
systemctl enable nftables

# Создание каталога для конфигов
mkdir -p /etc/nftables

# Запись файла hq.nft
cat > /etc/nftables/hq.nft <<'EOF'
table inet nat {
    chain PREROUTING {
        type nat hook prerouting priority filter; policy accept;
        ip daddr 172.16.1.2 tcp dport 8080 dnat ip to 192.168.1.2:80
        ip daddr 172.16.1.2 tcp dport 3306 dnat ip to 192.168.1.2:2026
    }

    chain POSTROUTING {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "ens160" masquerade
    }
}
EOF

# Загрузка правил
nft -f /etc/nftables/hq.nft

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


# Сохранение правил (чтобы загружались при старте)
echo 'include "/etc/nftables/hq.nft"' > /etc/nftables.conf
systemctl restart nftables

echo "HQ-RTR настроен."
echo "/etc/nftables/hq.nft"