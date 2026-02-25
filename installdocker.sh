#!/bin/bash
set -e

echo "päivitetään järjestelmä..."
apt update -y
apt upgrade -y

echo "asennetaan riippuvuudet..."
apt install -y ca-certificates curl gnupg lsb-release git

echo "lisätään Dockerin GPG-avain ja repo..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "päivitetään pakettilista..."
apt update -y

echo "asennetaan Docker ja docker-compose plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "käynnistetään Docker..."
systemctl enable docker
systemctl start docker

echo "lisätään user docker-ryhmään..."
usermod -aG docker vmtiina 

echo "clonataan GNS3 lab..."
cd /home
git clone https://github.com/VirtualNetLab/gns3-virtual-network-lab.git
cd gns3-virtual-network-lab

echo "Setup valmis!"
