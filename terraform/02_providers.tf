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
}
