# Kind cluster naming policy.
package main

import rego.v1

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "kind_cluster"
	name := rc.change.after.name
	contains(name, " ")
	msg := sprintf("kind_cluster '%s' has spaces in its name — must be DNS-1123 compatible", [name])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "kind_cluster"
	name := rc.change.after.name
	name != lower(name)
	msg := sprintf("kind_cluster name '%s' contains uppercase characters — must be all lowercase", [name])
}

deny contains msg if {
	rc := input.resource_changes[_]
	rc.type == "kind_cluster"
	name := rc.change.after.name
	count(name) > 32
	msg := sprintf("kind_cluster name '%s' is longer than 32 characters", [name])
}
