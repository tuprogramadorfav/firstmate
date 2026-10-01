#!/usr/bin/env python3
"""Fold `fm-procevent-lavish.sh read` output into the oracle's line shape."""
import sys

lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if line.startswith(('declared_items:', 'presented_items:', 'ANNOTATION ',
                        'element_uid:', 'element_selector:', 'tag:')) \
            and not line.startswith('ANNOTATIONS'):
        out.append(line)
    elif line in ('text:', 'note:', 'prompt:'):
        body = []
        i += 1
        while i < len(lines) and lines[i].startswith('| '):
            body.append(lines[i][2:])
            i += 1
        out.append(f'{line} {chr(10).join(body)!r}')
        continue
    i += 1
print('\n'.join(out))
