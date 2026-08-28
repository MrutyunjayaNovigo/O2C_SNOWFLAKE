# Pin deliberately. The Snowflake provider has renamed core resources before
# (snowflake_role -> snowflake_account_role; the whole grant resource family
# was redesigned in the v0.87 "new grants" rollout) — an un-pinned provider
# is the single most likely thing to silently break this stack on a new
# account. See terraform/README.md "Before you run this" for how to verify
# the pin still matches what's on the Registry.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 1.0.0, < 2.0.0"
    }
  }

  # Local state by default — fine for one operator bootstrapping one account.
  # If more than one person/pipeline will run this, switch to a remote
  # backend (e.g. an S3/GCS bucket or Snowflake-external backend) BEFORE the
  # first apply — moving state after the fact is extra, avoidable work.
  # backend "s3" {}
}
