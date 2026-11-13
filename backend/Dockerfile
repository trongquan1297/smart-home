FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src src
COPY migrations migrations
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* && useradd -r -u 10001 app
COPY --from=build /app/target/release/smart-backend /usr/local/bin/smart-backend
USER app
EXPOSE 8080
CMD ["smart-backend"]
