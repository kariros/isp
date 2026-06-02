#!/bin/bash
# brsrv2.sh — полная настройка BR-SRV (Samba DC, Ansible, Docker) + настройка sudo на клиентах

set -e

# Отключение SELinux (требует перезагрузки, но для текущей сессии можно setenforce 0)
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

# ============================================
# 0. Настройка chrony (клиент NTP)
# ============================================
echo "=== Установка и настройка chrony (клиент NTP) ==="
dnf install -y chrony
cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
sed -i 's/^server/#server/' /etc/chrony.conf
echo "server 172.16.2.1 iburst" >> /etc/chrony.conf
systemctl restart chronyd
systemctl enable chronyd
chronyc sources -v

# ============================================
# 1. Установка пакетов
# ============================================
echo "=== Установка пакетов ==="
if rpm -q podman-docker &>/dev/null; then
    dnf remove -y podman-docker
fi
dnf install -y samba samba-client samba-dc bind bind-utils
dnf install -y ansible sshpass || true
dnf install -y docker-ce docker-ce-cli docker-compose || true
if ! command -v docker &>/dev/null; then
    dnf install -y docker docker-compose || true
fi

# ============================================
# 2. Настройка SSH (порт 2026)
# ============================================
echo "=== Настройка SSH ==="
sed -i 's/^#Port 22/Port 2026/' /etc/ssh/sshd_config
sed -i 's/^Port 22/Port 2026/' /etc/ssh/sshd_config
systemctl restart sshd

# ============================================
# 3. Настройка Samba DC
# ============================================
echo "=== Настройка контроллера домена Samba ==="
systemctl mask systemd-resolved
systemctl stop systemd-resolved
rm -f /etc/samba/smb.conf
samba-tool domain provision --use-rfc2307 \
    --realm=AU-TEAM.IRPO \
    --domain=AU-TEAM \
    --adminpass='P@ssword' \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --option="bind interfaces only=no"
systemctl enable samba --now
echo "nameserver 127.0.0.1" > /etc/resolv.conf
echo "search au-team.irpo" >> /etc/resolv.conf

# Создание пользователей и группы (запрашиваем параметры)
read -p "Базовое имя пользователей (например, sidehquser): " USER_BASE
read -p "Количество пользователей (например, 5): " USER_COUNT
read -p "Имя группы (например, sidehq): " GROUP_NAME
for i in $(seq 1 $USER_COUNT); do
    samba-tool user create ${USER_BASE}$i \
        --given-name=User \
        --surname=$i \
        --password="$ADMIN_PASS"
done
samba-tool group add "$GROUP_NAME"
for i in $(seq 1 $USER_COUNT); do
    samba-tool group addmembers "$GROUP_NAME" ${USER_BASE}$i
done

# ============================================
# 4. Настройка Ansible
# ============================================
echo "=== Настройка Ansible ==="
mkdir -p /etc/ansible
cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
host_key_checking = False
interpreter_python = auto_silent
EOF

cat > /etc/ansible/hosts <<EOF
[servers]
HQ-SRV ansible_host=192.168.1.2 ansible_user=sshuser ansible_password=P@ssw0rd ansible_port=2026
HQ-CLI ansible_host=192.168.2.2 ansible_user=user ansible_password=P@ssword
HQ-RTR ansible_host=192.168.1.1 ansible_user=net_admin ansible_password=P@ssw0rd
BR-RTR ansible_host=192.168.4.1 ansible_user=net_admin ansible_password=P@ssw0rd
EOF

# Проверяем подключение (теперь ошибка «Host Key checking is enabled» должна исчезнуть)
if command -v ansible &>/dev/null && command -v sshpass &>/dev/null; then
    ansible all -m ping -i /etc/ansible/hosts || echo "Предупреждение: не все хосты доступны. Проверьте пароли и настройки SSH."
else
    echo "Ошибка: ansible или sshpass не установлены."
    exit 1
fi

# ============================================
# 6. Настройка Docker и приложения testapp
# ============================================
echo "=== Настройка Docker и testapp ==="
systemctl enable --now docker

# Монтирование ISO (если есть)
ISO_MOUNT="/mnt/iso"
mkdir -p "$ISO_MOUNT"
if ! mountpoint -q "$ISO_MOUNT"; then
    for dev in /dev/sr0 /dev/cdrom /dev/sr1; do
        if [ -b "$dev" ]; then
            mount "$dev" "$ISO_MOUNT" 2>/dev/null && break
        fi
    done
fi

# Импорт образов из ISO
if [ -d "$ISO_MOUNT/docker" ]; then
    for tarfile in "$ISO_MOUNT/docker"/*.tar; do
        [ -f "$tarfile" ] && docker load -i "$tarfile"
    done
else
    # Альтернативные пути
    for dir in /root/web /root/docker /opt/docker /mnt/docker; do
        if [ -d "$dir" ]; then
            for tarfile in "$dir"/*.tar; do
                [ -f "$tarfile" ] && docker load -i "$tarfile"
            done
        fi
    done
fi

# Перетегирование образов
if docker image inspect site_latest &>/dev/null; then
    docker tag site_latest site:latest
fi
if docker image inspect mariadb_latest &>/dev/null; then
    docker tag mariadb_latest mariadb:10.11
fi

# Создание docker-compose.yml (на основе readme.txt)
mkdir -p /opt/testapp
cat > /opt/testapp/docker-compose.yml <<'EOF'
services:
  testapp:
    container_name: testapp
    image: site:latest
    restart: always
    ports:
      - "80:8000"
    environment:
      DB_TYPE: maria
      DB_HOST: "192.168.4.2"
      DB_NAME: mariadb
      DB_PORT: "3306"
      DB_USER: testc
      DB_PASS: P@ssword
    depends_on:
      - db
  db:
    container_name: db
    image: mariadb:10.11
    restart: always
    ports:
      - "3306:3306"
    environment:
      MARIADB_DATABASE: mariadb
      MARIADB_USER: testc
      MARIADB_PASSWORD: P@ssword
      MARIADB_ROOT_PASSWORD: P@ssword
EOF

# Запуск стека (только если образы присутствуют)
if docker image inspect site:latest &>/dev/null && docker image inspect mariadb:10.11 &>/dev/null; then
    docker-compose -f /opt/testapp/docker-compose.yml up -d
else
    echo "Не найдены образы site:latest или mariadb:10.11. Запуск пропущен."
fi

echo "=== Настройка BR-SRV завершена ==="
echo " /etc/ssh/sshd_config, /opt/testapp/docker-compose.yml, /etc/ansible/hosts, /etc/samba/smb.conf"