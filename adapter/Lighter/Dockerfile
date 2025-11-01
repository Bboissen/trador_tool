ARG PYTHON_IMAGE=python:3.12-slim

FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS builder

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DEBIAN_FRONTEND=noninteractive

ARG LIGHTER_REPO_URL=https://github.com/elliottech/lighter-python.git
ARG LIGHTER_REPO_REF=v0.1.4

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/lighter

RUN git clone --depth 1 --branch "${LIGHTER_REPO_REF}" "${LIGHTER_REPO_URL}" .

ENV VIRTUAL_ENV=/opt/venv

RUN python -m venv ${VIRTUAL_ENV}

ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN pip install --upgrade pip setuptools wheel \
 && pip install .

# --- Runtime image ---
FROM --platform=linux/amd64 ${PYTHON_IMAGE} AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}" \
    LIGHTER_STATE_FILE=/tmp/lighter_adapter/state.json

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

WORKDIR /opt/app

COPY app/ ./

RUN useradd --system --home /opt/app --uid 1000 lighter \
 && chown -R lighter:lighter /opt/app /tmp

USER lighter

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python /opt/app/healthcheck.py

CMD ["python", "/opt/app/main.py"]

