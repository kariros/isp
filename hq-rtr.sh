#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# Финальная версия с гарантированной настройкой OSPF
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

find_parent_interface_by_ip() {
    local target_ip="172.16.1.2"
    local iface=$(ip -4 addr show | grep -B2 "inet $target_ip" | grep '^[0-9]*:' | awk -F': ' '{print $2}')
    echo "$iface"
}

echo "============================================="
echo "  Настройка маршрутизатора HQ-RTR"
echo "============================================="

read -p "Введите имя хоста (например, HQ-RTR): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    hostname "$NEW_HOSTNAME"
    echo "✅ Hostname: $NEW_HOSTNAME"
fi

PARENT_IF=$(find_parent_interface_by_ip)
if [ -z "$PARENT_IF" ]; then
    echo "⚠️ Не удалось автоматически найти интерфейс с IP 172.16.1.2."
    read -p "Введите имя родительского интерфейса (например, ens160): " PARENT_IF
    if ! interface_exists "$PARENT_IF"; then
        echo "❌ Интерфейс $PARENT_IF не найден. Доступные:"
        ip -br link | awk '{print $1}'
        exit 1
    fi
fi
echo "✅ Родительский интерфейс: $PARENT_IF"

vlan_networks=()
for i in 1 2 3; do
    echo "--- VLAN $i ---"
    read -p "Введите ID для VLAN $i (число): " vlan_id
    vlan_iface="$PARENT_IF.$vlan_id"
    if nmcli con show "$vlan_iface" &>/dev/null; then
        echo "⚠️ Профиль $vlan_iface уже существует. Пропускаем."
    else
        read -p "Введите маску для сети 192.168.$i.1 (CIDR или точечная): " mask_vlan
        cidr_vlan=$(mask_to_cidr "$mask_vlan")
        if [[ "$cidr_vlan" == "0" ]]; then
            echo "❌ Неверная маска"
            exit 1
        fi
        ip_addr="192.168.$i.1/$cidr_vlan"
        echo "→ Создаём $vlan_iface с IP $ip_addr"
        nmcli con add type vlan ifname "$vlan_iface" dev "$PARENT_IF" id "$vlan_id" con-name "$vlan_iface"
        nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
        nmcli con up "$vlan_iface"
        echo "✅ VLAN $vlan_iface создан"
        network=$(ipcalc -n "$ip_addr" | grep Network | awk '{print $2}')
        [ -n "$network" ] && vlan_networks+=("$network area 0")
    fi
done

timedatectl set-timezone Europe/Moscow
echo "✅ Часовой пояс: Europe/Moscow"

if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p
echo "✅ IP-форвардинг включён"

if ! command -v nft &> /dev/null; then
    dnf install -y nftables
fi
mkdir -p /etc/nftables
cat > /etc/nftables/hq.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "$PARENT_IF" masquerade
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

if ! lsmod | grep -q ip_gre; then
    modprobe ip_gre
    sleep 1
fi

if nmcli con show tun1 &>/dev/null; then
    echo "⚠️ Профиль туннеля tun1 уже существует. Пропускаем создание."
else
    local_ip="172.16.1.2"
    read -p "Введите удалённый IP для туннеля (например, 172.16.2.2): " remote_ip
    nmcli con add type ip-tunnel ip-tunnel.mode gre con-name tun1 ifname tun1 remote "$remote_ip" local "$local_ip" dev "$PARENT_IF"
    nmcli con mod tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
    nmcli con mod tun1 ip-tunnel.ttl 64
fi

for attempt in 1 2; do
    if nmcli con up tun1; then
        echo "✅ Туннель tun1 активирован"
        break
    else
        echo "⚠️ Попытка $attempt не удалась, ждём 2 секунды..."
        sleep 2
    fi
    if [ $attempt -eq 2 ]; then
        echo "❌ Не удалось активировать туннель. Проверьте родительский интерфейс."
        exit 1
    fi
done

for i in {1..5}; do
    if ip link show tun1 &>/dev/null; then
        echo "✅ Интерфейс tun1 обнаружен"
        break
    fi
    sleep 1
done

if ! command -v frr &>/dev/null; then
    dnf install -y frr
fi
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr

for attempt in {1..10}; do
    if systemctl is-active --quiet frr && pgrep -x "ospfd" > /dev/null; then
        echo "✅ ospfd запущен"
        break
    fi
    echo "⏳ Ожидание запуска ospfd... попытка $attempt"
    sleep 2
done

if ! pgrep -x "ospfd" > /dev/null; then
    echo "❌ ospfd не запустился. Перезапускаем FRR..."
    systemctl restart frr
    sleep 5
fi

# --- Настройка OSPF (построчная отправка команд) ---
echo "--- Настройка OSPF ---"
echo "Введите сети в формате '<сеть/маска> area 0' (например, 10.0.0.0/30 area 0)"
echo "Когда закончите, оставьте строку пустой и нажмите Enter."

networks_to_add=()
while true; do
    read -p "Сеть: " net
    if [ -z "$net" ]; then
        break
    fi
    networks_to_add+=("$net")
done

if [ ${#networks_to_add[@]} -eq 0 ]; then
    echo "⚠️ Не добавлено ни одной сети. OSPF не будет настроен."
else
    read -sp "Введите пароль аутентификации OSPF (общий для обоих концов): " ospf_password
    echo ""

    # Отправляем команды в vtysh по одной
    vtysh -c "configure terminal"
    vtysh -c "router ospf"
    vtysh -c "passive-interface default"
    for net in "${networks_to_add[@]}"; do
        vtysh -c "network $net"
    done
    vtysh -c "area 0 authentication"
    vtysh -c "exit"
    vtysh -c "interface tun1"
    vtysh -c "no ip ospf network broadcast"
    vtysh -c "no ip ospf passive"
    vtysh -c "ip ospf authentication"
    vtysh -c "ip ospf authentication-key $ospf_password"
    vtysh -c "exit"
    vtysh -c "exit"
    vtysh -c "write"

    echo "✅ OSPF настроен"
fi

echo "============================================="
echo "  Настройка HQ-RTR завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Туннель tun1: 10.0.0.1/30"
echo "  Проверьте OSPF: vtysh -c 'show ip ospf neighbor'"
echo "============================================="