# Printed at the end of every apply, and any time with `terraform output`.

output "argocd_url" {
  description = "Where Argo CD answers, once the platform Application has created the Gateway. Read from the same values file Argo CD is installed with."
  value       = "https://${yamldecode(file("${path.module}/../argocd/values.yaml")).global.domain}"
}

output "argocd_chart_version" {
  description = "The chart version this bootstrap installs. Argo CD then upgrades itself to whatever apps/argocd.yaml says."
  value       = helm_release.argocd.version
}
