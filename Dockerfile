FROM python:3.11-slim@sha256:9b2eb855efeb6805cb1b84f94f572cca40f6d277337db23ee64ae568bdc67f1f

ENV ANSIBLE_FORCE_COLOR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       openssh-client \
       git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY ansible/requirements.yml /tmp/requirements.yml
RUN pip install --no-cache-dir ansible==9.5.1 \
    && ansible-galaxy collection install -r /tmp/requirements.yml --force

CMD ["bash"]
