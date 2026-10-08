# Netflix OSS Microservices on AWS

A small online shop built as four Spring Cloud microservices (the Netflix OSS pattern), deployed to AWS ECS Fargate with Terraform and a GitHub Actions pipeline that logs in to AWS through OIDC, so no AWS keys are stored in GitHub.

## What it does

You send requests to one public URL. An API gateway forwards each request to the right service, and the services find each other through a service registry.

| Service | Role | Port |
|---|---|---|
| `discovery-server` | Eureka service registry. Every service registers here so others can find it. | 8761 |
| `api-gateway` | Spring Cloud Gateway. The only public entry point. Routes `/api/**` to the right service. | 8080 |
| `product-service` | Returns the product catalog. Has a chaos switch to simulate failure. | 8081 |
| `order-service` | Creates orders. Calls the product service for prices, protected by a Resilience4j circuit breaker. | 8082 |

## Architecture

```
Internet
   |
   v
Application Load Balancer (port 80)
   |
   v
api-gateway (8080)  ----- looks up services ----->  discovery-server (Eureka, 8761)
   |                                                      ^
   |-- /api/products --> product-service (8081) ----------|  (all services register)
   |-- /api/orders   --> order-service   (8082) ----------|
                              |
                              +-- calls product-service (circuit breaker)
```

**AWS building blocks**

- **ECS Fargate** runs the four containers without any servers to manage.
- **Application Load Balancer** is the public entry point and forwards traffic to the gateway.
- **ECR** stores one Docker image repository per service.
- **Cloud Map (private DNS)** lets services reach the Eureka server by name.
- **CloudWatch Logs** collects each service's logs (one log group per service).
- **Terraform** defines all of the above as code.
- **S3** holds the remote Terraform state.
- **GitHub Actions + OIDC** builds, pushes and deploys without stored credentials.

## Circuit breaker

The order service calls the product service to get a price. If the product service fails, the circuit breaker opens and the order service returns a safe fallback instead of hanging or crashing:

- Product service healthy: order status `CONFIRMED`
- Product service down: order status `PENDING_PRODUCT_SERVICE_UNAVAILABLE`
- After the product service recovers (about 20 seconds), the breaker closes and orders return to `CONFIRMED`

## API

Replace `$URL` with your load balancer address, for example `http://<alb-dns-name>`.

| Method | Path | Description |
|---|---|---|
| GET | `/api/products` | List all products |
| POST | `/api/orders` | Create an order |
| POST | `/api/products/chaos?fail=true` | Make the product service fail (demo) |
| POST | `/api/products/chaos?fail=false` | Restore the product service |

```bash
# List products
curl $URL/api/products

# Place an order
curl -X POST $URL/api/orders \
  -H "Content-Type: application/json" \
  -d '{"productId":1,"quantity":2}'
# {"id":1,"productId":1,"quantity":2,"total":110000.0,"status":"CONFIRMED"}
```

### Circuit breaker demo

```bash
# 1. Break the product service
curl -X POST "$URL/api/products/chaos?fail=true"

# 2. Place orders: they now return PENDING_PRODUCT_SERVICE_UNAVAILABLE
for i in 1 2 3 4 5; do
  curl -s -X POST $URL/api/orders -H "Content-Type: application/json" \
    -d '{"productId":1,"quantity":1}'; echo
done

# 3. Heal it, wait 20 seconds, order again: back to CONFIRMED
curl -X POST "$URL/api/products/chaos?fail=false"
sleep 20
curl -s -X POST $URL/api/orders -H "Content-Type: application/json" \
  -d '{"productId":1,"quantity":1}'
```

## Repository layout

```
.github/workflows/   deploy.yml and destroy.yml (GitHub Actions)
terraform/           main infrastructure: ECS, ALB, ECR, Cloud Map, IAM, logs
bootstrap/           one-time setup: S3 state bucket and the GitHub OIDC role
```

## Deploying

**One-time bootstrap** (needs AWS credentials once, from your machine). It creates the S3 bucket for Terraform state and the IAM role that GitHub Actions assumes through OIDC:

```bash
cd bootstrap
terraform init
terraform apply -var "github_repo=<owner>/<repo>"
```

Then set the outputs it prints (AWS region, role ARN, state bucket) in the repository's GitHub Actions configuration.

**Deploy** by running the workflow from the Actions tab, or:

```bash
gh workflow run "Deploy to AWS" --repo <owner>/<repo>
```

The workflow builds the images, pushes them to ECR, and applies the Terraform in `terraform/`. When it finishes, get the URL:

```bash
aws elbv2 describe-load-balancers --names netflix-oss-aws-alb --region ap-south-1 \
  --query 'LoadBalancers[0].DNSName' --output text
```

Wait 2 to 3 minutes after the run turns green so the services can register with Eureka. A 502 or 503 during that window is normal.

## Tearing down

The system costs a few US dollars per day while it runs. Destroy it when you're done:

```bash
gh workflow run "Destroy AWS resources" --repo <owner>/<repo> -f confirm=destroy
```

It takes about 8 minutes. Afterward, confirm nothing is left:

```bash
aws ecs list-clusters --region ap-south-1
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerName'
```

To also remove the state bucket and OIDC role, run `terraform destroy` in `bootstrap/` (only after the destroy workflow has finished).

## Problems solved along the way

**1. GitHub OIDC login rejected by AWS.** GitHub's token identified the repository in a different format than the IAM trust policy expected, so AWS refused to issue credentials. I read the token's `sub` claim and updated the role's trust policy to accept it.

**2. Gateway returned 500 with "connection refused".** Everything showed as running, but requests failed. The gateway logs showed it trying to reach `169.254.172.2:8081`. On Fargate, each service was registering with Eureka using a container-local link-local address that only exists inside its own container, so the gateway tried to connect to itself. Fix: register the task's VPC address instead, by adding these environment variables to the task definition:

```
EUREKA_INSTANCE_PREFER_IP_ADDRESS=true
SPRING_CLOUD_INETUTILS_PREFERRED_NETWORKS=172.31
```

## Known limits and next steps

This is a learning project, and the limits are deliberate:

- No database: data is held in memory, so it resets when a service restarts. Next: DynamoDB or RDS.
- No authentication: anyone with the URL can place orders. Next: Cognito or JWT at the gateway.
- Public subnets in the default VPC, to avoid the cost of a NAT gateway. Next: private subnets with VPC endpoints.
- One copy of each service. Next: ECS autoscaling and more than one task per service.
- HTTP only. Next: HTTPS with an ACM certificate on the load balancer.
