# HawkerFlow Terraform

Terraform for the HawkerFlow dev deployment on AWS: four FastAPI services on
ECS Fargate behind API Gateway, two Angular sites on S3 and CloudFront, one
PostgreSQL database, and the order queue and order events.

## Working on the shared dev deployment

The dev environment already exists in AWS account `971586140094`
(`ap-southeast-1`). To work on it from a fresh clone, do not create anything
new; connect to its existing state:

```bash
aws sts get-caller-identity          # must show account 971586140094
cp backend.tf.example backend.tf
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
```

A correct setup plans `0 to add, 8 to change, 0 to destroy`. The eight changes
are the API Gateway routes re-adding an authorizer ID that API Gateway drops;
they are harmless and appear on every plan. If the plan wants to add dozens of
resources, stop: the backend or the AWS account is wrong.

`terraform apply` only changes infrastructure. It does not build or upload
code. After changing a service or a site, release it with the scripts below.
They take everything they need (ECR repositories, API address, Cognito IDs,
buckets) from `terraform output`, so run them after `terraform init`. They
need Docker, Node, the AWS CLI and jq, and a bash shell (Git Bash on Windows).

```bash
# A backend service: build the image, push it to ECR, restart it on ECS
./scripts/release-service.sh order     ../hawkerflow-service-order
./scripts/release-service.sh hawker    ../hawkerflow-service-hawker
./scripts/release-service.sh customer  ../hawkerflow-service-customer
./scripts/release-service.sh analytics ../hawkerflow-service-analytics

# A site: build it against this deployment, upload it, clear the CDN cache
./scripts/release-frontend.sh customer ../diner-ui
./scripts/release-frontend.sh hawker   ../hawker-ui
```

If a change needs both new infrastructure and new code, for example a new
environment variable, release the code first and then run `terraform apply`.

Pull before every `terraform apply`, and tell the team when applying: everyone
shares one state.

## Architecture

The full diagram is [docs/hawkerflow-architecture.png](docs/hawkerflow-architecture.png)
(source: `docs/hawkerflow-architecture.svg`). In outline:

```text
            Diner / hawker browser
              |                |
              | HTTPS          | HTTPS (API calls)
              v                v
   CloudFront (2 sites)   API Gateway (HTTP API, CORS)
              |                |
              | OAC            | VPC Link
              v                v
   S3 site buckets        Internal ALB (:80, routes by path)
   (private)                   |
              +----------------+----------------+----------------+
              v                v                v                v
          /order           /hawker         /customer        /insights
          order            hawker          customer         analytics
          service          service         service          service
              |                |                |                |
              +----------------+-------+--------+----------------+
                                       v
                                 RDS PostgreSQL

   Order service only:
     API -> SQS order queue -> queue worker -> database   (new orders)
     every order step -> SNS order-status topic -> SQS order-events queue
```

ECS tasks, the ALB and RDS are not public. API Gateway is the only public
entry point to the services. There is no NAT gateway: the tasks reach AWS
services through VPC endpoints.

The analytics service is routed under `/insights`, not `/analytics`, because
browser ad blockers refuse requests whose path contains `/analytics/`.

## What gets created

- VPC across two Availability Zones, with public, application and database
  subnets
- VPC endpoints: S3 (gateway) and ECR, CloudWatch Logs, Secrets Manager, SQS
  and SNS (interface)
- Security groups restricting API Gateway -> ALB -> ECS -> PostgreSQL
- One ECR repository, Fargate service, task role and log group per service
- One ECS cluster and an internal Application Load Balancer with path routing
- API Gateway HTTP API with a VPC Link and CORS
- Two Cognito user pools, `customer` and `hawker`, each with an app client
- RDS PostgreSQL with its master password managed in Secrets Manager
- SQS order queue with a dead-letter queue
- SNS order-status topic and an SQS order-events queue subscribed to it
- Two private S3 buckets and CloudFront distributions for the sites
- A bastion host for database access

A NAT gateway is available through `enable_nat_gateway` but is off.

## Services

