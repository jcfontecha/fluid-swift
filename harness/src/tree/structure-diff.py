"""Inspect native structural mismatches without normalizing the comparison."""
import collections
import json
import sys
from pathlib import Path

path = Path(sys.argv[1] if len(sys.argv) > 1 else 'traces/tree/0-records.json')
data = json.loads(path.read_text())

def first_diff(actual, expected, path='root'):
    if isinstance(actual, list) and isinstance(expected, list):
        if len(actual) == len(expected) == 2 and actual[0] == expected[0] == 'object':
            a, b = actual[1], expected[1]
            ka, kb = [pair[0] for pair in a], [pair[0] for pair in b]
            if ka != kb:
                return path, f'keys {ka} != {kb}'
            for (key, av), (_, bv) in zip(a, b):
                result = first_diff(av, bv, path + '.' + key)
                if result:
                    return result
            return None
        if len(actual) != len(expected):
            return path, f'length {len(actual)} != {len(expected)}'
        for index, (a, b) in enumerate(zip(actual, expected)):
            result = first_diff(a, b, path + f'[{index}]')
            if result:
                return result
        return None
    if actual != expected:
        return path, f'{actual!r} != {expected!r}'
    return None

summary = collections.OrderedDict()
for index, (expected, actual) in enumerate(zip(data['expected'], data['actual'])):
    if expected[0] != actual[0]:
        print('WIRE MISMATCH', index)
        continue
    if len(expected) == 2 and expected[1] != actual[1]:
        result = first_diff(json.loads(actual[1]), json.loads(expected[1]))
        if result:
            path, reason = result
            rows, first_path = summary.setdefault(reason, ([], path))
            rows.append(index)
print('Mismatched rows:', sum(len(rows) for rows, _ in summary.values()))
for reason, (rows, path) in list(summary.items())[:30]:
    print(f'{len(rows)} rows; first={rows[0]} {path}\n  {reason}')
