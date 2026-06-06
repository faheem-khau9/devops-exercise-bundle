# Conftest policies applied to the Terraform plan JSON.
#
# These run against the output of:
#   terraform plan -out=tfplan && terraform show -json tfplan
#
# The plan JSON has `resource_changes[*]` with the planned state under `change.after`.
package main

import rego.v1

# ── Helm release versions must be pinned ────────────────────────────────────

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	not rc.change.after.version
	msg := sprintf("helm_release '%s' has no version pinned — every helm_release must declare an explicit version string", [rc.address])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	rc.change.after.version == ""
	msg := sprintf("helm_release '%s' has an empty version — every helm_release must declare an explicit version string", [rc.address])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	contains(rc.change.after.version, "*")
	msg := sprintf("helm_release '%s' uses a wildcard version ('%s') — must be a pinned exact version", [rc.address, rc.change.after.version])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	v := rc.change.after.version
	contains(v, ">")
	msg := sprintf("helm_release '%s' uses a comparison operator in version ('%s') — must be a pinned exact version", [rc.address, v])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	v := rc.change.after.version
	startswith(v, "^")
	msg := sprintf("helm_release '%s' uses a caret-range version ('%s') — must be a pinned exact version", [rc.address, v])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "helm_release"
	v := rc.change.after.version
	startswith(v, "~")
	msg := sprintf("helm_release '%s' uses a tilde-range version ('%s') — must be a pinned exact version", [rc.address, v])
}
