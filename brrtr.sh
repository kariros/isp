#!/bin/bash

hostnamectl set-hostname br-rtr.au-team.irpo
timedatectl set-timezone Europe/Moscow

# К ISP

# Туннель GRE к HQ-RTR
nmcli con add type ip-tunnel ifname tun1 con-name tun1 mode gre remote 172.168.1.2 local 172.168.2.2 dev ens160
nmcli con mod tun1 ipv4.addresses 10.0.0.2/30 ipv4.method manual
nmcli con mod tun1 ipv4.may-fail no
nmcli con mod tun1 ip-tunnel.ttl 64
nmcli con mod tun1 connection.autoconnect yes
nmcli con up tun1

# Локальная сеть BR-SRV (маска /28)
nmcli con mod ens224 ipv4.addresses 192.168.4.1/28 ipv4.method manual
nmcli con up ens224

# Перевод SELinux в режим Permissive
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0


# Форвардинг
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# NAT
dnf install -y nftables
cat > /etc/nftables/br-nat.nft <<EOF
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "ens160" masquerade
  }
}
EOF
echo 'include "/etc/nftables/br-nat.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables

# FRR OSPF
dnf install -y frr
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr

vtysh <<EOF
configure terminal
router ospf
 passive-interface default
 network 10.0.0.0/30 area 0
 network 192.168.4.0/28 area 0
 area 0 authentication
 exit
 interface tun1
  no ip ospf passive
  ip ospf authentication
  ip ospf authentication-key P@sswOrd
 exit
 exit
 write
EOF
systemctl restart frr

echo "BR-RTR настройка завершена"