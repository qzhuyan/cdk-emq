#!/bin/bash

# ulimt fds
#
sudo bash -c 'echo "session required pam_limits.so" >> /etc/pam.d/common-session'
sudo bash -c 'echo "*      soft    nofile      2000000"  >> /etc/security/limits.conf'
sudo bash -c 'echo "*      hard    nofile      2000000"  >> /etc/security/limits.conf'

echo "net.ipv4.tcp_tw_reuse=1" >>  /etc/sysctl.d/99-sysctl.conf
echo "fs.nr_open=8000000" >>  /etc/sysctl.d/99-sysctl.conf
echo 'net.ipv4.ip_local_port_range="1025 65534"' >>  /etc/sysctl.d/99-sysctl.conf

sysctl -w fs.nr_open=8000000
sysctl -w net.ipv4.tcp_tw_reuse=1

if [ -b /dev/nvme1n1 ]; then
echo "Find extra data vol, format and mount..."
mkfs.ext4 -L emqx_data /dev/nvme1n1
mkdir -p /var/lib/emqx/
mount -L  emqx_data /var/lib/emqx/
fi


apt update
apt install -y make prometheus wget gnupg2 git build-essential curl cmake debhelper
#snap install cmake --classic
wget -O - https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc | sudo apt-key add -
echo "deb https://packages.erlang-solutions.com/ubuntu focal contrib" | tee /etc/apt/sources.list.d/els.list
apt update
apt install -y esl-erlang=1:23.3.4.5-1

## install node exporter
useradd --no-create-home --shell /bin/false node_exporter
wget https://github.com/prometheus/node_exporter/releases/download/v1.1.2/node_exporter-1.1.2.linux-amd64.tar.gz
tar zxvf node_exporter-1.1.2.linux-amd64.tar.gz
mv node_exporter-1.1.2.linux-amd64/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter
mkdir -p /prometheus/metrics
chown node_exporter:node_exporter /prometheus/metrics

cat <<EOF > /lib/systemd/system/node_exporter.service
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/prometheus/metrics
Restart=always
RestartSec=10s
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

systemctl enable node_exporter
systemctl start node_exporter

# Install emqx
# A)  install official version
wget https://www.emqx.io/downloads/broker/v4.3.0/emqx-ubuntu20.04-4.3.0-amd64.deb
#sudo apt install ./emqx-ubuntu20.04-4.3.0-amd64.deb

# B)  install from S3
sudo apt update
sudo apt install awscli -y
aws s3 cp s3://team-private-hotpot/emqx-ubuntu20.04-5.0-alpha.5-ffded5ab-amd64.deb ./emqx.deb || echo "failed to fetch from s3"

#sudo apt install ./emqx.deb


cd /root/
git clone https://github.com/emqx/emqx
cd emqx
HOME=/root make emqx-pkg
dpkg -i ./_packages/emqx/*.deb

nodename="emqx@`hostname -f`"
cat <<EOF >> /etc/emqx/emqx.conf
node {
 name: $nodename
}

cluster {
 discovery_strategy = etcd

 etcd {
   server: "http://etcd0.int.emqx:2379"
   ssl.enable: false
 }
}

listeners.tcp.default {
 acceptors: 128
}

rate_limit {
 max_conn_rate = infinity
 conn_messages_in = infinity
 conn_bytes_in = infinity
}

prometheus {
    push_gateway_server = "http://lb.int.emqx:9091"
    interval = "15s"
    enable = true
}

gateway.exproto {
server {
  bind = 9101
 }
}

EOF

sudo emqx start
