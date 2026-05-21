#!/bin/bash

# =====================================================
# Настройка сервера HQ-SRV (RedOS)
# Пользователь sshuser, SSH, SELinux, DNS master
# =====================================================

if [ "$EUID" -ne 0 ]; then
    echo "Запустите с правами root (sudo ./hq-srv.sh)"
    exit 1
fi

echo "============================================="
echo "  Настройка сервера HQ-SRV"
echo "============================================="

# --- 1. Пользователь sshuser ---
read -p "Введите UID для пользователя sshuser: " USER_UID
read -sp "Введите пароль для sshuser: " USER_PASS
echo
useradd -u "$USER_UID" -m -s /bin/bash sshuser
echo "sshuser:$USER_PASS" | chpasswd
echo "✅ Пользователь sshuser создан (UID $USER_UID)"

# --- 2. Sudo без пароля ---
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
echo "✅ Права sudo добавлены"

# --- 3. Настройка SSH ---
read -p "Введите порт для SSH (например, 2222): " SSH_PORT
read -p "Введите количество попыток входа MaxAuthTries (например, 3): " SSH_TRIES

sed -i "s/^#Port .*/Port $SSH_PORT/; s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#MaxAuthTries .*/MaxAuthTries $SSH_TRIES/; s/^MaxAuthTries .*/MaxAuthTries $SSH_TRIES/" /etc/ssh/sshd_config
sed -i 's/^#Banner .*/Banner \/etc\/ssh\/banner/; s/^Banner .*/Banner \/etc\/ssh\/banner/' /etc/ssh/sshd_config
echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
echo "Authorized access only" > /etc/ssh/banner
echo "✅ SSH настроен: порт $SSH_PORT, MaxAuthTries $SSH_TRIES"

# --- 4. SELinux Permissive ---
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0
echo "✅ SELinux переведён в permissive"

# --- 5. Перезапуск SSH ---
systemctl restart sshd
systemctl enable sshd

# --- 6. Установка BIND ---
dnf install -y bind bind-utils
echo "✅ BIND установлен"

# --- 7. Настройка /etc/named.conf ---
read -p "Введите внешний DNS-сервер для forwarders (например, 8.8.8.8): " EXT_DNS
read -p "Введите IP-адрес этого сервера (например, 192.168.1.2): " SRV_IP

# Определяем обратную зону по первым трём октетам (только для /24)
REV_OCTETS=$(echo "$SRV_IP" | awk -F. '{print $3"."$2"."$1}')
REV_ZONE="$REV_OCTETS.in-addr.arpa"

# Создаём /etc/named.conf с нуля (безопаснее, чем дописывать)
cat > /etc/named.conf <<EOF
options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    allow-query { any; };
    forwarders { $EXT_DNS; };
    dnssec-validation no;
};

zone "." IN {
    type hint;
    file "named.ca";
};

zone "localhost" IN {
    type master;
    file "named.localhost";
};

zone "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa" IN {
    type master;
    file "named.loopback";
};

zone "1.0.0.127.in-addr.arpa" IN {
    type master;
    file "named.loopback";
};

zone "0.in-addr.arpa" IN {
    type master;
    file "named.empty";
};
EOF

# --- 8. Обратная зона (PTR) ---
mkdir -p /var/named/master
cat > /var/named/master/"$REV_ZONE".db <<EOF
\$TTL 1D
@   IN SOA  localhost. admin.localhost. (
                    0   ; serial
                    1D  ; refresh
                    1H  ; retry
                    1W  ; expire
                    3H )    ; minimum
    IN NS      localhost.
EOF

# Добавляем PTR-запись для самого сервера
LAST_OCTET=$(echo "$SRV_IP" | awk -F. '{print $4}')
echo "$LAST_OCTET    IN PTR    localhost." >> /var/named/master/"$REV_ZONE".db

# Добавляем обратную зону в named.conf (если не была добавлена)
grep -q "zone \"$REV_ZONE\"" /etc/named.conf || cat >> /etc/named.conf <<EOF

zone "$REV_ZONE" {
    type master;
    file "master/$REV_ZONE.db";
};
EOF

# --- 9. Прямая зона ---
read -p "Введите имя прямой зоны (например, au-team.irpo): " ZONE_NAME

# Создаём файл прямой зоны
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

# Запрашиваем дополнительные A-записи
echo "Теперь добавьте дополнительные A-записи (имя хоста и IP). Пустая строка для завершения."
while true; do
    read -p "Имя (например, www) и IP (например, $SRV_IP): " name ip
    [ -z "$name" ] && break
    echo "$name    IN A    $ip" >> /var/named/master/"$ZONE_NAME".db
done

# Добавляем прямую зону в named.conf
cat >> /etc/named.conf <<EOF

zone "$ZONE_NAME" {
    type master;
    file "master/$ZONE_NAME.db";
};
EOF

# --- 10. Проверка конфигурации ---
if ! named-checkconf; then
    echo "❌ Ошибка в named.conf. Проверьте синтаксис."
    exit 1
fi

if ! named-checkzone "$ZONE_NAME" /var/named/master/"$ZONE_NAME".db; then
    echo "❌ Ошибка в файле прямой зоны."
    exit 1
fi

if ! named-checkzone "$REV_ZONE" /var/named/master/"$REV_ZONE".db; then
    echo "❌ Ошибка в файле обратной зоны."
    exit 1
fi

# --- 11. Права на файлы зон ---
chown root:named /var/named/master/*.db
chmod 640 /var/named/master/*.db

# --- 12. Настройка DNS клиента на ens160 ---
nmcli con mod ens160 ipv4.dns "$SRV_IP $EXT_DNS"
nmcli con up ens160

# --- 13. Запуск named ---
systemctl enable named
systemctl restart named

if systemctl is-active --quiet named; then
    echo "✅ named запущен и добавлен в автозагрузку"
else
    echo "❌ Ошибка запуска named. Смотрите journalctl -u named"
    exit 1
fi

# --- 14. Финальные проверки ---
echo "============================================="
echo "  Настройка HQ-SRV завершена!"
echo "  Пользователь sshuser, SSH порт $SSH_PORT"
echo "  DNS-зона: $ZONE_NAME, IP сервера: $SRV_IP"
echo "  Проверьте DNS:"
echo "    host $ZONE_NAME 127.0.0.1"
echo "    host $SRV_IP 127.0.0.1"
echo "============================================="