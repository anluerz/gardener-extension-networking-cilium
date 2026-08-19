#!/usr/bin/env bash
# sync-cilium-sidecar-images.sh <cilium-version>
#
# Fetches the authoritative cilium/cilium values.yaml at the given Cilium version and
# updates imagevector/images.yaml with the exact cilium-envoy and certgen tags it pins.
# Intended to be called from Renovate postUpgradeTasks after a cilium-agent bump.
# Requires: curl, python3 (stdlib only)
set -euo pipefail

CILIUM_VERSION="${1:?Usage: $0 <cilium-version>}"
VALUES_URL="https://raw.githubusercontent.com/cilium/cilium/${CILIUM_VERSION}/install/kubernetes/cilium/values.yaml"
TARGET="imagevector/images.yaml"

echo "Fetching ${VALUES_URL}..."
VALUES=$(curl -fsSL "$VALUES_URL")

# Extract image tags using python3 -c (code via -c arg; stdin carries the YAML data).
# No external tools (yq/jq/etc.) needed — only python3 stdlib.
ENVOY_TAG=$(printf '%s' "$VALUES" | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
in_top = in_image = False
for line in lines:
    if line == 'envoy:':
        in_top = True; in_image = False
    elif in_top and line == '  image:':
        in_image = True
    elif in_top and in_image and line.startswith('    tag:'):
        val = line.split('tag:', 1)[1].strip().strip(chr(34)).strip(chr(39))
        print(val)
        break
    elif in_top and line and not line[0].isspace():
        in_top = in_image = False
")

CERTGEN_TAG=$(printf '%s' "$VALUES" | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
in_top = in_image = False
for line in lines:
    if line == 'certgen:':
        in_top = True; in_image = False
    elif in_top and line == '  image:':
        in_image = True
    elif in_top and in_image and line.startswith('    tag:'):
        val = line.split('tag:', 1)[1].strip().strip(chr(34)).strip(chr(39))
        print(val)
        break
    elif in_top and line and not line[0].isspace():
        in_top = in_image = False
")

ENVOY_VER=$(printf '%s' "$ENVOY_TAG" | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+')

echo "cilium-envoy: ${ENVOY_TAG}"
echo "certgen:      ${CERTGEN_TAG}"
echo "envoy ver:    ${ENVOY_VER}"

# Update imagevector/images.yaml using Python stdlib.
# Store the script in a variable (no pipe+heredoc conflict) then run via -c.
UPDATE_PY=$(cat <<'PYEOF'
import sys, re

target, envoy_tag, certgen_tag, envoy_ver_v = sys.argv[1:]
envoy_ver = envoy_ver_v.lstrip('v')  # e.g. "1.36.9"

with open(target) as f:
    content = f.read()

# 1. Replace cilium-envoy tag (unique format: v<maj>.<min>.<pat>-<10-digit-ts>-<sha>)
content = re.sub(
    r'(tag: )v\d+\.\d+\.\d+-\d{10}-[0-9a-f]+',
    r'\g<1>' + envoy_tag,
    content,
)

# 2. Replace certgen tag (simple semver, scoped to the certgen block)
def replace_certgen_tag(m):
    block = m.group(0)
    return re.sub(r'(    tag: )v\d+\.\d+\.\d+(\s)', r'\g<1>' + certgen_tag + r'\2', block)

content = re.sub(
    r'- name: certgen\b.*?(?=\n  - name:|\Z)',
    replace_certgen_tag,
    content,
    flags=re.DOTALL,
)

# 3. Update Envoy doc URL comments (both cilium-agent and cilium-envoy blocks)
content = re.sub(
    r'(envoy/v)\d+\.\d+\.\d+(/intro)',
    r'\g<1>' + envoy_ver + r'\g<2>',
    content,
)

with open(target, 'w') as f:
    f.write(content)

print(f"Updated {target}: cilium-envoy={envoy_tag}, certgen={certgen_tag}")
PYEOF
)

python3 -c "$UPDATE_PY" "$TARGET" "$ENVOY_TAG" "$CERTGEN_TAG" "$ENVOY_VER"

# Post a comment on the open PR listing the new sidecar versions (best-effort, no-fail)
PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --json number \
  --jq '.[0].number' 2>/dev/null || true)
if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --body "**Sidecar sync from cilium/cilium ${CILIUM_VERSION}**
- \`cilium-envoy\`: \`${ENVOY_TAG}\`
- \`certgen\`: \`${CERTGEN_TAG}\`" 2>/dev/null || true
fi
