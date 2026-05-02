output "iam_role_arn" {
  description = "EBS CSI Driver IAM Role ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "iam_role_name" {
  description = "EBS CSI Driver IAM Role name"
  value       = aws_iam_role.ebs_csi.name
}

output "addon_arn" {
  description = "EBS CSI Driver addon ARN"
  value       = aws_eks_addon.ebs_csi.arn
}