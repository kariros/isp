#!/bin/bash

# =====================================================
# Настройка маршрутизатора ISP (RedOS)
# Скрипт с проверкой интерфейсов и правильным nftables
# =====================================================

set -e  # остановка при ошибке

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo ./setup_isp.sh)"
    exit 1
fi

# Функция для преобразования точечной маски в CIDR
mask_to_cidr() {
    local mask=$1
    if [[ "$mask" =~ ^[0-9]+$ ]]; then
        echo "$mask"
    elif [[ "$mask" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Преобразуем 255.255.255.0 -> 24
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

# Запрос имени интерфейса с проверкой
get_interface() {
    local prompt="$1"
    local iface
    while true; do
        read -p "$prompt: " iface
        if interface_exists "$iface"; then
            echo "$iface"
            break
        else
            echo "Интерфейс $iface не найден. Доступные интерфейсы:"
            ip -br link | awk '{print $1}'
        fi
    done
}

echo "============================================="
echo "  Настройка маршрутизатора ISP для схемы"
echo "============================================="

# Запрос внешнего интерфейса (для masquerade)
EXT_IF=$(get_interface "Введите имя ВНЕШНЕГО интерфейса (смотрит в интернет, обычно ens160)")

# Запрос внутренних интерфейсов и их IP
INNER1_IF=$(get_interface "Введите имя ПЕРВОГО внутреннего интерфейса (например, ens192)")
read -p "Введите IP-адрес для $INNER1_IF (например, 172.16.2.2): " IP_INNER1
read -p "Введите маску для $INNER1_IF (например, 24 или 255.255.255.0): " MASK_INNER1
CIDR_INNER1=$(mask_to_cidr "$MASK_INNER1")
if [[ "$CIDR_INNER1" == "0" ]]; then
    echo "Не удалось распознать маску. Используйте CIDR (например, 24)."
    exit 1
fi

INNER2_IF=$(get_interface "Введите имя ВТОРОГО внутреннего интерфейса (например, ens256 или ens224)")
read -p "Введите IP-адрес для $INNER2_IF (например, 192.168.1.1): " IP_INNER2
read -p "Введите маску для $INNER2_IF (CIDR, например 25): " MASK_INNER2
CIDR_INNER2=$(mask_to_cidr "$MASK_INNER2")
if [[ "$CIDR_INNER2" == "0" ]]; then
    echo "Не удалось распознать маску. Используйте CIDR (например, 24)."
    exit 1
fi

# Настройка интерфейсов через nmcli
echo "→ Настройка $INNER1_IF с адресом ${IP_INNER1}/${CIDR_INNER1}"
nmcli con mod "$INNER1_IF" ipv4.addresses "${IP_INNER1}/${CIDR_INNER1}" ipv4.method manual
nmcli con up "$INNER1_IF"

echo "→ Настройка $INNER2_IF с адресом ${IP_INNER2}/${CIDR_INNER2}"
nmcli con mod "$INNER2_IF" ipv4.addresses "${IP_INNER2}/${CIDR_INNER2}" ipv4.method manual
nmcli con up "$INNER2_IF"

# Установка временной зоны
echo "→ Установка часового пояса Europe/Moscow"
timedatectl set-timezone Europe/Moscow

# Включение IP-форвардинга
echo "→ Включение IP-форвардинга (net.ipv4.ip_forward = 1)"
if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p

# Установка nftables (если не установлен)
if ! command -v nft &> /dev/null; then
    echo "→ Установка пакета nftables"
    dnf install -y nftables
fi

# Создание каталога и файла правил isp.nft
echo "→ Создание /etc/nftables/isp.nft"
mkdir -p /etc/nftables
cat > /etc/nftables/isp.nft <<EOF
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "$EXT_IF" masquerade
    }
}
EOF

# Правильная настройка /etc/sysconfig/nftables.conf (синтаксис include)
echo "→ Редактирование /etc/sysconfig/nftables.conf"
cat > /etc/sysconfig/nftables.conf <<EOF
include "/etc/nftables/isp.nft"
EOF

# Запуск и включение службы nftables
echo "→ Включение и запуск nftables"
systemctl enable --now nftables

# Проверка статуса
if systemctl is-active --quiet nftables; then
    echo "✅ nftables успешно запущен"
else
    echo "❌ Ошибка при запуске nftables. Проверьте: journalctl -xeu nftables"
    exit 1
fi

echo "============================================="
echo "  Настройка ISP завершена!"
echo "  Внешний интерфейс: $EXT_IF"
echo "  Внутренние: $INNER1_IF (${IP_INNER1}/${CIDR_INNER1}), $INNER2_IF (${IP_INNER2}/${CIDR_INNER2})"
echo "  Проверьте: systemctl status nftables"
echo "  Правила: nft list ruleset"
echo "============================================="
