#====================================================================================================
# FORTIGATE BOOTSTRAP FROM S3
#   The license file alone is ~14 KB and EC2 user-data is limited to 16 KB, so the user-data is a small JSON
#   that points the FortiGate at an S3 bucket (read through the instance profile) holding each unit's config and
#   license. An S3 gateway endpoint on the public route table lets the secondary, which has no public address
#   on port1, reach the bucket at first boot.
#====================================================================================================

locals {
  bootstrap_bucket = "${local.prefix}-fgt-bootstrap-${data.aws_caller_identity.current.account_id}"
  byol             = var.license_type == "byol"

  bootstrap_config = {
    primary   = local.primary_config
    secondary = local.secondary_config
  }
  bootstrap_license_file = {
    primary   = var.primary_license_file
    secondary = var.secondary_license_file
  }

  primary_userdata = jsonencode(merge(
    { bucket = local.bootstrap_bucket, region = var.aws_region, config = "/primary.conf" },
    local.byol ? { license = "/primary.lic" } : {}
  ))
  secondary_userdata = jsonencode(merge(
    { bucket = local.bootstrap_bucket, region = var.aws_region, config = "/secondary.conf" },
    local.byol ? { license = "/secondary.lic" } : {}
  ))
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = local.bootstrap_bucket
  force_destroy = true
  tags          = { Name = "${local.prefix}-fgt-bootstrap" }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "config" {
  for_each = toset(["primary", "secondary"])
  bucket   = aws_s3_bucket.bootstrap.id
  key      = "${each.key}.conf"
  content  = local.bootstrap_config[each.key]
}

resource "aws_s3_object" "license" {
  for_each = local.byol ? toset(["primary", "secondary"]) : toset([])
  bucket   = aws_s3_bucket.bootstrap.id
  key      = "${each.key}.lic"
  source   = local.bootstrap_license_file[each.key]
  etag     = filemd5(local.bootstrap_license_file[each.key])
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.inspection.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
  tags              = { Name = "${local.prefix}-s3-endpoint" }
}
