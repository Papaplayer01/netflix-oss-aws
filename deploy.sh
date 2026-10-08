#!/usr/bin/env bash
# Build the 4 images, push to ECR, create everything with Terraform.
set -euo pipefail
REGION="${REGION:-ap-south-1}"
PROJECT="${PROJECT:-netflix-oss-aws}"
SERVICES="discovery-server api-gateway product-service order-service"

cd terraform
terraform init
# 1) create only the ECR repos first, so there is somewhere to push
terraform apply -auto-approve -var "region=$REGION" -var "project=$PROJECT" -target=aws_ecr_repository.svc
cd ..

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# 2) build and push images
for m in $SERVICES; do
  docker build --platform linux/amd64 --build-arg MODULE="$m" -t "$REGISTRY/$PROJECT/$m:latest" .
  docker push "$REGISTRY/$PROJECT/$m:latest"
done

# 3) create the rest (cluster, ALB, services...)
cd terraform
terraform apply -auto-approve -var "region=$REGION" -var "project=$PROJECT"
terraform output gateway_url
