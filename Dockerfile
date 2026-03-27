FROM metacubex/mihomo:latest

ENV CONFIG_PATH=/root/.config/clash/config.yaml
ENV TARGET_GROUP=GLOBAL
ENV N_PROXIES=1
ENV BASE_PORT=7890
ENV API_BASE_PORT=19090

COPY scripts/clash-start.sh /clash-start.sh

RUN chmod 755 /clash-start.sh

VOLUME ["/root/.config/clash"]

EXPOSE 7890

ENTRYPOINT ["/bin/sh", "/clash-start.sh"]
