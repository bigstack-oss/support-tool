#!/usr/bin/env python3
"""No cluster: fake kubectl/openstack/ssh; --node-cmd on all / named machines, failure summary, no k8s-status copy."""
import base64, io, json, os, pathlib, subprocess, tarfile, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
MS = {'fw-master-a': '192.168.1.11', 'fw-worker-b': '192.168.1.12', 'fw-worker-c': '192.168.1.13'}   # c never joined
KUBECTL = r'''#!/usr/bin/env bash
case "$*" in
  *"get clusters.provisioning.cattle.io -o json"*) echo '{"items":[{"metadata":{"name":"fw"},"spec":{"kubernetesVersion":"v1.33","rkeConfig":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}';;
  *"get clusters.provisioning.cattle.io fw"*) echo '{"metadata":{"name":"fw"}}';;
  *"get machines.cluster.x-k8s.io -l cluster.x-k8s.io/cluster-name=fw"*) cat "$D/machines.json";;
  *"get secret "*"-machine-state"*) a="$*"; m=${a#*get secret }; cat "$D/state-${m%%-machine-state*}.b64";;
  *"get machines.cluster.x-k8s.io fw-"*) echo '{"spec":{"infrastructureRef":{"kind":"OpenstackMachine","apiGroup":"rke-machine.cattle.io","name":"x"}}}';;
  *"sshUser"*) echo ubuntu;;
  *"sshPort"*) echo 22;;
  *) exit 1;;
esac
'''
OPENSTACK = '#!/usr/bin/env bash\nexit 0\n'   # no floating IPs: the driver IP is used
SSH = r'''#!/usr/bin/env bash
a=("$@"); for i in "${!a[@]}"; do [[ ${a[$i]} == -- ]] && ip=${a[$((i+1))]} && cmd=${a[*]:$((i+2))}; done
echo "$ip $cmd" >> "$D/ssh.log"; echo "out from $ip"
[[ -n ${RUN_REMOTE:-} ]] && { sudo() { "$@"; }; export -f sudo; bash -c "$cmd"; exit; }
[[ $ip != "${FAIL_IP:-none}" ]]
'''
SCP = '#!/usr/bin/env bash\ntouch "$D/scp.called"\n'
def state(m, ip):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as t:
        for name, data in [('id_rsa', b'KEY\n'), ('config.json', json.dumps({'Driver': {'IPAddress': ip, 'MachineId': 'srv-' + m}}).encode())]:
            ti = tarfile.TarInfo(f'/x/machines/{m}/{name}'); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    return base64.b64encode(buf.getvalue()).decode()
