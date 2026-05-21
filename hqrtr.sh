#!/bin/bash

hostnamectl set-hostname hq-rtr.au-team.irpo
timedatectl set-timezone Europe/Moscow

# Интерфейсы
# Туннель GRE к BR-RTR
nmcli con add type ip-tunnel ifname tun1 con-name tun1 mode gre remote 172.168.2.2 local 172.168.1.2 dev ens160
nmcli con mod tun1 ipv4.addresses 10.0.0.1/30 ipv4.method manual
nmcli con mod tun1 ipv4.may-fail no
nmcli con mod tun1 ip-tunnel.ttl 64
nmcli con mod tun1 connection.autoconnect yes
nmcli con up tun1

# VLAN-ы (один физический порт ens224)
# VLAN 10 - HQ-SRV
nmcli con add type vlan con-name vlan10 ifname ens160.10 dev ens160 id 10
nmcli con mod vlan10 ipv4.method manual ipv4.addresses 192.168.10.1/26
nmcli con up vlan10
# VLAN 20 - HQ-CLI
nmcli con add type vlan con-name vlan20 ifname ens160.20 dev ens160 id 20
nmcli con mod vlan20 ipv4.method manual ipv4.addresses 192.168.20.1/27
nmcli con up vlan20
# VLAN 99 - управление
nmcli con add type vlan con-name vlan99 ifname ens160.99 dev ens160 id 99
nmcli con mod vlan99 ipv4.method manual ipv4.addresses 192.168.99.1/28
nmcli con up vlan99

# Перевод SELinux в режим Permissive
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
setenforce 0


# Включение форвардинга
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# NAT в сторону ISP
dnf install -y nftables
cat > /etc/nftables/hq-nat.nft <<EOF
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "ens192" masquerade
  }
}
EOF
echo 'include "/etc/nftables/hq-nat.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables

# FRR (OSPF)
dnf install -y frr
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr

vtysh <<EOF
configure terminal
router ospf
 passive-interface default
 network 10.0.0.0/30 area 0
 network 192.168.10.0/26 area 0
 network 192.168.20.0/27 area 0
 network 192.168.99.0/28 area 0
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

# DHCP для VLAN 20
dnf install -y dhcp-server
cat > /etc/dhcp/dhcpd.conf <<EOF
subnet 172.168.1.0 netmask 255.255.255.224 {
	range 172.168.1.1 172.168.1.20;
	option domain-name-servers 172.168.1.2;
	option domain-name "au-team.irpo";
	option routers 172.168.1.1;
	default-lease-time 600;
	max-lease-time 7200;
}
EOF
systemctl enable --now dhcpd

echo "HQ-RTR настройка завершена"