# Netflix-OSS-style Microservices on AWS (Fargate + Terraform)

A small but complete project that shows the **Netflix OSS pattern set** running on **AWS**.
Built to talk about in an IBM Consulting (AWS Application Consultant) interview.

## What it does

A client calls one URL. The gateway forwards the call to the right service.
`order-service` asks `product-service` for a price. If `product-service` breaks,
`order-service` does not crash: the circuit breaker returns a safe fallback answer.

```
                    Internet
                       |
                 [ AWS ALB ]
                       |
              [ api-gateway ]  (Spring Cloud Gateway)
               /            \
   [ product-service ]   [ order-service ] --(circuit breaker)--> product-service
               \            /
             [ discovery-server ]  (Eureka)   <- found by DNS name through AWS Cloud Map
```

## Netflix OSS role -> what is used here

| Role | Original Netflix tool | Used in this project | AWS-native alternative |
|---|---|---|---|
| Service discovery | Eureka | Eureka (Spring Cloud Netflix) | Cloud Map / ECS Service Connect |
| API gateway | Zuul | Spring Cloud Gateway | Amazon API Gateway |
| Client load balancing | Ribbon | `@LoadBalanced` + Spring Cloud LoadBalancer | ALB |
| Circuit breaker | Hystrix | Resilience4j | App Mesh / retries in the SDK |
| Config | Archaius | env vars (`EUREKA_URL`) | AppConfig, SSM Parameter Store |

Ribbon and Hystrix are retired; the Spring replacements above are what real projects use today.

## Services

| Module | Port | Job |
|---|---|---|
| discovery-server | 8761 | Eureka registry |
| api-gateway | 8080 | Public entry, routes `/api/products/**` and `/api/orders/**` |
| product-service | 8081 | `GET /api/products`, `GET /api/products/{id}`, `POST /api/products/chaos?fail=true` |
| order-service | 8082 | `POST /api/orders`, `GET /api/orders` |

## Run locally (Docker needed)

```bash
docker compose up --build
# Eureka dashboard: http://localhost:8761  (wait ~40s until all services show up)

curl http://localhost:8080/api/products
curl -X POST http://localhost:8080/api/orders -H 'Content-Type: application/json' \
     -d '{"productId":1,"quantity":2}'
# -> status CONFIRMED, total 110000
```

### Demo the circuit breaker (great for the interview)

```bash
curl -X POST "http://localhost:8080/api/products/chaos?fail=true"   # break product-service
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:8080/api/orders -H 'Content-Type: application/json' \
       -d '{"productId":1,"quantity":1}'; echo
done
# -> status PENDING_PRODUCT_SERVICE_UNAVAILABLE (fallback). After a few failures the circuit
#    opens and the fallback is returned instantly without calling product-service.
curl -X POST "http://localhost:8080/api/products/chaos?fail=false"  # heal it
# wait ~10s (open state) and orders become CONFIRMED again
```

## Deploy to AWS

Needs: AWS CLI configured, Docker, Terraform >= 1.5.

```bash
./deploy.sh                 # about 10 minutes
# prints gateway_url = http://<alb-dns-name>
curl http://<alb-dns-name>/api/products
./destroy.sh                # DELETE everything when done
```

What Terraform creates: 4 ECR repos, ECS cluster, 4 Fargate services, an ALB in front of the
gateway, a Cloud Map private DNS namespace (`discovery.netflix.local` -> Eureka),
security groups, IAM role, CloudWatch log groups.

**Cost warning:** 4 Fargate tasks (0.5 vCPU / 1 GB each) plus an ALB cost roughly a few US dollars
per day. Run `./destroy.sh` right after your demo.

## Interview talking points

1. **Why Eureka on AWS?** Eureka keeps the Spring/Netflix programming model. Cloud Map provides the
   DNS name where Eureka itself is found. A fully AWS-native design could drop Eureka and use ECS Service Connect.
2. **Why Fargate?** No servers to patch; each service scales on its own.
3. **Circuit breaker:** open / half-open / closed. Prevents one slow service from taking down everything.
4. **Garage Method link:** Co-create = start with one service MVP. Co-execute = Terraform + Docker pipeline.
   Co-operate = CloudWatch logs, health checks, fallback behaviour.
5. **Honest limitations (say these, consultants are expected to):** in-memory data (no database),
   public subnets to avoid NAT cost, no auth, single task per service. Next steps: RDS/DynamoDB, private subnets,
   Cognito/JWT at the gateway, autoscaling, CI/CD with GitHub Actions, X-Ray tracing.

## Project ideas to extend (pick one to show growth)

- Replace in-memory orders with DynamoDB or RDS (Terraform module).
- Add JWT validation in the gateway with Cognito.
- Add a GitHub Actions workflow that builds, pushes and deploys on every commit.
- Add ECS autoscaling on CPU.

## CI/CD with GitHub Actions

Three workflows live in `.github/workflows/`:

| Workflow | When | What it does |
|---|---|---|
| `ci.yml` | pull requests and pushes to any branch except `main` | `mvn verify` for all services, `terraform fmt` and `validate` |
| `deploy.yml` | push to `main`, or run manually | builds 4 images tagged with the commit SHA, pushes to ECR, `terraform apply` |
| `destroy.yml` | manual only (type `destroy`) | deletes all AWS resources |

**No AWS keys are stored in GitHub.** Actions logs in with OIDC and assumes an IAM role that only this
repository can use. Terraform state is kept in S3 because Actions runners are thrown away after every run.

### One-time setup

1. Create a GitHub repo and push this project (default branch `main`).
2. From your laptop (AWS CLI configured), create the trust, role and state bucket:
   ```bash
   cd bootstrap
   terraform init
   terraform apply -var "github_repo=YOUR_GITHUB_USERNAME/YOUR_REPO_NAME"
   ```
   If it says the OIDC provider already exists, add `-var "create_oidc_provider=false"`.
   Keep the `bootstrap/terraform.tfstate` file safe.
3. In GitHub: Settings -> Secrets and variables -> Actions:
   - **Secret** `AWS_ROLE_ARN` = output `AWS_ROLE_ARN`
   - **Variable** `TF_STATE_BUCKET` = output `TF_STATE_BUCKET`
   - **Variable** `AWS_REGION` = output `AWS_REGION` (e.g. `ap-south-1`)
4. Push a commit to `main`, or run **Deploy to AWS** from the Actions tab. The URL appears in the run summary.
5. When finished: Actions -> **Destroy AWS resources** -> type `destroy`.
   Optionally run `terraform destroy` in `bootstrap/` to remove the state bucket and role.
