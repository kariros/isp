#!/bin/bash

# =====================================================
# Настройка маршрутизатора ISP (RedOS)
# Внешний интерфейс: ens160, внутренние – запрашиваются
# Добавлены параметры IPv4 may-fail no и IPv6 ignore
# =====================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo ./isp.sh)"
    exit 1
fi

mask_to_cidr() {
    local mask=$1
    if [[ "$mask" =~ ^[0-9]+$ ]]; then
        echo "$mask"
    elif [[ "$mask" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local cidr=0
        IFS=. read -r o1 o2 o3 o4 <<< "$mask"
        for octet in $o1 $o2 $o3 $o4; do
            while [ $octet -gt 0 ]; do
                ((cidr += octet & 1))
                octet=$((octet >> 1))
            done
        done
        echo "$cidr"
    else
        echo "0"
    fi
}

interface_exists() {
    ip link show "$1" &>/dev/null
}

get_interface() {
    local prompt="$1"
    local iface
    while true; do
        read -p "$prompt: " iface
        if interface_exists "$iface"; then
            echo "$iface"
            break
        else
            echo "Интерфейс $iface не найден. Доступные:"
            ip -br link | awk '{print $1}'
        fi
    done
}

echo "============================================="
echo "  Настройка маршрутизатора ISP для схемы"
echo "============================================="

# Имя хоста
read -p "Введите желаемое имя хоста (например, ISP-1): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    hostname "$NEW_HOSTNAME"
    echo "✅ Hostname: $NEW_HOSTNAME"
fi

# Внешний интерфейс жестко ens160
EXT_IF="ens160"
echo "→ Внешний интерфейс: $EXT_IF"

# Первый внутренний интерфейс
INNER1_IF=$(get_interface "Введите имя ПЕРВОГО внутреннего интерфейса (например, ens192)")
read -p "IP-адрес для $INNER1_IF (например, 172.16.1.1): " IP_INNER1
read -p "Маска (CIDR или точечная): " MASK_INNER1
CIDR1=$(mask_to_cidr "$MASK_INNER1")
if [[ "$CIDR1" == "0" ]]; then
    echo "Неверная маска"
    exit 1
fi
nmcli con mod "$INNER1_IF" ipv4.addresses "${IP_INNER1}/${CIDR1}" ipv4.method manual
nmcli con mod "$INNER1_IF" ipv4.may-fail no        # требуем IPv4
nmcli con mod "$INNER1_IF" ipv6.method ignore      # игнорируем IPv6
nmcli con up "$INNER1_IF"
echo "✅ $INNER1_IF настроен"

# Второй внутренний интерфейс
INNER2_IF=$(get_interface "Введите имя ВТОРОГО внутреннего интерфейса (например,ens224)")
read -p "IP-адрес для $INNER2_IF (например, 172.16.2.1): " IP_INNER2
read -p "Маска (CIDR): " MASK_INNER2
CIDR2=$(mask_to_cidr "$MASK_INNER2")
if [[ "$CIDR2" == "0" ]]; then
    echo "Неверная маска"
    exit 1
fi
nmcli con mod "$INNER2_IF" ipv4.addresses "${IP_INNER2}/${CIDR2}" ipv4.method manual
nmcli con mod "$INNER2_IF" ipv4.may-fail no
nmcli con mod "$INNER2_IF" ipv6.method ignore
nmcli con up "$INNER2_IF"
echo "✅ $INNER2_IF настроен"

# Часовой пояс
timedatectl set-timezone Europe/Moscow
echo "→ Часовой пояс Europe/Moscow"

# IP-форвардинг
grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
echo "→ IP-форвардинг включён"

# nftables
command -v nft &>/dev/null || dnf install -y nftables
mkdir -p /etc/nftables
cat > /etc/nftables/isp.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "$EXT_IF" masquerade
    }
}
EOF
cat > /etc/sysconfig/nftables.conf <<EOF
include "/etc/nftables/isp.nft"
EOF
systemctl enable --now nftables
if systemctl is-active --quiet nftables; then
    echo "✅ nftables запущен"
else
    echo "❌ Ошибка nftables"
    exit 1
fi

echo "============================================="
echo "  Настройка ISP завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Внешний интерфейс: $EXT_IF"
echo "  Внутренние: $INNER1_IF (${IP_INNER1}/${CIDR1}), $INNER2_IF (${IP_INNER2}/${CIDR2})"
echo "  IPv4 required, IPv6 ignored"
echo "============================================="
