#!/usr/bin/env bash
# Run on the target cloud's controller. Menu style follows volume-config.sh.
# Bash + Python 3.6+ + openstack + nova-manage + cinder. No pip modules needed.
set -eo pipefail
# Append a complete transcript while keeping the menu interactive.
# --help does not require access to the controller log directory.
if [[ "${1:-}" != '--help' && "${1:-}" != '-h' ]]; then
    log_file=/var/log/nova/server-metadata-changes.log
    command -v tee >/dev/null || { echo '需要 tee' >&2; exit 1; }
    (umask 077; mkdir -p /var/log/nova; touch "$log_file") ||
        { echo "Cannot create log: $log_file" >&2; exit 1; }
    exec 4>>"$log_file" || { echo "Cannot append log: $log_file" >&2; exit 1; }
    exec 5>&1 6>&2
    exec > >(tee -a "$log_file") 2>&1
    log_tee_pid=$!
    finish_log() {
        log_exit_code=$?
        trap - EXIT
        printf '\n=== END %s pid=%s exit=%s ===\n' "$(date -Is)" "$$" "$log_exit_code"
        exec 1>&5 2>&6
        wait "$log_tee_pid" || {
            echo "Log output failed: $log_file" >&2
            [[ "$log_exit_code" != 0 ]] || log_exit_code=1
        }
        exit "$log_exit_code"
    }
    trap finish_log EXIT
    printf '\n=== START %s host=%s user=%s pid=%s ===\n' "$(date -Is)" "$(hostname)" "$(id -un)" "$$"
    printf 'Script: %s\nLog: %s\nArguments:' "$0" "$log_file"
    printf ' %q' "$@"
    printf '\n'
else
    exec 4>/dev/null
fi
# Load OpenStack environment, like volume-config.sh.
if [[ "${1:-}" != '--help' && "${1:-}" != '-h' ]]; then
    openrc_file="${OPENRC_FILE:-/etc/admin-openrc.sh}"
    [[ -r "$openrc_file" ]] || { echo "Cannot read OpenStack environment: $openrc_file" >&2; exit 1; }
    source "$openrc_file"
fi
set -u
command -v python3 >/dev/null || { echo '需要 python3' >&2; exit 1; }
# Keep terminal input separate from the embedded Python source.
exec 3<&0
python3 -u - "$@" <<'PY'
import argparse
import ast
import json
import os
import re
import time
import shlex
import shutil
import subprocess
import sys

PROFILES = [
    ('Enable QGA and Multiqueue', {
        'hw_qemu_guest_agent': 'yes', 'hw_vif_multiqueue_enabled': 'true'}),
    ('Custom metadata', None),
]


def parse_properties(text):
    properties = {}
    for item in text.split(','):
        key, separator, value = item.strip().partition('=')
        key, value = key.strip(), value.strip()
        if not separator or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.:-]*', key) or not value:
            raise ValueError('請輸入 key=value，以逗號分隔；key 與 value 不可為空。')
        if any(not c.isprintable() for c in value):
            raise ValueError('value 不可包含控制字元。')
        if key in properties:
            raise ValueError('重複的 metadata key：' + key)
        properties[key] = value
    return properties


def select_properties():
    profile = choose('profile', PROFILES, lambda p: p[0])
    if profile[1] is not None:
        return profile[1]
    print('Custom image metadata（值不可包含逗號），例如：')
    print('hw_vif_multiqueue_enabled=true, hw_qemu_guest_agent=yes')
    while True:
        try:
            return parse_properties(ask('Metadata: '))
        except ValueError as error:
            print(str(error))


def matches_property(key, actual, expected):
    # Only normalize known boolean properties; custom strings compare exactly.
    if key in ('hw_qemu_guest_agent', 'hw_vif_multiqueue_enabled'):
        aliases = {'yes': 'true', '1': 'true', 'true': 'true',
                   'no': 'false', '0': 'false', 'false': 'false'}
        return aliases.get(str(actual).lower(), str(actual)) == aliases.get(expected.lower(), expected)
    return str(actual) == expected



