# syscalls -- offline x86-64 Linux syscall tables (syscalls.lab). The mebeim/linux-syscalls
# site, trimmed to the x86-64 architecture: browsable syscall tables BY KERNEL VERSION
# (v4.0 - v6.17) for the x64 native ABI plus the ia32 / x32 compat ABIs reachable on a 64-bit
# kernel. Each syscall is shown with its full signature -- argument names, C types, and the
# calling-convention registers (rax, rdi, rsi, ...) -- its defining source location, and any
# Kconfig gate. Powered by Systrack.
#
# Built from source: clone the repo, keep only db/x86/64, then run the project's own pure-stdlib
# generator, which copies the db into www/ and builds its JSON index. nginx serves the static
# result -- the frontend fetches db/<arch>/<bits>/<abi>/<ver>/table.json as plain files. To ship
# other arches/ABIs instead, adjust the `rm` below. Self-contained; nothing is fetched at runtime.
FROM python:3.12-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/mebeim/linux-syscalls .
RUN rm -rf db/arm db/arm64 db/mips db/powerpc db/riscv db/s390 db/x86/32 \
 && python3 scripts/build_web_db.py \
 && [ -s www/db/index.json ]

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY --from=build /src/www /usr/share/nginx/html
