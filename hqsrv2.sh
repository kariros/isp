#!/bin/bash
# hq-srv_setup.sh - устойчивый к ошибкам скрипт настройки HQ-SRV

set -euo pipefail  # жёсткий режим, но ошибки монтирования перехватываются

# Отключение SELinux (требует перезагрузки, но для текущей сессии можно setenforce 0)
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true


echo "=== Установка chrony ==="
dnf install -y chrony
mount /dev/sr0 /mnt/ 


echo "=== Настройка /etc/chrony.conf ==="
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
echo "server 172.16.2.1 iburst" >> /etc/chrony.conf

systemctl restart chronyd
systemctl enable chronyd

echo "=== Проверка синхронизации ==="
chronyc sources -v

echo "=== Готово ==="

# === 1. Изменение порта SSH (всегда выполняется) ===
sed -i 's/^#Port 22/Port 2026/' /etc/ssh/sshd_config
sed -i 's/^Port 22/Port 2026/' /etc/ssh/sshd_config
systemctl restart sshd || true

# === 2. RAID1 (автоматический поиск свободных дисков) ===
echo "=== Настройка RAID1 ==="
ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
DISKS=()
for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
    [ -b "$dev" ] || continue
    if [[ "$dev" == "$ROOT_DEV"* ]]; then continue; fi
    if ls ${dev}[0-9]* 2>/dev/null | grep -q .; then continue; fi
    DISKS+=("$dev")
done

if [ ${#DISKS[@]} -ge 2 ]; then
    DISK1="${DISKS[0]}"
    DISK2="${DISKS[1]}"
    echo "Используем диски: $DISK1 и $DISK2"
    mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 "$DISK1" "$DISK2" || echo "RAID уже существует?"
    mdadm --detail --scan --verbose >> /etc/mdadm.conf 2>/dev/null || true
    mkfs.ext4 /dev/md0 || true
    mkdir -p /raid1
    if ! grep -q '/dev/md0' /etc/fstab; then
        echo '/dev/md0 /raid1 ext4 defaults 0 0' >> /etc/fstab
    fi
    mount -av || true
else
    echo "Не найдено двух свободных дисков для RAID. Пропускаем."
fi

# === 3. NFS ===
echo "=== Настройка NFS ==="
dnf install -y nfs-utils || true
mkdir -p /raid1/nfs
chmod -R 777 /raid1/nfs
if ! grep -q '/raid1/nfs' /etc/exports; then
    echo '/raid1/nfs 192.168.2.0/28(rw,sync,no_root_squash,no_subtree_check)' >> /etc/exports
fi
systemctl enable --now nfs-server || true
exportfs -a || true

# === 4. Веб-сервер и MariaDB ===
echo "=== Установка Apache, MariaDB, PHP ==="
dnf install -y httpd mariadb-server mariadb php php-mysqlnd || true
systemctl enable --now mariadb httpd || true

# 3. mysql_secure_installation (неинтерактивно)
mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('P@ssw0rd');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# 4. Создание БД и пользователя
mysql -uroot -p'P@ssw0rd' <<EOF
CREATE DATABASE webdb;
CREATE USER 'web'@'%' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'%';
FLUSH PRIVILEGES;
EOF

# 5. Импорт дампа

mysql webdb < /mnt/web/dump.sql

# 6. Рестарт MariaDB
systemctl restart mariadb

# 7. Копирование файлов сайта
cp /mnt/web/logo.png /var/www/html/
cp /mnt/web/index.php /var/www/html/

# 8. Правка index.php
sed -i \
  -e 's|\$servername *= *".*";|\$servername = "localhost";|' \
  -e 's|\$username *= *".*";|\$username = "web";|' \
  -e 's|\$password *= *".*";|\$password = "P@ssw0rd";|' \
  -e 's|\$dbname *= *".*";|\$dbname = "webdb";|' \
  /var/www/html/index.php

chown -R apache:apache /var/www/html

# 9. Запуск Apache
systemctl enable --now httpd

echo "=== Настройка HQ-SRV завершена ==="
echo ""
exit 0