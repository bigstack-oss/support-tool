#!/usr/bin/env python3
"""No cluster: fake kubectl serves CAPI objects; check stale MachineSet detection, diff, safety rule, delete, watch hint."""
import json, os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
FAKE = r'''#!/usr/bin/env bash
case "$*" in
  *"get secret runai-kubeconfig"*) [[ -f $D/dpods.json ]] && echo ZmFrZQ== || exit 1;;
  *"--kubeconfig"*"get pods -A"*) cat "$D/dpods.json";;
  *"--kubeconfig"*"get operations.catalog.cattle.io"*) cat "$D/ops.json";;
  *"--kubeconfig"*"get secrets -l owner=helm,name=rancher-webhook"*) printf '1 deployed\n';;
  *"--kubeconfig"*"get secrets -l owner=helm"*) ;;
  *"--kubeconfig"*" logs helm-operation-4zkvk -c helm"*) echo 'Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress';;
  *"--kubeconfig"*delete*) a="$*"; printf '%s\n' "${a##*--request-timeout=10s }" >> "$D/ddeleted";;
  *"get clusters.provisioning.cattle.io runai"*) cat "$D/cluster.json";;
  *"get machinedeployments"*) cat "$D/md.json";;
  *"get machinesets"*) cat "$D/ms.json";;
  *"get machines.cluster"*) cat "$D/m.json";;
  *"get OpenstackMachineTemplate.rke-machine.cattle.io "*) a="$*"; n=${a##*OpenstackMachineTemplate.rke-machine.cattle.io }; cat "$D/t-${n%% *}.json";;
  *"get pods"*) echo '{"items":[]}';;
  *delete*) printf '%s\n' "$*" >> "$D/deleted";;
  *) exit 1;;
esac
'''
REF = lambda n: {'apiVersion': 'rke-machine.cattle.io/v1', 'kind': 'OpenstackMachineTemplate', 'name': n}
REF2 = lambda n: {'apiGroup': 'rke-machine.cattle.io', 'kind': 'OpenstackMachineTemplate', 'name': n}   # CAPI v1beta2 (Rancher 2.15)
def tmpl(sg, pw):
    return {'spec': {'template': {'spec': {'secGroups': sg, 'flavorName': 'gpu', 'password': pw, 'userDataFile': '#cloud-config ' + pw}}}}
