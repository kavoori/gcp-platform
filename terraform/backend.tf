# Where this root's state lives: gs://kavoori-tfstate/dev-platform/
#
# The same bucket as terraform-gcp's roots, under its own prefix. This root and the environment
# root that creates the cluster never share state: this one finds the cluster with a data
# source, by name. Backend settings cannot use variables, so every value is written out.
terraform {
  backend "gcs" {
    bucket = "kavoori-tfstate"
    prefix = "dev-platform"
  }
}
