# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Tooling and common commands

This repo is a single-root Terraform configuration for AWS. You need Terraform (>= 1.5) and AWS credentials configured (via environment variables or an AWS profile) before running any commands.

### Remote backend prerequisites

The Terraform backend is configured to use an S3 bucket and DynamoDB table:

```hcl
backend "s3" {
  bucket         = "my-tf-remote-state-bucket"   # change to your bucket
  key            = "terraform-ec2-elb-s3-rds/terraform.tfstate"
  region         = "us-east-1"                    # change to your region
  dynamodb_table = "my-tf-locks"                 # change to your table
  encrypt        = true
}
```

That bucket and table must already exist **before** using the remote backend. Usual approaches:
- Create them manually (e.g., via console/CLI), matching the names above, then run `terraform init`.
- Or temporarily comment out the `backend "s3"` block and use local state to create the S3 bucket and DynamoDB table, then re-enable the backend and re-run `terraform init -migrate-state`.

Keep `aws_dynamodb_table.tf_locks.name` in `main.tf` in sync with `backend.dynamodb_table`.

### Day-to-day Terraform workflow

Run these from the repo root (`terraform-ec2-elb-s3-rds`):

- Initialize (or reconfigure) backend and providers:

```sh
terraform init
```

- Format configuration:

```sh
terraform fmt
```

- Validate configuration:

```sh
terraform validate
```

- Plan with required variables (update placeholders):

```sh
terraform plan \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"    # optional; overrides default
```

- Apply the plan:

```sh
terraform apply \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"
```

- Destroy all managed resources:

```sh
terraform destroy \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"
```

- Get useful outputs after apply:

```sh
terraform output alb_dns_name
terraform output rds_endpoint
```

No explicit automated tests exist in this repo; use `terraform validate` and `terraform plan` as basic checks before applying.

## High-level architecture

Everything lives in the root module (`main.tf`, `variables.tf`, `outputs.tf`, `user_data_app.sh`). Resources are grouped logically: networking, security, data stores, IAM, compute, and load balancing.

### Networking

- VPC `aws_vpc.main` with CIDR `10.0.0.0/16`.
- Public subnet `aws_subnet.public` (`10.0.1.0/24`) for the Application Load Balancer (ALB) and internet egress via:
  - `aws_internet_gateway.igw` attached to the VPC.
  - `aws_route_table.public` routing `0.0.0.0/0` to the IGW, associated with the public subnet.
- Private subnet `aws_subnet.private` (`10.0.10.0/24`) for EC2 web instances and the RDS database.
- Availability zone is taken from `data.aws_availability_zones.available.names[0]`.

### Security groups

- `aws_security_group.alb_sg` (ALB SG):
  - Ingress: HTTP `80/tcp` from `0.0.0.0/0`.
  - Egress: all outbound.
- `aws_security_group.web_sg` (web instances SG):
  - Ingress: HTTP `80/tcp` **only** from `alb_sg` via `security_groups`.
  - Optional SSH ingress is commented out; if enabled, it will allow `22/tcp` as currently written.
  - Egress: all outbound.
- `aws_security_group.rds_sg` (RDS SG):
  - Ingress: PostgreSQL `5432/tcp` **only** from `web_sg` via `security_groups`.
  - Egress: all outbound.

This enforces a typical pattern: public ALB → private web EC2 → private RDS, with no direct internet access to the EC2 or RDS instances.

### State and data stores

- Terraform remote state:
  - Backend: S3 bucket (name configurable in the `backend` block) plus DynamoDB table for state locking.
  - `aws_dynamodb_table.tf_locks` implements the lock table with hash key `LockID` and `PAY_PER_REQUEST` billing.
- Application S3 bucket `aws_s3_bucket.app_data`:
  - Name driven by `var.app_data_bucket_name`.
  - Used by the Flask app to store contacts in a single JSON object (`contacts.json`).

### IAM

- `aws_iam_role.ec2_role`:
  - Trusts `ec2.amazonaws.com` via `sts:AssumeRole`.
