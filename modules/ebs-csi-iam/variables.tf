variable "cluster_name" {
  description = "EKS cluster name (used as IAM role prefix)"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}