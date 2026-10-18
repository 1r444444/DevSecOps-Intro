# Lab 12 — VM-Backed Container Isolation with Kata

Author: Irina (`1r444444`). Executed 18 October 2026, Europe/Moscow.
All measurements below come from this run; the reading's illustrative numbers
and other students' measurements are not used as our data.
Compact measurements and process lists: [lab12-evidence.json](lab12-evidence.json).
Full command/stdout/stderr transcripts are retained locally in the gitignored
`labs/lab12/results/` directory.

## Environment and reproducibility

| Component | Actual configuration |
|---|---|
| Physical machine | Apple M3 Pro, macOS 26.6.2, 18 GiB RAM |
| Disposable Linux host | Lima 2.2.1, VZ, `nestedVirtualization: true`, 4 vCPUs, 4 GiB RAM, 12 GiB sparse disk |
| Linux OS/kernel | Ubuntu 26.04.1 LTS, `7.0.0-38-generic`, aarch64 |
| containerd / nerdctl / runc | 2.4.1 / 2.4.1 / 1.5.2 |
| Kata | **4.1.0**, official Go shim, commit `ddcb1ad8d23cbb4323f86c209f132b89592902df` |
| Hypervisor | Bundled QEMU 11.0.1, **KVM**, CPU `host` |
| Kata guest | 1 vCPU, 2048 MiB configured memory, `virtio-fs`, disk image rootfs |
| Image | `alpine:3.20`, linux/arm64, pulled before timing |
| Storage | containerd overlayfs on the disposable Linux host's ext4 `/dev/vda1` |

Here “host” means the disposable **Linux** VM, not macOS. Docker Desktop's
`6.10.14-linuxkit` VM had no `/dev/kvm`; it was not used for these experiments.
The M3 Pro supports nested virtualization through VZ, so a separate Lima VM
provided the required KVM device. No host directories or SSH agent were shared
with the lab VM; existing Docker Desktop containers were left untouched.

Preflight actually opened `/dev/kvm` read/write and used `KVM_GET_API_VERSION`:

```text
Host: 7.0.0-38-generic aarch64
/dev/kvm: opened read/write; KVM API version 12
```

Successful Kata execution with its distinct guest kernel, and the observed QEMU
`accel=kvm` process, establish more than the mere presence of a device node.
The same cached image index was used for both runtimes:

```text
sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
```

### Installation and ARM nested-virtualization adjustments

I read all three supplied setup/build scripts before executing host-changing
commands. The default Rust/Dragonball and Rust/QEMU profiles did not complete
normal container creation in this ARM setup. The final measured configuration
uses the official **Go build of the same pinned Kata 4.1.0**, not a newer Kata
release or software CPU emulation.

The default `pmu=off` CPU feature is not exposed by this nested host, so the CPU
feature string is empty. Direct kernel boot is used, with firmware paths empty.
Most importantly, ITS-backed interrupts did not deliver the guest vsock traffic:
a minimal QEMU/agent probe timed out, while the same probe with ITS disabled
connected successfully. Disabling all MSI also prevents PCIe root-port creation,
so the final configuration selects **`msi=gicv2m`**, retaining MSI/PCIe hotplug
without the failing nested ITS path. This final configuration runs with the
normal nerdctl network, without extra `--net=none` benchmark flags.

```toml
[hypervisor.qemu]
path = "/opt/kata/bin/qemu-system-aarch64"
kernel = "/opt/kata/share/kata-containers/vmlinux.container"
image = "/opt/kata/share/kata-containers/kata-containers.img"
firmware = ""
firmware_volume = ""
cpu_features = ""
machine_accelerators = "msi=gicv2m"
default_vcpus = 1
default_memory = 2048
shared_fs = "virtio-fs"
```

Debug logging was disabled for measurements. The runtime registration in this
Lima-provisioned containerd config is:

```toml
[plugins.'io.containerd.grpc.v1.cri'.containerd.runtimes.kata]
  runtime_type = 'io.containerd.kata.v2'
```

