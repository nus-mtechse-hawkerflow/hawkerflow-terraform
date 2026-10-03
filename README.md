# HawkerFlow AWS ECS/Fargate Terraform starter

This project creates a reusable AWS foundation for four (or more) HTTP microservices.

## Architecture

```text
       [ User Browser ]
         │          │
         │ (HTTPS)  │ (REST with Cognito JWT)
         ▼          ▼
┌──────────────────┐    ┌───────────────────────────────────────────────┐
│ CloudFront (CDN) │    │ API Gateway (HTTP API with CORS)              │
│ (2 Distributions)│    └──────────────────────┬────────────────────────┘
└────────┬─────────┘                           │
         │ (OAC)                               │ VPC Link
         ▼                                     ▼
┌──────────────────┐            ┌─────────────────────────────┐
│    S3 Buckets    │            │ Internal ALB                │
│ (Private / SPAs) │            └──────────────┬──────────────┘
│  • Customer Web  │                           │ Path-based
│  • Hawker Web    │            ┌──────────────┼──────────────┐
└──────────────────┘            ▼              ▼              ▼
                          /order/*        /hawker/*      /customer/* ...
                          (ECS Task)      (ECS Task)     (ECS Task)
                                └──────────────┬──────────────┘
                                               ▼
                                         RDS PostgreSQL
```

ECS tasks, the ALB, and RDS are not directly public. API Gateway is the public application entry point.

## What gets created

- VPC spanning two Availability Zones
- Public subnets for the NAT Gateway
- Private application subnets for ALB, VPC Link ENIs and Fargate tasks
- Isolated database subnets for RDS
- Internet Gateway + one NAT Gateway
- Security groups restricting API Gateway -> ALB -> ECS -> PostgreSQL
- One ECR repository per service
- One ECS cluster
- One Fargate task definition/service per microservice
- CloudWatch log group per microservice
- Internal Application Load Balancer with path-based routing
- API Gateway HTTP API + VPC Link
- Cognito User Pool + app client + API Gateway JWT authorizer
- RDS PostgreSQL with AWS-managed master password in Secrets Manager
- ECS execution IAM role and one application task role per microservice

## 1. Install tools

Install:

- Terraform 1.7+
- AWS CLI v2
- Docker

Then configure AWS credentials. For local development, `aws configure` is the easiest starting point. Verify with:

```bash
aws sts get-caller-identity
```

Do not put AWS access keys in `.tf` files.

## 2. Configure your services

Copy the example variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Change the service keys, ports, route prefixes, CPU/memory and desired counts to match your applications.

The module is reusable: adding another entry to `services` creates another ECR repository, target group, ALB route, ECS task/service, CloudWatch log group and API Gateway routes.

## 3. Important first-deployment detail: container images

Terraform can create the ECR repositories before your ECS services exist, but ECS cannot successfully start a task until an image exists in each repository.

For a beginner-friendly workflow, do the first deployment in two phases.

