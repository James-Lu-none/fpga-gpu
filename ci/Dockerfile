FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential cmake clang-18 llvm-18-dev verilator zlib1g-dev libzstd-dev \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf linux-headers-generic \
    ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
