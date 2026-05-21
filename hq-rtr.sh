#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# Версия: Финальная, с ручным вводом параметров
# =====================================================

set -e  # Остановка при любой ошибке

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите скрипт с правами root (sudo ./hq-rtr.sh)"
    exit 1
fi

# Функция для преобразования маски (например, 24 или 255.255.255.0) в CIDR
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

# Функция для проверки существования интерфейса
interface_exists() {
    ip link show "$1" &>/dev/null
}

# Функция для поиска родительского интерфейса по IP
find_parent_interface_by_ip() {
    local target_ip="172.16.1.2"
    local iface=$(ip -4 addr show | grep -B2 "inet $target_ip" | grep '^[0-9]*:' | awk -F': ' '{print $2}')
    if [ -n "$iface" ]; then
        echo "$iface"
    else
        echo ""
    fi
}

echo "============================================="
echo "  Настройка маршрутизатора HQ-RTR"
echo "============================================="

# --- 1. Имя хоста ---
read -p "Введите имя хоста (например, HQ-RTR): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    hostname "$NEW_HOSTNAME"
    echo "✅ Hostname установлен: $NEW_HOSTNAME"
fi

# --- 2. Определение родительского интерфейса ---
PARENT_IF=$(find_parent_interface_by_ip)
if [ -z "$PARENT_IF" ]; then
    echo "⚠️ Не удалось автоматически найти интерфейс с IP 172.16.1.2."
    read -p "Введите имя родительского интерфейса (например, ens160): " PARENT_IF
    if ! interface_exists "$PARENT_IF"; then
        echo "❌ Интерфейс $PARENT_IF не найден. Доступные интерфейсы:"
        ip -br link | awk '{print $1}'
        exit 1
    fi
fi
echo "✅ Родительский интерфейс: $PARENT_IF"

# --- 3. Создание трёх VLAN ---
vlan_networks=()
for i in 1 2 3; do
    echo "--- Настройка VLAN $i ---"
    read -p "Введите ID для VLAN $i (число): " vlan_id
    vlan_iface="$PARENT_IF.$vlan_id"
    # Проверяем, не существует ли уже профиль
    if nmcli con show "$vlan_iface" &>/dev/null; then
        echo "⚠️ Профиль $vlan_iface уже существует. Пропускаем создание."
    else
        read -p "Введите маску для сети 192.168.$i.1 (например, 24 или 255.255.255.0): " mask_vlan
        cidr_vlan=$(mask_to_cidr "$mask_vlan")
        if [[ "$cidr_vlan" == "0" ]]; then
            echo "❌ Неверный формат маски. Используйте CIDR (например, 24)."
            exit 1
        fi
        ip_addr="192.168.$i.1/$cidr_vlan"
        echo "→ Создаём профиль $vlan_iface с IP $ip_addr"
        nmcli con add type vlan ifname "$vlan_iface" dev "$PARENT_IF" id "$vlan_id" con-name "$vlan_iface"
        nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
        nmcli con up "$vlan_iface"
        echo "✅ VLAN $vlan_iface создан и активирован."
    fi
done

# --- 4. Настройка времени ---
timedatectl set-timezone Europe/Moscow
echo "✅ Часовой пояс установлен: Europe/Moscow"

# --- 5. Включение IP-форвардинга ---
if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p
echo "✅ IP-форвардинг включён"

# --- 6. Настройка NAT через nftables ---
if ! command -v nft &> /dev/null; then
    echo "→ Устанавливаем пакет nftables"
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
    echo "✅ nftables запущен и настроен."
else
    echo "❌ Ошибка при запуске nftables."
    exit 1
fi

# --- 7. Создание GRE туннеля tun1 ---
# Загружаем модуль GRE, если не загружен
if ! lsmod | grep -q ip_gre; then
    echo "→ Загружаем модуль ядра ip_gre"
    modprobe ip_gre
fi

# Проверяем, существует ли уже подключение
if nmcli con show tun1 &>/dev/null; then
    echo "⚠️ Профиль туннеля tun1 уже существует. Пропускаем создание."
else
    echo "--- Настройка GRE туннеля tun1 ---"
    # Автоматически определяем локальный IP для туннеля (172.16.1.2)
    local_ip="172.16.1.2"
    read -p "Введите удалённый IP для туннеля (на ISP-1, например 172.16.2.2): " remote_ip
    echo "→ Создаём туннель tun1"
    nmcli connection add type ip-tunnel ip-tunnel.mode gre con-name tun1 ifname tun1 remote "$remote_ip" local "$local_ip" dev "$PARENT_IF"
    nmcli connection modify tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
    nmcli connection modify tun1 ip-tunnel.ttl 64
fi

# Активируем туннель (с повторной попыткой)
for attempt in 1 2; do
    if nmcli connection up tun1; then
        echo "✅ Туннель tun1 активирован."
        break
    else
        echo "⚠️ Попытка $attempt не удалась, ждём 2 секунды..."
        sleep 2
    fi
    if [ $attempt -eq 2 ]; then
        echo "❌ Не удалось активировать туннель. Проверьте родительский интерфейс и доступность удалённого IP."
        exit 1
    fi
done

# --- 8. Установка и настройка FRR (OSPF) ---
if ! command -v frr &>/dev/null; then
    echo "→ Устанавливаем пакет FRRouting"
    dnf install -y frr
fi
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr
echo "✅ FRR установлен, ospfd включён и запущен."

# --- 9. Настройка OSPF (ручной ввод) ---
echo "--- Настройка OSPF ---"
echo "Введите сети для анонса в формате '<сеть/маска> area 0'"
echo "Примеры: 10.0.0.0/30 area 0, 192.168.1.0/24 area 0"
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
    echo "✅ OSPF настроен и конфигурация сохранена."
fi

echo "============================================="
echo "  Настройка HQ-RTR успешно завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Родительский интерфейс: $PARENT_IF"
echo "  Туннель tun1: 10.0.0.1/30"
echo "============================================="