# Stage 1: Use full Alpine to install Python and tools
FROM alpine:3.22 AS python-installer
RUN apk add --no-cache python3 py3-pip bash curl git

# Clone only the Python task runner package at the exact n8n version tag
RUN git clone --depth 1 --filter=blob:none --sparse \
        --branch "n8n@2.11.2" \
        https://github.com/n8n-io/n8n.git /tmp/n8n-src && \
    cd /tmp/n8n-src && \
    git sparse-checkout set "packages/@n8n/task-runner-python"

# Create the virtual environment required by the Python runner.
# Use --ignore-requires-python because the pyproject.toml declares >=3.13
# but the runtime code only needs websockets and is 3.12-compatible.
RUN cd /tmp/n8n-src/packages/@n8n/task-runner-python && \
    python3 -m venv .venv && \
    .venv/bin/pip install --upgrade pip && \
    .venv/bin/pip install websockets>=15.0.1 && \
    .venv/bin/pip install --ignore-requires-python --no-deps -e .

# Stage 2: Build on the hardened n8n image
FROM n8nio/n8n:latest

USER root

# Copy Python binaries and stdlib
COPY --from=python-installer /usr/bin/python3 /usr/bin/python3
COPY --from=python-installer /usr/bin/python3.12 /usr/bin/python3.12
COPY --from=python-installer /usr/bin/python /usr/bin/python
COPY --from=python-installer /usr/lib/python3.12 /usr/lib/python3.12
COPY --from=python-installer /usr/lib/libpython3.12.so.1.0 /usr/lib/libpython3.12.so.1.0
COPY --from=python-installer /usr/lib/libpython3.so /usr/lib/libpython3.so

# Copy pip
COPY --from=python-installer /usr/bin/pip /usr/bin/pip
COPY --from=python-installer /usr/bin/pip3 /usr/bin/pip3

# Copy bash
COPY --from=python-installer /bin/bash /bin/bash

# Copy curl and its shared libraries
COPY --from=python-installer /usr/bin/curl /usr/bin/curl
COPY --from=python-installer /usr/lib/libcurl.so.4 /usr/lib/libcurl.so.4
COPY --from=python-installer /usr/lib/libcurl.so.4.8.0 /usr/lib/libcurl.so.4.8.0
COPY --from=python-installer /usr/lib/libnghttp2.so.14 /usr/lib/libnghttp2.so.14
COPY --from=python-installer /usr/lib/libnghttp2.so.14.28.4 /usr/lib/libnghttp2.so.14.28.4
COPY --from=python-installer /usr/lib/libbrotlidec.so.1 /usr/lib/libbrotlidec.so.1
COPY --from=python-installer /usr/lib/libbrotlidec.so.1.1.0 /usr/lib/libbrotlidec.so.1.1.0
COPY --from=python-installer /usr/lib/libbrotlicommon.so.1 /usr/lib/libbrotlicommon.so.1
COPY --from=python-installer /usr/lib/libbrotlicommon.so.1.1.0 /usr/lib/libbrotlicommon.so.1.1.0
COPY --from=python-installer /usr/lib/libzstd.so.1 /usr/lib/libzstd.so.1
COPY --from=python-installer /usr/lib/libzstd.so.1.5.7 /usr/lib/libzstd.so.1.5.7
COPY --from=python-installer /usr/lib/libssl.so.3 /usr/lib/libssl.so.3
COPY --from=python-installer /usr/lib/libcrypto.so.3 /usr/lib/libcrypto.so.3
COPY --from=python-installer /usr/lib/libz.so.1 /usr/lib/libz.so.1
COPY --from=python-installer /usr/lib/libz.so.1.3.1 /usr/lib/libz.so.1.3.1

# Copy the Python task runner package with its pre-built venv
# n8n expects it at /usr/local/lib/node_modules/@n8n/task-runner-python
COPY --from=python-installer /tmp/n8n-src/packages/@n8n/task-runner-python \
    /usr/local/lib/node_modules/@n8n/task-runner-python

USER node

# Pre-install community nodes that are recorded in the database
RUN mkdir -p /home/node/.n8n/nodes && \
    cd /home/node/.n8n/nodes && \
    npm install @apify/n8n-nodes-apify n8n-nodes-browserbase && \
    # npm resolves n8n-workflow from the public registry (v1.82.0, last published).
    # n8n 2.x ships n8n-workflow v2.x internally via pnpm but never publishes it to npm.
    # Community nodes that use newer APIs (e.g. NodeConnectionTypes) fail at load time
    # because they see the stale public version. Replace it with a symlink to n8n's own copy.
    rm -rf node_modules/n8n-workflow && \
    ln -s /usr/local/lib/node_modules/n8n/node_modules/n8n-workflow \
          node_modules/n8n-workflow