class NodeCmdTests(unittest.TestCase):
    def run_it(self, d, *args, env_extra=None):
        p = pathlib.Path(d); b = p / 'bin'; b.mkdir(exist_ok=True)
        for m, ip in MS.items(): (p / f'state-{m}.b64').write_text(state(m, ip))
        (p / 'machines.json').write_text(json.dumps({'items': [
            {'metadata': {'name': m}, 'status': {'phase': 'Running', **({'nodeRef': {'name': m}} if m != 'fw-worker-c' else {})}} for m in MS]}))
        for n, body in [('kubectl', KUBECTL), ('openstack', OPENSTACK), ('ssh', SSH), ('scp', SCP)]:
            (b / n).write_text(body); (b / n).chmod(0o755)
        env = {**os.environ, 'D': d, 'KUBECTL': f'{b}/kubectl', 'KEY_DIR': f'{d}/keys', 'LOG_DIR': f'{d}/log',
               'OS_AUTH_URL': 'x', 'PATH': f'{b}:' + os.environ['PATH'], **(env_extra or {})}
        return subprocess.run(['bash', str(SCRIPT), '--node-cmd', *args], input='', text=True, capture_output=True, env=env)
    def test_all_runs_on_joined_machines_only(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, 'fw', 'all', '--', 'sudo ip r get 10.32.2.49')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual((pathlib.Path(d) / 'ssh.log').read_text().splitlines(),
                             ['192.168.1.11 sudo ip r get 10.32.2.49', '192.168.1.12 sudo ip r get 10.32.2.49'])
            self.assertIn('== fw-master-a\n', r.stdout); self.assertIn('   out from 192.168.1.12', r.stdout)
            self.assertNotIn('fw-worker-c', r.stdout)
            self.assertIn('2/2 ok', r.stdout)
            self.assertFalse((pathlib.Path(d) / 'scp.called').exists())       # no k8s-status.sh copy
            self.assertTrue(any((pathlib.Path(d) / 'log').glob('rancher-operation-node-cmd-fw-*.log')))
    def test_named_machines_and_failure_summary(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, 'fw', 'fw-worker-b', 'fw-master-a', '--', 'hostname', env_extra={'FAIL_IP': '192.168.1.12'})
            self.assertEqual(r.returncode, 1)
            self.assertEqual([l.split()[0] for l in (pathlib.Path(d) / 'ssh.log').read_text().splitlines()],
                             ['192.168.1.12', '192.168.1.11'])                  # order given, continues after a failure
            self.assertIn('1/2 ok', r.stdout); self.assertIn('FAILED: fw-worker-b (rc 1)', r.stdout)
    def test_unknown_machine_does_not_stop_the_rest(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, 'fw', 'nope', 'fw-master-a', '--', 'hostname')
            self.assertEqual(r.returncode, 1)
            self.assertIn('no SSH key in secret', r.stdout); self.assertIn('1/2 ok', r.stdout)
            self.assertIn('192.168.1.11 hostname', (pathlib.Path(d) / 'ssh.log').read_text())
    def test_command_required(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, 'fw', 'all')
            self.assertNotEqual(r.returncode, 0); self.assertIn('--node-cmd [CLUSTER] [MACHINE...|all] [-- COMMAND | --bash SCRIPT [ARG...]]', r.stderr)
            self.assertFalse((pathlib.Path(d) / 'ssh.log').exists())
    def test_bash_script_runs_with_quoted_args(self):
        with tempfile.TemporaryDirectory() as d:
            sc = pathlib.Path(d) / 'test.sh'
            sc.write_text('echo "script on $(hostname -s >/dev/null; echo node) argc=$# a1=[$1] a2=[$2]"\n')
            r = self.run_it(d, 'fw', 'fw-master-a', '--bash', str(sc), '10.32.0.0/16', 'two words', env_extra={'RUN_REMOTE': '1'})
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('   script on node argc=2 a1=[10.32.0.0/16] a2=[two words]', r.stdout)
            self.assertIn("192.168.1.11 sudo bash -s -- 10.32.0.0/16 two\\ words", (pathlib.Path(d) / 'ssh.log').read_text())
    def test_bash_missing_script(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, 'fw', 'all', '--bash', f'{d}/nope.sh')
            self.assertNotEqual(r.returncode, 0); self.assertIn('--bash needs a readable local script', r.stderr)
            self.assertFalse((pathlib.Path(d) / 'ssh.log').exists())
    def run_tty(self, d, answers):
        """No arguments, stdin a terminal: answer the prompts."""
        import pty
        self.run_it(d, 'fw', 'all')                                   # writes the fakes; fails (no command, no tty)
        p = pathlib.Path(d); b = p / 'bin'
        env = {**os.environ, 'D': d, 'KUBECTL': f'{b}/kubectl', 'KEY_DIR': f'{d}/keys', 'LOG_DIR': f'{d}/log',
               'OS_AUTH_URL': 'x', 'PATH': f'{b}:' + os.environ['PATH']}
        mfd, sfd = pty.openpty()
        os.write(mfd, answers.encode())
        r = subprocess.run(['bash', str(SCRIPT), '--node-cmd'], stdin=sfd, text=True, capture_output=True, env=env, timeout=60)
        os.close(sfd); os.close(mfd)
        return r
    def test_interactive_all_and_confirm(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_tty(d, '1\na\nhostname -s\ny\n')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('  a  ALL machines that joined the cluster', r.stdout)
            self.assertIn('Cluster fw, 2 machine(s): fw-master-a fw-worker-b', r.stdout)
            self.assertIn('Run: hostname -s', r.stdout); self.assertIn('2/2 ok', r.stdout)
            self.assertEqual(len((pathlib.Path(d) / 'ssh.log').read_text().splitlines()), 2)
    def test_interactive_pick_numbers_and_decline(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_tty(d, '1\n3 1\nsudo reboot\nn\n')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('2 machine(s): fw-worker-c fw-master-a', r.stdout)   # numbers in the order typed
            self.assertIn('Nothing run.', r.stdout); self.assertFalse((pathlib.Path(d) / 'ssh.log').exists())
if __name__ == '__main__':
    unittest.main()
