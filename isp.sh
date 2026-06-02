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
INNER2_IF=$(get_interface "Введите имя ВТОРОГО внутреннего интерфейса (например, ens224)")
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

# ===================== БЛОК ДЛЯ ОТЧЕТА =====================
echo ""
read -p "Нужна ли вам помощь с заполнением отчета? (yes/no): " help_report
if [[ "$help_report" == "yes" || "$help_report" == "y" || "$help_report" == "YES" ]]; then
    # Здесь вы можете написать любой текст, который будет помещен в файл /etc/banner2
    REPORT_TEXT="
===========================================
   Шпаргалка по командам
===========================================
exec bash -> обновить имя машины
EDITOR=nano visudo -> перенести root права юзера в середину файла 
timedatectl -> проверить часовой пояс машины (если не соотв. заданию то писать timedatectl set-timezone Europe/Moscow
/etc/sysctl.conf -> net.ipv4.ip_forward = 1 затем sysctl -p
/etc/sysconfig/nftables.conf -> проверить соответстует ли файлу
systemctl enable –-now nftables -> включить нфтаблес
nmcli connection modify tun1 ip-tunnel.ttl 64 -> расширение жизни пакета
===========================================
    VTYSH
===========================================
Во Vtysh ввести команду show ip ospf route, если там есть соседние сети, то всё работает как надо.
show ip ospf neighbor в vtysh позволяет увидеть соседний маршрутизатор с настроенной динамической маршрутизацией.
===========================================
    SSH
===========================================
/etc/ssh/sshd_config  -> настройка SSH
SSH можно подключиться к этому устройству, используя команду SSH [имя пользователя]@[IP-адрес] -p [порт].
===========================================
    DNS
===========================================
настройки DNS -> /etc/named.conf
Для проверки зоны можно использовать команду named-checkconf -z
Откройте nmtui и измените DNS-сервер у адаптера ens160. В первом DNS укажите адрес самого сервера, во втором — внешний DNS. Затем перезапустите адаптер
    Проверка прямой зоны
host hq-srv.au-team.irpo
host br-srv.au-team.irpo
    Проверка обратной зоны
host [ip машины]
===========================================
    МАСКИ ПОДСЕТИ
===========================================
255.255.255.255 - /32 - 1 ip 
255.255.255.254 - /31 - 2 ip 
255.255.255.252 - /30 - 4 ip 
255.255.255.248 - /29 - 8 ip 
255.255.255.240 - /28 - 16 ip 
255.255.255.224 - /27 - 32 ip
255.255.255.192 - /26 - 64 ip
255.255.255.128 - /25 - 128 ip
255.255.255.0 - /24 - 256 ip

"
    echo "$REPORT_TEXT" > /etc/banner2
    echo "✅ Файл /etc/banner2 создан с готовым отчётом. Откройте его: nano /etc/banner2"
else
    echo "Помощь с отчетом не требуется."
fi

echo "============================================="
echo "  Настройка ISP завершена!"
echo "  Имя хоста: $(hostname)"
echo "  Внешний интерфейс: $EXT_IF"
echo "  Внутренние: $INNER1_IF (${IP_INNER1}/${CIDR1}), $INNER2_IF (${IP_INNER2}/${CIDR2})"
echo "  IPv4 required, IPv6 ignored"
echo "============================================="
