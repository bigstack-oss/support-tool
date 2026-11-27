#!/usr/bin/env python3
"""No cluster access: fake kubectl serves JSON fixtures and logs patches."""
import base64, json, os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
FAKE = r'''#!/usr/bin/env bash
case "$*" in
  *"get clusters.provisioning.cattle.io -o json"*) cat "$D/list.json";;
  *"get clusters.provisioning.cattle.io roy-test"*) cat "$D/cluster.json";;
  *"get machines"*) echo roy-test-pool1-a;;
  *"get secret"*) cat "$D/plan.b64";;
  *patch*) printf '%s\n' "$*" >> "$D/patches";;
esac
'''
EPS = 'http://10.0.0.1:5080 http://10.0.0.2:5080'
ALL = ['docker.io', 'index.docker.io', 'quay.io', 'registry-1.docker.io', 'registry.k8s.io', 'registry.rancher.com', 'nvcr.io']
def mirrors(eps, hosts=ALL):
    return {h: {'endpoint': eps.split()} for h in hosts}
class MirrorTests(unittest.TestCase):
    def run_it(self, d, args, registries, stdin=''):
        p = pathlib.Path(d)
        cl = {'metadata': {'name': 'roy-test'}, 'spec': {'kubernetesVersion': 'v1.36.6+rke2r1', 'rkeConfig': {'registries': registries}}}
        (p / 'cluster.json').write_text(json.dumps(cl))
        (p / 'list.json').write_text(json.dumps({'items': [cl, {'metadata': {'name': 'imported'}, 'spec': {}}]}))
        reg = base64.b64encode(json.dumps({'configs': {}, 'mirrors': None}).encode()).decode()
        plan = {'files': [{'path': '/etc/rancher/rke2/registries.yaml', 'content': reg}]}
        (p / 'plan.b64').write_text(base64.b64encode(json.dumps(plan).encode()).decode())
        (p / 'kubectl').write_text(FAKE); (p / 'kubectl').chmod(0o755)
        (p / 'bin').mkdir(exist_ok=True); (p / 'bin' / 'curl').write_text('#!/bin/sh\nexit 0\n'); (p / 'bin' / 'curl').chmod(0o755)
        env = {**os.environ, 'D': d, 'KUBECTL': f'{d}/kubectl', 'ENDPOINTS': EPS, 'LOG_DIR': f'{d}/log',
               'PATH': f'{d}/bin:' + os.environ['PATH']}
        return subprocess.run(['bash', str(SCRIPT), '--repo', *args], input=stdin, text=True, capture_output=True, env=env)
    def test_menu_update_then_reset(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, [], {'configs': {'x': {}}}, stdin='1\n1\n')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('roy-test', r.stdout); self.assertNotIn('imported', r.stdout)
            self.assertIn('NO MIRROR', r.stdout)
            self.assertIn('previous registries of roy-test: {"configs":{"x":{}}}', r.stdout)
            patch = (pathlib.Path(d) / 'patches').read_text()
            self.assertIn('--type merge', patch)
            body = json.loads(patch.split(' -p ', 1)[1])
            self.assertEqual(body['spec']['rkeConfig']['registries']['mirrors'], mirrors(EPS))
            r = self.run_it(d, ['roy-test', 'reset'], {'configs': {'*': {'insecureSkipVerify': True}}, 'mirrors': mirrors(EPS)})
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('Reset roy-test', r.stdout)
            last = (pathlib.Path(d) / 'patches').read_text().splitlines()[-1]
            self.assertIn('--type json', last)
            self.assertEqual(json.loads(last.split(' -p ', 1)[1]), [{'op': 'add', 'path': '/spec/rkeConfig/registries', 'value': {}}])
            n = len((pathlib.Path(d) / 'patches').read_text().splitlines())
            r = self.run_it(d, ['roy-test', 'reset'], {})
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('Nothing to reset', r.stdout)
            self.assertEqual(len((pathlib.Path(d) / 'patches').read_text().splitlines()), n)   # no patch when already empty
    def test_already_up_to_date_is_noop(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, ['roy-test', 'update'], {'mirrors': mirrors(EPS)})
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('Already up to date', r.stdout)
            self.assertFalse((pathlib.Path(d) / 'patches').exists())
    def test_default_vip_and_normalize(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p/'vip.txt').write_text('cubesys.controller.ip = 10.0.0.5\ncubesys.control.vip = 10.0.0.100\n')
            (p/'single.txt').write_text('cubesys.controller.ip = 10.0.0.5\n')
            env = {k: v for k, v in os.environ.items() if k != 'ENDPOINTS'}
            code = ('SETTINGS=$D/vip.txt endpoints </dev/null; SETTINGS=$D/single.txt endpoints </dev/null; '
                    'SETTINGS=$D/none endpoints </dev/null; echo "[$(SETTINGS=$D/none endpoints </dev/null)]"; '
                    'ENDPOINTS="10.1.1.1 http://r.local:5000/ https://h" endpoints')
            r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"\n' + code], text=True, capture_output=True, env={**env, 'D': d})
            lines = r.stdout.splitlines()
            self.assertEqual(lines[0], 'http://10.0.0.100:5080')
            self.assertEqual(lines[1], 'http://10.0.0.5:5080')
            self.assertIn('[]', lines)
            self.assertEqual(lines[-1], 'http://10.1.1.1:5080 http://r.local:5000 https://h:5080')
    def test_host_choice(self):
        code = ('for c in "" 1 "2 4" "6,7" "3 3 1" "2 9"; do echo "[$(hosts_from_choice "$c" 2>&1)]"; done; '
                'echo "[$(pick_hosts </dev/null)]"; echo "[$(MIRROR_HOSTS="quay.io" pick_hosts)]"')
        r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"\n' + code], text=True, capture_output=True)
        a = ' '.join(ALL)
        self.assertEqual(r.stdout.splitlines(), [f'[{a}]', f'[{a}]', '[docker.io quay.io]', '[registry.k8s.io registry.rancher.com]',
                                                 f'[{a}]', '[ERROR: invalid choice: 9]', f'[{a}]', '[quay.io]'])
    def test_update_selected_hosts_only(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ['MIRROR_HOSTS'] = 'docker.io registry.k8s.io'
            try: r = self.run_it(d, ['roy-test', 'update'], {})
            finally: del os.environ['MIRROR_HOSTS']
            self.assertEqual(r.returncode, 0, r.stderr)
            body = json.loads((pathlib.Path(d) / 'patches').read_text().split(' -p ', 1)[1])
            self.assertEqual(body['spec']['rkeConfig']['registries']['mirrors'], mirrors(EPS, ['docker.io', 'registry.k8s.io']))
if __name__ == '__main__':
    unittest.main()
