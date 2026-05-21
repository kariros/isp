#!/bin/bash

# =====================================================
# Настройка сервера HQ-SRV (RedOS)
# Пользователь sshuser, SSH, SELinux permissive, DNS master
# =====================================================

if [ "$EUID" -ne 0 ]; then
    echo "Запустите с правами root (sudo ./hq-srv.sh)"
    exit 1
fi

echo "============================================="
echo "  Настройка сервера HQ-SRV"
echo "============================================="

# --- 1. Создание пользователя sshuser ---
read -p "Введите UID для пользователя sshuser: " USER_UID
read -sp "Введите пароль для sshuser: " USER_PASS
echo
useradd -u "$USER_UID" -m -s /bin/bash sshuser
echo "sshuser:$USER_PASS" | chpasswd
echo "✅ Пользователь sshuser создан (UID $USER_UID)"

# --- 2. Права sudo без пароля ---
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
echo "✅ Права sudo добавлены"

# --- 3. Настройка SSH ---
read -p "Введите порт для SSH (например, 2222): " SSH_PORT
read -p "Введите количество попыток входа MaxAuthTries (например, 3): " SSH_TRIES

# Редактируем /etc/ssh/sshd_config
sed -i "s/^#Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#MaxAuthTries .*/MaxAuthTries $SSH_TRIES/" /etc/ssh/sshd_config
sed -i "s/^MaxAuthTries .*/MaxAuthTries $SSH_TRIES/" /etc/ssh/sshd_config
sed -i 's/^#Banner .*/Banner \/etc\/ssh\/banner/' /etc/ssh/sshd_config
sed -i 's/^Banner .*/Banner \/etc\/ssh\/banner/' /etc/ssh/sshd_config
echo "AllowUsers sshuser" >> /etc/ssh/sshd_config

# Создаём файл баннера
echo "Authorized access only" > /etc/ssh/banner
echo "✅ SSH настроен: порт $SSH_PORT, MaxAuthTries $SSH_TRIES, баннер создан"

# --- 4. SELinux Permissive ---
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0
echo "✅ SELinux переведён в permissive"

# --- 5. Перезапуск SSH ---
systemctl restart sshd
systemctl enable sshd
echo "✅ SSH перезапущен"

# --- 6. Установка BIND ---
dnf install -y bind bind-utils
echo "✅ BIND установлен"

# --- 7. Настройка /etc/named.conf ---
# Спрашиваем внешний DNS для forwarders
read -p "Введите внешний DNS-сервер (например, 8.8.8.8): " EXT_DNS

# Резервное копирование
cp /etc/named.conf /etc/named.conf.bak

# Настраиваем параметры
sed -i 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/' /etc/named.conf
sed -i 's/listen-on-v6 port 53 { ::1; };/listen-on-v6 port 53 { none; };/' /etc/named.conf
sed -i 's/allow-query     { localhost; };/allow-query     { any; };/' /etc/named.conf
sed -i 's/dnssec-validation yes;/dnssec-validation no;/' /etc/named.conf

# Добавляем forwarders (ищем секцию options и вставляем перед закрывающей скобкой)
sed -i "/options {/a \    forwarders { $EXT_DNS; };" /etc/named.conf

echo "✅ /etc/named.conf настроен"

# --- 8. Прямая зона ---
read -p "Введите имя зоны (например, example.com): " ZONE_NAME
read -p "Введите IP-адрес этого сервера (для NS-записи): " SRV_IP

# Создаём папку master
mkdir -p /var/named/master

# Копируем шаблон
cp /var/named/named.localhost /var/named/master/"$ZONE_NAME".db

# Редактируем файл прямой зоны
# Заменяем @ на имя зоны, rname.invalid на почту (точка вместо @)
cat > /var/named/master/"$ZONE_NAME".db <<EOF
\$TTL 1D
@   IN SOA  $ZONE_NAME. admin.$ZONE_NAME. (
                    0   ; serial
                    1D  ; refresh
                    1H  ; retry
                    1W  ; expire
                    3H )    ; minimum
    IN NS      $ZONE_NAME.
    IN A       $SRV_IP
