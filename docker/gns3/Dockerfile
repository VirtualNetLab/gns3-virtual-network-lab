FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Helsinki

# Base deps + add GNS3 PPA
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    software-properties-common \
    locales \
  && add-apt-repository -y ppa:gns3/ppa \
  && locale-gen en_US.UTF-8 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install GNS3 runtime bits (minimal-ish)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gns3-server \
    dynamips \
    ubridge \
    vpcs \
    qemu-system-x86 \
    qemu-kvm \
    iproute2 \
    iptables\
    dnsmasq\
&& rm -rf /var/lib/apt/lists/*

# If you want to use a bind-mounted config file:
# (your start script should pass --config /etc/gns3/gns3_server.conf)
CMD ["gns3server", "--port", "3080"]