The `services` variable defines the four services. Its defaults in
`variables.tf` are what is deployed, so `terraform.tfvars` does not set it:

| Key | Route prefix | Port | Health check |
|---|---|---|---|
| `order` | `/order` | 8080 | `/health` |
| `hawker` | `/hawker` | 8080 | `/health` |
| `customer` | `/customer` | 8080 | `/health` |
| `analytics` | `/insights` | 8080 | `/health` |

The ALB forwards the full path, prefix included, so each service must serve
its routes under its prefix. Adding an entry to `services` creates another ECR
repository, target group, ALB rule, ECS service, log group and API routes.

### Settings passed to the containers

Every service receives `DB_HOST`, `DB_PORT` and `DB_NAME`, plus `DB_USERNAME`
and `DB_PASSWORD` from the RDS-managed secret.

The order service also receives:

| Variable | Purpose |
|---|---|
| `SQS__ENABLED`, `SQS__QUEUE_URL`, `SQS__REGION_NAME` | Turn on queued checkout and name the order queue |
| `EVENTS__ENABLED`, `EVENTS__TOPIC_ARN`, `EVENTS__REGION_NAME` | Turn on order events and name the topic |
| `EXPIRY__ENABLED`, `EXPIRY__PENDING_MINUTES` | Cancel orders no stall accepted in time (`order_pending_expiry_minutes`, default 15) |

All three features are off in the order service's own `config.yml`; these
variables turn them on.

## How requests flow

1. The site signs the user in through Cognito.
2. The site calls API Gateway.
3. API Gateway uses its VPC Link to reach the private ALB.
4. The ALB picks the service from the URL path.
5. The service connects to PostgreSQL on port 5432.

API Gateway does **not** validate tokens today. A Cognito JWT authorizer is
defined in `modules/api-gateway`, but every route has `authorization_type =
"NONE"`. Enforcing it is the main outstanding piece of work; it needs the
hawker pool wired in and the diner's guest routes left public.

## IAM

- **Execution role:** used by ECS itself to pull images, write logs and read
  the database secret.
- **Task roles:** one per service, used by the application code. Only the
  order service's role has permissions: the order queue and the order-status
  topic.
- **Deployment identity:** whoever runs Terraform needs rights to create all
  of the above. The team currently shares one administrator access key;
  delete it when the project ends.

## Networking

- `public` subnets: the bastion host. They have a route to the Internet
  Gateway.
- `app` subnets: ECS tasks, the internal ALB and the VPC Link. No internet
  route; AWS services are reached through the VPC endpoints.
- `db` subnets: RDS only.

Security-group chain:

```text
VPC Link SG -> ALB SG :80
ALB SG      -> ECS SG :application ports
ECS SG      -> RDS SG :5432
Bastion SG  -> RDS SG :5432
ECS SG      -> VPC endpoint SG :443
```

The database is `publicly_accessible = false`.

## Rebuilding from nothing

Only when the deployment does not exist: after `terraform destroy`, or in a
different AWS account. Never while the shared deployment is up.

1. Create `backend.tf` and `terraform.tfvars` from the examples and run
   `terraform init`. In a new account, first create a private, versioned S3
   bucket for the state and put its name in `backend.tf`.
2. Create everything except the ECS services, so the image repositories exist:

   ```bash
   terraform apply -target=module.network -target=module.ecr -target=module.iam \
     -target=module.database -target=module.cognito -target=module.alb \
     -target=module.bastion -target=module.api_gateway -target=module.spa_hosting \
     -target=aws_ecs_cluster.this -target=aws_iam_role_policy.ecs_read_db_secret
   ```

3. Push a first image for each service by hand, because the ECS services do
   not exist yet:

   ```bash
   aws ecr get-login-password --region ap-southeast-1 | \
     docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.ap-southeast-1.amazonaws.com
   docker build --platform linux/amd64 -t ECR_REPOSITORY_URL:latest ../hawkerflow-service-order
   docker push ECR_REPOSITORY_URL:latest
   ```

   Repeat for `hawker`, `customer` and `analytics`, using the addresses in
   `terraform output ecr_repository_urls`.
