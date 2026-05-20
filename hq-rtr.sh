#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# Только ens192 + три VLAN + GRE туннель + FRR/OSPF
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

# Функция настройки интерфейса с созданием профиля при необходимости
configure_interface() {
    local iface=$1
    local desc=$2
    echo "--- Настройка $desc ($iface) ---"
    read -p "IP-адрес для $iface: " ip_addr
    read -p "Маска (CIDR, например 24): " mask
    cidr=$(mask_to_cidr "$mask")
    if [[ "$cidr" == "0" ]]; then
        echo "Неверная маска"
        exit 1
    fi
    read -p "Шлюз по умолчанию (если есть, иначе пусто): " gateway
    read -p "DNS-серверы (через пробел): " dns_servers

    # Создаём профиль, если его нет
    if ! nmcli con show "$iface" &>/dev/null; then
        nmcli con add type ethernet ifname "$iface" con-name "$iface"
    fi

    nmcli con mod "$iface" ipv4.addresses "${ip_addr}/${cidr}" ipv4.method manual
    [ -n "$gateway" ] && nmcli con mod "$iface" ipv4.gateway "$gateway"
    [ -n "$dns_servers" ] && nmcli con mod "$iface" ipv4.dns "$dns_servers"
    nmcli con up "$iface"
    echo "✅ $iface настроен"
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

# 2. Настройка ens192 (создаст профиль)
configure_interface "ens192" "интерфейса ens192"

# 3. Проверка наличия ens160 (не настраиваем его, только используем)
if ! interface_exists "ens160"; then
    echo "Интерфейс ens160 не найден. VLAN и туннель невозможны."
    exit 1
fi

# 4. Создание трёх VLAN на ens160
for i in 1 2 3; do
    echo "--- VLAN $i ---"
    read -p "Введите ID для VLAN $i (число): " vlan_id
    read -p "Введите маску для сети 192.168.$i.1 (CIDR): " mask_vlan
    cidr_vlan=$(mask_to_cidr "$mask_vlan")
    if [[ "$cidr_vlan" == "0" ]]; then
        echo "Неверная маска"
        exit 1
    fi
    vlan_iface="ens160.$vlan_id"
    ip_addr="192.168.$i.1/$cidr_vlan"
    echo "→ Создаём $vlan_iface с IP $ip_addr"
    nmcli con add type vlan ifname "$vlan_iface" dev ens160 id "$vlan_id"
    nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
    nmcli con up "$vlan_iface"
    echo "✅ VLAN $vlan_iface создан"
done

# 5. Часовой пояс
timedatectl set-timezone Europe/Moscow
echo "→ Часовой пояс Europe/Moscow"

# 6. IP-форвардинг
if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p
echo "→ IP-форвардинг включён"

# 7. nftables (masquerade через ens160)
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

# 8. GRE туннель tun1
echo "--- Настройка GRE туннеля tun1 ---"
read -p "Локальный IP (адрес на ens160 для туннеля): " local_ip
read -p "Удалённый IP (адрес другого конца туннеля): " remote_ip
nmcli connection add type ip-tunnel ip-tunnel.mode gre con-name tun1 ifname tun1 remote "$remote_ip" local "$local_ip" dev ens160
nmcli connection modify tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
nmcli connection modify tun1 ip-tunnel.ttl 64
nmcli connection up tun1
echo "✅ Туннель tun1 создан (10.0.0.1/30)"

# 9. Установка FRR и включение ospfd
dnf install -y frr
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr
echo "✅ FRR установлен, ospfd включён"

# 10. Настройка OSPF через vtysh
networks_to_add=()
# ens192
ip_cidr_ens192=$(nmcli -g ipv4.addresses con show ens192 | head -1)
if [ -n "$ip_cidr_ens192" ]; then
    network_ens192=$(ipcalc -n "$ip_cidr_ens192" | grep Network | awk '{print $2}')
    [ -n "$network_ens192" ] && networks_to_add+=("$network_ens192 area 0")
fi
# VLAN
for i in 1 2 3; do
    vlan_iface=$(nmcli -t -f NAME con show --active | grep "ens160\." | head -$i | tail -1)
    if [ -n "$vlan_iface" ]; then
        ip_cidr_vlan=$(nmcli -g ipv4.addresses con show "$vlan_iface")
        network_vlan=$(ipcalc -n "$ip_cidr_vlan" | grep Network | awk '{print $2}')
        [ -n "$network_vlan" ] && networks_to_add+=("$network_vlan area 0")
    fi
done
# туннель
networks_to_add+=("10.0.0.0/30 area 0")

read -sp "Введите пароль аутентификации OSPF (общий для обоих концов): " ospf_password
echo ""

vtysh_cmds=(
    "configure terminal"
    "router ospf"
    "passive-interface default"
)
for net in "${networks_to_add[@]}"; do
    vtysh_cmds+=("network $net")
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
