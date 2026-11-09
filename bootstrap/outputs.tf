output "role_plan_arn" {
  value = aws_iam_role.plan.arn
}

output "role_apply_arn" {
  value = aws_iam_role.apply.arn
}

output "bucket_state" {
  value = aws_s3_bucket.state.bucket
}

output "account_id" {
  value = data.aws_caller_identity.atual.account_id
}
