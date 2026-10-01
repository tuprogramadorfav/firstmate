#!/usr/bin/env python3
"""Independent oracle for a Lavish capture: lists every queued item's fields
and each choice's Context-data note, parsed without the adapter's code."""
import json
import re
import sys

HEADER = re.compile(r'^(?:prompts|feedback)\[(\d+)\](?:\{([^}]*)\})?:\s*$')


def scalar(v):
    v = v.strip()
    if v.startswith('"'):
        return json.loads(v)
    return v


def table_values(row):
    vals, i, row = [], 0, row.strip()
    while i <= len(row):
        if i < len(row) and row[i] == '"':
            dec = json.JSONDecoder()
            val, end = dec.raw_decode(row, i)
            vals.append(val)
            i = end
        else:
            j = row.find(',', i)
            j = len(row) if j < 0 else j
            vals.append(row[i:j])
            i = j
        if i < len(row) and row[i] == ',':
            i += 1
            continue
        break
    return vals


def parse(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    for n, line in enumerate(lines):
        m = HEADER.match(line)
        if m:
            break
    else:
        return 0, []
    want, fields = int(m.group(1)), m.group(2)
    body = []
    for line in lines[n + 1:]:
        if not line.startswith((' ', '\t')):
            break
        body.append(line)
    items = []
    if fields:
        names = fields.split(',')
        for row in body[:want]:
            items.append(dict(zip(names, table_values(row))))
        return want, items
    cur = None
    for line in body:
        if line.startswith('  - '):
            cur = {}
            items.append(cur)
            line = '    ' + line[4:]
        if line.startswith('    ') and not line.startswith('     '):
            k, _, v = line[4:].partition(':')
            if v.strip():
                cur[k] = scalar(v)
    return want, items


def note(prompt):
    m = re.search(r'Context data:\s*(\{.*\})\s*\Z', prompt, re.S)
    if not m:
        return ''
    try:
        d = json.loads(m.group(1))
    except ValueError:
        return ''
    n = d.get('note') if isinstance(d, dict) else None
    return n if isinstance(n, str) else ''


want, items = parse(sys.argv[1])
annotations = [i for i in items if i.get('tag') != 'message']
print(f'declared_items: {want}')
print(f'presented_items: {len(items)}')
for k, it in enumerate(annotations, 1):
    print(f'ANNOTATION {k} of {len(annotations)}')
    print(f'element_uid: {it.get("uid", "")}')
    print(f'element_selector: {it.get("selector", "")}')
    print(f'tag: {it.get("tag", "")}')
    print(f'text: {it.get("text", "")!r}')
    if it.get('tag') == 'choice':
        n = note(it.get('prompt', ''))
        if n:
            print(f'note: {n!r}')
    elif it.get('prompt'):
        print(f'prompt: {it["prompt"]!r}')
