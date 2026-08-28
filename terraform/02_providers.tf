# Key-pair auth, not password — the provider supports both, but a password
# variable is one `terraform.tfvars` accident away from being committed.
# Key-pair auth keeps the private key on disk (gitignored) and only its path
# passed to Terraform. See terraform/README.md for the one-time keypair setup.

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name       = var.snowflake_account_name
  user               = var.snowflake_user
  role               = var.snowflake_role

  authenticator           = "SNOWFLAKE_JWT"
  private_key             = var.snowflake_private_key_path != "" ? file(var.snowflake_private_key_path) : null
  private_key_passphrase  = var.snowflake_private_key_passphrase != "" ? var.snowflake_private_key_passphrase : null
}
