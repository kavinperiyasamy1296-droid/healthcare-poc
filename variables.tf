variable "region" {
  type    = string
  default = "ap-south-1"
}
variable "name" {
  type    = string
  default = "healthcare-poc"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.name)) && !endswith(var.name, "-") && !strcontains(var.name, "--")
    error_message = "Use 3-30 lowercase letters, digits or hyphens; start with a letter, no trailing or consecutive hyphens."
  }
}
variable "github_repository" {
  type        = string
  description = "Exact GitHub owner/repository, case-sensitive."
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use owner/repository."
  }
}
variable "github_branch" {
  type    = string
  default = "main"
}
variable "existing_github_oidc_arn" {
  type        = string
  default     = null
  description = "Existing account GitHub OIDC provider ARN; otherwise create one."
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "postgres_version" {
  type        = string
  default     = "17"
  description = "PostgreSQL major/minor available in selected Region."
}
variable "web_cidrs" {
  type        = list(string)
  description = "Allowed IPv4 CIDRs for HTTP/HTTPS, for example your public IP/32."
  validation {
    condition     = length(var.web_cidrs) > 0 && alltrue([for c in var.web_cidrs : can(cidrnetmask(c))])
    error_message = "Provide at least one valid IPv4 CIDR."
  }
}
variable "alarm_topic_arn" {
  type        = string
  default     = null
  description = "Optional existing SNS topic ARN, with confirmed subscribers. Null creates alarms without notifications."
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "final_snapshot_suffix" {
  type        = string
  default     = "final-01"
  description = "Unique suffix for final DB snapshot. Change if a snapshot with this name already exists."
}
