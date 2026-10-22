"""Verify the entire VFS option shadow and LAN reinjection against an installed game.

python tools/ui_layout_check.py GAME_ROOT [--ref REF] [--injector-ref REF]
--ref and --injector-ref support negative controls without touching the working tree.
"""
import argparse
import copy
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = 'ui/ui-vue/src/modules/options/runtime/layout.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game_root', type=Path)
    parser.add_argument('--ref')
    parser.add_argument('--injector-ref')
    args = parser.parse_args()

    def read(path, ref=None):
        if ref:
            return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT).decode('utf-8')
        return (ROOT / path).read_text(encoding='utf-8')

    def nodes(node):
        if isinstance(node, dict):
            yield node
            for value in node.values():
                yield from nodes(value)
        elif isinstance(node, list):
            for value in node:
                yield from nodes(value)

    stock = json.loads((args.game_root / LAYOUT).read_text(encoding='utf-8'))
    shipped = json.loads(read(LAYOUT, args.ref))
    failures = []

    def check(name, test):
        try:
            test()
            print('PASS', name)
        except AssertionError as error:
            failures.append(name)
            print('FAIL', name, str(error))

    def same_stock():
        stripped = copy.deepcopy(shipped)
        stripped['items'] = [c for c in stripped['items'] if not c.get('categoryId', '').startswith('beammp')]
        assert stripped == stock, 'non-BeamMP content differs from installed game'
        print(f'  {len(stripped["items"])} stock categories; {sum(1 for _ in nodes(stripped))} full tree nodes')

    def shadow_population():
        shadows = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'ui/ui-vue/src').rglob('*') if p.is_file() and (args.game_root / p.relative_to(ROOT)).is_file())
        assert shadows == ['ui/ui-vue/src/modules/options/runtime/conditions.js', LAYOUT], shadows

    namespace = {'__file__': str(ROOT / 'tools/inject_lan_options.py'), '__name__': 'test_injector'}
    exec(compile(read('tools/inject_lan_options.py', args.injector_ref or args.ref), 'inject_lan_options.py', 'exec'), namespace)

    def lan_contract():
        family = [c for c in shipped['items'] if c.get('categoryId', '').startswith('beammp')]
        assert len(family) == 7
        lan = next(c for c in family if c['categoryId'] == 'beammplan')
        assert lan['items'] == namespace['LAN_ITEMS']
        settings = [n.get('setting') for n in nodes(family)]
        assert settings.count('disableInstabilityPausing') == 1
        assert 'refreshIngame' not in settings
        for node in nodes(family):
            if node.get('setting') == 'playerlistLeftclick':
                assert 2 not in [o.get('value') for o in node['options']]
        assert 'beammpHowBlobIllegal' not in json.dumps(family)
        print(f'  all {len(lan["items"])} LAN items unchanged; instability preference retained; LAN prunes applied')

    def injector():
        upstream = json.loads(read(LAYOUT, 'v4.23.1'))
        combined = copy.deepcopy(stock)
        combined['items'].extend(c for c in upstream['items'] if c.get('categoryId', '').startswith('beammp'))
        with tempfile.TemporaryDirectory(prefix='beammp-options-') as temporary:
            output = Path(temporary) / 'layout.json'
            output.write_text(json.dumps(combined), encoding='utf-8')
            namespace['LAYOUT'] = str(output)
            assert namespace['main']() == 0
            first = output.read_bytes()
            rebuilt = json.loads(first)
            assert sum(n.get('setting') == 'disableInstabilityPausing' for n in nodes(rebuilt)) == 1, 'injector lost retained instability setting'
            assert namespace['main']() == 0
            assert output.read_bytes() == first, 'second injection changed bytes'
            if not args.ref:
                assert rebuilt == shipped, 'shipped layout cannot be reproduced from game + upstream + injector'

    check('complete stock layout equality', same_stock)
    check('entire shipped Vue stock-shadow population', shadow_population)
    check('LAN option contract and prunes', lan_contract)
    check('rebuild from upstream and byte-for-byte injector idempotence', injector)
    print(f'RESULT: {"FAIL" if failures else "PASS"} ({len(failures)} failures)')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
