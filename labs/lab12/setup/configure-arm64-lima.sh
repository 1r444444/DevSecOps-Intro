#!/usr/bin/env bash
# After unpacking official kata-go-static-4.1.0-arm64.tar.zst in a disposable VM.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == aarch64 && $EUID == 0 ]] || {
  echo 'Run as root inside the disposable ARM64 Linux/KVM VM' >&2; exit 1;
}
[[ -c /dev/kvm ]] || { echo '/dev/kvm is required' >&2; exit 1; }
[[ $(cat /opt/kata/VERSION) == 4.1.0 ]] || { echo 'Expected Kata 4.1.0' >&2; exit 1; }
/opt/kata/bin/containerd-shim-kata-v2 --version
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_config=/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
live_config=/etc/kata-containers/configuration.toml
[[ -f "$source_config" ]] || { echo "Unpack the complete official Go archive first" >&2; exit 1; }
mkdir -p /etc/kata-containers
if [[ -f "$live_config" ]]; then
  cp -a "$live_config" "${live_config}.$(date +%Y%m%d%H%M%S).bak"
fi
cp "$source_config" "$live_config"
# Direct boot; the parent VZ VM does not expose a PMU. gicv2m delivers MSI as
# SPIs instead of using the nested ITS path. It retains PCIe hotplug and KVM.
python3 - "$live_config" <<'PY'
from pathlib import Path
import re
import sys
import tomllib
p = Path(sys.argv[1])
s = p.read_text()
for key, value in {'cpu_features': '', 'firmware': '', 'firmware_volume': '',
                   'machine_accelerators': 'msi=gicv2m'}.items():
    s, n = re.subn(r'^' + key + r' = .*$', f'{key} = "{value}"', s, flags=re.M)
    assert n == 1, (key, n)
data = tomllib.loads(s)
assert data['hypervisor']['qemu']['machine_accelerators'] == 'msi=gicv2m'
p.write_text(s)
PY
ln -sfn /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
bash "$root_dir/scripts/configure-containerd-kata.sh"
containerd --config /etc/containerd/config.toml config dump >/dev/null
sysctl -w net.ipv4.ip_forward=1
systemctl restart containerd
/opt/kata/bin/kata-runtime --version
