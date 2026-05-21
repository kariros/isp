#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# Три VLAN на ens160 + GRE туннель + FRR/OSPF с ручным вводом сетей
# =====================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Запустите с правами root (sudo ./hq-rtr.sh)"
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

echo "============================================="
echo "  Настройка маршрутизатора HQ-RTR"
echo "============================================="

# 1. Имя хоста
read -p "Введите имя хоста (например, HQ-RTR): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    hostname "$NEW_HOSTNAME"
    echo "✅ Hostname: $NEW_HOSTNAME"
fi

# 2. Проверка наличия ens160
if ! interface_exists "ens160"; then
    echo "Интерфейс ens160 не найден. VLAN и туннель невозможны."
    exit 1
fi

# 3. Создание трёх VLAN на ens160 (запрашиваем ID и маску)
for i in 1 2 3; do
    echo "--- VLAN $i ---"
    read -p "Введите ID для VLAN $i (число): " vlan_id
    read -p "Введите маску для сети 192.168.$i.1 (CIDR, например 24): " mask_vlan
    cidr_vlan=$(mask_to_cidr "$mask_vlan")
    if [[ "$cidr_vlan" == "0" ]]; then
        echo "Неверная маска"
        exit 1
    fi
    vlan_iface="ens160.$vlan_id"
    ip_addr="192.168.$i.1/$cidr_vlan"
    echo "→ Создаём профиль $vlan_iface с IP $ip_addr"
    nmcli con add type vlan ifname "$vlan_iface" dev ens160 id "$vlan_id" con-name "$vlan_iface"
    nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
    nmcli con up "$vlan_iface"
    echo "✅ VLAN $vlan_iface создан"
done

# 4. Часовой пояс
timedatectl set-timezone Europe/Moscow
echo "→ Часовой пояс Europe/Moscow"

# 5. IP-форвардинг
if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p
echo "→ IP-форвардинг включён"

# 6. nftables (masquerade через ens160)
if ! command -v nft &> /dev/null; then
    dnf install -y nftables
fi
mkdir -p /etc/nftables
cat > /etc/nftables/hq.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "ens160" masquerade
    }
}
EOF
cat > /etc/sysconfig/nftables.conf <<EOF
include "/etc/nftables/hq.nft"
EOF
systemctl enable --now nftables
if systemctl is-active --quiet nftables; then
    echo "✅ nftables запущен"
else
    echo "❌ Ошибка nftables"
    exit 1
fi

# 7. GRE туннель tun1
echo "--- Настройка GRE туннеля tun1 ---"
read -p "Локальный IP (адрес на ens160 для туннеля): " local_ip
read -p "Удалённый IP (адрес другого конца туннеля): " remote_ip
nmcli connection add type ip-tunnel ip-tunnel.mode gre con-name tun1 ifname tun1 remote "$remote_ip" local "$local_ip" dev ens160
nmcli connection modify tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
nmcli connection modify tun1 ip-tunnel.ttl 64
nmcli connection up tun1
echo "✅ Туннель tun1 создан (10.0.0.1/30)"

# 8. Установка FRR и включение ospfd
dnf install -y frr
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr
echo "✅ FRR установлен, ospfd включён"

# 9. Интерактивный ввод сетей для OSPF
echo "--- Настройка OSPF ---"
echo "Введите сети для анонсирования в формате 'сеть/маска' (например, 10.0.0.0/30 или 192.168.1.0/24)."
echo "После ввода всех сетей оставьте строку пустой и нажмите Enter."
ospf_networks=()
while true; do
    read -p "Сеть (пустая строка для завершения): " net
    if [ -z "$net" ]; then
        break
    fi
    # Простая проверка формата (наличие /)
    if [[ "$net" =~ ^[0-9./]+$ ]]; then
        ospf_networks+=("$net area 0")
    else
        echo "Неверный формат, используйте например 192.168.1.0/24"
    fi
done

read -sp "Введите пароль аутентификации OSPF (общий для обоих концов): " ospf_password
echo ""

# 10. Применение конфигурации OSPF через vtysh
vtysh_cmds=(
    "configure terminal"
    "router ospf"
    "passive-interface default"
)
for net_entry in "${ospf_networks[@]}"; do
    vtysh_cmds+=("network $net_entry")
done
vtysh_cmds+=(
    "area 0 authentication"
    "exit"
    "interface tun1"
    "no ip ospf network broadcast"
    "no ip ospf passive"
    "ip ospf authentication"
    "ip ospf authentication-key $ospf_password"
    "exit"
    "exit"
    "write"
)

for cmd in "${vtysh_cmds[@]}"; do
    vtysh -c "$cmd"
done

echo "✅ OSPF настроен, конфигурация сохранена"

echo "============================================="
echo "  Настройка HQ-RTR завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Туннель tun1: 10.0.0.1/30"
echo "  Проверьте nftables: systemctl status nftables"
echo "  Проверьте туннель: ip link show tun1"
echo "  OSPF: vtysh -c 'show ip ospf neighbor'"
echo "============================================="