def fail(message):
    raise RuntimeError(message)


def field(obj, *names, default=''):
    for name in names:
        if name in obj:
            return obj[name]
    return default


def display(value):
    # Prevent resource names from injecting terminal control sequences.
    return ''.join(c if c.isprintable() else ' ' for c in str(value))


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True)
    os.write(4, ('[COMMAND] {}\n[exit={}]\n{}{}\n'.format(
        ' '.join(shlex.quote(x) for x in args), result.returncode,
        result.stdout, result.stderr)).encode('utf-8'))
    if result.returncode:
        fail('指令失敗 (exit {}): {}\n{}'.format(
            result.returncode, ' '.join(shlex.quote(x) for x in args),
            display(result.stderr.strip() or result.stdout.strip())))
    return result.stdout.strip()


def osc(*args):
    raw = run(['openstack'] + list(args) + ['-f', 'json'])
    try:
        return json.loads(raw)
    except ValueError:
        fail('OpenStack 未回傳有效 JSON；請確認 CLI 版本。')


def structured(value, kind):
    if isinstance(value, kind):
        return value
    if isinstance(value, str):
        for parse in (json.loads, ast.literal_eval):
            try:
                result = parse(value)
                if isinstance(result, kind):
                    return result
            except (ValueError, SyntaxError):
                pass
    fail('無法讀取結構化欄位；請確認 openstack CLI 版本。')


def ask(prompt):
    print(prompt, end='', flush=True)
    answer = INPUT.readline()
    if not answer:
        raise EOFError()
    os.write(4, ('[INPUT] ' + answer.rstrip('\n') + '\n').encode('utf-8'))
    return answer.strip()


def choose(resource, rows, label, auto_single=False):
    if not rows:
        fail('No {} available for selection.'.format(resource))
    if auto_single and len(rows) == 1:
        print('Auto-selected {}: {}'.format(resource, display(label(rows[0]))))
        return rows[0]
    print('\nSelect a {}:'.format(resource))
    for index, row in enumerate(rows, 1):
        print('{}. {}'.format(index, display(label(row))))
    print('0. Exit')
    while True:
        answer = ask('Enter {} number: '.format(resource))
        if answer == '0':
            raise EOFError()
        if answer.isdecimal() and 1 <= int(answer) <= len(rows):
            return rows[int(answer) - 1]
        print('Invalid option. Please try again.')


def check_vm(vm_id, project_id, require_shutoff=True, allow_task=False):
    vm = osc('server', 'show', vm_id)
    if require_shutoff and str(field(vm, 'status', 'Status')).upper() != 'SHUTOFF':
        fail('VM 必須為 SHUTOFF；目前為 {}。請先正常關機再執行。'.format(vm.get('status')))
    if field(vm, 'project_id', 'tenant_id') != project_id:
        fail('VM project 不符或無法確認。')
    task = vm.get('OS-EXT-STS:task_state')
    if not allow_task and task not in (None, '', 'None', 'none', 'null'):
        fail('VM 正在執行其他工作：{}'.format(display(task)))
    return vm


def wait_vm(vm_id, project_id, target, timeout=300):
    deadline = time.monotonic() + timeout
    while True:
        vm = check_vm(vm_id, project_id, require_shutoff=False, allow_task=True)
        status = str(field(vm, 'status', 'Status')).upper()
        task = vm.get('OS-EXT-STS:task_state')
        if status == target and task in (None, '', 'None', 'none', 'null'):
            return vm
        if status not in ('ACTIVE', 'SHUTOFF'):
            fail('等待 {} 時 VM 狀態異常：{}'.format(target, display(status)))
        if time.monotonic() >= deadline:
            fail('等待 VM {} 超過 {} 秒，停止；請檢查 VM 狀態。'.format(target, timeout))
        time.sleep(3)


