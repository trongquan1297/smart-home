# Matter bridge: đưa thiết bị Zigbee2MQTT sang Matter cho Apple Home / Google Home / Alexa / SmartThings.
# Dựa trên Matterbridge (Apache-2.0) + plugin matterbridge-zigbee2mqtt. Image gốc hỗ trợ linux/amd64 và linux/arm64
# (Raspberry Pi 3 chạy OS 64-bit).
FROM luligu/matterbridge:latest

# Ghim phiên bản plugin để build lặp lại được; nâng khi đã thử nghiệm.
ARG Z2M_PLUGIN_VERSION=3.3.1
RUN npm install -g "matterbridge-zigbee2mqtt@${Z2M_PLUGIN_VERSION}" --omit=dev --no-audit --no-fund

COPY entrypoint.sh /matterbridge/entrypoint.smart.sh
COPY autolist.mjs /matterbridge/autolist.mjs
RUN chmod +x /matterbridge/entrypoint.smart.sh
ENTRYPOINT ["/matterbridge/entrypoint.smart.sh"]