The source config has `version = 2`; containerd 2.4.1 accepts it through automatic
migration. Its effective configuration and successful runtime launches were
checked. nerdctl prints a warning that it cannot set the Kata cgroup manager to
systemd; the successful measured commands still exit 0.

### Reproduce

[setup/lima-vz.yaml](../labs/lab12/setup/lima-vz.yaml) pins the Ubuntu ARM64 image
and checksum and disables host mounts. Install official Lima 2.2.1, then create
the VM with `limactl start --name=lab12 --tty=false labs/lab12/setup/lima-vz.yaml`.
Copy only the lab directory into the guest, without sharing the Mac home:

```bash
limactl shell lab12 -- mkdir -p /tmp/course/labs
limactl copy -r labs/lab12 lab12:/tmp/course/labs/
limactl shell lab12
cd /tmp/course
```

Inside that disposable Linux VM, with system containerd and nerdctl available:

```bash
sudo bash labs/lab12/scripts/preflight.sh
# Required packages in the disposable Linux VM: curl, zstd, Python 3.11+.
curl -fL https://github.com/kata-containers/kata-containers/releases/download/4.1.0/kata-go-static-4.1.0-arm64.tar.zst -o /tmp/kata-go.tar.zst
printf '%s  %s\n' 9008fa1acdc6e9f5c86e9f4fa0e22dbaf09106f8ddc62383bfcb7cfa0df42ff3 /tmp/kata-go.tar.zst | sha256sum -c -
sudo tar --zstd -xf /tmp/kata-go.tar.zst -C /
sudo bash labs/lab12/setup/configure-arm64-lima.sh
sudo python3 labs/lab12/scripts/measure.py --output labs/lab12/results
sudo python3 labs/lab12/scripts/memory-and-bind.py --output labs/lab12/results
```

The archive SHA256 matches the release asset digest returned by GitHub's API.
The original Rust archive was downloaded during diagnosis; its kernel, root image
and initrd were compared by SHA256 with the Go archive's corresponding assets and
matched. The final Go shim/configuration and ARM setup helper were exercised in
the VM; no measurements from failed exploratory launches enter the tables.
The collector runs commands as root with a dedicated containerd namespace,
`lab12`. The timeout is 180 seconds per command and nonzero benchmark exits fail
the collector instead of becoming bogus timing samples.

The supplied registration script's `awk` used `\s`, which does not portably
match indentation and could append a duplicate `runtime_type` on a second run.
I replaced it with POSIX `[[:space:]]`; the regression test
`python3 labs/lab12/scripts/test-config.py` runs registration twice against both
v2 and v3 plugin fixtures, parses the resulting TOML and checks runc is preserved.

## Task 1

### One image, two runtimes

