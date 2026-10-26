"""Choose an installed iOS device; do not assume a fixed simulator model/UUID."""
import json
import os
import subprocess


def select_device(inventory, family):
    candidates = []
    for runtime, devices in inventory.get('devices', {}).items():
        if '.iOS-' not in runtime:
            continue
        for device in devices:
            if device.get('isAvailable') and device.get('name', '').startswith(family):
                candidates.append((runtime, device['name'], device['udid']))
    if not candidates:
        raise RuntimeError(f'No available {family} simulator in selected Xcode. Check xcrun simctl list.')
    return sorted(candidates)[-1][2]


if __name__ == '__main__':
    inventory = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True))
    simulator_id = select_device(inventory, os.environ['DEVICE_FAMILY'])
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
        output.write(f'SIMULATOR_ID={simulator_id}\n')
    print(f'Selected {os.environ["DEVICE_FAMILY"]}: {simulator_id}')
