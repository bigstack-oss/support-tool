#!/usr/bin/env python3
"""No cluster: fake kubectl/openstack/ssh; check key extraction, sshUser/port, FIP lookup, fallback IP, ssh args."""
import base64, io, json, os, pathlib, subprocess, tarfile, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
M = 'runai-gpu-g4lj9-5j7fc'
KUBECTL = r'''#!/usr/bin/env bash
case "$*" in
  *"get clusters.provisioning.cattle.io runai"*) echo '{"metadata":{"name":"runai"}}';;
  *"get secret $M-machine-state"*) cat "$D/state.b64";;
  *"get machines.cluster.x-k8s.io $M"*) echo '{"spec":{"infrastructureRef":{"kind":"OpenstackMachine","apiGroup":"rke-machine.cattle.io","name":"'$M'"}}}';;
  *"OpenstackMachine.rke-machine.cattle.io $M"*"sshUser"*) echo "${SSH_USER:-ubuntu}";;
  *"OpenstackMachine.rke-machine.cattle.io $M"*"sshPort"*) echo 2222;;
  *) exit 1;;
esac
'''
OPENSTACK = r'''#!/usr/bin/env bash
echo "$*" >> "$D/os.log"
[[ -n ${NO_FIP:-} ]] && exit 0
case "$*" in
  "server list"*) echo srv-1; [[ -n ${DUP:-} ]] && echo srv-2;;
  "port list --server srv-1"*) printf 'p1\np2\n';;
  "floating ip list --port p2"*) echo 10.170.52.88;;
esac
'''
SSH = '#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$D/ssh.args"\n'
SCP = '#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$D/scp.args"\n[[ -z ${SCP_FAIL:-} ]]\n'
DRIVER = {'IPAddress': '192.168.1.9', 'SSHUser': 'x', 'SSHPort': 22, 'MachineId': 'srv-1', 'TenantId': 'proj-1'}
def state(driver=DRIVER):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as t:
        for name, data in [('id_rsa', b'-----BEGIN KEY-----\nabc\n'), ('config.json', json.dumps({'Driver': driver}).encode())]:
            ti = tarfile.TarInfo(f'/home/machine/.docker/machine/machines/{M}/{name}'); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    return base64.b64encode(buf.getvalue()).decode()
