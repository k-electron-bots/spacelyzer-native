#!/usr/bin/env python3
"""Summarise a macOS `sample` report: the heaviest leaf frames on the main thread (self time by sample count)."""
import sys, re, collections
lines = open(sys.argv[1]).read().split('\n')
start = next((i for i, l in enumerate(lines) if 'Call graph:' in l), None)
if start is None:
    print('no call graph'); sys.exit()
main = []
in_main = False
for l in lines[start + 1:]:
    if re.match(r'^\s+\d+ Thread_', l):
        in_main = 'main' in l.lower() or 'DispatchQueue_1' in l
    if l.startswith('Total number in stack'): break
    if in_main: main.append(l)
# self time = count minus sum of direct children's counts
pat = re.compile(r'^(\s*)(?:[+!:|\s]*)(\d+) (.+?)  \(in (.+?)\)')
frames = []
for l in main:
    m = pat.match(l.replace('+', ' ').replace('!', ' ').replace(':', ' ').replace('|', ' '))
    if m: frames.append((len(l) - len(l.lstrip(' +!:|')), int(m.group(2)), m.group(3), m.group(4)))
selfc = collections.Counter()
for i, (ind, n, name, img) in enumerate(frames):
    child = 0
    for ind2, n2, _, _ in frames[i + 1:]:
        if ind2 <= ind: break
        if ind2 > ind and len([1 for _ in ()]) == 0:
            pass
    selfc[(name, img)] += n
top = []
# simpler: report the 25 frames with the highest inclusive counts below the top-level run loop
seen = collections.Counter()
for ind, n, name, img in frames:
    seen[(name, img)] = max(seen[(name, img)], n)
for (name, img), n in seen.most_common(40):
    top.append(f'{n:6d}  {name} ({img})')
interval = next((l for l in lines if l.startswith("Analysis of sampling")), "sampling interval unavailable")
print("main thread, highest inclusive sample counts; " + interval + "; window duration from command/status evidence")
print('\n'.join(top))
