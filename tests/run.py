"""Syntax-checks the addon under Lua 5.1 (WoW's dialect) and checks that every
:Method( call is a widget method in Forever's API docs or a known non-widget method.

Needs: pip install lupa
Usage: python tests/run.py   (from the project root)
"""
import glob
import os
import re
import sys

import lupa.lua51 as lua51

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
ok = True

for path in sorted(glob.glob('QuestPin/*.lua')):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    src = open(path, encoding='utf-8').read()
    compiled, err = rt.eval(
        'function(src, name) local f, e = loadstring(src, name) return f ~= nil, tostring(e) end'
    )(src, '@' + path)
    if compiled:
        print('syntax ok  ' + path)
    else:
        ok = False
        print('SYNTAX ' + str(err))

documented = {
    line.strip() for line in open(os.path.join('tests', 'forever_widget_methods.txt'), encoding='utf-8')
    if line.strip() and not line.startswith('#')
}
known = {
    # GameTooltip (Lua side).
    'AddLine', 'AddDoubleLine', 'GetOwner',
    # Menu description objects.
    'CreateButton', 'CreateDivider',
    # Frame pools.
    'EnumerateActive',
    # ObjectiveTrackerManager / container / module / block mixins (Blizzard_ObjectiveTracker).
    'GetContainerForModule', 'RemoveModule', 'SetModuleContainer', 'SetHeader', 'MarkDirty',
    'AddObjective',
    # QuestCache quest objects.
    'GetID',
}
bad = []
for path in sorted(glob.glob('QuestPin/*.lua')):
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        code = line.split('--', 1)[0]
        if re.match(r'\s*function\s', code):
            continue  # our own method definitions
        for method in re.findall(r':([A-Z]\w*)\(', code):
            if method not in documented and method not in known:
                bad.append('%s:%d  %s' % (path, n, method))
for b in bad:
    print('UNKNOWN METHOD ' + b)
print('method check: %d unknown' % len(bad))
ok = ok and not bad

sys.exit(0 if ok else 1)
