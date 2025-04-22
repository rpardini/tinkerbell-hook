FROM debian:12-slim AS base

RUN DEBIAN_FRONTEND=noninteractive apt update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends  udev && \
    apt-cache show udev && \
    dpkg -L udev && \
    apt-get clean autoclean && \
    apt-get autoremove --yes && \
    rm -rf /var/lib/apt /var/lib/dpkg /var/lib/cache /var/lib/log /var/cache/* /usr/lib/apt/* /usr/share/*

RUN cat /etc/init.d/udev

RUN /lib/systemd/systemd-udevd --help

CMD ["/lib/systemd/systemd-udevd", "--debug"]
