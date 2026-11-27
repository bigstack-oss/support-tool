#!/usr/bin/env python3
"""No cluster access: stub `k` with JSON fixtures and drive step() through a provisioning sequence."""
import base64, gzip, json, os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
STUB = r'''k() { case "$*" in
  *clusters.provisioning*) cat "$D/cluster.json";;
  *machines.cluster*) cat "$D/machines.json";;
  *"get secret"*) cat "$D/secret.json" 2>/dev/null || return 1;;
  *"get pods"*) cat "$D/pods.json";;
  *logs*) printf 'Creating machine...\nerror creating machine: parse " http://x:5000/v3": bad\n';;
esac; }
'''
def cluster(msg, ready='Unknown'):
    return {'status': {'conditions': [{'type': 'Updated', 'status': 'Unknown', 'message': msg},
                                      {'type': 'Ready', 'status': ready, 'message': msg}]}}
class WatchTests(unittest.TestCase):
    def test_sequence(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d); w = lambda n, o: (p / n).write_text(json.dumps(o))
            w('machines.json', {'items': [{'metadata': {'name': 'v12-pool1-a'}, 'status': {'phase': 'Provisioning'}}]})
            w('pods.json', {'items': [{'metadata': {'name': 'v12-pool1-a-machine-provision-x'}, 'status': {'phase': 'Failed'}}]})
            out = gzip.compress(b'line1\nrke2 install failed: image not found\n')
            enc = lambda b: base64.b64encode(b).decode()
            w('secret.json', {'data': {'failed-checksum': enc(b'abc'), 'failure-count': enc(b'1'), 'failed-output': enc(out)}})
            steps = [cluster('waiting for agent to check in'), cluster('waiting for agent to check in'),
                     cluster('waiting for probes: etcd'), cluster('done', 'True')]
            code = STUB
            for i, c in enumerate(steps):
                code += f"cp '{d}/c{i}.json' '{d}/cluster.json'; step v12; echo RC=$?\n"
                (p / f'c{i}.json').write_text(json.dumps(c))
            r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"\n' + code], text=True, capture_output=True, env={**os.environ, 'D': d})
            o = r.stdout
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(o.count('waiting for agent to check in'), 1, o)       # unchanged message printed once
            self.assertIn('[INFO ] waiting for probes: etcd', o)
            self.assertEqual(o.count('machine v12-pool1-a: Provisioning'), 1, o)
            self.assertEqual(o.count('plan failed (failures 1)'), 1, o)
            self.assertIn('rke2 install failed: image not found', o)
            self.assertEqual(o.count('provision job v12-pool1-a-machine-provision-x failed'), 1, o)
            self.assertIn('error creating machine', o)
            self.assertIn('[DONE ] cluster v12 is Ready', o)
            self.assertEqual([l for l in o.splitlines() if l.startswith('RC=')], ['RC=1', 'RC=1', 'RC=1', 'RC=0'])
    def test_missing_cluster(self):
        r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"\nk() {{ return 1; }}; step nope; echo RC=$?'], text=True, capture_output=True)
        self.assertIn('not found', r.stdout); self.assertIn('RC=2', r.stdout)
    def test_pick_when_no_cluster(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p/'list.json').write_text(json.dumps({'items': [
                {'metadata': {'name': 'v35'}, 'spec': {'kubernetesVersion': 'v1.36.6+rke2r1', 'rkeConfig': {}}},
                {'metadata': {'name': 'imported-x'}, 'spec': {}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}}]}))
            (p/'one.json').write_text(json.dumps(cluster('done', 'True')))
            code = '''k() { case "$*" in *"clusters.provisioning.cattle.io -o json") cat "$D/list.json";; *clusters.provisioning*) echo "$*" >> "$D/asked"; cat "$D/one.json";;
  *machines*) echo '{"items":[]}';; *pods*) echo '{"items":[]}';; *) return 1;; esac; }
watch_main --once <<< 2; echo RC=$?'''
            r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"\n' + code], text=True, capture_output=True, env={**os.environ, 'D': d})
            self.assertIn('v35', r.stdout); self.assertIn('imported-x', r.stdout)      # all clusters listed
            self.assertIn('imported-x -o json', (p/'asked').read_text())                 # number 2 picked
            self.assertIn('[DONE ] cluster imported-x is Ready', r.stdout); self.assertIn('RC=0', r.stdout)
if __name__ == '__main__':
    unittest.main()
