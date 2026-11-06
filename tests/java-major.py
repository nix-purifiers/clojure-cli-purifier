#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Evaluate the actual builder selector; no legacy JVM lifecycle claim."""
import json
from pathlib import Path
import re
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
expression = re.search(r'^  javaMajor = (.*);$', source, re.M).group(1)
cases = [{'version': v, 'expected': e} for v, e in [
    ('1.6.0-119', '6'), ('1.7.0_352', '7'), ('1.8.0_504', '8'),
    ('8', '8'), ('11.0.29', '11'), ('17.0.17', '17'), ('21.0.12.1', '21'), ('21', '21')]]
code = ('let lib = import '+json.dumps(sys.argv[2])+'; '
        'parse = javaVersion: let lock = { inherit javaVersion; }; in '+expression+'; '
        'cases = builtins.fromJSON '+json.dumps(json.dumps(cases))+'; '
        'in map (c: { inherit (c) version expected; actual = parse c.version; }) cases')
result = json.loads(subprocess.check_output([
    'nix-instantiate', '--store', 'dummy://', '--eval', '--strict', '--json', '--expr', code], text=True))
assert all(c['actual'] == c['expected'] for c in result), result
print('PASS actual builder legacy and modern Java major selection')