def disks(vm_id, project_id):
    # Read actual server attachments; never infer the OS disk from list order.
    result = []
    for item in osc('server', 'volume', 'list', vm_id):
        vol_id = field(item, 'Volume ID', 'volume_id')
        if not vol_id:
            fail('掛載清單缺少 Volume ID，停止以避免選錯磁碟。')
        vol = osc('volume', 'show', vol_id)
        owner = field(vol, 'os-vol-tenant-attr:tenant_id', 'project_id')
        if owner != project_id:
            fail('Volume {} 的 project 不符或無法確認；需要 admin 權限。'.format(vol_id))
        attachments = structured(vol.get('attachments'), list)
        own = [a for a in attachments if a.get('server_id') == vm_id]
        if not own:
            fail('Volume {} 已不再掛載於所選 VM。'.format(vol_id))
        device = field(item, 'Device', 'device') or own[0].get('device', '')
        result.append(dict(id=vol_id, name=vol.get('name') or '(未命名)',
                           device=device, size=vol.get('size', '?'),
                           bootable=vol.get('bootable', '?'), volume=vol,
                           shared=any(a.get('server_id') != vm_id for a in attachments)))
    return result


def check_disk(disk, vm):
    if disk['shared']:
        fail('所選磁碟同時掛載其他 VM，請改用專門的維護流程。')
    root = vm.get('OS-EXT-SRV-ATTR:root_device_name')
    if root and disk['device'] and root != disk['device']:
        fail('所選磁碟 {} 不符 VM root device {}。'.format(disk['device'], root))


def nova_property(vm_id, key):
    command = ['nova-manage', 'image_property', 'show', vm_id, key]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True)
    os.write(4, ('[COMMAND] {}\n[exit={}]\n{}{}\n'.format(
        ' '.join(shlex.quote(x) for x in command), result.returncode,
        result.stdout, result.stderr)).encode('utf-8'))
    if result.returncode == 3:
        return None
    if result.returncode:
        fail('Nova metadata 讀取失敗：{}: {}'.format(key, display(result.stderr or result.stdout)))
    return result.stdout.strip()


def root_disk(volumes, vm):
    root = vm.get('OS-EXT-SRV-ATTR:root_device_name')
    matches = [d for d in volumes if root and d['device'] == root]
    if len(matches) != 1:
        fail('root device {} 無法對應唯一掛載 volume。'.format(display(root)))
    check_disk(matches[0], vm)
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description='選 project → VM / ALL VM → profile（自動選取 root disk），設定 image metadata')
    parser.add_argument('--dry-run', action='store_true', help='只預覽，不寫入 metadata 或開關機')
    args = parser.parse_args()
    for command in ('openstack', 'nova-manage', 'cinder'):
        if not shutil.which(command):
            fail('找不到 {}；請在目標雲端的 controller 執行。'.format(command))
    print('VM image metadata 設定選單（列出 project 內所有狀態的 VM）')
    print('請確認 admin openrc 與本機 nova-manage 設定屬於同一個叢集。')
    projects = [p for p in osc('project', 'list', '--long')
                if str(p['Name']).lower() != 'service']
    project = choose('project', projects,
                     lambda p: '{} ({}) [{}]'.format(p['ID'], p['Name'], field(p, 'Description', 'description') or 'NULL'), auto_single=True)
    project_id = project['ID']
    print('Selected project name: ' + display(project['Name']))
    servers = osc('server', 'list', '--all-projects', '--project', project_id,
                  '--long')
    # No status filter: list ACTIVE, SHUTOFF and other states.
    if not servers:
        fail('No VM available for selection.')
    server = choose('VM', servers + [None], lambda s: 'ALL VM' if s is None else
                    '{} ({}) [status={}]'.format(s['ID'], s['Name'], s['Status']))
    selected = servers if server is None else [server]
    batch = None
    if server is None:
        shutdown = False if args.dry_run else ask(
            'Shutdown originally ACTIVE VMs if metadata changes? Type "YES" to confirm: ') == 'YES'
        properties = select_properties()
        print(json.dumps(properties, ensure_ascii=True))
        if not args.dry_run and ask('Apply metadata changes to ALL VM root disks? Type "YES" to confirm: ') != 'YES':
            return
        power_on = False if args.dry_run else ask(
            'Power on only VMs that were ACTIVE before this operation? Type "YES" to confirm: ') == 'YES'
        batch = dict(shutdown=shutdown, properties=properties, power_on=power_on)
    results = ['NOT RUN'] * len(selected)
    try:
        for index, server in enumerate(selected):
            print('\n=== VM {}/{}: {} ({}) ==='.format(
                index + 1, len(selected), display(server['Name']), server['ID']))
            try:
                results[index] = update_vm(server, project, args, batch)
            except (RuntimeError, OSError):
                results[index] = 'FAILED'
                raise
            except (EOFError, KeyboardInterrupt):
                results[index] = 'INTERRUPTED'
                raise
    finally:
        print('\nSummary:')
        for index, (server, result) in enumerate(zip(selected, results), 1):
            try:
                status = field(osc('server', 'show', server['ID']), 'status', 'Status')
            except (RuntimeError, OSError):
                status = 'UNKNOWN'
            print('{}. {} ({}) [status={}] ({})'.format(
                index, server['ID'], display(server['Name']), display(status), result))


