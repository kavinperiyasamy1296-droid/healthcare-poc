terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.name, Environment = "poc", ManagedBy = "Terraform" }
  }
}
data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
locals {
  prefix   = "arn:${data.aws_partition.current.partition}"
  actions  = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]
  oidc_arn = var.existing_github_oidc_arn != null ? var.existing_github_oidc_arn : aws_iam_openid_connect_provider.github[0].arn
}
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}
resource "aws_internet_gateway" "main" { vpc_id = aws_vpc.main.id }
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.name}-public" }
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name}-private-${count.index + 1}" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "private" { vpc_id = aws_vpc.main.id }
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  vpc_id      = aws_vpc.main.id
  dynamic "ingress" {
    for_each = toset([80, 443])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.web_cidrs
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}
resource "aws_db_subnet_group" "main" {
  name       = var.name
  subnet_ids = aws_subnet.private[*].id
}
resource "aws_db_instance" "main" {
  identifier                      = var.name
  engine                          = "postgres"
  engine_version                  = var.postgres_version
  instance_class                  = var.db_instance_class
  allocated_storage               = 20
  max_allocated_storage           = 50
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "bootstrap"
  username                        = "pocadmin"
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  publicly_accessible             = false
  multi_az                        = false
  backup_retention_period         = 1
  backup_window                   = "18:00-19:00"
  maintenance_window              = "sun:20:00-sun:21:00"
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${var.name}-${var.final_snapshot_suffix}"
  copy_tags_to_snapshot           = true
}
resource "aws_ecr_repository" "app" {
  for_each             = toset(["frontend", "backend"])
  name                 = "${var.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration { encryption_type = "AES256" }
  image_scanning_configuration { scan_on_push = true }
}
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy     = jsonencode({ rules = [{ rulePriority = 1, description = "Remove old untagged layers", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }, action = { type = "expire" } }] })
}
resource "aws_cloudwatch_log_group" "app" {
  for_each          = toset(["application", "system"])
  name              = "/${var.name}/${each.key}"
  retention_in_days = 7
}
# Empty secret container: populate outside Terraform to avoid secret values in state.
resource "aws_secretsmanager_secret" "runtime" {
  name                    = "${var.name}/runtime"
  recovery_window_in_days = 7
}
resource "aws_iam_role" "ec2" {
  name               = "${var.name}-ec2"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "${local.prefix}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "ec2" {
  role = aws_iam_role.ec2.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = [for r in aws_ecr_repository.app : r.arn] },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.runtime.arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = [for g in aws_cloudwatch_log_group.app : "${g.arn}:*"] },
    { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "CWAgent" } } }
  ] })
}
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2"
  role = aws_iam_role.ec2.name
}
resource "aws_instance" "app" {
  count                       = 3
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  monitoring                  = true
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    system_log_group = aws_cloudwatch_log_group.app["system"].name
  })
  user_data_replace_on_change = true
  depends_on                  = [aws_route_table_association.public, aws_iam_role_policy.ec2, aws_iam_role_policy_attachment.ssm]
  tags                        = { Name = "${var.name}-server-${count.index + 1}" }
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_github_oidc_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
resource "aws_iam_role" "github" {
  name = "${var.name}-github-deploy"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Federated = local.oidc_arn }, Action = "sts:AssumeRoleWithWebIdentity",
    Condition = { StringEquals = {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
    } }
  }] })
}
resource "aws_iam_role_policy" "github" {
  role = aws_iam_role.github.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"], Resource = [for r in aws_ecr_repository.app : r.arn] },
    { Effect = "Allow", Action = ["ssm:SendCommand"], Resource = concat([for instance in aws_instance.app : instance.arn], ["${local.prefix}:ssm:${var.region}::document/AWS-RunShellScript"]) },
    { Effect = "Allow", Action = ["ssm:GetCommandInvocation"], Resource = "*" }
  ] })
}
locals {
  alarms = {
    cpu        = { namespace = "AWS/EC2", metric = "CPUUtilization", threshold = 80, comparison = "GreaterThanThreshold", statistic = "Average", dimensions = {} }
    status     = { namespace = "AWS/EC2", metric = "StatusCheckFailed", threshold = 0, comparison = "GreaterThanThreshold", statistic = "Maximum", dimensions = {} }
    memory     = { namespace = "CWAgent", metric = "mem_used_percent", threshold = 85, comparison = "GreaterThanThreshold", statistic = "Average", dimensions = {} }
    db_storage = { namespace = "AWS/RDS", metric = "FreeStorageSpace", threshold = 5368709120, comparison = "LessThanThreshold", statistic = "Average", dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier } }
    db_cpu     = { namespace = "AWS/RDS", metric = "CPUUtilization", threshold = 80, comparison = "GreaterThanThreshold", statistic = "Average", dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier } }
  }
  instance_alarms = merge([
    for idx, instance in aws_instance.app : {
      for alarm_name in ["cpu", "status", "memory"] :
      "server-${idx + 1}-${alarm_name}" => merge(
        local.alarms[alarm_name],
        { dimensions = { InstanceId = instance.id } }
      )
    }
  ]...)
  all_alarms = merge(
    local.instance_alarms,
    { for alarm_name in ["db_storage", "db_cpu"] : alarm_name => local.alarms[alarm_name] }
  )
}
resource "aws_cloudwatch_metric_alarm" "basic" {
  for_each            = local.all_alarms
  alarm_name          = "${var.name}-${each.key}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  statistic           = each.value.statistic
  dimensions          = each.value.dimensions
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "missing"
  alarm_actions       = local.actions
  ok_actions          = local.actions
}