class CleanupTests(unittest.TestCase):
    def setup(self, d, stale=True):
        p = pathlib.Path(d); w = lambda n, o: (p / n).write_text(json.dumps(o))
        w('cluster.json', {'metadata': {'name': 'runai'}, 'status': {'conditions': []}})
        w('md.json', {'items': [{'metadata': {'name': 'runai-gpu'}, 'spec': {'template': {'spec': {'infrastructureRef': REF('gpu-new')}}}},
                                {'metadata': {'name': 'runai-control'}, 'spec': {'template': {'spec': {'infrastructureRef': REF('ctl-new')}}}}]})
        sets = [{'metadata': {'name': 'runai-gpu-dffn5', 'labels': {'cluster.x-k8s.io/deployment-name': 'runai-gpu'}},
                 'spec': {'template': {'spec': {'infrastructureRef': REF('gpu-new')}}}, 'status': {}}]
        if stale:
            sets += [{'metadata': {'name': 'runai-gpu-55nbv', 'labels': {'cluster.x-k8s.io/deployment-name': 'runai-gpu'}},
                      'spec': {'template': {'spec': {'infrastructureRef': REF2('gpu-old')}}}, 'status': {'readyReplicas': 0}},
                     {'metadata': {'name': 'runai-control-old', 'labels': {'cluster.x-k8s.io/deployment-name': 'runai-control'}},
                      'spec': {'template': {'spec': {'infrastructureRef': REF('ctl-old')}}}, 'status': {}}]
        w('ms.json', {'items': sets})
        # control-old has a machine that joined the cluster (nodeRef) although not Ready now: must be kept
        w('m.json', {'items': [{'metadata': {'name': 'runai-control-old-a', 'labels': {'cluster.x-k8s.io/set-name': 'runai-control-old'}},
                                'status': {'phase': 'Running', 'nodeRef': {'name': 'n1'}}},
                               {'metadata': {'name': 'runai-gpu-55nbv-x', 'labels': {'cluster.x-k8s.io/set-name': 'runai-gpu-55nbv'}},
                                'status': {'phase': 'Provisioning'}}]})
        w('t-gpu-old.json', tmpl('defaultmdefault-k8s', 'old-secret')); w('t-gpu-new.json', tmpl('default,default-k8s', 'new-secret'))
        w('t-ctl-old.json', tmpl('default', 'x')); w('t-ctl-new.json', tmpl('default,default-k8s', 'x'))
        (p / 'kubectl').write_text(FAKE); (p / 'kubectl').chmod(0o755)
        return {**os.environ, 'D': d, 'KUBECTL': f'{d}/kubectl', 'LOG_DIR': f'{d}/log'}
    def run_it(self, env, *args, stdin=''):
        return subprocess.run(['bash', str(SCRIPT), '--cleanup', *args], input=stdin, text=True, capture_output=True, env=env)
    def test_yes_deletes_only_never_joined_sets(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(self.setup(d), 'runai', '--yes')
            o = r.stdout
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('== MachineSet runai-gpu-55nbv (pool runai-gpu): template gpu-old, current gpu-new', o)
            self.assertIn('secGroups: "defaultmdefault-k8s" -> "default,default-k8s"', o)
            self.assertIn('password: *** -> ***', o); self.assertNotIn('secret', o)
            self.assertIn('userDataFile: *** -> ***', o)                        # user data may carry secrets
            self.assertEqual(oct(next((pathlib.Path(d) / 'log').glob('*.log')).stat().st_mode & 0o777), '0o600')
            self.assertNotIn('flavorName', o)                                   # unchanged fields hidden
            self.assertIn('KEEP   0 ready, 1 joined', o)
            self.assertNotIn('runai-gpu-dffn5 (pool', o)                        # current set not listed
            self.assertEqual((pathlib.Path(d) / 'deleted').read_text().split('delete ')[1].split()[:2],
                             ['machinesets.cluster.x-k8s.io', 'runai-gpu-55nbv'])
            self.assertEqual(len((pathlib.Path(d) / 'deleted').read_text().splitlines()), 1)
    def test_no_terminal_no_yes_deletes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(self.setup(d), 'runai')
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('re-run with --yes', r.stdout)
            self.assertFalse((pathlib.Path(d) / 'deleted').exists())
    def test_nothing_stale(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(self.setup(d, stale=False), 'runai', '--yes')
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('No stale MachineSets in runai', r.stdout)
            self.assertFalse((pathlib.Path(d) / 'deleted').exists())
    def test_watch_hint(self):
        with tempfile.TemporaryDirectory() as d:
            env = self.setup(d)
            r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"; step runai; step runai'], text=True, capture_output=True, env=env)
            self.assertEqual(r.stdout.count('[WARN ] MachineSet runai-gpu-55nbv still builds machines from old template gpu-old'), 1, r.stdout)
            self.assertIn('bash ', r.stdout); self.assertIn('--cleanup runai', r.stdout)
            self.assertIn('MachineSet runai-control-old on old template ctl-old is being rolled out', r.stdout)
    def helmops(self, d):
        import datetime
        env = self.setup(d, stale=False); p = pathlib.Path(d); w = lambda n, o: (p / n).write_text(json.dumps(o))
        recent = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        def pod(name, exit_code, fin, proxy_running=True, phase='Running'):
            return {'metadata': {'namespace': 'cattle-system', 'name': name}, 'status': {'phase': phase, 'containerStatuses': [
                {'name': 'helm', 'state': {'terminated': {'exitCode': exit_code, 'finishedAt': fin}}},
                {'name': 'proxy', 'state': {'running': {}} if proxy_running else {'terminated': {'exitCode': 0}}}]}}
        w('dpods.json', {'items': [pod('helm-operation-4zkvk', 123, '2026-11-26T06:39:20Z'),          # stuck
                                   pod('helm-operation-new01', 0, recent),                          # proxy still shutting down
                                   pod('helm-operation-mj66q', 0, '2026-11-26T06:42:35Z', False, 'Succeeded'),
                                   {'metadata': {'namespace': 'x', 'name': 'web'}, 'status': {'phase': 'Running'}}]})
        w('ops.json', {'items': [{'status': {'podName': 'helm-operation-4zkvk', 'releaseName': 'rancher-webhook', 'namespace': 'cattle-system'}}]})
        return env
    def test_stuck_helm_operation_listed_and_deleted(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(self.helmops(d), 'runai', '--yes')
            o = r.stdout
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('== helm operation cattle-system/helm-operation-4zkvk: helm exited 123 at 2026-11-26T06:39:20Z', o)
            self.assertIn('release rancher-webhook (cattle-system) is now: deployed (revision 1)', o)
            self.assertIn('another operation (install/upgrade/rollback) is in progress', o)
            self.assertNotIn('WARN   release', o)
            self.assertNotIn('new01', o); self.assertNotIn('mj66q', o)
            self.assertEqual((pathlib.Path(d) / 'ddeleted').read_text().split(), ['-n', 'cattle-system', 'delete', 'pod', 'helm-operation-4zkvk', '--wait=false'])
            self.assertFalse(any(pathlib.Path(d).glob('tmp*')))
    def test_stuck_helm_operation_needs_yes(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(self.helmops(d), 'runai')
            self.assertIn('re-run with --yes to delete 1 stuck helm-operation pod(s): cattle-system/helm-operation-4zkvk', r.stdout)
            self.assertFalse((pathlib.Path(d) / 'ddeleted').exists())
    def test_watch_warns_stuck_helm_operation_once(self):
        with tempfile.TemporaryDirectory() as d:
            env = self.helmops(d)
            r = subprocess.run(['bash', '-c', f'source "{SCRIPT}"; step runai; step runai'], text=True, capture_output=True, env=env)
            self.assertEqual(r.stdout.count('[WARN ] helm operation helm-operation-4zkvk (rancher-webhook) is over'), 1, r.stdout)
            self.assertIn('release now: deployed (revision 1); remove: bash ', r.stdout)
if __name__ == '__main__':
    unittest.main()
