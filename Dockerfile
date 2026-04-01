FROM vllm/vllm-openai:latest
RUN pip install "ray[default]"
