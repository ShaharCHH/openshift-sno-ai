provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project      = "openshift-sno-ai"
      AccountAlias = var.account_alias
      ManagedBy    = "terraform"
    }
  }
}