- `aws_iam_policy.ec2_policy`:
  - Grants the web instances permission to `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the app-data bucket and its contents.
  - Grants limited `rds-db:connect` and `rds:DescribeDBInstances` permissions.
- `aws_iam_role_policy_attachment.ec2_attach` attaches the policy to the role.
- `aws_iam_instance_profile.ec2_profile` wraps the role for EC2 use.

### Database

- `aws_db_subnet_group.rds_subnets` contains the private subnet.
- `aws_db_instance.app_db`:
  - PostgreSQL 15.3 (`engine = "postgres"`, `engine_version = "15.3"`).
  - Class `db.t3.micro`, 20 GB storage.
  - Credentials and DB name come from `var.db_username`, `var.db_password` (sensitive), and `var.db_name` (default `contactsdb`).
  - Located in the private subnet group, with security group `rds_sg` and no public accessibility.

### Compute and load balancing

- AMI: `data.aws_ami.amazon_linux` selects the most recent x86_64 Amazon Linux 2023 image (`al2023-ami-*-x86_64`).
- `locals.user_data_common` uses `templatefile("${path.module}/user_data_app.sh", { ... })` to render the bootstrap script with:
  - `app_data_bucket` (S3 bucket name)
  - `db_endpoint` (RDS endpoint)
  - `db_name`, `db_username`, `db_password`.

- EC2 instances:
  - `aws_instance.web1` and `aws_instance.web2`:
    - In private subnet.
    - Use `var.instance_type` (default `t3.micro`).
    - Attach `web_sg` and `ec2_profile` instance profile.
    - `associate_public_ip_address = false`.
    - `user_data` is the rendered `user_data_app.sh` plus an exported `SERVER_MESSAGE` that differs between `web1` and `web2` ("Hello World 1" vs. "Hello World 2").

- Application Load Balancer:
  - `aws_lb.app_alb` in the public subnet with `alb_sg` security group.
  - `aws_lb_target_group.app_tg` on port 80, with HTTP health checks on `/` and typical thresholds.
  - `aws_lb_listener.http` forwarding HTTP traffic on port 80 to the target group.
  - `aws_lb_target_group_attachment.web1_attach` and `.web2_attach` register the two web instances with the target group.

### Application bootstrap (`user_data_app.sh`)

`user_data_app.sh` is rendered by Terraform and executed as EC2 user data. It:

- Installs Python 3, pip, and Python dependencies (`flask`, `boto3`, `psycopg2-binary`).
- Writes `/opt/app.py`, a small Flask app that:
  - Renders a simple HTML form page using `render_template_string`.
  - Stores and retrieves contacts in two backends:
    - **S3**: JSON document (`contacts.json`) in `APP_DATA_BUCKET` via `boto3`.
    - **RDS**: `contacts` table in PostgreSQL, created on first use (`ensure_rds_table`).
  - Uses environment variables set by systemd (`APP_DATA_BUCKET`, `DB_ENDPOINT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`, `SERVER_MESSAGE`).
  - Exposes routes:
    - `/` – main form.
    - `/add_s3`, `/search_s3` – S3-backed operations.
    - `/add_rds`, `/search_rds` – RDS-backed operations.

- Defines and enables a systemd unit at `/etc/systemd/system/app.service` that runs `python3 /opt/app.py` on boot, with the environment wired to the values provided by Terraform and the per-instance `SERVER_MESSAGE`.

## Notes for future Warp agents

- When modifying the backend configuration, keep the S3 bucket and DynamoDB table names consistent with any resources created in `main.tf`.
- Be careful editing `user_data_app.sh`: it relies on here-docs (`<< 'PYEOF'`, `<< 'SEOF'`) and Terraform interpolation via `templatefile`. Preserve quoting and markers so the script remains valid.
- If you introduce modules or additional resources, align with the existing tagging pattern (e.g., `Name = "tf-ec2-elb-s3-rds-*"`) and the public-ALB/private-EC2/private-RDS network model already established.
