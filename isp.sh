#!/bin/bash

# =====================================================
# Настройка маршрутизатора ISP (RedOS)
# Скрипт для загрузки с GitHub и запуска на ВМ
# =====================================================

set -e  # остановка при ошибке

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт с правами root (sudo ./setup_isp.sh)"
    exit 1
fi

echo "============================================="
echo "  Настройка маршрутизатора ISP для схемы"
echo "============================================="

# 1. Запрос IP и маски для ens192
read -p "Введите IP-адрес для интерфейса ens192 (например, 172.16.2.2): " IP_ENS192
read -p "Введите маску для ens192 (например, 24 или 255.255.255.0): " MASK_ENS192
# Преобразуем маску, если введена в формате CIDR
if [[ "$MASK_ENS192" =~ ^[0-9]+$ ]]; then
    CIDR_ENS192="/$MASK_ENS192"
else
    CIDR_ENS192=" $MASK_ENS192"   # для nmcli формат "IP/маска" - лучше привести к CIDR
    # Попробуем преобразовать из точечной маски в CIDR (упрощённо)
    # Но проще попросить ввести CIDR. Подстрахуемся:
    echo "Предупреждение: рекомендуется использовать формат CIDR (число от 1 до 32)"
    echo "Попробуем использовать маску как есть, но возможна ошибка."
    CIDR_ENS192="/$MASK_ENS192"
fi

# 2. Запрос IP и маски для ens256
read -p "Введите IP-адрес для интерфейса ens256 (например, 192.168.1.1): " IP_ENS256
read -p "Введите маску для ens256 (CIDR, например 24): " MASK_ENS256
if [[ "$MASK_ENS256" =~ ^[0-9]+$ ]]; then
    CIDR_ENS256="/$MASK_ENS256"
else
    CIDR_ENS256=" $MASK_ENS256"
fi

# 3. Настройка интерфейсов через nmcli
echo "→ Настройка ens192 с адресом ${IP_ENS192}${CIDR_ENS192}"
nmcli con mod ens192 ipv4.addresses "${IP_ENS192}${CIDR_ENS192}" ipv4.method manual
nmcli con up ens192

echo "→ Настройка ens256 с адресом ${IP_ENS256}${CIDR_ENS256}"
nmcli con mod ens256 ipv4.addresses "${IP_ENS256}${CIDR_ENS256}" ipv4.method manual
nmcli con up ens256

# 4. Установка временной зоны
echo "→ Установка часового пояса Europe/Moscow"
timedatectl set-timezone Europe/Moscow

# 5. Включение IP-форвардинга
echo "→ Включение IP-форвардинга (net.ipv4.ip_forward = 1)"
if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sysctl -p

# 6. Установка nftables (если не установлен)
if ! command -v nft &> /dev/null; then
    echo "→ Установка пакета nftables"
    dnf install -y nftables
fi

# 7. Создание каталога и файла правил isp.nft
echo "→ Создание /etc/nftables/isp.nft"
mkdir -p /etc/nftables
cat > /etc/nftables/isp.nft << 'EOF'
table inet nat {
    chain POSTROUTING {
        type nat hook postrouting priority srcnat;
        oifname "ens160" masquerade
    }
}
EOF

# 8. Настройка /etc/sysconfig/nftables.conf
echo "→ Редактирование /etc/sysconfig/nftables.conf"
# Раскомментировать строку Include и заменить main на isp
sed -i 's/^#\s*Include\s*/Include /' /etc/sysconfig/nftables.conf 2>/dev/null || true
# Если строка Include отсутствует, добавим
if ! grep -q "^Include" /etc/sysconfig/nftables.conf; then
    echo "Include /etc/nftables/isp.nft" >> /etc/sysconfig/nftables.conf
else
    # Заменяем имя файла на isp.nft
    sed -i 's/Include .*/Include \/etc\/nftables\/isp.nft/' /etc/sysconfig/nftables.conf
fi

# 9. Запуск и включение службы nftables
echo "→ Включение и запуск nftables"
systemctl enable --now nftables

echo "============================================="
echo "  Настройка ISP завершена!"
echo "  Проверьте статус: systemctl status nftables"
echo "  Правила: nft list ruleset"
echo "============================================="