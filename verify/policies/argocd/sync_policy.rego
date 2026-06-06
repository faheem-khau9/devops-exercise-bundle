# Policies applied to ArgoCD Application manifests in argocd/apps/*.yaml.
package main

import rego.v1

# Only enforce on Application kind (skip AppProject + everything else).
is_application if {
	input.kind == "Application"
	input.apiVersion == "argoproj.io/v1alpha1"
}

# ── Sync policy must be automated with prune + selfHeal ──────────────────────

deny contains msg if {
	is_application
	not input.spec.syncPolicy.automated
	msg := sprintf("Application '%s' has no syncPolicy.automated — set automated.prune and automated.selfHeal to true", [input.metadata.name])
}

deny contains msg if {
	is_application
	input.spec.syncPolicy.automated
	not input.spec.syncPolicy.automated.prune == true
	msg := sprintf("Application '%s' must set syncPolicy.automated.prune = true", [input.metadata.name])
}

deny contains msg if {
	is_application
	input.spec.syncPolicy.automated
	not input.spec.syncPolicy.automated.selfHeal == true
	msg := sprintf("Application '%s' must set syncPolicy.automated.selfHeal = true", [input.metadata.name])
}

# ── No 'project: default' ───────────────────────────────────────────────────

deny contains msg if {
	is_application
	input.spec.project == "default"
	msg := sprintf("Application '%s' uses 'project: default' — create a scoped AppProject and reference it", [input.metadata.name])
}

deny contains msg if {
	is_application
	not input.spec.project
	msg := sprintf("Application '%s' has no spec.project — must reference a scoped AppProject", [input.metadata.name])
}

# ── Destination namespace must be explicit ──────────────────────────────────

deny contains msg if {
	is_application
	not input.spec.destination.namespace
	msg := sprintf("Application '%s' has no spec.destination.namespace — must be explicit, not inherited", [input.metadata.name])
}

deny contains msg if {
	is_application
	input.spec.destination.namespace == ""
	msg := sprintf("Application '%s' has empty spec.destination.namespace", [input.metadata.name])
}
