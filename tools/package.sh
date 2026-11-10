#!/bin/sh
# Builds the plugin zip in dist/, with its checksum.
set -eu
. "$(dirname "$0")/package_lib.sh"
package_start ink_knight
package_stage
package_add assets
package_zip
