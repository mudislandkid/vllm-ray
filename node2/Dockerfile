# Custom Dockerfile for Ray Worker
# Use this if you need to customize the environment
# Otherwise, the default vllm/vllm-openai:latest image works out of the box

FROM rayproject/ray:2.43.0-py310-gpu

# Install vLLM with compatible dependencies
# All nodes must have vLLM installed for distributed inference
# Force reinstall numpy to avoid binary incompatibility
RUN pip install --no-cache-dir --force-reinstall numpy && \
    pip install --no-cache-dir vllm

# Set working directory
WORKDIR /workspace

# Default command (can be overridden in docker-compose)
# Note: --address will be set via docker-compose
CMD ["ray", "start", "--block"]
