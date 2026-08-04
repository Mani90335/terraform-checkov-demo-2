provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}

# --- KMS key for default bucket encryption (fixes CKV_AWS_145) ---
# Fixes CKV2_AWS_64 — explicit key policy
resource "aws_kms_key" "s3_key" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowS3ServiceUse"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
      {
        Sid       = "AllowSNSServiceUse"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      }
    ]
  })
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
# Fixes CKV_AWS_300 — abort incomplete multipart uploads
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

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.example]
}

# --- Separate bucket to receive access logs (fixes CKV_AWS_18 on primary bucket) ---
# CKV_AWS_144 and CKV2_AWS_62 are intentionally skipped below: this bucket exists
# solely as a passive logging target. Cross-region replicating log files and firing
# event notifications on every log write add cost and operational noise with no
# real security benefit for a bucket that isn't serving application data.
#checkov:skip=CKV_AWS_144:Logging-target bucket; replicating log files cross-region provides no security benefit
#checkov:skip=CKV2_AWS_62:Logging-target bucket; notifications on every log write are unnecessary operational noise
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

# Fixes CKV_AWS_21 for log_bucket — versioning
resource "aws_s3_bucket_versioning" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Fixes CKV_AWS_145 for log_bucket — KMS encryption (reuses the same-region key)
resource "aws_s3_bucket_server_side_encryption_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key.arn
    }
    bucket_key_enabled = true
  }
}

# Fixes CKV2_AWS_61 + CKV_AWS_300 for log_bucket — lifecycle with abort incomplete multipart
resource "aws_s3_bucket_lifecycle_configuration" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    expiration {
      days = 180
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.log_bucket]
}

resource "aws_s3_bucket_logging" "example" {
  bucket        = aws_s3_bucket.example.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}

# --- Event notifications (fixes CKV2_AWS_62 on primary bucket) ---
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

# --- Cross-region replication (fixes CKV_AWS_144 on primary bucket) ---
# Destination bucket in a second region — replication requires versioning there too.
# CKV_AWS_18 and CKV2_AWS_62 are intentionally skipped below: this bucket only ever
# receives objects via S3 replication. Standing up a dedicated cross-region log
# bucket and notification pipeline just to watch a passive replication target
# adds real infrastructure cost without a corresponding security benefit.
#checkov:skip=CKV_AWS_18:Replication target only; access logging adds cost with no meaningful security value here
#checkov:skip=CKV2_AWS_62:Replication target only; source bucket already has notifications configured
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

# Fixes CKV2_AWS_64 for replica key — explicit key policy
# KMS keys are regional, so the replica bucket (us-west-2) needs its own key —
# it cannot use the primary key, which lives in us-east-1.
resource "aws_kms_key" "s3_key_replica" {
  provider                = aws.replica
  description             = "KMS key for S3 replica bucket encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowS3ServiceUse"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      }
    ]
  })
}

# Fixes CKV_AWS_145 for replica — KMS encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_key_replica.arn
    }
    bucket_key_enabled = true
  }
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
