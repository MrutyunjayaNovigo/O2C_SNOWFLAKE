# Key-pair auth, not password — the provider supports both, but a password
# variable is one `terraform.tfvars` accident away from being committed.
# Key-pair auth keeps the private key on disk (gitignored) and only its path
# passed to Terraform. See terraform/README.md for the one-time keypair setup.

provider "snowflake" {
  organization_name = var.SNOWFLAKE_ORGANIZATION_NAME
  account_name       = var.SNOWFLAKE_ACCOUNT_NAME
  user               = var.SNOWFLAKE_USER
  role               = var.snowflake_role

  authenticator           = "SNOWFLAKE_JWT"
  private_key             = var.SNOWFLAKE_PRIVATE_KEY_PATH != "" ? file(var.SNOWFLAKE_PRIVATE_KEY_PATH) : null
  private_key_passphrase  = var.snowflake_private_key_passphrase != "" ? var.snowflake_private_key_passphrase : null

  # snowflake_external_access_integration is still a preview feature in this
  # provider (pinned >= 1.0.0, < 2.0.0 in 01_versions.tf) — without this, the
  # resource type isn't registered at all and `terraform plan` fails with
  # "does not support resource type". See
  # https://github.com/snowflakedb/terraform-provider-snowflake/blob/main/docs/index.md
  preview_features_enabled = ["snowflake_external_access_integration_resource"]
}
