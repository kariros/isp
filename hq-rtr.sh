#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# + Пользователь-администратор + DHCP-сервер
# + Настройки IPv4 required / IPv6 ignore для VLAN
# =====================================================

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
    ip -4 addr show | grep -B2 "inet 172.16.1.2" | grep '^[0-9]*:' | awk -F': ' '{print $2}'
}

echo "============================================="
echo "  Настройка маршрутизатора HQ-RTR"
echo "============================================="

# --- Имя хоста ---
read -p "Введите имя хоста (например, HQ-RTR): " NEW_HOSTNAME
[ -n "$NEW_HOSTNAME" ] && hostnamectl set-hostname "$NEW_HOSTNAME" && hostname "$NEW_HOSTNAME"
echo "✅ Hostname: $(hostname)"

# --- Родительский интерфейс ---
PARENT_IF=$(find_parent_interface_by_ip)
if [ -z "$PARENT_IF" ]; then
    read -p "Введите имя родительского интерфейса (например, ens160): " PARENT_IF
    if ! interface_exists "$PARENT_IF"; then
        echo "❌ Интерфейс $PARENT_IF не найден"
        exit 1
    fi
fi
echo "✅ Родительский интерфейс: $PARENT_IF"

# --- VLAN с настройками IPv4 required / IPv6 ignore ---
vlan_networks=()
for i in 1 2 3; do
    echo "--- VLAN $i ---"
    read -p "СМОТРИТЕ ЗАДАНИ!!! Введите ID для VLAN $i: Е" vlan_id
    vlan_iface="$PARENT_IF.$vlan_id"
    if nmcli con show "$vlan_iface" &>/dev/null; then
        echo "⚠️ Профиль $vlan_iface уже существует"
        ip_addr=$(nmcli -g ipv4.addresses con show "$vlan_iface" | head -1)
    else
        read -p "Введите маску для сети 192.168.$i.1 (CIDR) СМОТРИТЕ ЗАДАНИЕ: " mask_vlan
        cidr=$(mask_to_cidr "$mask_vlan")
        ip_addr="192.168.$i.1/$cidr"
        nmcli con add type vlan ifname "$vlan_iface" dev "$PARENT_IF" id "$vlan_id" con-name "$vlan_iface"
        nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
        echo "✅ VLAN $vlan_iface создан"
    fi
    # Принудительно устанавливаем параметры IPv4/IPv6
    nmcli con mod "$vlan_iface" ipv4.may-fail no
    nmcli con mod "$vlan_iface" ipv6.method ignore
    nmcli con up "$vlan_iface"
    network=$(ipcalc -n "$ip_addr" | grep Network | awk '{print $2}')
    [ -n "$network" ] && vlan_networks+=("$network area 0")
done

# --- Часовой пояс ---
timedatectl set-timezone Europe/Moscow
echo "✅ Часовой пояс: Europe/Moscow"

# --- IP-форвардинг ---
grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
echo "✅ IP-форвардинг включён"

# --- nftables ---   
command -v nft &>/dev/null || dnf install -y nftables
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

# --- GRE туннель через ip (без NetworkManager) ---
echo "--- Настройка GRE туннеля tun1 ---"
nmcli con del tun1 2>/dev/null
ip link del tun1 2>/dev/null
if ! lsmod | grep -q ip_gre; then
    modprobe ip_gre
    sleep 1
fi
local_ip="172.16.1.2"
read -p "Введите удалённый IP для туннеля (например, 172.16.2.2): " remote_ip
ip tunnel add tun1 mode gre remote "$remote_ip" local "$local_ip" ttl 64
ip link set tun1 up
ip addr add 10.0.0.1/30 dev tun1
if ip link show tun1 &>/dev/null; then
    echo "✅ Туннель tun1 создан и активирован"
else
    echo "❌ Не удалось создать туннель"
    exit 1
fi

# --- FRR ---
command -v frr &>/dev/null || dnf install -y frr
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

# --- OSPF (единый вызов vtysh) ---
echo "--- Настройка OSPF ---"
echo "Введите сети в формате '<сеть/маска> area 0' (например, 10.0.0.0/30 area 0)"
echo "Когда закончите, оставьте строку пустой и нажмите Enter."
networks_to_add=()
while true; do
    read -p "Сеть: " net
    [ -z "$net" ] && break
    networks_to_add+=("$net")
