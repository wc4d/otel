#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGION=${AWS_REGION:-eu-west-2}
STACK_NAME=${STACK_NAME:-otel-lambda-demo}
ECR_STACK_NAME=${ECR_STACK_NAME:-${STACK_NAME}-ecr}
IMAGE_TAG=${IMAGE_TAG:-$(date -u +%Y%m%d%H%M%S)}

if [[ -z "${ADOT_LAYER_ARN:-}" ]]; then
  if [[ "$REGION" == "eu-west-2" ]]; then
    ADOT_LAYER_ARN=arn:aws:lambda:eu-west-2:901920570463:layer:aws-otel-collector-amd64-ver-0-117-0:1
  else
    echo "Set ADOT_LAYER_ARN to the collector layer ARN for $REGION before deploying." >&2
    exit 1
  fi
fi

for command_name in aws docker curl unzip jq; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$ECR_STACK_NAME" \
  --template-file "$PROJECT_DIR/ecr.yaml"

REPOSITORY_URI=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$ECR_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" \
  --output text)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

if [[ -n "${NEXUS_OTEL_URL:-}" ]]; then
  "$PROJECT_DIR/fetch-otel-artifact.sh"
else
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  LAYER_URL=$(aws lambda get-layer-version-by-arn \
    --region "$REGION" \
    --arn "$ADOT_LAYER_ARN" \
    --query Content.Location \
    --output text)
  curl --fail --location --silent --show-error "$LAYER_URL" --output "$TEMP_DIR/layer.zip"
  unzip -q "$TEMP_DIR/layer.zip" -d "$TEMP_DIR/layer"

  mkdir -p "$PROJECT_DIR/.build/aws-layer"
  find "$PROJECT_DIR/.build/aws-layer" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$TEMP_DIR/layer/." "$PROJECT_DIR/.build/aws-layer/"
fi

docker build --platform linux/amd64 --target lambda \
  --provenance=false \
  --tag "$REPOSITORY_URI:$IMAGE_TAG" "$PROJECT_DIR"
docker push "$REPOSITORY_URI:$IMAGE_TAG"

IMAGE_DIGEST=$(aws ecr describe-images \
  --region "$REGION" \
  --repository-name "${REPOSITORY_URI##*/}" \
  --image-ids imageTag="$IMAGE_TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text)
IMAGE_URI="$REPOSITORY_URI@$IMAGE_DIGEST"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$PROJECT_DIR/template.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides ImageUri="$IMAGE_URI"

API_URL=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" \
  --output text)

echo "Deployment complete"
echo "Test URL: ${API_URL}?count=5"
