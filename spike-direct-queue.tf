# -------------------------------------------------------------
# SPIKE (throwaway): API Gateway sends straight to the order queue.
# Answers one question: what does the caller get back from a direct SQS
# integration, and does the order worker pick the message up?
# Delete this file and apply again to remove it.
# -------------------------------------------------------------
data "aws_iam_policy_document" "spike_apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "spike_apigw_order_queue" {
  name               = "${local.name}-spike-apigw-order-queue"
  assume_role_policy = data.aws_iam_policy_document.spike_apigw_assume.json
}

resource "aws_iam_role_policy" "spike_apigw_order_queue" {
  name = "${local.name}-spike-apigw-order-queue"
  role = aws_iam_role.spike_apigw_order_queue.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = [aws_sqs_queue.order.arn]
    }]
  })
}

resource "aws_apigatewayv2_integration" "spike_order_queue" {
  api_id                 = module.api_gateway.api_id
  integration_type       = "AWS_PROXY"
  integration_subtype    = "SQS-SendMessage"
  credentials_arn        = aws_iam_role.spike_apigw_order_queue.arn
  payload_format_version = "1.0"

  request_parameters = {
    QueueUrl    = aws_sqs_queue.order.url
    MessageBody = "$request.body"
  }
}

resource "aws_apigatewayv2_route" "spike_order_queue" {
  api_id    = module.api_gateway.api_id
  route_key = "POST /spike/order-queue"
  target    = "integrations/${aws_apigatewayv2_integration.spike_order_queue.id}"
}