class NodeConnectTests(unittest.TestCase):
    def run_it(self, d, extra_env=None, *args, pos=('runai', M), driver=DRIVER):
        p = pathlib.Path(d); b = p / 'bin'; b.mkdir(exist_ok=True)
        (p / 'state.b64').write_text(state(driver))
        for n, body in [('kubectl', KUBECTL), ('openstack', OPENSTACK), ('ssh', SSH), ('scp', SCP)]:
            (b / n).write_text(body); (b / n).chmod(0o755)
        env = {**os.environ, 'D': d, 'M': M, 'KUBECTL': f'{b}/kubectl', 'KEY_DIR': d, 'LOG_DIR': f'{d}/log',
               'OS_AUTH_URL': 'x', 'PATH': f'{b}:' + os.environ['PATH'], **(extra_env or {})}
        return subprocess.run(['bash', str(SCRIPT), '--connect', *pos, *args], input='', text=True, capture_output=True, env=env)
    def test_fip_user_port_key_and_command(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, None, '--', 'sudo', 'bash', 'k8s-status.sh')
            self.assertEqual(r.returncode, 0, r.stderr)
            key = pathlib.Path(d) / f'{M}-id_rsa'
            self.assertEqual(key.read_text(), '-----BEGIN KEY-----\nabc\n')
            self.assertEqual(oct(key.stat().st_mode & 0o777), '0o600')
            args = (pathlib.Path(d) / 'ssh.args').read_text().splitlines()
            self.assertEqual(args[:2], ['-i', str(key)]); self.assertEqual(args[2:4], ['-p', '2222'])
            self.assertEqual(args[args.index('-l') + 1], 'ubuntu')
            self.assertEqual(args[args.index('--') + 1], '10.170.52.88')              # destination after --, user via -l
            self.assertIn('StrictHostKeyChecking=accept-new', args); self.assertIn(f'UserKnownHostsFile={d}/{M}-known_hosts', args)
            self.assertEqual(args[-3:], ['sudo', 'bash', 'k8s-status.sh'])
            os_log = (pathlib.Path(d) / 'os.log').read_text()
            self.assertNotIn('server list', os_log); self.assertIn('port list --server srv-1', os_log)   # by server ID, no name search
            self.assertIn(f'runai {M} ubuntu@10.170.52.88:2222', (pathlib.Path(d) / 'log/rancher-node-connect.log').read_text())
    def test_no_fip_falls_back_to_driver_ip(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, {'NO_FIP': '1'})
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('using the IP Rancher uses: 192.168.1.9', r.stderr)
            args = (pathlib.Path(d) / 'ssh.args').read_text().splitlines()
            self.assertEqual(args[-2:], ['--', '192.168.1.9'])                    # login shell: no remote command
    def test_command_after_dashdash_is_not_a_name(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, None, '--', 'hostname', pos=('runai',))   # MACHINE missing: must prompt, not use 'hostname'
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('hostname-machine-state', r.stderr)
    def test_refuses_symlinked_key_dir(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as other:
            link = pathlib.Path(d) / 'keys'; link.symlink_to(other)
            r = self.run_it(d, {'KEY_DIR': str(link)})
            self.assertNotEqual(r.returncode, 0); self.assertIn('is not a private directory', r.stderr)
            self.assertEqual(list(pathlib.Path(other).iterdir()), [])          # nothing written through the link
    def test_copies_k8s_status_before_ssh(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d)
            self.assertEqual(r.returncode, 0, r.stderr)
            a = (pathlib.Path(d) / 'scp.args').read_text().splitlines()
            self.assertEqual(a[-3:], ['--', str(SCRIPT.parent / 'k8s-status.sh'), '10.170.52.88:k8s-status.sh'])
            self.assertIn('User=ubuntu', a)
            self.assertIn('-P', a); self.assertEqual(a[a.index('-P') + 1], '2222')
            self.assertIn(f'UserKnownHostsFile={d}/{M}-known_hosts', a)
            self.assertIn('copied k8s-status.sh', r.stdout)
    def test_scp_failure_or_missing_file_still_connects(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, {'SCP_FAIL': '1'})
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('connecting anyway', r.stderr)
            self.assertTrue((pathlib.Path(d) / 'ssh.args').exists())
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, {'K8S_STATUS': '/nonexistent/k8s-status.sh'})
            self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('not found; not copied', r.stderr)
            self.assertFalse((pathlib.Path(d) / 'scp.args').exists()); self.assertTrue((pathlib.Path(d) / 'ssh.args').exists())
    def test_unsafe_ssh_user_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, {'SSH_USER': '-oProxyCommand=touch /tmp/pwn'})
            self.assertNotEqual(r.returncode, 0); self.assertIn("refusing sshUser", r.stderr)
            self.assertFalse((pathlib.Path(d) / 'ssh.args').exists()); self.assertFalse((pathlib.Path(d) / 'scp.args').exists())
    def test_name_search_only_without_id_and_never_ambiguous(self):
        no_id = {k: v for k, v in DRIVER.items() if k != 'MachineId'}
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, None, driver=no_id)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(f'server list --all-projects --project proj-1 --name ^{M}$', (pathlib.Path(d) / 'os.log').read_text())
            self.assertEqual((pathlib.Path(d) / 'ssh.args').read_text().splitlines()[-1], '10.170.52.88')
        with tempfile.TemporaryDirectory() as d:
            r = self.run_it(d, {'DUP': '1'}, driver=no_id)
            self.assertIn('2 OpenStack servers named', r.stderr); self.assertIn('using the IP Rancher uses: 192.168.1.9', r.stderr)
            self.assertEqual((pathlib.Path(d) / 'ssh.args').read_text().splitlines()[-1], '192.168.1.9')
if __name__ == '__main__':
    unittest.main()
