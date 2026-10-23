#!/bin/bash
# Set a pipeline label on an issue or PR, removing labels it replaces
# (other status:* labels, or the same prefix group such as qa:*).
#
# Usage: set_status.sh <issue|pr> <number> <label>
# Example: set_status.sh pr 42 qa:passed      # removes qa:in-progress / qa:failed
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 3 && $1 =~ ^(issue|pr)$ ]] || die "usage: $(basename "$0") <issue|pr> <number> <label>"
set_label "$1" "$2" "$3"
