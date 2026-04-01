FROM vllm/vllm-openai:latest
RUN pip install "ray[default]" hf_transfer
ENV HF_HUB_ENABLE_HF_TRANSFER=1
