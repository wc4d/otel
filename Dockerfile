FROM public.ecr.aws/lambda/python:3.13 AS app

COPY requirements.txt ${LAMBDA_TASK_ROOT}/requirements.txt
RUN pip install --no-cache-dir --requirement ${LAMBDA_TASK_ROOT}/requirements.txt --target ${LAMBDA_TASK_ROOT}

COPY app.py collector.yaml ${LAMBDA_TASK_ROOT}/

# This target omits the Lambda extension so the handler can be exercised with
# a normal Collector sidecar through Docker Compose.
FROM app AS local
CMD ["app.handler"]

# deploy.sh downloads the official collector-only ADOT Lambda layer and places
# its extracted /opt contents here. Lambda automatically starts executables in
# /opt/extensions as external extensions.
FROM app AS lambda
COPY .aws-layer/ /opt/
CMD ["app.handler"]

