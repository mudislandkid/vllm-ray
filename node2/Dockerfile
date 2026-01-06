# Dockerfile for Ray + vLLM (unified image)
# Based on rayproject/ray:latest-gpu with vLLM installed

FROM rayproject/ray:latest-gpu

USER root

# Install vLLM
RUN pip install --no-cache-dir vllm

# Switch back to ray user (optional, or keep root)
# USER ray

WORKDIR /workspace
