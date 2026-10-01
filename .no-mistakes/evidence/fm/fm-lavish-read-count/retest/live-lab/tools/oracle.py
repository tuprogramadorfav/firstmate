#!/usr/bin/env python3
"""Independent oracle for a Lavish capture: lists every queued item's fields,
parsed without the adapter's code, plus the captain's typed note for each
choice taken from the spec the browser driver typed (the ground truth)."""
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
            val, end = json.JSONDecoder().raw_decode(row, i)
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


def typed_notes(spec_path):
    """question label -> note the captain typed, from the browser spec."""
    if not spec_path:
        return None
    spec = json.load(open(spec_path, encoding='utf-8'))
    notes = {}
    for c in spec.get('choices', []):
        notes[c['question']] = (c.get('note') or '').strip()
    for c in spec.get('calls', []):
        notes[c['question']] = (c.get('note') or '').strip()
    return notes


def context_question(prompt):
    # The question key is always the first key of the board's data object, so
    # find it by its literal pretty-printed line rather than by decoding JSON.
    m = re.search(r'\n  "question": "([^"]+)",?\n', prompt)
    return m.group(1) if m else None


def context_note(prompt):
    # Without a typed spec: the Context data block is the first `Context data:`
    # whose remainder is exactly one JSON object.
    start = 0
    while True:
        i = prompt.find('Context data:', start)
        if i < 0:
            return ''
        try:
            d = json.loads(prompt[i + len('Context data:'):])
        except ValueError:
            start = i + 1
            continue
        if isinstance(d, dict):
            n = d.get('note')
            return n if isinstance(n, str) else ''
        start = i + 1


want, items = parse(sys.argv[1])
notes = typed_notes(sys.argv[2] if len(sys.argv) > 2 else None)
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
        if notes is None:
            n = context_note(it.get('prompt', ''))
        else:
            q = context_question(it.get('prompt', ''))
            n = notes.get(q, '') if q else ''
        if n:
            print(f'note: {n!r}')
    elif it.get('prompt'):
        print(f'prompt: {it["prompt"]!r}')
