#!/usr/bin/env python3
"""No network: stub skopeo/cubectl; check ref mapping, download resume/failure, upload to every controller."""
import os, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rancher-operation.sh'
def run(code, **env):
    return subprocess.run(['bash', '-c', f'source "{SCRIPT}"\n' + code], text=True, capture_output=True, env={**os.environ, **env})
class OfflineImagesTests(unittest.TestCase):
    def test_mapping(self):
        r = run('for i in registry.k8s.io/sig-storage/x:1 rancher/y:2 nginx:3 docker.io/rancher/z:4 quay.io/a/b:5; do echo "$(source_ref $i) $(dest_path $i)"; done')
        self.assertEqual(r.stdout.split('\n')[:5], [
            'registry.k8s.io/sig-storage/x:1 sig-storage/x:1', 'docker.io/rancher/y:2 rancher/y:2',
            'docker.io/library/nginx:3 library/nginx:3', 'docker.io/rancher/z:4 rancher/z:4', 'quay.io/a/b:5 a/b:5'])
    def test_download_resume_failure_and_upload(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d); (p/'list.txt').write_text('# comment\nregistry.k8s.io/sig-storage/x:1\nrancher/y:2\nbad/fail:9\nnodigest\n')
            stub = r'''skopeo() { echo "$*" >> "$LOG"; case "$*" in *fail:9*) return 1;; *) local a; for a; do case $a in oci-archive:*.part:*) a=${a#oci-archive:}; echo x > "${a%%.part:*}.part";; esac; done;; esac; }
cubectl() { printf 'cc1,10.0.0.1,control-converged\ncc2,10.0.0.2,control\ncp1,10.0.0.9,compute\n'; }
'''
            env = dict(LOG=str(p/'log'), SETTINGS=str(p/'no-settings'))   # use the cubectl stub, not the host's settings.txt
            r = run(stub + f'download "{d}/list.txt" "{d}/pkg"', **env)
            self.assertNotEqual(r.returncode, 0); self.assertIn('1 image(s) failed: docker.io/bad/fail:9', r.stderr)
            self.assertIn('skip (need name:tag): nodigest', r.stderr)
            tsv = (p/'pkg/images.tsv').read_text()
            self.assertIn('sig-storage/x:1\timages/sig-storage_x_1.tar', tsv); self.assertIn('rancher/y:2\timages/rancher_y_2.tar', tsv)
            self.assertIn('images/rancher_y_2.tar', (p/'pkg/SHA256SUMS').read_text())
            (p/'log').write_text('')
            run(stub + f'download "{d}/list.txt" "{d}/pkg"', **env)            # resume: existing archives not fetched again
            self.assertNotIn('sig-storage/x:1', (p/'log').read_text())
            (p/'log').write_text('')
            r = run(stub + f'upload "{d}/pkg"', **env)
            self.assertEqual(r.returncode, 0, r.stderr)
            log = (p/'log').read_text()
            for ip in ('10.0.0.1', '10.0.0.2'): self.assertIn(f'docker://{ip}:5080/sig-storage/x:1', log)
            self.assertNotIn('10.0.0.9', log)
    def test_controllers_from_settings(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p/'ha.txt').write_text('cubesys.control.vip = 10.0.0.100\ncubesys.control.addrs = 10.0.0.1,10.0.0.2,10.0.0.3\ncubesys.controller.ip = 10.0.0.100\n')
            (p/'one.txt').write_text('cubesys.controller.ip = 10.0.0.5\n')
            r = run('cubectl() { echo "cc9,10.0.0.9,control"; }; for f in ha.txt one.txt none; do echo "$(SETTINGS=$D/$f controllers | tr "\\n" " ")"; done', D=d)
            self.assertEqual(r.stdout.splitlines(), ['10.0.0.1 10.0.0.2 10.0.0.3 ', '10.0.0.5 ', '10.0.0.9 '])
    def test_verify(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p/'list.txt').write_text('# c\nrancher/a:1\nregistry.k8s.io/sig-storage/b:2\ndocker.io/rancher/gone:3\nnginx:4\n')
            (p/'s.txt').write_text('cubesys.control.vip = 10.0.0.100\n')
            stub = r'''curl() { local a u; for a; do u=$a; done; echo "$u" >> "$LOG"
  case $u in */v2/) return 0;; */rancher/a/manifests/1|*/sig-storage/b/manifests/2) echo 200;; *) echo 404;; esac; }
'''
            r = run(stub + f'verify "{d}/list.txt" "{d}/miss.txt"', LOG=str(p/'log'), SETTINGS=str(p/'s.txt'))
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('2/4 ok on http://10.0.0.100:5080', r.stdout)
            self.assertIn('MISSING docker.io/rancher/gone:3  (HTTP 404)', r.stdout)
            self.assertEqual((p/'miss.txt').read_text().split(), ['docker.io/rancher/gone:3', 'docker.io/library/nginx:4'])
            self.assertIn('http://10.0.0.100:5080/v2/library/nginx/manifests/4', (p/'log').read_text())
            (p/'all.txt').write_text('rancher/a:1\n')
            r = run(stub + f'verify "{d}/all.txt"', LOG=str(p/'log'), SETTINGS=str(p/'s.txt'))
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr); self.assertIn('1/1 ok', r.stdout)
if __name__ == '__main__':
    unittest.main()