Equivalent live commands (shown without the collector's namespace argument):

```bash
uname -r
nerdctl run --rm alpine:3.20 uname -r
nerdctl run --rm --runtime=io.containerd.kata.v2 alpine:3.20 uname -r
# For each runtime, also: ls -1 /dev; grep ^CapEff /proc/1/status
```

| Observation | runc | Kata |
|---|---|---|
| Linux host kernel | `7.0.0-38-generic` | `7.0.0-38-generic` |
| Container kernel | `7.0.0-38-generic` | `6.18.35` |
| Matches host | Yes | No |
| `/dev` entries | 15 | 14 |
| PID 1 `CapEff` | `00000000a80425fb` | `00000000a80425fb` |

The device counts include symlinks/directories, rather than counting physical
hardware. runc has `/dev/core`; Kata does not. Equal capability masks do not
remove the separate-kernel boundary.

### What the exact kernel output tells an attacker

`7.0.0-38-generic` in runc matches the host, exposing the Ubuntu kernel family
against which an attacker could investigate relevant bugs and accessible attack
surfaces. The release string alone does not establish exploitability because
backported patches, configuration and capabilities also matter. In Kata,
`6.18.35` identifies the guest kernel, so an exploit of that kernel would initially
compromise the disposable guest rather than the Linux host. Reaching the host
would require an additional boundary failure, or access explicitly exported by
the operator, such as a writable host directory.

## Task 2

### Five startup times and medians

The image pull and one complete `true` warm-up per runtime were excluded from
timing. Five successful commands followed sequentially for each runtime:
`nerdctl run --rm [--runtime=io.containerd.kata.v2] alpine:3.20 true`.
The collector uses Python's monotonic `time.perf_counter()` around the subprocess;
JSON saving happens outside the measured interval. Like the assignment's
`/usr/bin/time`, it includes nerdctl, containerd, network setup, execution and
removal, rather than measuring hypervisor boot in isolation. The collector itself
already runs as root, so neither runtime pays a per-command sudo/authentication cost.

| Runtime | Run 1, s | Run 2, s | Run 3, s | Run 4, s | Run 5, s | Median, s |
|---|---:|---:|---:|---:|---:|---:|
| runc | 0.236370 | 0.210596 | 0.244292 | 0.219394 | 0.237690 | **0.236370** |
| kata | 12.717339 | 12.084983 | 11.653342 | 12.041381 | 10.961588 | **12.041381** |

Kata's median full-lifecycle time is **50.94 times** runc's here, adding
**11.805 seconds**.
The actual difference is larger than tenfold; I do not replace it with the
reading's values or another student's measurements. This nested M3/VZ/KVM setup
and IRQ workaround are part of the measurement environment. The figures do not
predict bare-metal x86 or production tail latency, and the lifecycle measurement
cannot attribute all the difference to guest boot alone.

### Actual filesystem I/O

```bash
nerdctl run --rm alpine:3.20 \
  sh -o pipefail -c 'dd if=/dev/zero of=/tmp/bench bs=1M count=512 conv=fsync 2>&1 | tail -1'
nerdctl run --rm --runtime=io.containerd.kata.v2 alpine:3.20 \
  sh -o pipefail -c 'dd if=/dev/zero of=/tmp/bench bs=1M count=512 conv=fsync 2>&1 | tail -1'
```

```text
runc: 536870912 bytes (512.0MB) copied, 0.764235 seconds, 670.0MB/s
Kata: 536870912 bytes (512.0MB) copied, 11.332115 seconds, 45.2MB/s
```

Each run writes **536,870,912 bytes (512 MiB)**. BusyBox labels its binary-unit
throughput `MB/s`: 512 / 0.764235 = approximately **670.0 MiB/s**, versus
512 / 11.332115 = approximately **45.2 MiB/s**. The file and `conv=fsync` exercise
the storage/flush path, including virtio-fs for Kata; `/dev/null` would discard
writes and skip the layer being compared. These are one sequential-write sample
per runtime with host/VM caches and backing storage involved, not a complete
persistent-volume performance profile.

### Memory per idle container

For each runtime the collector starts a detached `alpine:3.20 sleep 300`, waits
five seconds, then samples `/proc/<pid>/smaps_rollup` three times, one second apart.
It compares the PID set before and after starting the container, summing PSS for
the new long-lived workload processes; their complete command lines and each
sample are in the evidence JSON. The first container is removed before the
second is started, and no other guest commands ran during these memory snapshots.

| Runtime | Three process-PSS totals, KiB | Median, KiB | Median, MiB |
|---|---|---:|---:|
| runc | 40740, 40740, 40740 | **40740** | **39.79** |
| kata | 256432, 256432, 256432 | **256432** | **250.42** |

For clarity, processes included in the middle (median) snapshot were:

| Runtime | Host-visible process | PSS, KiB |
|---|---|---:|
| runc | containerd-shim-runc-v2 | 10384 |
| runc | nerdctl logging helper | 29516 |
| runc | sleep | 840 |
| kata | containerd-shim-kata-v2 | 35412 |
| kata | virtiofsd | 1020 |
| kata | qemu-system-aarch64 | 188244 |
| kata | virtiofsd | 2028 |
| kata | nerdctl logging helper | 29728 |

Under this stated process-footprint method, Kata adds **210.64 MiB**
per idle container, approximately **6.29 times** the runc footprint.
PSS apportions shared pages, avoiding the duplication produced by summing RSS
across QEMU and virtiofsd. QEMU includes the resident guest memory and workload;
the configured 2048 MiB allocation is not the same as the observed resident cost.
These figures exclude the shared containerd daemon, host kernel allocations and
unmapped page cache, so they are not a claim about the total host memory delta
or the peak memory of a real workload.

### Three workloads

| Workload | Verdict | Reason |
|---|---|---|
| Trusted first-party FastAPI/Streamlit coursework service on a dedicated node | runc | Its controlled image and operators may justify standard kernel hardening without paying the measured sandbox lifecycle and memory cost. |
| CI runner executing build scripts from untrusted pull requests | Kata | Arbitrary contributor code benefits from a guest-kernel boundary, especially for jobs long enough to amortize boot cost. |
| Multi-tenant GPU inference with a cold-start latency target | needs more information | Representative GPU passthrough, tail latency, memory density and storage tests are needed; this CPU-only Alpine benchmark cannot settle compatibility or latency. |

### When the startup gap does not matter

A prestarted worker or batch service running for hours or days pays the extra
startup delay once, outside its steady-state request path. For a 24-hour worker,
our approximately 11.8-second extra lifecycle time is about 0.014% of that lifetime.
Creating a fresh container per short request would instead expose that delay on
every invocation and materially change the decision. Memory and sustained I/O
costs remain relevant even when startup is amortized.

## Bonus

### Exact command from the assignment

The sentinel was reset to `original` **before each runtime**. The two command
lines differ only by the runtime flag (the collector also uses namespace `lab12`):

```bash
echo original >/tmp/lab12-target
nerdctl run --rm --privileged -v /tmp:/host_tmp alpine:3.20 \
  sh -c 'echo "OVERWRITTEN" > /host_tmp/lab12-target'
echo "exit=$?"; cat /tmp/lab12-target

echo original >/tmp/lab12-target
nerdctl run --rm --runtime=io.containerd.kata.v2 --privileged \
  -v /tmp:/host_tmp alpine:3.20 \
  sh -c 'echo "OVERWRITTEN" > /host_tmp/lab12-target'
echo "exit=$?"; cat /tmp/lab12-target
```

| Exact privileged test | runc | Kata |
|---|---|---|
| Exit code | 0 | 1 |
| Host file after run | `OVERWRITTEN` | `original` |
| `/dev` count from separate privileged probe | 194 | Unavailable: creation failed |
| Privileged `CapEff` | `000001ffffffffff` | Unavailable: no process started |

The separate Kata probe without a bind mount also fails during creation with:

```text
failed to create shim task:
Conflicting resource updates for host_major=253 host_minor=1
```

That is a host-device/resource compatibility error. The file remains `original`
because the write command never starts; it is **not evidence that a guest kernel
intercepted the attempted write**. The collector now records expected nonzero
bonus outcomes, exit statuses, error text and subsequent host file state rather
than aborting before recording them.

### Supplement: working privileged guests without host-device passthrough

Following the official [nerdctl 2.4.1 command reference](https://github.com/containerd/nerdctl/blob/v2.4.1/docs/command-reference.md)
and [Kata privileged-container guidance](https://github.com/kata-containers/kata-containers/blob/4.1.0/docs/how-to/privileged.md),
I repeated both commands with **`--security-opt privileged-without-host-devices`**
added on **both runtimes**. This retains privileged capabilities while excluding
host devices from the OCI device list. It is explicitly a supplementary test,
not a claim that the original command succeeded.

```bash
for rt in runc kata; do
  FLAG=""
  [ "$rt" != kata ] || FLAG="--runtime=io.containerd.kata.v2"
  echo original >/tmp/lab12-target
  nerdctl run --rm $FLAG --privileged \
    --security-opt privileged-without-host-devices -v /tmp:/host_tmp alpine:3.20 \
    sh -c 'echo "OVERWRITTEN" > /host_tmp/lab12-target'
  echo "exit=$?"; cat /tmp/lab12-target
  nerdctl run --rm $FLAG --privileged \
    --security-opt privileged-without-host-devices alpine:3.20 \
    sh -c 'ls /dev | wc -l; grep ^CapEff /proc/1/status'
done
```

| Supplementary privileged test | runc | Kata |
|---|---|---|
| Exit status | 0 | 0 |
| Host file afterward | `OVERWRITTEN` | `OVERWRITTEN` |
| `/dev` count | 15 | 14 |
| Actual PID 1 `CapEff` | `000001ffffffffff` | `000001ffffffffff` |

With runc, privileged capabilities are evaluated by the Linux host kernel and
the default privileged setup also exposes host devices. Kata evaluates those
capabilities inside the guest kernel, which remains separate even with the same
full capability mask. Our exact Kata command fails on device passthrough, but
the working supplementary test modifies the host file through the deliberately
writable virtio-fs export. This is operator-granted access, not a VM escape or
proof that Kata silently turns bind mounts into private copies.

**Honest limitation:** Kata does not protect a host file that an operator
explicitly exports writable to the guest.

## Public PR comparison and acceptance audit

After our own runtime launches, startup/I/O/memory measurements and exact
privileged attempt, I compared lab12 reports from
[#1878](https://github.com/inno-devops-labs/DevSecOps-Intro/pull/1878),
[#1798](https://github.com/inno-devops-labs/DevSecOps-Intro/pull/1798) and
[#1553](https://github.com/inno-devops-labs/DevSecOps-Intro/pull/1553).
They are cross-checks, not authoritative reference answers.

- #1878 also uses Go Kata 4.1.0, observes a failed exact privileged launch and
  separates it from a working `privileged-without-host-devices` experiment. Its
  supplementary method led me to the official option documentation; I then ran
  it here and recorded our own outcomes and masks. Our ARM kernels/capabilities
  are consistent with the same guest version, while x86 timing values differ.
- #1798 reports that its M1 environment cannot run Kata. That restriction does
  not describe this M3 Pro: our VZ VM has verified KVM and actually executes both
  runtimes, so no Kata values in this report are theoretical substitutions.
- #1553 uses an older Kata release and reports means and `/dev/null` I/O under
  an older task format. The current lab explicitly requires medians and a real
  fsynced file, so our acceptance audit follows today's specification. Its failed
  privileged launch likewise does not establish successful containment of a write.

| Required item | Evidence/result |
|---|---|
| Linux KVM, version recorded | KVM ioctl 12, Kata 4.1.0, observed KVM QEMU launch. |
| Host/runc/Kata kernels | 7.0.0-38-generic / 7.0.0-38-generic / 6.18.35. |
| Device counts and capabilities | Task 1 table and evidence JSON. |
| Specific attacker interpretation | Task 1 explanation tied to those releases. |
| Five warmed timings and median per runtime | Ten exit-0 samples, Task 2 table. |
| Real file I/O | 512 MiB, `conv=fsync`, raw throughput lines. |
| Memory measurement/method | Three process-PSS samples, process list, scope stated. |
| Three workload verdicts | runc / Kata / needs more information with reasons. |
| Startup gap interpretation | Measured 50.94×; amortization for prestarted long-lived workers. |
| Both exact privileged attempts and host state | runc writes; Kata exits 1 before execution; state recorded. |
| Privileged masks/counts for both runtimes | Exact runc probe plus working supplementary probes; no invented mask for the failed Kata process. |
| Honest privilege explanation and limitation | Guest kernel scope; writable export succeeds in working guest. |

Syntax checks, the v2/v3 registration regression test and live collectors passed.
The exact Kata creation error is retained as the observed bonus result; the
supplementary test establishes actual privileged-guest behavior. Full unmodified
`tools/verify-lab.sh 12 --run` is not claimed: its directives skip the host-changing
and Kata-dependent commands; the live collectors explicitly execute those tests.

## Cleanup

Cleanup completed after exporting the measurements: the dedicated Lima `lab12`
instance was stopped and deleted. This removed its `/opt/kata`, containerd runtime
registration and all guest test artifacts together, achieving the assignment's
cleanup without changing the Mac's Docker daemon. The sentinel was removed by
the collector, and temporary downloaded Kata archives were deleted after recording
their checksums. The four pre-existing Docker Desktop containers remained running.
No host-runtime installation was performed on macOS.
