locals {
  dlq_list = { for idx, q in var.sqs_queues : idx => q if q.dlq_enable }
}

# Primary Queue creation
resource "aws_sqs_queue" "sqs_queue" {
  for_each                  = var.sqs_queues

  name                      = each.key
  delay_seconds             = each.value["delay_seconds"]
  max_message_size          = each.value["max_message_size"]
  message_retention_seconds = each.value["message_retention_seconds"]
  receive_wait_time_seconds = each.value["receive_wait_time_seconds"]

  tags                      = merge(var.global_tags, each.value["tags"])
}

# DLQ creation based on a trimmed list local.dlq_list
resource "aws_sqs_queue" "sqs_dlq" {
  for_each                  = local.dlq_list

  name                      = each.key
  delay_seconds             = try(each.value["dlq_delay_seconds"], null)
  max_message_size          = try(each.value["dlq_max_message_size"], null)
  message_retention_seconds = try(each.value["dlq_message_retention_seconds"], null)
  receive_wait_time_seconds = try(each.value["dlq_receive_wait_time_seconds"], null)

  tags                      = merge(var.global_tags, each.value["tags"])
}

# DLQ Policy for the primary queue
resource "aws_sqs_queue_redrive_policy" "dlq_policy" {
  for_each  = local.dlq_list

  queue_url = aws_sqs_queue.sqs_queue[each.key].id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sqs_dlq[each.key].arn
    maxReceiveCount     = try(each.value["dlq_max_receive_count"], 10)
  })
}

# DLQ Allow Policy for the dlq
resource "aws_sqs_queue_redrive_allow_policy" "dlq_allow" {
  for_each  = local.dlq_list

  queue_url = aws_sqs_queue.sqs_dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.sqs_queue[each.key].arn]
  })
}

# SNS Topic Creation
resource "aws_sns_topic" "sns_topic" {
  for_each   = var.sns_topics
  name       = each.key

  fifo_topic        = lookup(each.value, "enable_fifo", false)
  kms_master_key_id = lookup(each.value, "kms_key_id", null)
  tags              = merge(var.global_tags, each.value["tags"])
}

resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  for_each  = var.sqs_queues
  topic_arn = aws_sns_topic.sns_topic[each.value["sns_topic_name"]].arn

  protocol  = "sqs"
  endpoint  = aws_sqs_queue.sqs_queue[each.key].arn
}

resource "aws_sqs_queue_policy" "sqs_sns_policy" {
  for_each  = var.sqs_queues
  queue_url = aws_sqs_queue.sqs_queue[each.key].id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "sqspolicy-${each.key}",
  "Statement": [
    {
      "Sid": "sqspolicy-${each.key}",
      "Effect": "Allow",
      "Principal": {
        "Service": "sns.amazonaws.com"
      },
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.sqs_queue[each.key].arn}"
    }
  ]
}
POLICY
}
