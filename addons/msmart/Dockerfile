FROM rust:1-bookworm AS build
# btleplug (Bluetooth qua BlueZ/D-Bus) cần libdbus khi build.
RUN apt-get update && apt-get install -y --no-install-recommends libdbus-1-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/* && mkdir /data && chown 65534:65534 /data
COPY --from=build /app/target/release/msmart-addon /usr/local/bin/msmart-addon
# nobody (65534): uid có sẵn trên mọi máy chủ Linux, nên dbus-daemon của máy chủ nhận kết nối (Bluetooth cho máy lọc nước).
# Volume /data rỗng được Docker tạo theo quyền của thư mục này trong image → phải cùng uid với user chạy.
USER 65534:65534
VOLUME /data
CMD ["msmart-addon"]
