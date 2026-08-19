#!/usr/bin/env python3
"""sync-cilium-sidecar-images.py <cilium-version>

Fetches the authoritative cilium/cilium values.yaml at the given Cilium version and
updates imagevector/images.yaml with the exact cilium-envoy and certgen tags it pins.
Intended to be called from Renovate postUpgradeTasks after a cilium-agent bump.
Requires: python3 (stdlib only)
"""

import re
import sys
import urllib.request


def extract_image_tag(lines: list[str], top_key: str) -> str:
    in_top = in_image = False
    for line in lines:
        if line == f'{top_key}:':
            in_top = True
            in_image = False
        elif in_top and line == '  image:':
            in_image = True
        elif in_top and in_image and line.startswith('    tag:'):
            return line.split('tag:', 1)[1].strip().strip('"').strip("'")
        elif in_top and line and not line[0].isspace():
            in_top = in_image = False
    raise ValueError(f'tag not found for {top_key!r}')


def update_images_yaml(
    target: str,
    envoy_tag: str,
    certgen_tag: str,
    envoy_ver: str,
    cilium_ver: str,
) -> None:
    with open(target) as f:
        content = f.read()

    # 1. Replace cilium-envoy tag (unique format: v<maj>.<min>.<pat>-<10-digit-ts>-<sha>)
    content = re.sub(
        r'(tag: )v\d+\.\d+\.\d+-\d{10}-[0-9a-f]+',
        r'\g<1>' + envoy_tag,
        content,
    )

    # 2. Replace certgen tag (simple semver, scoped to the certgen block)
    def replace_certgen_tag(m: re.Match) -> str:
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

    # 4. Update or insert a sync-info comment before the cilium-envoy entry
    sync_comment = (
        f'  # Synced from cilium/cilium {cilium_ver}:'
        f' cilium-envoy={envoy_tag}, certgen={certgen_tag}\n'
    )
    if '  # Synced from cilium/cilium' in content:
        content = re.sub(r'  # Synced from cilium/cilium[^\n]*\n', sync_comment, content)
    else:
        content = content.replace(
            '  - name: cilium-envoy\n',
            sync_comment + '  - name: cilium-envoy\n',
            1,
        )

    with open(target, 'w') as f:
        f.write(content)

    print(f'Updated {target}: cilium-envoy={envoy_tag}, certgen={certgen_tag}')


def main() -> None:
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <cilium-version>', file=sys.stderr)
        sys.exit(1)

    cilium_ver = sys.argv[1]
    values_url = (
        f'https://raw.githubusercontent.com/cilium/cilium/{cilium_ver}'
        f'/install/kubernetes/cilium/values.yaml'
    )
    target = 'imagevector/images.yaml'

    print(f'Fetching {values_url}...')
    with urllib.request.urlopen(values_url, timeout=30) as resp:
        lines = resp.read().decode().splitlines()

    envoy_tag = extract_image_tag(lines, 'envoy')
    certgen_tag = extract_image_tag(lines, 'certgen')

    m = re.match(r'v(\d+\.\d+\.\d+)', envoy_tag)
    if not m:
        print(f'Could not extract semver from envoy tag: {envoy_tag!r}', file=sys.stderr)
        sys.exit(1)
    envoy_ver = m.group(1)  # e.g. "1.36.9"

    print(f'cilium-envoy: {envoy_tag}')
    print(f'certgen:      {certgen_tag}')
    print(f'envoy ver:    {envoy_ver}')

    update_images_yaml(target, envoy_tag, certgen_tag, envoy_ver, cilium_ver)


if __name__ == '__main__':
    main()
