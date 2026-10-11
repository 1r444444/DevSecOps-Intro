package k8s.security

deny contains msg if {
  input.kind == "Deployment"
  c := input.spec.template.spec.containers[_]
  not contains(c.image, "@sha256:")
  msg := sprintf("container %q must pin image by digest", [c.name])
}

warn contains msg if {
  input.kind == "Deployment"
  input.spec.template.spec.automountServiceAccountToken == true
  c := input.spec.template.spec.containers[_]
  msg := sprintf("container %q should not automount the service account token", [c.name])
}
