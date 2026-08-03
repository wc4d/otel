FROM public.ecr.aws/lambda/provided:al2023 AS app

ENV LAMBDA_TASK_ROOT=/var/task \
    PYTHONPATH=/var/task
WORKDIR ${LAMBDA_TASK_ROOT}

RUN dnf install --assumeyes --setopt=install_weak_deps=0 \
      python3 \
      python3-pip \
    && dnf clean all

COPY requirements.txt ${LAMBDA_TASK_ROOT}/requirements.txt
RUN python3 -m pip install --no-cache-dir \
      --requirement ${LAMBDA_TASK_ROOT}/requirements.txt \
      --prefix /usr

COPY --chmod=755 bootstrap /var/runtime/bootstrap
COPY app.py collector.yaml ${LAMBDA_TASK_ROOT}/

# This target omits the Lambda extension so the handler can be exercised with
# a normal Collector sidecar through Docker Compose.
FROM app AS local
CMD ["app.handler"]

# fetch-otel-artifact.sh or deploy.sh verifies and extracts the collector-only
# ADOT Lambda artifact here. Lambda automatically starts executables in
# /opt/extensions as external extensions.
FROM app AS lambda
COPY .build/aws-layer/ /opt/
CMD ["app.handler"]
