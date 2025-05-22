# This is a Terraform configuration file for setting up a basic infrastructure in AWS.
# James Tuttle
# 2025-05-21
#


provider "aws" {
  region = "us-west-2"
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_job_scraper_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy_attachment" "lambda_logs" {
    name = "lambda_logs"
    roles = [aws_iam_role.lambda_exec_role.name]
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Writing to SES/DynamoDB
resource "aws_iam_role_policy" "lambda_custom_policy" {
    name = "lambda_suctom_policy"
    role = aws_iam_role.lambda_exec_role.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Action = [
                    "dynamodb:*"
                ]
                Resource = "*"
            },
            Effect = "Allow"
            Action = [
                "ses:SendEmail",
                "ses:sendRawEmail"
            ]
            Resource = "*"
        ]
    })
}

# ************************
# ** N E T W O R K I N G **
# ************************

# VPC ---------------------------
resource "aws_vpc" "main_vpc" {
    cidr_block = "10.0.0.0/16"`
}

# Subnet - PRIVATE
resource "aws_subnet" "private_subnet" {
    vpc_id = aws_vpc.main_vpc.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "us-west-2a"
    map_public_ip_on_launch = false
}

# Security Group
resource "aws_security_group" "lambda_sg" {
    name = "lambda_sg"
    vpc_id = aws_vpc.main_vpc.id
    description = "Allow lambda to access internet via VPC endpoints"

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# DynamoDB VPC Endpoint
resource "aws_dynamodb_table" "jobs_table" {
    name = "job_scraper_table"
    billing_mode ="PAY_PER_REQUEST"
    hash_key = "url"

    attribute {
        name = "url"
        type = "S"
    }
    attribute {
        name = "hasSent"
        type = "N"
    }
}

# Lambda Layers
resource "aws_lambda_layer_version" "certifi_layer" {
    filename = "lambda/layers/certifi-layer.zip"
    layer_name = "certifi-layer"
    compatible_runtimes = ["python3.9"]
}

resource "aws_lambda_layer_version" "selenium_layer" {
    filename = "lambda/layers/selenium_layer.zip"
    layer_name = "selenium-chromium"
    compatible_runtimes = ["python3.9"]
}

## Lambda Function
resource "aws_lambda_function" "job_scraper" {
    function_name = "job_scraper_lambda"
    handler = "main.lambda_handler"
    runtime = "python3.9"
    role = aws_iam_role.lambda_exec_role.arn
    filename = "lambda/job_scraper.zip"

    vpc_config {
        subnet_ids = [aws_subnet.private_subnet.id]
        security_group_ids = [aws_security_group.lambda_sg.id]
    }

    environment {
        variables = {
            EMAIL_TO = "james.j.tuttle@gmail.com"
            REGION = "us-west-2"
            TABLE = aws_dynamodb_table.jobs_table.name
        }
    }

    layers = [
        aws_lambda_layer_version.certifi_layer.arn,
        aws_lambda_layer_version.selenium_layer.arn
    ]
}

## CloudWatch Event Rule (hourly trigger)
resource "aws_cloudwatch_event_rule" "every_hour" {
    name = "job_scraper_schedule"
    schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "invoke_lambda" {
    rule = aws_cloudwatch_event_rule.every_hour.name
    target_id = "lambda"
    arn = aws_lambda_function.job_scraper.arn
}

resource "aws_lambda_permissions" "allow_cloudwatch" {
    statement_id = "AllowExecutionFromCloudwatch"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.job_scraper.function_name
    principal = "events.amazonaws.com"
    source_arn = aws_cloudwatch_event_rule.every_hour.arn
}
###### E N D