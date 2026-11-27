terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_subnet" "helper" {
  id = var.subnet_id
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  tags = {
    "panfactum.com/module" = "aws_talos_ami"
  }
  object_keys = {
    for key, image in var.images : key => "${talos_image_factory_schematic.this[key].id}/${image.talos_version}/aws-${image.architecture}.raw"
  }
}

resource "talos_image_factory_schematic" "this" {
  for_each = var.images
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = sort(each.value.extensions)
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  for_each      = var.images
  platform      = "aws"
  architecture  = each.value.architecture
  talos_version = each.value.talos_version
  schematic_id  = talos_image_factory_schematic.this[each.key].id
}

data "aws_iam_policy_document" "vmie_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vmie.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:Externalid"
      values   = ["vmimport"]
    }
  }
}

data "aws_iam_policy_document" "vmie" {
  statement {
    actions = [
      "ec2:ModifySnapshotAttribute",
      "ec2:CopySnapshot",
      "ec2:RegisterImage",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.staging.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.staging.arn}/*"]
  }
}

resource "aws_s3_bucket" "staging" {
  bucket_prefix = "${var.name_prefix}-ami-import-"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "staging" {
  bucket                  = aws_s3_bucket.staging.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    id     = "expire-staged-images"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_iam_role" "vmimport" {
  name               = "${var.name_prefix}-vmimport"
  assume_role_policy = data.aws_iam_policy_document.vmie_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "vmimport" {
  name   = "vmimport"
  role   = aws_iam_role.vmimport.id
  policy = data.aws_iam_policy_document.vmie.json
}

resource "aws_ebs_snapshot_import" "this" {
  for_each  = var.images
  role_name = aws_iam_role.vmimport.name

  disk_container {
    format = "RAW"
    user_bucket {
      s3_bucket = aws_s3_bucket.staging.id
      s3_key    = local.object_keys[each.key]
    }
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-${each.key}" })

  timeouts {
    create = "120m"
  }

  depends_on = [aws_iam_role_policy.vmimport, terraform_data.stage]
}

resource "aws_ami" "this" {
  for_each            = var.images
  name                = "${var.name_prefix}-${each.key}-${each.value.talos_version}-${each.value.architecture}-${substr(talos_image_factory_schematic.this[each.key].id, 0, 12)}"
  architecture        = each.value.architecture == "arm64" ? "arm64" : "x86_64"
  root_device_name    = "/dev/xvda"
  virtualization_type = "hvm"
  ena_support         = true
  imds_support        = "v2.0"

  # NOTE: Talos publishes its AWS AMIs UEFI-preferred. arm64 instances only support uefi.
  boot_mode = each.value.architecture == "arm64" ? "uefi" : "uefi-preferred"

  ebs_block_device {
    device_name           = "/dev/xvda"
    snapshot_id           = aws_ebs_snapshot_import.this[each.key].id
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-${each.key}" })
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "helper" {
  statement {
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.staging.arn}/*"]
  }
}

resource "aws_iam_role" "helper" {
  name               = "${var.name_prefix}-ami-helper"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "helper" {
  name   = "stage-image"
  role   = aws_iam_role.helper.id
  policy = data.aws_iam_policy_document.helper.json
}

resource "aws_iam_instance_profile" "helper" {
  name = "${var.name_prefix}-ami-helper"
  role = aws_iam_role.helper.name
  tags = local.tags
}

resource "aws_security_group" "helper" {
  name_prefix = "${var.name_prefix}-ami-helper-"
  description = "Egress-only security group for the Talos image staging helper"
  vpc_id      = data.aws_subnet.helper.vpc_id
  tags        = local.tags

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "helper" {
  name_prefix   = "${var.name_prefix}-ami-helper-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = "t4g.nano"
  iam_instance_profile { name = aws_iam_instance_profile.helper.name }
  instance_initiated_shutdown_behavior = "terminate"
  tags                                 = local.tags

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  network_interfaces {
    associate_public_ip_address = false
    subnet_id                   = var.subnet_id
    security_groups             = [aws_security_group.helper.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.name_prefix}-ami-helper" })
  }
}

# NOTE: The helper terminates itself, so it is launched here instead of modelled as aws_instance, which would be recreated on every plan.
resource "terraform_data" "stage" {
  for_each         = var.images
  triggers_replace = [talos_image_factory_schematic.this[each.key].id, each.value.talos_version, each.value.architecture]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
      if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
      exists() { aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; }
      if exists; then exit 0; fi
      id=$(aws ec2 run-instances --launch-template "LaunchTemplateId=$TEMPLATE,Version=$TEMPLATE_VERSION" \
        --user-data "$USER_DATA" --query 'Instances[0].InstanceId' --output text)
      deadline=$((SECONDS + 5400))
      while ! exists; do
        state=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
        if [ "$state" = terminated ] && ! exists; then echo "helper $id terminated without staging s3://$BUCKET/$KEY" >&2; exit 1; fi
        if [ "$SECONDS" -ge "$deadline" ]; then echo "timed out staging s3://$BUCKET/$KEY" >&2; aws ec2 terminate-instances --instance-ids "$id" >/dev/null; exit 1; fi
        sleep 30
      done
    EOT
    environment = {
      REGION           = data.aws_region.current.region
      PROFILE          = var.aws_profile == null ? "" : var.aws_profile
      BUCKET           = aws_s3_bucket.staging.id
      KEY              = local.object_keys[each.key]
      TEMPLATE         = aws_launch_template.helper.id
      TEMPLATE_VERSION = aws_launch_template.helper.latest_version
      USER_DATA        = <<-EOT
        #!/bin/bash
        set -euo pipefail
        trap 'shutdown -h now' EXIT
        curl -fsSL https://factory.talos.dev/image/${talos_image_factory_schematic.this[each.key].id}/${each.value.talos_version}/aws-${each.value.architecture}.raw.xz \
          | xz -d | aws s3 cp - s3://${aws_s3_bucket.staging.id}/${local.object_keys[each.key]} --expected-size 10737418240
      EOT
    }
  }
}
