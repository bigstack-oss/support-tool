#!/usr/bin/env bash
# Run on the target cloud's controller. Menu style follows volume-config.sh.
# Bash + Python 3.6+ + openstack + nova-manage + cinder. No pip modules needed.
set -eo pipefail
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
exec python3 - "$@" <<'PY'
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


def check_vm(vm_id, project_id, zone, require_shutoff=True, allow_task=False):
    vm = osc('server', 'show', vm_id)
    if require_shutoff and str(field(vm, 'status', 'Status')).upper() != 'SHUTOFF':
        fail('VM 必須為 SHUTOFF；目前為 {}。請先正常關機再執行。'.format(vm.get('status')))
    if field(vm, 'project_id', 'tenant_id') != project_id:
        fail('VM project 不符或無法確認。')
    if field(vm, 'OS-EXT-AZ:availability_zone', 'availability_zone') != zone:
        fail('VM zone 不符或無法確認。')
    task = vm.get('OS-EXT-STS:task_state')
    if not allow_task and task not in (None, '', 'None', 'none', 'null'):
        fail('VM 正在執行其他工作：{}'.format(display(task)))
    return vm


def wait_vm(vm_id, project_id, zone, target, timeout=300):
    deadline = time.monotonic() + timeout
    while True:
        vm = check_vm(vm_id, project_id, zone, require_shutoff=False, allow_task=True)
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


