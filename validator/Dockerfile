FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir iiif-validator
ENTRYPOINT ["iiif-validate.py"]
