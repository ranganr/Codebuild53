
###############################################################################
# Terraform: CodePipeline (GitHub via CodeStar Connections) + CodeBuild
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

############################
# Variables
############################
variable "region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region"
}

variable "pipeline_name" {
  type        = string
  default     = "github-codepipeline"
  description = "CodePipeline name"
}

variable "project_name" {
  type        = string
  default     = "github-codebuild-project"
  description = "CodeBuild project name"
}

variable "artifact_bucket" {
  type        = string
  description = "S3 bucket for pipeline artifacts (must have versioning enabled)"
}

# GitHub (CodeStar Connections)
variable "github_owner" {
  type        = string
  description = "GitHub organization or user"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}

variable "github_branch" {
  type        = string
  default     = "main"
  description = "Git branch to build"
}

# Optional KMS for artifact store
variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for artifact store (optional)"
  default     = null
}

############################
# S3 Artifact bucket versioning (required by CodePipeline)
############################
resource "aws_s3_bucket_versioning" "artifact_versioning" {
  bucket = var.artifact_bucket
  versioning_configuration {
    status = "Enabled"
  }
}

############################
# IAM: CodeBuild service role + policy
############################
resource "aws_iam_role" "codebuild_role" {
  name               = "${var.project_name}-ServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "codebuild.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.project_name}-InlinePolicy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Pipeline-managed artifacts: CodeBuild reads/writes via temp S3 locations
      {
        Sid    = "S3ArtifactsReadWrite",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::${var.artifact_bucket}",
          "arn:aws:s3:::${var.artifact_bucket}/*"
        ]
      },
      # CloudWatch Logs
      {
        Sid    = "CloudWatchLogs",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
      # (Optional) Add KMS decrypt/describe if you set var.kms_key_arn
    ]
  })
}

############################
# CodeBuild: Project
############################
resource "aws_codebuild_project" "project" {
  name          = var.project_name
  description   = "Build project for GitHub source via CodePipeline"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 20

  artifacts {
    type      = "CODEPIPELINE"   # Pipeline-managed artifacts
    packaging = "ZIP"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"  # Amazon Linux 2023
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"   # Source provided by CodePipeline
    buildspec = <<-EOT
      version: 0.2
      phases:
        install:
          commands:
            - echo "Install phase"
        build:
          commands:
            - echo "Building from GitHub repo: ${var.github_owner}/${var.github_repo}"
            - mkdir -p dist
            - cp -r * dist/ || true
            - zip -r build_output.zip dist
      artifacts:
        files:
          - build_output.zip
    EOT
  }

  logs_config {
    cloudwatch_logs { status = "ENABLED" }
  }

  depends_on = [aws_iam_role_policy.codebuild_policy]
}

############################
# CodeStar Connections: GitHub connection
############################
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.pipeline_name}-github-connection"
  provider_type = "GitHub"
}

# NOTE: After apply, go to AWS Console → Developer Tools → Connections
# and click "Update / Authorize" on this connection to finish GitHub auth.

############################
# IAM: CodePipeline service role + policy
############################
resource "aws_iam_role" "codepipeline_role" {
  name               = "${var.pipeline_name}-ServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "codepipeline.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${var.pipeline_name}-InlinePolicy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Artifact store S3 R/W
      {
        Sid    = "ArtifactBucketAccess",
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${var.artifact_bucket}",
          "arn:aws:s3:::${var.artifact_bucket}/*"
        ]
      },
      # Invoke CodeBuild
      {
        Sid    = "CodeBuildInvoke",
        Effect = "Allow",
        Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:BatchGetProjects"],
        Resource = [aws_codebuild_project.project.arn]
      },
      # Pass only the CodeBuild service role (least privilege)
      {
        Sid    = "PassCodeBuildServiceRoleLeastPrivilege",
        Effect = "Allow",
        Action = ["iam:PassRole"],
        Resource = [aws_iam_role.codebuild_role.arn]
      },
      # Use CodeStar Connections in Source action
      {
        Sid    = "UseConnections",
        Effect = "Allow",
        Action = ["codestar-connections:UseConnection"],
        Resource = [aws_codestarconnections_connection.github.arn]
      }
      # (Optional) Add KMS permissions if artifact store uses SSE-KMS
    ]
  })
}

############################
# CodePipeline:
