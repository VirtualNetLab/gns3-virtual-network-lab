#!/bin/bash

set -e

echo "päivitetään systemi..."
apt update -y

echo "ladataan docker..."
apt install -y docker.io docker-compose-plugin git

echo "käynnistetään Docker..."
systemctl enable docker
systemctl start docker

echo "lisätään user docker ryhmään..."
usermod -aG docker $(whoami)

echo "cloonataan GNS3 lab..."
cd /home
git clone https://github.com/VirtualNetLab/gns3-virtual-network-lab.git

cd gns3-virtual-network-lab


echo "Setup valmis!"