done
if [ ${#networks_to_add[@]} -eq 0 ]; then
    echo "⚠️ Не добавлено ни одной сети. OSPF не будет настроен."
else
    read -sp "Введите пароль аутентификации OSPF (общий для обоих концов): " ospf_password
    echo ""
    cmds=(
        "configure terminal"
        "router ospf"
        "passive-interface default"
    )
    for net in "${networks_to_add[@]}"; do
        cmds+=("network $net")
    done
    cmds+=(
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
    printf "%s\n" "${cmds[@]}" | vtysh
    echo "✅ OSPF настроен"
fi

# ===================== НОВЫЕ БЛОКИ =====================

# --- Создание административного пользователя и добавление в /etc/sudoers ---
echo "--- Создание административного пользователя ---"
read -p "Введите имя пользователя (например, net_admin): " ADMIN_USER
if [ -z "$ADMIN_USER" ]; then
    ADMIN_USER="net_admin"
fi
read -p "Введите UID для пользователя $ADMIN_USER: " ADMIN_UID
read -sp "Введите пароль для $ADMIN_USER: " ADMIN_PASS
echo
useradd -u "$ADMIN_UID" -m -s /bin/bash "$ADMIN_USER"
echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd

# Добавляем строку в /etc/sudoers, если её ещё нет
SUDOERS_LINE="$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"
if ! grep -Fxq "$SUDOERS_LINE" /etc/sudoers; then
    # Временно добавляем строку в конец файла
    echo "$SUDOERS_LINE" >> /etc/sudoers
    # Проверяем синтаксис sudoers
    if visudo -c &>/dev/null; then
        echo "✅ Права sudo NOPASSWD добавлены в /etc/sudoers для $ADMIN_USER"
    else
        # Если синтаксис ошибочен, откатываем изменение
        sed -i "\$d" /etc/sudoers
        echo "❌ Ошибка синтаксиса sudoers. Права не добавлены."
        exit 1
    fi
else
    echo "⚠️ Запись для $ADMIN_USER уже существует в /etc/sudoers"
fi

# --- Настройка DHCP-сервера для HQ-CLI ---
echo "--- Установка и настройка DHCP-сервера ---"
dnf install -y dhcp-server

# Запрашиваем параметры подсети
echo "Введите параметры для DHCP-пула (например, для VLAN 20):"
read -p "IP-сеть (например, 192.168.2.0): " dhcp_subnet
read -p "Маска сети (например, 255.255.255.240): " dhcp_netmask
read -p "Диапазон IP (начало, например 192.168.2.2): " dhcp_range_start
read -p "Диапазон IP (конец, например 192.168.2.5): " dhcp_range_end
read -p "DNS-серверы (через запятую, например 172.16.1.2, 8.8.8.8): " dhcp_dns
read -p "Доменное имя (например, au-team.irpo или написано в задании): " dhcp_domain
read -p "Шлюз (маршрутизатор, например 192.168.2.1): " dhcp_router
read -p "Время аренды по умолчанию (сек, например 600): " dhcp_default_lease
read -p "Максимальное время аренды (сек, например 7200): " dhcp_max_lease

# Создаём конфигурационный файл dhcpd.conf
cat > /etc/dhcp/dhcpd.conf <<EOF
# DHCP configuration for HQ-CLI subnet
subnet $dhcp_subnet netmask $dhcp_netmask {
    range $dhcp_range_start $dhcp_range_end;
    option domain-name-servers $dhcp_dns;
    option domain-name "$dhcp_domain";
    option routers $dhcp_router;
    default-lease-time $dhcp_default_lease;
    max-lease-time $dhcp_max_lease;
}
EOF

# Определяем интерфейс, на котором будет работать DHCP (должен соответствовать подсети)
echo "На каком интерфейсе должен работать DHCP-сервер? (например, $PARENT_IF.20)"
read -p "Интерфейс: " dhcp_interface
if ! interface_exists "$dhcp_interface"; then
    echo "⚠️ Интерфейс $dhcp_interface не найден. DHCP может не запуститься."
fi

# Указываем в настройках DHCP, на каком интерфейсе слушать
echo "DHCPDARGS=\"$dhcp_interface\"" > /etc/sysconfig/dhcpd

# Запуск DHCP-сервера
systemctl enable --now dhcpd
if systemctl is-active --quiet dhcpd; then
    echo "✅ DHCP-сервер запущен на интерфейсе $dhcp_interface"
else
    echo "❌ Ошибка запуска DHCP. Проверьте конфигурацию /etc/dhcp/dhcpd.conf"
    exit 1
fi

# =====================================================

echo "============================================="
echo "  Настройка HQ-RTR завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Туннель tun1: 10.0.0.1/30"
echo "  Создан администратор: $ADMIN_USER (UID $ADMIN_UID, sudo без пароля)"
echo "  DHCP-сервер настроен для сети $dhcp_subnet/$dhcp_netmask"
echo "  Для VLAN установлены: IPv4 required, IPv6 ignored"
echo "  Проверьте OSPF: vtysh -c 'show ip ospf neighbor'"
echo "  Проверьте DHCP: systemctl status dhcpd"
echo "============================================="
