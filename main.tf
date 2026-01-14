terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    # NOTE: This bucket and DynamoDB table must already exist.
    bucket         = "my-tf-remote-state-bucket"    # TODO: change to your bucket name
    key            = "terraform-ec2-elb-s3-rds/terraform.tfstate"
    region         = "us-east-1"                     # TODO: change to your region
    dynamodb_table = "my-tf-locks"                  # TODO: change to your DynamoDB table name
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

########################
# Networking (VPC, subnets, routes)
########################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "tf-ec2-elb-s3-rds-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "tf-ec2-elb-s3-rds-igw"
  }
}

# Public subnet for the load balancer and NAT gateway
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "tf-ec2-elb-s3-rds-public"
  }
}

# Private subnet for EC2 instances and RDS (as requested 10.0.10.0/24)
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "tf-ec2-elb-s3-rds-private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "tf-ec2-elb-s3-rds-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

########################
# Security groups
########################

# SG for ALB - allow HTTP from the world
resource "aws_security_group" "alb_sg" {
  name        = "tf-alb-sg"
  description = "Allow HTTP from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tf-alb-sg"
  }
}

# SG for EC2 instances - allow HTTP from ALB, DB from within VPC, and outbound
resource "aws_security_group" "web_sg" {
  name        = "tf-web-sg"
  description = "Web server SG"
  vpc_id      = aws_vpc.main.id

  # HTTP from ALB
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # For debugging/SSH you may optionally add an SSH rule here (commented out)
  # ingress {
  #   from_port   = 22
  #   to_port     = 22
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tf-web-sg"
  }
}

# SG for RDS - allow DB port from web instances only
resource "aws_security_group" "rds_sg" {
  name        = "tf-rds-sg"
  description = "RDS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tf-rds-sg"
  }
}

########################
# S3 bucket for app data and DynamoDB table for Terraform locks
########################

resource "aws_s3_bucket" "app_data" {
  bucket = var.app_data_bucket_name

  tags = {
    Name = "tf-ec2-elb-s3-rds-app-data"
  }
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = "my-tf-locks" # keep in sync with backend config
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name = "tf-remote-state-locks"
  }
}

########################
# IAM role for EC2 instances to access S3 and RDS
########################

resource "aws_iam_role" "ec2_role" {
  name = "tf-web-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "ec2_policy" {
  name        = "tf-web-ec2-policy"
  description = "Allow web instances to access S3 app bucket and RDS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.app_data.arn,
          "${aws_s3_bucket.app_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "rds-db:connect",
          "rds:DescribeDBInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "tf-web-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

########################
# RDS PostgreSQL instance
########################

resource "aws_db_subnet_group" "rds_subnets" {
  name       = "tf-rds-subnet-group"
  subnet_ids = [aws_subnet.private.id]

  tags = {
    Name = "tf-rds-subnet-group"
  }
}

resource "aws_db_instance" "app_db" {
  identifier              = "tf-app-db"
  engine                  = "postgres"
  engine_version          = "15.3"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  username                = var.db_username
  password                = var.db_password
  db_name                 = var.db_name
  skip_final_snapshot     = true
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.rds_subnets.name
  publicly_accessible     = false
  deletion_protection     = false

  tags = {
    Name = "tf-app-db"
  }
}

########################
# Application user_data script
########################

data "aws_ami" "amazon_linux" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

locals {
  user_data_common = templatefile("${path.module}/user_data_app.sh", {
    app_data_bucket = aws_s3_bucket.app_data.bucket
    db_endpoint     = aws_db_instance.app_db.address
    db_name         = var.db_name
    db_username     = var.db_username
    db_password     = var.db_password
  })
}

resource "aws_instance" "web1" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = false

  user_data = <<-EOF
${local.user_data_common}
export SERVER_MESSAGE="Hello World 1"
EOF

  tags = {
    Name = "tf-web1"
  }
}

resource "aws_instance" "web2" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = false

  user_data = <<-EOF
${local.user_data_common}
export SERVER_MESSAGE="Hello World 2"
EOF

  tags = {
    Name = "tf-web2"
  }
}

########################
# Application Load Balancer
########################

resource "aws_lb" "app_alb" {
  name               = "tf-app-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id]

  tags = {
    Name = "tf-app-alb"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "tf-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "tf-app-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "web1_attach" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.web1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "web2_attach" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.web2.id
  port             = 80
}

########################
# Data sources
########################

data "aws_availability_zones" "available" {}