EOF

# Запрашиваем дополнительные записи для прямой зоны
echo "Теперь добавьте записи A для устройств (имя и IP)."
echo "Введите имя и IP через пробел. Пустая строка для завершения."
while true; do
    read -p "Имя и IP (например, www 192.168.1.10): " host_ip
    [ -z "$host_ip" ] && break
    echo "$host_ip" | while read host ip; do
        echo "$host    IN A    $ip" >> /var/named/master/"$ZONE_NAME".db
    done
done

echo "✅ Файл прямой зоны создан: /var/named/master/$ZONE_NAME.db"

# --- 9. Обратная зона ---
# Определяем обратную зону по IP сервера (первые три октета в обратном порядке)
REV_OCTETS=$(echo "$SRV_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="$REV_OCTETS.in-addr.arpa"

# Добавляем обратную зону в named.conf
cat >> /etc/named.conf <<EOF

zone "$REV_ZONE" {
    type master;
    file "master/$REV_ZONE.db";
};
EOF

# Копируем прямой файл как шаблон для обратной
cp /var/named/master/"$ZONE_NAME".db /var/named/master/"$REV_ZONE".db

# Очищаем всё, кроме SOA, и добавляем PTR записи
cat > /var/named/master/"$REV_ZONE".db <<EOF
\$TTL 1D
@   IN SOA  $ZONE_NAME. admin.$ZONE_NAME. (
                    0   ; serial
                    1D  ; refresh
                    1H  ; retry
                    1W  ; expire
                    3H )    ; minimum
    IN NS      $ZONE_NAME.
EOF

# Добавляем PTR запись для самого сервера
LAST_OCTET=$(echo "$SRV_IP" | awk -F. '{print $4}')
echo "$LAST_OCTET    IN PTR    $ZONE_NAME." >> /var/named/master/"$REV_ZONE".db

# Запрашиваем PTR записи для других устройств
echo "Теперь добавьте PTR записи для обратной зоны (последний октет и полное доменное имя)."
echo "Введите октет и FQDN через пробел. Пустая строка для завершения."
while true; do
    read -p "Октет и FQDN (например, 10 server.example.com.): " ptr_entry
    [ -z "$ptr_entry" ] && break
    echo "$ptr_entry" | while read octet fqdn; do
        echo "$octet    IN PTR    $fqdn" >> /var/named/master/"$REV_ZONE".db
    done
done

echo "✅ Файл обратной зоны создан: /var/named/master/$REV_ZONE.db"

# --- 10. Проверка конфигурации ---
named-checkconf
if [ $? -eq 0 ]; then
    echo "✅ named-checkconf OK"
else
    echo "❌ Ошибка в named.conf. Проверьте вручную."
    exit 1
fi

named-checkconf -z
if [ $? -eq 0 ]; then
    echo "✅ named-checkconf -z OK"
else
    echo "❌ Ошибка в файлах зон. Проверьте вручную."
    exit 1
fi

# --- 11. Права на файлы зон ---
chown root:named /var/named/master/*
chmod 640 /var/named/master/*
echo "✅ Права установлены"

# --- 12. Настройка DNS клиента на ens160 через nmcli ---
# Предполагаем, что интерфейс ens160 существует
nmcli con mod ens160 ipv4.dns "$SRV_IP $EXT_DNS"
nmcli con up ens160
echo "✅ DNS клиента настроен: первый DNS = $SRV_IP, второй = $EXT_DNS"

# --- 13. Запуск named ---
systemctl enable named
systemctl start named
if systemctl is-active --quiet named; then
    echo "✅ named запущен и добавлен в автозагрузку"
else
    echo "❌ Ошибка запуска named. Проверьте журнал: journalctl -u named"
    exit 1
fi

echo "============================================="
echo "  Настройка HQ-SRV завершена!"
echo "  Пользователь sshuser создан, SSH порт $SSH_PORT"
echo "  DNS-зона: $ZONE_NAME, IP сервера: $SRV_IP"
echo "  Проверьте работу DNS: nslookup $ZONE_NAME localhost"
echo "============================================="