def main():
    parser = argparse.ArgumentParser(description='選 zone → project → VM → OS disk → profile，設定 image metadata')
    parser.add_argument('--dry-run', action='store_true', help='只預覽，不寫入 metadata 或開關機')
    args = parser.parse_args()
    for command in ('openstack', 'nova-manage', 'cinder'):
        if not shutil.which(command):
            fail('找不到 {}；請在目標雲端的 controller 執行。'.format(command))
    print('VM image metadata 設定選單（zone = Compute Availability Zone）')
    print('請確認 admin openrc 與本機 nova-manage 設定屬於同一個叢集。')
    zones = osc('availability', 'zone', 'list', '--compute')
    names = sorted(set(str(field(z, 'Zone Name', 'zoneName')) for z in zones
                       if field(z, 'Zone Name', 'zoneName')
                       and str(field(z, 'Zone Name', 'zoneName')).lower() != 'internal'))
    zone = choose('zone', names, str, auto_single=True)
    print('Selected zone: ' + display(zone))
    projects = [p for p in osc('project', 'list')
                if str(p['Name']).lower() != 'service']
    project = choose('project', projects,
                     lambda p: '{} ({})'.format(p['ID'], p['Name']), auto_single=True)
    project_id = project['ID']
    print('Selected project name: ' + display(project['Name']))
    servers = osc('server', 'list', '--all-projects', '--project', project_id,
                  '--availability-zone', zone, '--long')
    server = choose('VM', servers, lambda s: '{} ({}) [status={}]'.format(
        s['ID'], s['Name'], s['Status']))
    vm_id = server['ID']
    print('Selected VM name: ' + display(server['Name']))
    vm = check_vm(vm_id, project_id, zone, require_shutoff=False)
    # Show attached-volume image metadata before any shutdown confirmation.
    # Do not assume the first attached volume is the OS disk.
    preview_disks = disks(vm_id, project_id)
    print('\nCurrent attached-volume image metadata:')
    if not preview_disks:
        fail('VM 沒有掛載的 volume，無法選取 OS disk。')
    for preview in preview_disks:
        print('Volume: {} ({}) [device={}]'.format(
            preview['id'], display(preview['name']), display(preview['device'] or '?')))
        metadata = preview['volume'].get('volume_image_metadata')
        print(json.dumps(structured(metadata, dict) if metadata else {},
                         indent=2, ensure_ascii=True))
    status = str(field(vm, 'status', 'Status')).upper()
    if status == 'ACTIVE':
        if args.dry_run:
            print('DRY RUN：VM 為 ACTIVE；正式套用前需要確認關機。')
        else:
            if ask('Do you want to shutdown the VM? Type "YES" to confirm: ') != 'YES':
                print('已取消，未關機或修改 metadata。')
                return
            check_vm(vm_id, project_id, zone, require_shutoff=False)
            run(['openstack', 'server', 'stop', vm_id])
            print('等待 VM 關機至 SHUTOFF...', flush=True)
            vm = wait_vm(vm_id, project_id, zone, 'SHUTOFF')
            print('VM 已關機；若之後取消或失敗，VM 將保持關機。')
    elif status != 'SHUTOFF':
        fail('只支援 ACTIVE 或 SHUTOFF VM；目前為 {}。'.format(display(status)))
    volumes = disks(vm_id, project_id)
    root = vm.get('OS-EXT-SRV-ATTR:root_device_name')
    print('\nVM root device：{}'.format(display(root or 'API 未提供，請自行確認 OS disk')))
    print('bootable=true 僅為提示，不保證是這台 VM 的 OS disk。')
    disk = choose('OS disk', volumes, lambda d:
                  '{} ({}) [device={}, size={} GiB, bootable={}]{}'.format(
                      d['id'], d['name'], d['device'] or '?', d['size'], d['bootable'],
                      ' [root device]' if root and root == d['device'] else ''))
    check_disk(disk, vm)
    vol_id = disk['id']
    print('Selected volume name: ' + display(disk['name']))
    print('\nCurrent volume image metadata:')
    before = disk['volume'].get('volume_image_metadata')
    print(json.dumps(structured(before, dict) if before else {}, indent=2, ensure_ascii=True))
    properties = select_properties()
    commands = []
    for key, value in properties.items():
        commands.extend([
            ['nova-manage', 'image_property', 'set', vm_id, '--property', key + '=' + value],
            ['cinder', 'image-metadata', vol_id, 'set', key + '=' + value],
        ])
    print('\nZone: {}\nProject: {} ({})\nVM: {} ({})\nOS disk: {} ({})'.format(
        display(zone), project_id, display(project['Name']),
        vm_id, display(server['Name']), vol_id, display(disk['name'])))
    for command in commands:
        print('  ' + ' '.join(shlex.quote(x) for x in command))
    if args.dry_run:
        print('\nDRY RUN：未修改任何 metadata，未執行開關機。')
        return
    if ask('\nConfirm this is the OS disk and apply changes? Type "YES" to confirm: ') != 'YES':
        print('已取消，未修改 metadata。')
        return
    # Re-read state and attachments after the user finishes the menu.
    vm = check_vm(vm_id, project_id, zone)
    current = [d for d in disks(vm_id, project_id) if d['id'] == vol_id]
    if len(current) != 1:
        fail('所選磁碟掛載已變更，停止執行。')
    check_disk(current[0], vm)
    print('\n開始設定。中斷或失敗可能留下部分設定；請依顯示的 UUID 檢查。', flush=True)
    completed = []
    try:
        for command in commands:
            vm = check_vm(vm_id, project_id, zone)
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
    print('\nUpdated volume image metadata:')
    print(json.dumps(actual, indent=2, ensure_ascii=True))
    print('\nMetadata 設定完成。')
    if ask('Do you want to power on the VM? Type "YES" to confirm: ') == 'YES':
        check_vm(vm_id, project_id, zone)
        run(['openstack', 'server', 'start', vm_id])
        print('等待 VM 開機至 ACTIVE...', flush=True)
        wait_vm(vm_id, project_id, zone, 'ACTIVE')
        print('VM 已開機。請在 guest 內確認所選功能。')
        print('\nVolume image metadata after power-on ({}):'.format(vol_id))
        after = osc('volume', 'show', vol_id).get('volume_image_metadata')
        print(json.dumps(structured(after, dict) if after else {},
                         indent=2, ensure_ascii=True))
        for key in properties:
            print('Nova {} 回讀值：{}'.format(key, display(
                run(['nova-manage', 'image_property', 'show', vm_id, key]))))
    else:
        print('VM 保持關機。')



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
