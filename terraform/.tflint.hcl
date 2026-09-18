# General Terraform rules: unused variables, missing version constraints, deprecated syntax.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Google-specific rules: invalid machine types, invalid regions, and similar mistakes that
# `terraform plan` does not catch because it never asks Google whether the value is real.
plugin "google" {
  enabled = true
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
