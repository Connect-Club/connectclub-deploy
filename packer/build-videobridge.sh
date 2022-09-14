#!/bin/bash
set -e
echo "sleeping..."
sleep 60
sudo apt-get update
sudo apt-get install -y \
    git unzip gpg wget curl apt-transport-https \
    openjdk-8-jdk openjdk-8-jre

java -version

# filebeat
# wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
# echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list
# sudo apt-get update && sudo apt-get install filebeat
# sudo mv /tmp/filebeat.yml /etc/filebeat/filebeat.yml
# sudo chown root:root /etc/filebeat/filebeat.yml
# sudo chmod go-w /etc/filebeat/filebeat.yml
# sudo mv /tmp/filebeat.service /lib/systemd/system
# sudo systemctl daemon-reload
# sudo systemctl enable filebeat
# filebeat version

# node_exporter
curl -OL https://github.com/prometheus/node_exporter/releases/download/v1.1.1/node_exporter-1.1.1.linux-amd64.tar.gz
tar xvf node_exporter-1.1.1.linux-amd64.tar.gz
sudo mv node_exporter-*/node_exporter /usr/local/bin/node_exporter
rm -rf node_exporter-*
node_exporter --version
sudo useradd -rs /bin/false node_exporter
sudo mv /tmp/node_exporter.service /lib/systemd/system
sudo systemctl daemon-reload
sudo systemctl enable node_exporter

# configure kernel
echo "net.core.rmem_max=104857600" | sudo tee -a /etc/sysctl.conf
echo "net.core.netdev_max_backlog=100000" | sudo tee -a /etc/sysctl.conf
echo "net.core.rmem_default=26214400" | sudo tee -a /etc/sysctl.conf

# install videobridge
## prepare repo
cd
git clone https://github.com/Connect-Club/jitsi-videobridge
cd jitsi-videobridge/
git checkout $GIT_COMMIT_SHA
git submodule update --init --recursive
mkdir -p ~/.m2
cp settings.xml ~/.m2/settings.xml
## build maven
curl https://apache-mirror.rbc.ru/pub/apache/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.zip -o maven.zip
unzip maven.zip
apache-maven-3.6.3/bin/mvn clean package
sudo unzip target/jitsi-videobridge.docker.zip -d /opt
## cleanup
cd
rm -rf jitsi-videobridge
rm -rf .ssh/deploy_key
sudo apt-get purge git -y

## install
sudo mkdir -p /var/log/jvb
sudo chmod a+w /var/log/jvb
sudo install -m 0644 /tmp/videobridge.service /lib/systemd/system/videobridge.service
sudo ln -s /lib/systemd/system/videobridge.service /etc/systemd/system/multi-user.target.wants/
sudo systemctl enable videobridge.service

sudo systemctl start videobridge
sleep 5
sudo systemctl status videobridge
sudo systemctl stop videobridge
sleep 5
sudo rm -rf /var/log/jvb/*.log
