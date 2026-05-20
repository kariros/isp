#!/bin/bash

# =====================================================
# Настройка маршрутизатора HQ-RTR (RedOS)
# Включает VLAN, GRE туннель, FRR/OSPF
# =====================================================

set -e  # остановка при ошибке

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo ./hq-rtr.sh)"
    exit 1
fi

# Функция для преобразования точечной маски в CIDR
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

# Функция проверки существования интерфейса
interface_exists() {
    ip link show "$1" &>/dev/null
}

# Функция для настройки физического интерфейса (IP, маска, шлюз, DNS)
configure_interface() {
    local iface=$1
    local desc=$2
    echo "--- Настройка $desc ($iface) ---"
    read -p "Введите IP-адрес для $iface: " ip_addr
    read -p "Введите маску (CIDR, например 24): " mask
    cidr=$(mask_to_cidr "$mask")
    if [[ "$cidr" == "0" ]]; then
        echo "Неверный формат маски"
        exit 1
    fi
    read -p "Введите шлюз по умолчанию для $iface (если есть, иначе оставить пустым): " gateway
    read -p "Введите DNS-серверы (через пробел, например 8.8.8.8 1.1.1.1): " dns_servers

    # Настройка IP и маски
    nmcli con mod "$iface" ipv4.addresses "${ip_addr}/${cidr}" ipv4.method manual
    if [ -n "$gateway" ]; then
        nmcli con mod "$iface" ipv4.gateway "$gateway"
    fi
    if [ -n "$dns_servers" ]; then
        nmcli con mod "$iface" ipv4.dns "$dns_servers"
    fi
    nmcli con up "$iface"
    echo "✅ $iface настроен"
}

echo "============================================="
echo "  Настройка маршрутизатора HQ-RTR"
echo "============================================="

# 1. Имя хоста
read -p "Введите желаемое имя хоста (например, HQ-RTR): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    hostname "$NEW_HOSTNAME"
    echo "✅ Hostname установлен: $NEW_HOSTNAME"
fi

# 2. Настройка ens192
configure_interface "ens192" "первого интерфейса (ens192)"

# 3. Настройка ens224
configure_interface "ens224" "второго интерфейса (ens224)"

# 4. Создание трёх VLAN на ens160
# Предварительно проверим, что ens160 существует
if ! interface_exists "ens160"; then
    echo "Интерфейс ens160 не найден. Создание VLAN невозможно."
    exit 1
fi

for i in 1 2 3; do
    echo "--- Настройка VLAN $i ---"
    read -p "Введите ID VLAN для VLAN $i (число): " vlan_id
    read -p "Введите маску для сети 192.168.$i.1 (CIDR, например 24): " mask_vlan
    cidr_vlan=$(mask_to_cidr "$mask_vlan")
    if [[ "$cidr_vlan" == "0" ]]; then
        echo "Неверный формат маски"
        exit 1
    fi
    vlan_iface="ens160.$vlan_id"
    ip_addr="192.168.$i.1/$cidr_vlan"
    echo "→ Создание VLAN $vlan_iface с IP $ip_addr"
    nmcli con add type vlan ifname "$vlan_iface" dev ens160 id "$vlan_id"
    nmcli con mod "$vlan_iface" ipv4.addresses "$ip_addr" ipv4.method manual
    nmcli con up "$vlan_iface"
    echo "✅ VLAN $vlan_iface создан"
done

# 5. Часовой пояс
timedatectl set-timezone Europe/Moscow
echo "→ Часовой пояс установлен: Europe/Moscow"

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

# 8. Создание GRE туннеля tun1
echo "--- Настройка GRE туннеля tun1 ---"
read -p "Введите локальный IP для туннеля (адрес на ens160, который будет использоваться как локальный конец GRE): " local_ip
read -p "Введите удалённый IP для туннеля (адрес удалённого маршрутизатора): " remote_ip
# Имя профиля tun1, устройство tun1, режим GRE, родитель ens160
nmcli connection add type ip-tunnel ip-tunnel.mode gre con-name tun1 ifname tun1 remote "$remote_ip" local "$local_ip" dev ens160
nmcli connection modify tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
nmcli connection modify tun1 ip-tunnel.ttl 64
nmcli connection up tun1
echo "✅ Туннель tun1 создан"

# 9. Установка FRR и включение ospfd
dnf install -y frr
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr
echo "✅ FRR установлен и ospfd включён"

# 10. Настройка OSPF через vtysh
# Соберём сети, которые нужно анонсировать: 
# - сети VLAN (192.168.1.0, 192.168.2.0, 192.168.3.0) с их масками
# - туннельная сеть 10.0.0.0/30
# Также сети от ens192 и ens224, если они не внешние (ens192 и ens224 считаем внутренними). Но по условию внешний только ens160.
# Определим автоматически все IP-адреса, кроме ens160 (и его VLAN? но VLAN мы уже учли отдельно). 
# Упростим: добавим сети, которые мы сами настроили.
# Получим сети VLAN из созданных интерфейсов.
networks_to_add=()
# Добавим сети для ens192 и ens224 (если они имеют IP)
for iface in ens192 ens224; do
    ip_cidr=$(nmcli -g ipv4.addresses con show "$iface" | head -1)
    if [ -n "$ip_cidr" ]; then
        # Преобразуем IP/маску в сеть (упрощённо: отбросим последний октет, но лучше использовать ipcalc)
        network=$(ipcalc -n "$ip_cidr" | grep Network | awk '{print $2}')
        if [ -n "$network" ]; then
            networks_to_add+=("$network area 0")
        fi
    fi
done
# Добавим сети VLAN
for i in 1 2 3; do
    # Маску возьмём из настроенного интерфейса ens160.$vlan_id
    vlan_iface=$(nmcli -t -f NAME con show --active | grep "ens160\." | head -$i | tail -1)
    if [ -n "$vlan_iface" ]; then
        ip_cidr=$(nmcli -g ipv4.addresses con show "$vlan_iface")
        network=$(ipcalc -n "$ip_cidr" | grep Network | awk '{print $2}')
        if [ -n "$network" ]; then
            networks_to_add+=("$network area 0")
        fi
    fi
done
# Добавим туннельную сеть
networks_to_add+=("10.0.0.0/30 area 0")

# Запросим пароль аутентификации OSPF
read -sp "Введите пароль для аутентификации OSPF (должен быть одинаков на обоих концах туннеля): " ospf_password
echo ""

# Теперь применим настройки через vtysh
vtysh -c "configure terminal" \
       -c "router ospf" \
       -c "passive-interface default" \
       $(for net in "${networks_to_add[@]}"; do echo "-c \"network $net\""; done) \
       -c "area 0 authentication" \
       -c "exit" \
       -c "interface tun1" \
       -c "no ip ospf network broadcast" \
       -c "no ip ospf passive" \
       -c "ip ospf authentication" \
       -c "ip ospf authentication-key $ospf_password" \
       -c "exit" \
       -c "exit" \
       -c "write"

echo "✅ OSPF настроен и конфигурация сохранена"

echo "============================================="
echo "  Настройка HQ-RTR завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Туннель tun1: 10.0.0.1/30"
echo "  Проверьте статус nftables: systemctl status nftables"
echo "  Проверьте туннель: ip link show tun1"
echo "  OSPF: vtysh -c 'show ip ospf neighbor'"
echo "============================================="