# Pin deliberately. The Snowflake provider has renamed core resources before
# (snowflake_role -> snowflake_account_role; the whole grant resource family
# was redesigned in the v0.87 "new grants" rollout) — an un-pinned provider
# is the single most likely thing to silently break this stack on a new
# account. See terraform/README.md "Before you run this" for how to verify
# the pin still matches what's on the Registry.
#
# >= 2.20.0 specifically: snowflake_external_access_integration wasn't
# registered as a production (non-preview) resource until 2.20.0 — anything
# in the 1.x line (the previous pin here) doesn't have it at all, which
# fails as "provider does not support resource type", not a preview-feature
# error. See 07_network_and_secrets.tf.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 2.20.0, < 3.0.0"
    }
  }

  # HCP Terraform as a pure state backend — Execution Mode is set to Local
  # on the workspace, so `terraform apply` still runs from GitHub Actions /
  # a local terminal, not HCP Terraform's own runners. This only replaces
  # local state with remote state + locking, so both you and CI see the
  # same state instead of each starting from empty and colliding with
  # objects the other already created. Auth: set TF_TOKEN_app_terraform_io
  # (dots -> underscores is Terraform's own convention for this env var
  # name) rather than committing a credentials file anywhere.
  cloud {
    organization = "snowflake-terraform-mj"

    workspaces {
      name = "o2c-snowflake"
    }
  }
}