### Phase A: create ECR and shared infrastructure

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply -target=module.network -target=module.ecr -target=module.iam -target=module.database -target=module.cognito -target=module.alb
```

Then inspect the repository URLs:

```bash
terraform output ecr_repository_urls
```

### Phase B: build and push each Docker image

Login Docker to ECR (replace REGION and ACCOUNT_ID):

```bash
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.ap-southeast-1.amazonaws.com
```

For each service:

```bash
docker build -t hawkerflow-user ./path/to/user-service
docker tag hawkerflow-user:latest ECR_REPOSITORY_URL:latest
docker push ECR_REPOSITORY_URL:latest
```

Repeat for all four services.

### Phase C: create the full stack

```bash
terraform plan
terraform apply
```

Afterwards:

```bash
terraform output api_url
terraform output cognito_user_pool_id
terraform output cognito_client_id
```

## 4. How requests flow

1. Your frontend signs the user in through Cognito.
2. Cognito supplies JWT tokens.
3. The frontend sends `Authorization: Bearer <token>` to API Gateway.
4. API Gateway validates the JWT.
5. API Gateway uses its VPC Link to reach the private ALB.
6. The ALB examines the URL path and selects the target ECS service.
7. The ECS task connects to PostgreSQL on port 5432.

The sample protects every generated service route with Cognito. You will probably want selected public routes later, such as registration or public catalogue endpoints. Add separate API Gateway routes without JWT authorization for those endpoints.

## 5. Database variables visible to each container

Each task receives:

```text
DB_HOST
DB_PORT
DB_NAME
DB_USERNAME
DB_PASSWORD
```

`DB_USERNAME` and `DB_PASSWORD` come from the RDS-managed Secrets Manager secret. They are not hard-coded into Terraform.

Your application can construct a PostgreSQL URL from those values. Do not print the password to logs.

## 6. IAM explained

### ECS execution role

Used by the ECS/Fargate platform, not by your business code. It lets ECS pull your image from ECR, write logs, and read the RDS credential secret that ECS injects into the container.

### ECS task role

Used by application code inside a container. The starter task roles deliberately have no permissions. Add only what a particular service needs. For example, if only `order` needs SQS, attach SQS permissions only to the order task role.

### Deployment identity

The IAM identity running Terraform needs permissions to create these AWS resources and to pass the ECS roles. In a real project, use a CI/CD role (for example GitHub Actions via OIDC) instead of long-lived AWS access keys.

## 7. Networking explained

The three subnet types have different jobs:

- `public`: NAT Gateway. A route to the Internet Gateway exists here.
- `app`: ECS tasks, internal ALB, and API Gateway VPC Link ENIs. Outbound traffic goes through NAT.
- `db`: RDS only. There is no default internet route.

Security-group chain:

```text
VPC Link SG -> ALB SG :80
ALB SG      -> ECS SG :application ports
ECS SG      -> RDS SG :5432
```

The database is `publicly_accessible = false`.

## 8. Fargate explained

ECS is the orchestrator; Fargate is the serverless compute used to run each ECS task. You do not create or patch EC2 worker instances. Each service defines CPU, memory, desired task count and container port.

For production, use at least two tasks per important service so a single task restart does not remove all capacity.

## 9. Destroying the environment

For a disposable dev environment:

```bash
terraform plan -destroy
terraform destroy
```

The starter RDS configuration uses `skip_final_snapshot = true` and has deletion protection disabled so a development environment can be destroyed. **Change those settings for production.**

ECR repositories are not force-deleted. If they contain images, AWS can block repository deletion. This is intentional protection. Delete images first or explicitly change the module for disposable environments.

## 10. Production changes to make later

This starter favors understandability over a fully hardened production platform. Before production, consider:

- separate AWS accounts/environments for dev/staging/prod
- Terraform remote state in S3 with locking
- Route 53 + ACM custom API domain
- AWS WAF if your threat model calls for it
- RDS Multi-AZ, deletion protection, final snapshots and longer backups
- RDS Proxy if connection spikes from many tasks become a problem
- ECS autoscaling
- ALB/API access logging and alarms
- CloudWatch dashboards/alarms and possibly X-Ray/OpenTelemetry
- AWS Budgets / Cost Anomaly Detection
- VPC endpoints for ECR, S3, CloudWatch Logs and Secrets Manager where appropriate
- KMS customer-managed keys if your security requirements need them
- per-service database users/schemas rather than every service using the RDS master user
- CI/CD with GitHub Actions OIDC -> ECR -> ECS deployment
- database migration jobs rather than migrations during every web-task startup

## 11. A note about microservice databases

This starter provisions one PostgreSQL RDS instance because that is what the requested stack specifies. All services currently receive the master database credentials to keep the first deployment understandable.

That is not the target production security model. A better next step is to give each microservice its own PostgreSQL database/schema and a restricted database user, with separate secrets. This limits blast radius and makes service ownership clearer.

## 12. Frontend SPA Hosting (Angular)

Two Angular applications (`customer` and `hawker`) are hosted using **Amazon S3 + CloudFront Origin Access Control (OAC)**:

- **Cost:** Practically $0/month (CloudFront free tier includes 1 TB transfer and 10M requests; S3 storage for compiled static assets is <$0.01/month).
- **Security:** S3 buckets are completely private; public access is blocked, and access is permitted only via CloudFront OAC.
- **SPA Client-side Routing:** HTTP 403 & 404 error responses are rewritten to `/index.html` with status 200, enabling Angular HTML5 routing (`PathLocationStrategy`).
- **Backend Access & CORS:** API Gateway has built-in CORS configuration enabled so both Angular web apps can make requests to `api_url` seamlessly with Cognito JWT tokens.

### Deploying an Angular Application

1. In your Angular project, configure your environment with the outputs from Terraform:
   ```typescript
   export const environment = {
     production: true,
     apiUrl: '<terraform-output-api_url>',
     cognito: {
       userPoolId: '<terraform-output-cognito_user_pool_id>',
       clientId: '<terraform-output-cognito_client_id>'
     }
   };
   ```

2. Build your Angular app for production:
   ```bash
   ng build --configuration production
   ```

3. Deploy using the provided helper script:
   ```bash
   # Usage: ./scripts/deploy-frontend.sh <customer|hawker> <path-to-dist-browser-dir>
   ./scripts/deploy-frontend.sh customer ../path-to-customer-app/dist/customer/browser
   ./scripts/deploy-frontend.sh hawker ../path-to-hawker-app/dist/hawker/browser
   ```

## 13. Files/modules

```text
.
├── versions.tf
├── providers.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── terraform.tfvars.example
├── backend.tf.example
├── scripts
│   ├── deploy-frontend.sh
│   └── toggle-protection.sh
└── modules
    ├── network
    ├── ecr
    ├── iam
    ├── rds
    ├── cognito
    ├── alb
    ├── ecs-service
    ├── api-gateway
    └── spa-hosting
```

