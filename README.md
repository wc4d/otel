# Container-based ADOT Lambda demo

This project deploys a Python Lambda container that contains the same reduced
ADOT Collector distributed in AWS's collector-only Lambda layer. No Lambda
layer is attached to the function. The layer contents are downloaded during
the build and copied into `/opt`; Lambda starts its executable from
`/opt/extensions` as an external extension.

The runtime image is based on AWS's OS-only Amazon Linux 2023 image
`public.ecr.aws/lambda/provided:al2023`, rather than an AWS Python base image.
Python and the AWS Lambda Python Runtime Interface Client are installed and
managed explicitly in the image.

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

The default collector package is:

```text
arn:aws:lambda:eu-west-2:901920570463:layer:aws-otel-collector-amd64-ver-0-117-0:1
```

AWS returns its download as a short-lived signed URL. Retrieve a fresh URL
with:

```sh
aws lambda get-layer-version-by-arn \
  --region eu-west-2 \
  --arn arn:aws:lambda:eu-west-2:901920570463:layer:aws-otel-collector-amd64-ver-0-117-0:1 \
  --query Content.Location \
  --output text
```

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
./test-local.sh
```

This starts the AL2023 Lambda Runtime Interface Emulator and a full ADOT
Collector sidecar, invokes the function, and verifies that all three metrics
reach the collector. No AWS credentials are required.

To additionally verify the invocation through a temporary public Cloudflare
Quick Tunnel:

```sh
EXPOSE_CLOUDFLARE=true ./test-local.sh
```

The tunnel exists only for the duration of the test. This local route does not
emulate API Gateway or the Lambda Extensions API; the cloud smoke test covers
those AWS-managed integrations.

## Package the cached ADOT extension

If `.aws-layer/` already contains a layer downloaded from AWS, create the
immutable artifact and checksum with:

```sh
./package-otel-artifact.sh
```

This creates ignored local files:

```text
artifacts/aws-otel-collector-amd64-0.117.0.zip
artifacts/aws-otel-collector-amd64-0.117.0.zip.sha256
```

Upload both to a private, immutable Nexus raw repository path such as:

```text
repository/aws-third-party/aws-otel-collector/0.117.0/amd64/
```

## Build with the artifact from Nexus or Artifactory

Use a read-only token and the checksum recorded when the artifact was
published:

```sh
export NEXUS_OTEL_URL='https://nexus.example.com/repository/aws-third-party/aws-otel-collector/0.117.0/amd64/aws-otel-collector-amd64-0.117.0.zip'
export NEXUS_OTEL_SHA256='<sha256-from-the-published-checksum-file>'
export NEXUS_TOKEN='<short-lived-read-only-token>'

./fetch-otel-artifact.sh

docker build \
  --platform linux/amd64 \
  --target lambda \
  --provenance=false \
  --tag otel-lambda:local \
  .
```

For basic authentication, set `NEXUS_USERNAME` and `NEXUS_PASSWORD` instead
of `NEXUS_TOKEN`. The fetch script downloads into a temporary directory,
checks SHA-256 before extraction, validates the expected layer layout, and
places the content under `.build/aws-layer/`. The Dockerfile copies that
directory to `/opt/`; credentials and the ZIP are never added to the image.

The normal cloud deployment also supports Nexus. When `NEXUS_OTEL_URL` is
set, `deploy.sh` calls `fetch-otel-artifact.sh` instead of downloading the
layer from AWS.
