# -------------------------------------------------------------
# Role for the hawkerflow-qa repo's load-test workflow, which reads the
# CloudWatch metrics for a test window and charts them. Read-only metrics
# access, assumable only from GitHub Actions runs in that one repository.
#
# Uses the account's existing GitHub OIDC provider (not managed here).
# -------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "loadtest_metrics_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.loadtest_github_subject_prefix}:*"]
    }
  }
}

resource "aws_iam_role" "loadtest_metrics" {
  name               = "${local.name}-loadtest-metrics"
  assume_role_policy = data.aws_iam_policy_document.loadtest_metrics_assume.json
}

# Neither action supports resource-level permissions, so Resource must be "*".
resource "aws_iam_role_policy" "loadtest_metrics" {
  name = "${local.name}-loadtest-metrics"
  role = aws_iam_role.loadtest_metrics.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
      Resource = "*"
    }]
  })
}
