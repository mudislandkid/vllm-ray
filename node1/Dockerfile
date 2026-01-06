# Custom Dockerfile for Ray Head + vLLM
# Use this if you need to customize the environment
# Otherwise, the default vllm/vllm-openai:latest image works out of the box

FROM rayproject/ray:2.43.0-py310-gpu

# Install vLLM with compatible dependencies
# Force reinstall numpy to avoid binary incompatibility
RUN pip install --no-cache-dir --force-reinstall numpy && \
    pip install --no-cache-dir vllm

# Set working directory
WORKDIR /workspace

# Expose ports
# 6379: Ray GCS server
# 8265: Ray dashboard
# 8000: vLLM API server
EXPOSE 6379 8265 8000

# Default command (can be overridden in docker-compose)
CMD ["ray", "start", "--head", "--port=6379", "--dashboard-host=0.0.0.0", "--block"]
