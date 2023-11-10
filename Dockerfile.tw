FROM registry.opensuse.org/opensuse/tumbleweed:latest AS build

RUN zypper install -y kernel-default dracut systemd && \
    dracut --regenerate-all -f

FROM scratch
COPY --from=build /boot /boot
