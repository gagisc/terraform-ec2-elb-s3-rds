# Terraform EC2 + ALB + S3 + RDS Demo

This repository contains a small end-to-end AWS demo built with Terraform. It provisions:

- A VPC with public and private subnets
- An Application Load Balancer (ALB) in the public subnet
- Two EC2 instances running a simple Flask "contacts" app in the private subnet
- An S3 bucket used by the app to store contacts as a JSON document
- A PostgreSQL RDS instance used by the app as a relational backend
- IAM roles/policies and security groups wiring everything together
- DynamoDB table for Terraform state locking when using an S3 backend

The Flask app lets you add and search contacts (name/phone) backed by both S3 and RDS.

## Prerequisites

- Terraform >= 1.5.0
- An AWS account and credentials configured (e.g., via `aws configure`)
- An existing S3 bucket and DynamoDB table for the Terraform remote backend, or adjust/remove the `backend "s3"` block in `main.tf`

## Quick start

From the repo root:

```sh
terraform init
terraform fmt
terraform validate
```

Plan and apply, providing required variables:

```sh
terraform plan \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"    # optional; overrides default

terraform apply \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"
```

After `apply` completes, Terraform will output:

- `alb_dns_name` – the public DNS name of the Application Load Balancer
- `rds_endpoint` – the endpoint of the PostgreSQL RDS instance

Visit `http://<alb_dns_name>/` in your browser to use the contacts app.

## Variables

Defined in `variables.tf`:

- `aws_region` (string, default `us-east-1`): AWS region to deploy into.
- `instance_type` (string, default `t3.micro`): EC2 instance type for web servers.
- `app_data_bucket_name` (string, required): Name of the S3 bucket used by the app to store contacts.
- `db_username` (string, required): RDS database username.
- `db_password` (string, required, sensitive): RDS database password.
- `db_name` (string, default `contactsdb`): RDS database name.

## Architecture overview

- **Networking**: One VPC (`10.0.0.0/16`) with a public subnet (`10.0.1.0/24`) for the ALB and a private subnet (`10.0.10.0/24`) for EC2 and RDS.
- **Security groups**: ALB open on HTTP 80 to the internet; web instances only accept HTTP from the ALB; RDS only accepts PostgreSQL traffic from the web instances.
- **Compute**: Two Amazon Linux 2023 EC2 instances, each running the same Flask app but with a different `SERVER_MESSAGE` to distinguish them.
- **Data stores**: S3 bucket for JSON contacts storage; PostgreSQL RDS instance for relational storage.
- **IAM**: EC2 role and policy granting S3 access to the app-data bucket and limited RDS permissions; instance profile attached to web instances.
- **User data**: `user_data_app.sh` installs Python, Flask, boto3, psycopg2, writes `app.py`, and configures a systemd service to run the app on boot.

## Cleaning up

To destroy all managed resources and avoid ongoing AWS charges:

```sh
terraform destroy \
  -var "app_data_bucket_name=YOUR_APP_DATA_BUCKET" \
  -var "db_username=YOUR_DB_USER" \
  -var "db_password=YOUR_DB_PASSWORD" \
  -var "db_name=contactsdb"
```

Make sure the S3 bucket and DynamoDB table used for Terraform state (if any) are handled according to your own state management practices.
