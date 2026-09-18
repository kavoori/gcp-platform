# Printed at the end of every apply, and any time with `terraform output`.

output "argocd_url" {
  description = "Where Argo CD answers, once the platform Application has created its route."
  value       = "https://argocd.dev.gcp.kavoori.com"
}

output "argocd_chart_version" {
  description = "The chart version this bootstrap installs. Argo CD then upgrades itself to whatever apps/argocd.yaml says."
  value       = helm_release.argocd.version
}
