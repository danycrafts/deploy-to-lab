FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       ca-certificates \
       git \
       openssh-client \
       rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
