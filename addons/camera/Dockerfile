FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* && useradd -r -u 10001 app && mkdir /data && chown app /data
COPY --from=build /app/target/release/msmart-camera /usr/local/bin/msmart-camera
USER app
VOLUME /data
CMD ["msmart-camera"]
