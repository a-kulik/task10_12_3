#!/bin/bash
dir_pwd=$(dirname "$0")
dir_pwd=$(cd "$dir_pwd" && pwd)
source ${dir_pwd}/config
#--- Chek folder
mkdir -p $(echo "$VM1_HDD" |rev| cut -d / -f2- | rev)
mkdir -p $(echo "$VM2_HDD" |rev| cut -d / -f2- | rev)
mkdir -p $(echo "$VM1_CONFIG_ISO" |rev| cut -d / -f2- | rev)
mkdir -p $(echo "$VM2_CONFIG_ISO" |rev| cut -d / -f2- | rev)
mkdir -p ${dir_pwd}/docker/etc
mkdir -p ${dir_pwd}/docker/certs
mkdir -p ${dir_pwd}/config-drives/vm1-config/
mkdir -p ${dir_pwd}/config-drives/vm2-config/
mkdir -p ${dir_pwd}/networks/
#--- Create nginx config
touch ${dir_pwd}/docker/etc/nginx.conf
cat << EOF > ${dir_pwd}/docker/etc/nginx.conf
server {
    listen    80 ssl;
    ssl_prefer_server_ciphers  on;
    ssl_ciphers  'ECDH !aNULL !eNULL !SSLv2 !SSLv3';
    ssl_certificate  /etc/ssl/certs/web.crt;
    ssl_certificate_key  /etc/ssl/certs/web.key;
    location / {
        proxy_pass   http://${VM2_VXLAN_IP}:${APACHE_PORT};
    }
   }
