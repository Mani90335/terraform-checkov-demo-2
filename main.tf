terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "azure" {
  region = "us-east-1"
}

#################################
# Latest Amazon Linux 2
#################################

data "aws_ami" "amazon_linux" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

#################################
# IAM Role
#################################

resource "aws_iam_role" "ec2_role" {
  name = "secure-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Principal = {
        Service = "ec2.amazonaws.com"
      }

      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "profile" {
  name = "secure-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

#################################
# Security Group
#################################

resource "aws_security_group" "ec2" {
  name        = "secure-ec2-sg"
  description = "Secure EC2 SG"

  egress {
    description = "HTTPS"

    from_port = 443
    to_port   = 443
    protocol  = "tcp"

    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    Name = "secure-sg"
  }
}

#################################
# EC2 Instance
#################################

resource "aws_instance" "secure_instance" {

  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  monitoring   = true
  ebs_optimized = true

  iam_instance_profile = aws_iam_instance_profile.profile.name

  vpc_security_group_ids = [
    aws_security_group.ec2.id
  ]

  metadata_options {

    http_endpoint = "enabled"

    http_tokens = "required"

    http_put_response_hop_limit = 2
  }

  root_block_device {

    encrypted = true

    volume_type = "gp3"

    volume_size = 20

    delete_on_termination = true
  }

  tags = {
    Name = "Secure-EC2"
  }
}

#################################
# Outputs
#################################

output "instance_id" {
  value = aws_instance.secure_instance.id
}

output "public_ip" {
  value = aws_instance.secure_instance.public_ip
}