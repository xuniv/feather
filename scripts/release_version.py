#!/usr/bin/env python3
"""Validate the public fork version and its monotonic numeric package version."""
import json
from pathlib import Path
import re


def versions(path=Path('Feather.xcconfig')):
    text = Path(path).read_text()
    def setting(key, pattern):
        match = re.search(r'^' + key + r'=(' + pattern + r')$', text, re.M)
        if not match:
            raise ValueError('Invalid ' + key)
        return match[1]
    numeric = r'(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)'
    package = setting('FEATHER_PROJECT_VERSION', numeric)
    upstream = setting('FEATHER_UPSTREAM_VERSION', numeric)
    revision = setting('FEATHER_FIX_VERSION', r'[1-9]\d*')
    setting('FEATHER_RELEASE_VERSION', r'\$\(FEATHER_UPSTREAM_VERSION\)-\$\(FEATHER_FIX_VERSION\)')
    return {'release': upstream + '-' + revision, 'package': package, 'upstream': upstream, 'revision': revision}


if __name__ == '__main__':
    print(json.dumps(versions(), sort_keys=True))
