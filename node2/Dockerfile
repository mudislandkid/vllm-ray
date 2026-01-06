# Dockerfile for Ray + vLLM (unified image)
# Based on rayproject/ray:latest-gpu with vLLM installed

FROM rayproject/ray:latest-gpu

USER root

# Install vLLM and hf_transfer for high-speed downloads
RUN pip install --no-cache-dir vllm hf_transfer

# Switch back to ray user (optional, or keep root)
# USER ray

WORKDIR /workspace
