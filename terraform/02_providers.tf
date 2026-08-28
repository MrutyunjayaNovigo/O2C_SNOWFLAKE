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

  # snowflake_external_access_integration is a preview feature as of the
  # provider version pinned in 01_versions.tf (>= 2.20.0) — without this, the
  # resource errors "must be enabled by adding ... to preview_features_enabled".
  # An earlier attempt at this same flag failed differently: under the older
  # 1.x provider (before the version bump), the flag name wasn't even a
  # recognized preview option yet, since the resource itself didn't exist
  # until 2.20.0. Expect possible breaking changes to this resource in future
  # provider releases even without a major version bump — see
  # https://github.com/snowflakedb/terraform-provider-snowflake/blob/main/docs/index.md
  preview_features_enabled = ["snowflake_external_access_integration_resource"]
}
