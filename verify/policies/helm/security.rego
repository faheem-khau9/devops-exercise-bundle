# Policies applied to `helm template` output of the candidate's chart with
# their values.local.yaml overlay applied.
package main

import rego.v1

# Only enforce on Deployment kind (skip Service, ConfigMap, etc.).
is_deployment if {
	input.kind == "Deployment"
}

# ── Every container must have CPU + memory limits ───────────────────────────

deny contains msg if {
	is_deployment
	c := input.spec.template.spec.containers[_]
	not c.resources.limits.cpu
	msg := sprintf("Deployment '%s' container '%s' has no resources.limits.cpu", [input.metadata.name, c.name])
}

deny contains msg if {
	is_deployment
	c := input.spec.template.spec.containers[_]
	not c.resources.limits.memory
	msg := sprintf("Deployment '%s' container '%s' has no resources.limits.memory", [input.metadata.name, c.name])
}

# ── No image with :latest or missing tag ────────────────────────────────────

deny contains msg if {
	is_deployment
	c := input.spec.template.spec.containers[_]
	endswith(c.image, ":latest")
	msg := sprintf("Deployment '%s' container '%s' uses image with :latest tag — must pin a specific tag", [input.metadata.name, c.name])
}

deny contains msg if {
	is_deployment
	c := input.spec.template.spec.containers[_]
	not contains(c.image, ":")
	msg := sprintf("Deployment '%s' container '%s' image '%s' has no tag — must pin a specific tag", [input.metadata.name, c.name, c.image])
}

# ── runAsNonRoot must be true at pod or container level ─────────────────────

deny contains msg if {
	is_deployment
	not input.spec.template.spec.securityContext.runAsNonRoot
	c := input.spec.template.spec.containers[_]
	not c.securityContext.runAsNonRoot
	msg := sprintf("Deployment '%s' container '%s' must run as non-root (set securityContext.runAsNonRoot: true)", [input.metadata.name, c.name])
}
