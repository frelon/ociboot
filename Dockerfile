FROM registry.opensuse.org/opensuse/leap:15.5 AS build

RUN zypper install -y kernel-default dracut systemd && \
    dracut --regenerate-all -f

FROM scratch
COPY --from=build /boot/vmlinu* /boot
COPY --from=build /boot/init* /boot