def update_vm(server, project, args, batch=None):
    project_id = project['ID']
    vm_id = server['ID']
    print('Selected VM name: ' + display(server['Name']))
    vm = check_vm(vm_id, project_id, require_shutoff=False)
    # Show attached-volume image metadata before any shutdown confirmation.
    # Do not assume the first attached volume is the OS disk.
    preview_disks = disks(vm_id, project_id)
    print('\nCurrent attached-volume image metadata:')
    for preview in preview_disks:
        print('Volume: {} ({}) [device={}]'.format(
            preview['id'], display(preview['name']), display(preview['device'] or '?')))
        metadata = preview['volume'].get('volume_image_metadata')
        print(json.dumps(structured(metadata, dict) if metadata else {},
                         indent=2, ensure_ascii=True))
    try:
        disk = root_disk(preview_disks, vm)
    except RuntimeError as error:
        print('SKIP VM: ' + str(error))
        return 'SKIP'
    vol_id = disk['id']
    original_status = str(field(vm, 'status', 'Status')).upper()
    if original_status not in ('ACTIVE', 'SHUTOFF'):
        print('SKIP VM: unsupported state ' + display(original_status))
        return 'SKIP'
    properties = batch['properties'] if batch is not None else select_properties()
    before = disk['volume'].get('volume_image_metadata')
    before = structured(before, dict) if before else {}
    commands = []
    for key, value in properties.items():
        nova_value = nova_property(vm_id, key)
        if nova_value is None or not matches_property(key, nova_value, value):
            commands.append(['nova-manage', 'image_property', 'set', vm_id,
                             '--property', key + '=' + value])
        if key not in before or not matches_property(key, before[key], value):
            commands.append(['cinder', 'image-metadata', vol_id, 'set', key + '=' + value])
    if not commands:
        print('UNCHANGED：Nova 與 Cinder metadata 已符合設定，不寫入或開關機。')
        return 'UNCHANGED'
    status = original_status
    if status == 'ACTIVE':
        if args.dry_run:
            print('DRY RUN：VM 為 ACTIVE；正式套用前需要確認關機。')
        else:
            shutdown = batch['shutdown'] if batch is not None else (
                ask('Do you want to shutdown the VM? Type "YES" to confirm: ') == 'YES')
            if not shutdown:
                print('已取消，未關機或修改 metadata。')
                return 'SKIP'
            check_vm(vm_id, project_id, require_shutoff=False)
            run(['openstack', 'server', 'stop', vm_id])
            print('等待 VM 關機至 SHUTOFF...', flush=True)
            vm = wait_vm(vm_id, project_id, 'SHUTOFF')
            print('VM 已關機；若之後取消或失敗，VM 將保持關機。')
    elif status != 'SHUTOFF':
        fail('只支援 ACTIVE 或 SHUTOFF VM；目前為 {}。'.format(display(status)))
    current_disk = root_disk(disks(vm_id, project_id), vm)
    if current_disk['id'] != vol_id:
        fail('Root disk 已變更，停止執行。')
    print('Auto-selected OS disk: {} [device={}]'.format(vol_id, display(disk['device'])))
    print('\nProject: {} ({})\nVM: {} ({})\nOS disk: {} ({})'.format(
        project_id, display(project['Name']),
        vm_id, display(server['Name']), vol_id, display(disk['name'])))
    for command in commands:
        print('  ' + ' '.join(shlex.quote(x) for x in command))
    if args.dry_run:
        print('\nDRY RUN：未修改任何 metadata，未執行開關機。')
        return 'DRY RUN'
    if batch is None and ask('\nConfirm this is the OS disk and apply changes? Type "YES" to confirm: ') != 'YES':
        print('已取消，未修改 metadata。')
        return 'SKIP'
    # Re-read state and attachments after the user finishes the menu.
    vm = check_vm(vm_id, project_id)
    current = [d for d in disks(vm_id, project_id) if d['id'] == vol_id]
    if len(current) != 1:
        fail('所選磁碟掛載已變更，停止執行。')
    check_disk(current[0], vm)
    print('\n開始設定。中斷或失敗可能留下部分設定；請依顯示的 UUID 檢查。', flush=True)
    completed = []
    try:
        for command in commands:
            vm = check_vm(vm_id, project_id)
            current = [d for d in disks(vm_id, project_id) if d['id'] == vol_id]
            if len(current) != 1:
                fail('所選磁碟掛載已變更。')
            check_disk(current[0], vm)
            print('Running: ' + ' '.join(shlex.quote(x) for x in command), flush=True)
            run(command)
            completed.append(' '.join(shlex.quote(x) for x in command))
            print('OK', flush=True)
        actual = structured(osc('volume', 'show', vol_id).get('volume_image_metadata'), dict)
        for key, value in properties.items():
            if key not in actual or not matches_property(key, actual[key], value):
                fail('Cinder metadata 回讀驗證未通過：' + key)
            print('Nova {} 回讀值：{}'.format(key, display(
                run(['nova-manage', 'image_property', 'show', vm_id, key]))))
    except (RuntimeError, OSError) as error:
        fail('設定或驗證失敗，可能部分完成；不會自動開機。\n已成功的寫入指令：\n{}\n{}'
             .format('\n'.join(completed) or '(無)', error))
    print('\nMetadata 設定完成。')
    power_on = original_status == 'ACTIVE' and (
        batch['power_on'] if batch is not None else
        ask('Power on the VM (originally ACTIVE)? Type "YES" to confirm: ') == 'YES')
    if power_on:
        check_vm(vm_id, project_id)
        run(['openstack', 'server', 'start', vm_id])
        print('等待 VM 開機至 ACTIVE...', flush=True)
        wait_vm(vm_id, project_id, 'ACTIVE')
        print('VM 已開機。請在 guest 內確認所選功能。')
    else:
        print('VM 保持關機。')
    print('\nVolume image metadata {} ({}):'.format(
        'after power-on' if power_on else 'after update', vol_id))
    after = osc('volume', 'show', vol_id).get('volume_image_metadata')
    print(json.dumps(structured(after, dict) if after else {}, indent=2, ensure_ascii=True))
    for key in properties:
        print('Nova {}: {}'.format(key, display(nova_property(vm_id, key))))
    return 'OK'




if __name__ == '__main__':
    INPUT = os.fdopen(3, 'r', encoding='utf-8')
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        print('\n已離開；若在寫入期間中斷，請檢查上方執行進度。')
        sys.exit(130)
    except (RuntimeError, OSError) as error:
        print('\n錯誤：' + str(error), file=sys.stderr)
        sys.exit(1)
PY