4. Run `terraform apply` with no targets.
5. Check `https://<api_url>/<prefix>/health` for all four prefixes.
6. Publish both sites with `release-frontend.sh`.

A rebuilt deployment has a new API address, new Cognito IDs and an empty
database.

## Destroying the environment

```bash
terraform plan -destroy
terraform destroy
```

RDS uses `skip_final_snapshot = true` and has deletion protection off, so the
database and its data are deleted. ECR repositories are not force-deleted: if
they contain images, delete the images first.

The deployment costs roughly US$0.29 an hour while it is up.

## Frontend hosting

The two Angular sites are served from private S3 buckets through CloudFront
with Origin Access Control. 403 and 404 responses are rewritten to
`/index.html`, so Angular's client-side routes work.

`release-frontend.sh` builds a site and publishes it. It sets the site's API
address and Cognito IDs from `terraform output` through the site's
`set-env.js`, so nothing deployment-specific is committed to the UI
repositories. `deploy-frontend.sh` is the upload step alone, for a site that
is already built.

## Before production

This setup favours being understandable over being hardened. Before
production, consider:

- enforcing the JWT authorizer, and verifying the caller in each service
- restricting the bastion to known IP addresses
- a database user per service in place of the shared master account
- separate AWS accounts for dev, staging and production
- CI/CD through GitHub Actions with OIDC, in place of a shared access key
- RDS Multi-AZ, deletion protection, final snapshots and longer backups
- at least two tasks per service, and ECS autoscaling
- a custom API domain with Route 53 and ACM, and AWS WAF if needed
- alarms on the dead-letter queue, the ALB and the services
- database migrations as a job, in place of table creation at service start

## Files

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
│   ├── release-service.sh
│   ├── release-frontend.sh
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
    ├── spa-hosting
    └── bastion
```

## Connecting to the database from DBeaver (bastion SSH tunnel)

The RDS PostgreSQL database is isolated in private database subnets with no public internet routing. To let tools like **DBeaver** or `psql` connect:

- A lightweight EC2 Bastion host (`t4g.nano`, ~$0.0053/hr) is placed in the **public subnet** with an Internet Gateway route.
- Security groups permit inbound SSH (port 22) to the Bastion host and allow the Bastion host to access PostgreSQL (port 5432) on the RDS instance.
- **Cost optimization:** When not in use, you can stop the bastion instance (`aws ec2 stop-instances --instance-ids $(terraform output -raw bastion_instance_id)`). While stopped, you only pay for 8 GB gp3 storage (~$0.64/month).

### Step 1: Save the auto-generated SSH key

```bash
terraform output -raw bastion_ssh_private_key > bastion.pem
chmod 400 bastion.pem
```

### Step 2: Retrieve the database credentials

```bash
# Database endpoint
terraform output database_endpoint

# Master password from AWS Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw database_secret_arn) \
  --query SecretString \
  --output text
```

### Step 3: Configure DBeaver

1. In DBeaver, click **New Database Connection** -> **PostgreSQL**.
2. In the **Main** tab:
   - **Host:** Enter your `database_endpoint` (from `terraform output database_endpoint`)
   - **Port:** `5432`
   - **Database:** `hawkerflow` (or `var.db_name`)
   - **Authentication:** Database Native
   - **Username:** `hawkerflow_admin` (or `var.db_username`)
   - **Password:** Paste the password retrieved from Secrets Manager
3. In the **SSH** tab:
   - Check **Use SSH Tunnel**
   - **Host/IP:** Enter your `bastion_public_ip` (from `terraform output bastion_public_ip`)
   - **Port:** `22`
   - **User Name:** `ec2-user`
   - **Authentication Method:** `Public Key`
   - **Private Key:** Select the `bastion.pem` file you saved in Step 1
4. Click **Test Connection** -> **Finish**.

*(Optional) Alternative CLI port forwarding:*
```bash
# Opens localhost:5432 forwarded to RDS
$(terraform output -raw bastion_ssh_tunnel_command)
```



