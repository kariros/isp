#!/bin/bash
# isp_setup.sh - без настройки IP

set -e

# Отключение SELinux (требует перезагрузки, но для текущей сессии можно setenforce 0)
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 2>/dev/null || true

dnf install -y chrony nginx httpd-tools

#!/bin/bash
# isp_ntp_setup.sh — настройка NTP сервера на ISP

set -e

echo "=== Установка chrony ==="
dnf install -y chrony

echo "=== Настройка /etc/chrony.conf ==="
cat > /etc/chrony.conf <<'EOF'
# Используем только один сервер с меткой prefer
server ntp1.vniiftri.ru iburst prefer
# Остальные серверы закомментированы
#server ntp2.unifitri.ru iburst
#server ntp3.unifitri.ru iburst
#server ntp4.unifitri.ru iburst

# Разрешаем доступ всем клиентам сети
allow 0.0.0.0/0

# Служим источником времени даже если не синхронизированы с внешним сервером
local stratum 5

# Путь для логов (опционально)
logdir /var/log/chrony
EOF

echo "=== Перезапуск chronyd ==="
systemctl restart chronyd
systemctl enable chronyd

echo "=== Проверка статуса (опционально) ==="
chronyc tracking


mkdir -p /etc/nginx
htpasswd -bc /etc/nginx/.htpasswd WEB P@sswOrd

# Запись конфигурации
cat > /etc/nginx/nginx.conf <<'EOF'
server {
    listen 80;
    server_name web.au-team.irpo;
    location / {
        proxy_pass http://172.16.1.2:8080;
		auth_basic "Restricted area";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}

server {
    listen 80;
    server_name docker.au-team.irpo;
    location / {
        proxy_pass http://172.16.2.2:8080;
        }
}
EOF

# Удаляем стандартный дефолтный конфиг, если мешает
rm -f /etc/nginx/conf.d/default.conf

# Проверка конфигурации и перезапуск
nginx -t
systemctl enable --now nginx

echo "Настройка ISP завершена. Прокси настроены на http://172.16.1.2:8080 и http://172.16.2.2:8080"

# Включение маршрутизации (для проброса пакетов, если IP forwarding нужен)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo  "/etc/chrony.conf, /etc/nginx, /etc/nginx/nginx.conf"