#!/bin/bash

# =====================================================
# Настройка маршрутизатора BR-RTR (RedOS)
# ens192 (внутренний) + NAT через ens160 + GRE туннель + FRR/OSPF
# =====================================================

if [ "$EUID" -ne 0 ]; then
    echo "Запустите с правами root (sudo ./br-rtr.sh)"
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
echo "  Настройка маршрутизатора BR-RTR"
echo "============================================="

# 1. Имя хоста
read -p "Введите имя хоста (например, BR-RTR): " NEW_HOSTNAME
[ -n "$NEW_HOSTNAME" ] && hostnamectl set-hostname "$NEW_HOSTNAME" && hostname "$NEW_HOSTNAME"
echo "✅ Hostname: $(hostname)"

# 2. Настройка внутреннего интерфейса ens192 (только IP и маска)
echo "--- Настройка интерфейса ens192 ---"
read -p "Введите IP-адрес для ens192 (например, 192.168.2.2): " IP_ENS192
read -p "Введите маску (CIDR, например 25): " MASK_ENS192
CIDR_ENS192=$(mask_to_cidr "$MASK_ENS192")
if [[ "$CIDR_ENS192" == "0" ]]; then
    echo "❌ Неверный формат маски"
    exit 1
fi

if ! interface_exists "ens192"; then
    echo "❌ Интерфейс ens192 не найден. Доступные:"
    ip -br link | awk '{print $1}'
    exit 1
fi

# Создаём профиль, если его нет
if ! nmcli con show ens192 &>/dev/null; then
    nmcli con add type ethernet ifname ens192 con-name ens192
fi

nmcli con mod ens192 ipv4.addresses "${IP_ENS192}/${CIDR_ENS192}" ipv4.method manual
nmcli con up ens192
echo "✅ ens192 настроен (без шлюза, только IP)"

# 3. Часовой пояс
timedatectl set-timezone Europe/Moscow
echo "✅ Часовой пояс: Europe/Moscow"

# 4. IP-форвардинг
grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
echo "✅ IP-форвардинг включён"

# 5. nftables (masquerade через ens160)
command -v nft &>/dev/null || dnf install -y nftables
mkdir -p /etc/nftables
cat > /etc/nftables/br.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "ens160" masquerade
    }
}
EOF
cat > /etc/sysconfig/nftables.conf <<EOF
include "/etc/nftables/br.nft"
EOF
systemctl enable --now nftables
if systemctl is-active --quiet nftables; then
    echo "✅ nftables запущен (NAT через ens160)"
else
    echo "❌ Ошибка nftables"
    exit 1
fi

# 6. GRE туннель tun1 (через ip tunnel)
echo "--- Настройка GRE туннеля tun1 ---"
nmcli con del tun1 2>/dev/null
ip link del tun1 2>/dev/null

if ! lsmod | grep -q ip_gre; then
    modprobe ip_gre
    sleep 1
fi

read -p "Введите локальный IP для туннеля (адрес на BR-RTR, обычно 172.16.2.2): " local_ip
read -p "Введите удалённый IP для туннеля (адрес HQ-RTR, например 172.16.1.2): " remote_ip
read -p "Введите IP для туннельного интерфейса в формате 10.0.0.2/30: " tunnel_ip

ip tunnel add tun1 mode gre remote "$remote_ip" local "$local_ip" ttl 64
ip link set tun1 up
ip addr add "$tunnel_ip" dev tun1

if ip link show tun1 &>/dev/null; then
    echo "✅ Туннель tun1 создан и активирован"
else
    echo "❌ Не удалось создать туннель"
    exit 1
fi

# 7. FRR и OSPF
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
    echo "⚠️ ospfd не запустился. Перезапускаем FRR..."
    systemctl restart frr
    sleep 5
fi

# 8. OSPF (ручной ввод сетей)
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

echo "============================================="
echo "  Настройка BR-RTR завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Туннель tun1: $tunnel_ip"
echo "  Проверьте OSPF: vtysh -c 'show ip ospf neighbor'"
echo "============================================="