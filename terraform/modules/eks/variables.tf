variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC ID the cluster runs in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the cluster and node groups."
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS control plane (from the iam module)."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for the worker nodes (from the iam module)."
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
