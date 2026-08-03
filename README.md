# Container-based ADOT Lambda demo

This project deploys a Python Lambda container that contains the same reduced
ADOT Collector distributed in AWS's collector-only Lambda layer. No Lambda
layer is attached to the function. The layer contents are downloaded during
the build and copied into `/opt`; Lambda starts its executable from
`/opt/extensions` as an external extension.

The handler publishes three sample metrics over OTLP/HTTP to
`http://localhost:4318/v1/metrics`. The collector converts them to CloudWatch
Embedded Metric Format in the `OtelLambdaDemo` namespace.

## Cloud deployment

Prerequisites: configured AWS CLI credentials, Docker, `curl`, `unzip`, and
`jq`. Docker must be running.

```sh
cd otel
./deploy.sh
```

The defaults deploy `otel-lambda-demo` and its ECR repository to `eu-west-2`.
Override them with `AWS_REGION`, `STACK_NAME`, `ECR_STACK_NAME`, or
`IMAGE_TAG`. For another region, set `ADOT_LAYER_ARN` to that region's
collector-only x86_64 layer ARN.

After deployment, use the `ApiUrl` stack output:

```sh
curl "$(aws cloudformation describe-stacks \
  --region eu-west-2 \
  --stack-name otel-lambda-demo \
  --query \"Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue\" \
  --output text)?count=5"
```

Then inspect **CloudWatch > Metrics > All metrics > OtelLambdaDemo**. EMF
records are retained for 14 days in `/aws/otel/otel-lambda-demo/metrics`.

The API is intentionally public for this test and throttled to five requests
per second. Delete or protect it before adapting this example for production.

## Local test without AWS

The local target omits the Lambda extension and runs a full ADOT Collector as
a sidecar with the debug exporter. This validates the handler, OTLP/HTTP
transport, metric payloads, and collector pipeline without sending data to AWS.

```sh
cd otel
docker compose -f docker-compose.local.yaml up --build
```

In another terminal:

```sh
curl -X POST \
  'http://localhost:9000/2015-03-31/functions/function/invocations' \
  -H 'content-type: application/json' \
  -d '{"rawPath":"/metrics","queryStringParameters":{"count":"5"}}'
```

The detailed `demo.requests`, `demo.samples`, and `demo.handler.duration`
metrics appear in the collector container logs. This local route does not
emulate API Gateway or the Lambda Extensions API; the cloud smoke test covers
those AWS-managed integrations.