EOF
#--- Create certs
touch ${dir_pwd}/docker/certs/conf.cnf
cat << EOF > ${dir_pwd}/docker/certs/conf.cnf
[ req ]
default_bits = 4096
distinguished_name  = req_distinguished_name
req_extensions     = req_ext
[ req_distinguished_name ]
[ req_ext ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName          = IP:${VM1_EXTERNAL_IP},DNS:${VM1_NAME}
EOF
openssl genrsa -out ${dir_pwd}/docker/certs/root.key 4096 > /dev/null
openssl req -new -x509 -days 365 -key ${dir_pwd}/docker/certs/root.key -out ${dir_pwd}/docker/certs/root.crt -subj "/CN=root" > /dev/null
openssl genrsa -out ${dir_pwd}/docker/certs/web.key 4096 > /dev/null
openssl req -new -key ${dir_pwd}/docker/certs/web.key -config ${dir_pwd}/docker/certs/conf.cnf -reqexts req_ext -out ${dir_pwd}/docker/certs/web.csr -subj "/CN=${VM1_NAME}" > /dev/null
openssl x509 -req -days 365 -CA ${dir_pwd}/docker/certs/root.crt -CAkey ${dir_pwd}/docker/certs/root.key -set_serial 01 -extfile ${dir_pwd}/docker/certs/conf.cnf -extensions req_ext -in ${dir_pwd}/docker/certs/web.csr -out ${dir_pwd}/docker/certs/web.crt > /dev/null
#--- Copy files to iso disk
cp ${dir_pwd}/docker/certs/root.crt ${dir_pwd}/config-drives/vm1-config/root.crt
cp ${dir_pwd}/docker/certs/web.key ${dir_pwd}/config-drives/vm1-config/web.key
cp ${dir_pwd}/docker/certs/web.crt ${dir_pwd}/config-drives/vm1-config/web.crt
cp ${dir_pwd}/docker/etc/nginx.conf ${dir_pwd}/config-drives/vm1-config/nginx.conf
#--- external network
MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
touch ${dir_pwd}/networks/external.xml
cat << EOF > ${dir_pwd}/networks/external.xml
<network>
  <name>$EXTERNAL_NET_NAME</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address="$EXTERNAL_NET_HOST_IP" netmask="$EXTERNAL_NET_MASK">
    <dhcp>
      <host mac="$MAC" name="$VM1_NAME" ip="$VM1_EXTERNAL_IP"/>
    </dhcp>
  </ip>
</network>
EOF
#--- internal network
touch ${dir_pwd}/networks/internal.xml
cat << EOF > ${dir_pwd}/networks/internal.xml
<network>
  <name>$INTERNAL_NET_NAME</name>
</network>
EOF
#--- management network
touch ${dir_pwd}/networks/management.xml
cat << EOF > ${dir_pwd}/networks/management.xml
<network>
  <name>$MANAGEMENT_NET_NAME</name>
  <ip address="$MANAGEMENT_HOST_IP" netmask="$MANAGEMENT_NET_MASK"/>
</network>
EOF
#--- VM1 meta-data
touch ${dir_pwd}/config-drives/vm1-config/meta-data
cat << EOF > ${dir_pwd}/config-drives/vm1-config/meta-data
hostname: $VM1_NAME
local-hostname: $VM1_NAME
network-interfaces: |
  auto $VM1_EXTERNAL_IF
  iface $VM1_EXTERNAL_IF inet dhcp
  dns-nameservers $VM_DNS

  auto $VM1_INTERNAL_IF
  iface $VM1_INTERNAL_IF inet static
  address $VM1_INTERNAL_IP
  network ${INTERNAL_NET}.0
  netmask $INTERNAL_NET_MASK
  broadcast ${INTERNAL_NET}.255

  auto $VM1_MANAGEMENT_IF
  iface $VM1_MANAGEMENT_IF inet static
  address $VM1_MANAGEMENT_IP
  network ${MANAGEMENT_NET}.0
  netmask $MANAGEMENT_NET_MASK
  broadcast ${MANAGEMENT_NET}.255
EOF
#--- VM1 user-data
pub_key=$(cat $SSH_PUB_KEY)
touch ${dir_pwd}/config-drives/vm1-config/user-data
cat << EOF > ${dir_pwd}/config-drives/vm1-config/user-data
#cloud-config
password: qwerty
chpasswd: { expire: False }
ssh_authorized_keys:
 - $pub_key
runcmd:
 - mount -t iso9660 -o ro /dev/sr0 /mnt
 - mkdir /root/certs
 - cp /mnt/root.crt /root/certs/root.crt
 - cp /mnt/web.crt /root/certs/web.crt
 - cp /mnt/web.key /root/certs/web.key
 - sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
 - sysctl -p > /dev/null
 - iptables -t nat -A POSTROUTING --out-interface $VM1_EXTERNAL_IF -j MASQUERADE
 - iptables -A FORWARD --in-interface $VM1_INTERNAL_IF -j ACCEPT
 - apt-get update
 - apt-get install apt-transport-https ca-certificates curl software-properties-common -y
 - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
 - apt-key fingerprint 0EBFCD88
 - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
 - apt-get update
 - apt-get install docker-ce -y
 - mkdir -p $NGINX_LOG_DIR
 - cp /mnt/nginx.conf $NGINX_LOG_DIR/nginx.conf
 - touch $NGINX_LOG_DIR/access.log
 - ip link add $VXLAN_IF type vxlan id $VID remote $VM2_INTERNAL_IP local $VM1_INTERNAL_IP dstport 4789
 - ip link set $VXLAN_IF up
 - ip addr add ${VM1_VXLAN_IP}/24 dev $VXLAN_IF
 - docker run --name hginx -v $NGINX_LOG_DIR/access.log:/var/log/nginx/access.log -v /root/certs:/etc/ssl/certs -v /root/etc/nginx.conf:/etc/nginx/conf.d/default.conf -d  -p $NGINX_PORT:80 nginx:1.13
EOF
#--- Download Ubuntu cloud image
wget -O "$VM1_HDD".temp "$VM_BASE_IMAGE"
cp "$VM1_HDD".temp "$VM1_HDD"
cp "$VM1_HDD".temp "$VM2_HDD"
#--- Create two disks from image
mkisofs -o "$VM1_CONFIG_ISO" -V cidata -r -J --quiet ${dir_pwd}/config-drives/vm1-config/
#--- Create network
virsh net-define ${dir_pwd}/networks/external.xml
virsh net-define ${dir_pwd}/networks/internal.xml
virsh net-define ${dir_pwd}/networks/management.xml
virsh net-start external
virsh net-start internal
virsh net-start management
#--- Create  VM1
virt-install \
--connect qemu:///system \
--name $VM1_NAME \
--import \
--ram $VM1_MB_RAM --vcpus=$VM1_NUM_CPU --$VM_TYPE \
--os-type=linux --os-variant=ubuntu16.04 \
--disk path="$VM1_HDD",format=qcow2,bus=virtio,cache=none \
--disk path="$VM1_CONFIG_ISO",device=cdrom \
--network network=$EXTERNAL_NET_NAME,mac="$MAC" \
--network network=$INTERNAL_NET_NAME \
--network network=$MANAGEMENT_NET_NAME \
--graphics vnc,port=-1 \
--noautoconsole --quiet --virt-type $VM_VIRT_TYPE
#--- VM2 meta-data
touch ${dir_pwd}/config-drives/vm2-config/meta-data
cat << EOF > ${dir_pwd}/config-drives/vm2-config/meta-data
hostname: $VM2_NAME
local-hostname: $VM2_NAME
network-interfaces: |

  auto $VM2_INTERNAL_IF
  iface $VM2_INTERNAL_IF inet static
  address $VM2_INTERNAL_IP
  network ${INTERNAL_NET}.0
  netmask $INTERNAL_NET_MASK
  broadcast ${INTERNAL_NET}.255
  dns-nameservers $VM_DNS

  auto $VM2_MANAGEMENT_IF
  iface $VM2_MANAGEMENT_IF inet static
  address $VM2_MANAGEMENT_IP
  network ${MANAGEMENT_NET}.0
  netmask $MANAGEMENT_NET_MASK
  broadcast ${MANAGEMENT_NET}.255
EOF
#--- VM2 user-data
touch ${dir_pwd}/config-drives/vm2-config/user-data
cat << EOF > ${dir_pwd}/config-drives/vm2-config/user-data
#cloud-config
password: qwerty
chpasswd: { expire: False }
ssh_authorized_keys:
 - $pub_key
runcmd:
 - ip route add default via $VM1_INTERNAL_IP dev $VM2_INTERNAL_IF
 - apt-get update
 - apt-get install apt-transport-https ca-certificates curl software-properties-common -y
 - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
 - apt-key fingerprint 0EBFCD88
 - add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
 - apt-get update
 - apt-get install docker-ce -y
 - ip link add $VXLAN_IF type vxlan id $VID remote $VM1_INTERNAL_IP local $VM2_INTERNAL_IP dstport 4789
 - ip link set $VXLAN_IF up
 - ip addr add ${VM2_VXLAN_IP}/24 dev $VXLAN_IF
 - docker run --name apache -p ${VM2_VXLAN_IP}:${APACHE_PORT}:80 -d httpd:2.4
EOF
#--- Create  VM2
mkisofs -o "$VM2_CONFIG_ISO" -V cidata -r -J --quiet ${dir_pwd}/config-drives/vm2-config/
virt-install \
--connect qemu:///system \
--name $VM2_NAME \
--import \
--ram $VM2_MB_RAM --vcpus=$VM2_NUM_CPU --$VM_TYPE \
--os-type=linux --os-variant=ubuntu16.04 \
--disk path="$VM2_HDD",format=qcow2,bus=virtio,cache=none \
--disk path="$VM2_CONFIG_ISO",device=cdrom \
--network network=$INTERNAL_NET_NAME \
--network network=$MANAGEMENT_NET_NAME \
--graphics vnc,port=-1 \
--noautoconsole --quiet --virt-type $VM_VIRT_TYPE
#---
rm ${dir_pwd}/config-drives/vm1-config/root.crt
rm ${dir_pwd}/config-drives/vm1-config/web.key
rm ${dir_pwd}/config-drives/vm1-config/web.crt
rm ${dir_pwd}/config-drives/vm1-config/nginx.conf
