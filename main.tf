provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

# --- KMS key for default bucket encryption (fixes CKV_AWS_145) ---
resource "aws_kms_key" "s3_key" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true
}

# --- Primary bucket ---
resource "aws_s3_bucket" "example" {
  bucket = "my-demo-bucket-12345"
}

resource "aws_s3_bucket_public_access_block" "example" {
  bucket                  = aws_s3_bucket.example.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Fixes CKV_AWS_145 — default encryption with KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "example" {
  bucket = aws_s3_bucket.example.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
    bucket_key_enabled = true
  }
}

# Fixes CKV_AWS_21 — versioning (also required for replication to work)
resource "aws_s3_bucket_versioning" "example" {
  bucket = aws_s3_bucket.example.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Fixes CKV2_AWS_61 — lifecycle configuration
resource "aws_s3_bucket_lifecycle_configuration" "example" {
  bucket = aws_s3_bucket.example.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    expiration {
      days = 365
    }
  }

  depends_on = [aws_s3_bucket_versioning.example]
}

# --- Separate bucket to receive access logs (fixes CKV_AWS_18) ---
resource "aws_s3_bucket" "log_bucket" {
  bucket = "my-demo-bucket-12345-logs"
}

resource "aws_s3_bucket_public_access_block" "log_bucket" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "example" {
  bucket        = aws_s3_bucket.example.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}

# --- Event notifications (fixes CKV2_AWS_62) ---
# Requires an SNS topic to publish to
resource "aws_sns_topic" "bucket_events" {
  kms_master_key_id = aws_kms_key.s3_key.id
}

resource "aws_sns_topic_policy" "bucket_events" {
  arn = aws_sns_topic.bucket_events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.bucket_events.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.example.arn }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "example" {
  bucket = aws_s3_bucket.example.id

  topic {
    topic_arn = aws_sns_topic.bucket_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.bucket_events]
}

# --- Cross-region replication (fixes CKV_AWS_144) ---
# Destination bucket in a second region — replication requires versioning there too
resource "aws_s3_bucket" "replica" {
  provider = aws.replica
  bucket   = "my-demo-bucket-12345-replica"
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider                = aws.replica
  bucket                   = aws_s3_bucket.replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role that S3 assumes to perform the replication
resource "aws_iam_role" "replication" {
  name = "s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  name = "s3-replication-policy"
  role = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [aws_s3_bucket.example.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl"]
        Resource = ["${aws_s3_bucket.example.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete"]
        Resource = ["${aws_s3_bucket.replica.arn}/*"]
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "example" {
  bucket = aws_s3_bucket.example.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicate-all"
    status = "Enabled"

    destination {
      bucket = aws_s3_bucket.replica.arn
    }
  }

  depends_on = [aws_s3_bucket_versioning.example]
}


# Added to satisfy remaining Checkov demo checks

resource "aws_s3_bucket_notification" "log_bucket_notification" {
  bucket = aws_s3_bucket.log_bucket.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  provider = aws.replica
  bucket = aws_s3_bucket.replica.id
  rule {
    id="cleanup"
    status="Enabled"
    expiration { days = 365 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

resource "aws_s3_bucket" "replica_logs" {
  provider = aws.replica
  bucket = "my-demo-bucket-12345-replica-logs-demo"
}

resource "aws_s3_bucket_logging" "replica_logging" {
  provider = aws.replica
  bucket = aws_s3_bucket.replica.id
  target_bucket = aws_s3_bucket.replica_logs.id
  target_prefix = "logs/"
}

resource "aws_s3_bucket_notification" "replica_notification" {
  provider = aws.replica
  bucket = aws_s3_bucket.replica.id
  eventbridge = true
}
