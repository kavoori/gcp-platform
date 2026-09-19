# What identifies this bootstrap. None of these is a secret.

variable "github_app_id" {
  type        = number
  default     = 4985493
  description = "The GitHub App Argo CD authenticates as. Shown on the App's page in GitHub."
}

variable "github_app_installation_id" {
  type        = number
  default     = 162645956
  description = "The App's installation on the account that owns the repositories. The number in the installation page's URL."
}

variable "github_app_key_revision" {
  type        = number
  default     = 1
  description = "Bump by one after adding a new key version in Secret Manager. Terraform resends a write-only value only when this changes."
}

variable "platform_repository_url" {
  type        = string
  default     = "https://github.com/kavoori/gcp-platform.git"
  description = "This repository, as Argo CD clones it. HTTPS, because GitHub App credentials only work over HTTPS."
}

variable "google_oauth_client_secret_revision" {
  type        = number
  default     = 1
  description = "Bump by one after adding a new version of the Google OAuth client secret in Secret Manager. Terraform resends a write-only value only when this changes."
}
