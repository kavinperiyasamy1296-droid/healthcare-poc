
output "vpc_id" {
  value = aws_vpc.main.id
}

output "instance_ids" {
  value = [for instance in aws_instance.app : instance.id]
}

output "instance_names" {
  value = [for instance in aws_instance.app : instance.tags.Name]
}

output "public_ips" {
  value = [for instance in aws_instance.app : instance.public_ip]
}

output "rds_address" {
  value = aws_db_instance.main.address
}

output "rds_master_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "runtime_secret_arn" {
  value = aws_secretsmanager_secret.runtime.arn
}

output "ecr_repositories" {
  value = {
    for k, r in aws_ecr_repository.app : k => r.repository_url
  }
}

output "github_role_arn" {
  value = aws_iam_role.github.arn
}

output "log_groups" {
  value = {
    for k, g in aws_cloudwatch_log_group.app : k => g.name
  }
}

output "ssm_connect_commands" {
  value = {
    for idx, instance in aws_instance.app :
    instance.tags.Name => "aws ssm start-session --region ${var.region} --target ${instance.id}"
  }
}
