#!/usr/bin/env bash
# Second half of the supervision host suite. tests/fm-supervision-host.test.sh
# owns the cases, the harness, and the split point; this entry exists only so the
# portable serial lane can place the two halves on separate CI runners.
set -u
FM_SUPERVISION_HOST_TEST_PART=2 exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
