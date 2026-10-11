# Lab 9 submission

Environment used for verification:

- Docker: `Docker version 28.4.0`
- Falco: `falcosecurity/falco:0.43.1`
- Conftest: `v0.69.0` with `OPA 1.19.0`, run via `openpolicyagent/conftest:v0.69.0`

On macOS Docker Desktop, `/boot` is not shared into Docker, so Falco was started without that mount. Falco still loaded the `syscall` source and detected the required events.

## Task 1

Built-in Falco rules from 9.2:

1. `Terminal shell in container`

Triggered by:

```bash
docker exec -t lab9-target sh -lc 'echo hello-from-shell'
```

Alert:

```json
{"hostname":"3eaa237f5bdf","output":"2026-10-11T20:27:01.165077434+0000: Notice A shell was spawned in a container with an attached terminal | evt_type=execve user=root user_uid=0 user_loginuid=-1 process=sh proc_exepath=/bin/busybox parent=containerd-shim command=sh -lc echo hello-from-shell terminal=34816 exe_flags=EXE_WRITABLE|EXE_LOWER_LAYER container_id=fe692f5abdc5 container_name=lab9-target container_image_repository=alpine container_image_tag=3.20 k8s_pod_name=<NA> k8s_ns_name=<NA>","output_fields":{"container.id":"fe692f5abdc5","container.image.repository":"alpine","container.image.tag":"3.20","container.name":"lab9-target","evt.arg.flags":"EXE_WRITABLE|EXE_LOWER_LAYER","evt.time.iso8601":1791750421165077434,"evt.type":"execve","k8s.ns.name":null,"k8s.pod.name":null,"proc.cmdline":"sh -lc echo hello-from-shell","proc.exepath":"/bin/busybox","proc.name":"sh","proc.pname":"containerd-shim","proc.tty":34816,"user.loginuid":-1,"user.name":"root","user.uid":0},"priority":"Notice","rule":"Terminal shell in container","source":"syscall","tags":["T1059","container","maturity_stable","mitre_execution","shell"],"time":"2026-10-11T20:27:01.165077434Z"}
```

2. `Read sensitive file untrusted`

Triggered by:

```bash
docker exec lab9-target sh -c 'cat /etc/shadow'
```

Alert:

```json
{"hostname":"3eaa237f5bdf","output":"2026-10-11T20:27:01.172476559+0000: Warning Sensitive file opened for reading by non-trusted program | file=/etc/shadow gparent=init ggparent=<NA> gggparent=<NA> evt_type=openat user=root user_uid=0 user_loginuid=-1 process=cat proc_exepath=/bin/busybox parent=containerd-shim command=cat /etc/shadow terminal=0 container_id=fe692f5abdc5 container_name=lab9-target container_image_repository=alpine container_image_tag=3.20 k8s_pod_name=<NA> k8s_ns_name=<NA>","output_fields":{"container.id":"fe692f5abdc5","container.image.repository":"alpine","container.image.tag":"3.20","container.name":"lab9-target","evt.time.iso8601":1791750421172476559,"evt.type":"openat","fd.name":"/etc/shadow","k8s.ns.name":null,"k8s.pod.name":null,"proc.aname[2]":"init","proc.aname[3]":null,"proc.aname[4]":null,"proc.cmdline":"cat /etc/shadow","proc.exepath":"/bin/busybox","proc.name":"cat","proc.pname":"containerd-shim","proc.tty":0,"user.loginuid":-1,"user.name":"root","user.uid":0},"priority":"Warning","rule":"Read sensitive file untrusted","source":"syscall","tags":["T1555","container","filesystem","host","maturity_stable","mitre_credential_access"],"time":"2026-10-11T20:27:01.172476559Z"}
```

Custom rule file:

```yaml
- rule: Container Write Below Tmp
  desc: Detect writes under /tmp from inside a container
  condition: open_write and container.id != host and fd.name startswith /tmp/
  output: Container wrote under /tmp (container=%container.name user=%user.name file=%fd.name command=%proc.cmdline)
  priority: WARNING
  tags: [container, drift]

- rule: Suspicious Mining Pool Connection
  desc: Detect a likely cryptominer process connecting to a common mining pool port
  condition: >
    evt.type=connect and container.id != host and
    (fd.sport in (3333, 4444, 5555, 7777, 14444) or fd.rport in (3333, 4444, 5555, 7777, 14444) or
     evt.arg.addr regex ".*:(3333|4444|5555|7777|14444)") and
    (proc.name in (xmrig, minerd, cpuminer, ccminer, cryptonight, nc, ncat, netcat) or proc.cmdline contains "nc -w")
  output: Suspicious mining pool connection (container=%container.name process=%proc.name command=%proc.cmdline destination=%fd.rip:%fd.rport requested_addr=%evt.arg.addr)
  priority: CRITICAL
  tags: [container, mitre_command_and_control]
```

The `/tmp` rule was triggered by:

```bash
docker exec --user 0 lab9-target sh -lc 'echo test > /tmp/my-write.txt'
```

Alert:

```json
{"hostname":"3eaa237f5bdf","output":"2026-10-11T20:27:21.925800652+0000: Warning Container wrote under /tmp (container=lab9-target user=root file=/tmp/my-write.txt command=sh -lc echo test > /tmp/my-write.txt) container_id=fe692f5abdc5 container_name=lab9-target container_image_repository=alpine container_image_tag=3.20 k8s_pod_name=<NA> k8s_ns_name=<NA>","output_fields":{"container.id":"fe692f5abdc5","container.image.repository":"alpine","container.image.tag":"3.20","container.name":"lab9-target","evt.time.iso8601":1791750441925800652,"fd.name":"/tmp/my-write.txt","k8s.ns.name":null,"k8s.pod.name":null,"proc.cmdline":"sh -lc echo test > /tmp/my-write.txt","user.name":"root"},"priority":"Warning","rule":"Container Write Below Tmp","source":"syscall","tags":["container","drift"],"time":"2026-10-11T20:27:21.925800652Z"}
```

An incident-relevant JSON field that is not part of my human-readable message is `container.id`. It lets responders correlate this event with Docker metadata, image history, and other container runtime logs even if the container name is reused later.

This rule will flag legitimate workloads that use `/tmp` as scratch space, for example image converters, archive extractors, package managers, or web apps that write upload buffers there. I would keep the detection but reduce noise by scoping it to unexpected images/namespaces, excluding known temporary filenames for approved workloads, and alerting only when writes come from unusual processes or happen after container startup. Another option is to keep low-severity telemetry for all `/tmp` writes and raise severity only when it combines with shell execution, sensitive file access, or network activity.

## Task 2

Shipped policy results:

```text
juice-hardened.yaml:   30 tests, 30 passed, 0 warnings, 0 failures, 0 exceptions
juice-unhardened.yaml: 30 tests, 20 passed, 2 warnings, 8 failures, 0 exceptions
juice-compose.yml:    15 tests, 15 passed, 0 warnings, 0 failures, 0 exceptions
```

Two failures mapped to their Rego rules:

- `container "juice" uses disallowed :latest tag` maps to the `deny` rule in `labs/lab9/policies/k8s-security.rego` that checks `endswith(c.image, ":latest")`.
- `container "juice" must set readOnlyRootFilesystem: true` maps to the `deny` rule in `labs/lab9/policies/k8s-security.rego` that checks `not c.securityContext.readOnlyRootFilesystem == true`.

The same requirement needs separate Compose and Kubernetes rules because the input schemas are different: Kubernetes containers live under `input.spec.template.spec.containers`, while Compose services live under `input.services`. The Compose file passing means the policy set can recognize a compliant manifest, not only report failures on intentionally weak Kubernetes input.

My additional policy file:

```rego
package k8s.security

deny contains msg if {
  input.kind == "Deployment"
  c := input.spec.template.spec.containers[_]
  not contains(c.image, "@sha256:")
  msg := sprintf("container %q must pin image by digest", [c.name])
}

warn contains msg if {
  input.kind == "Deployment"
  input.spec.template.spec.automountServiceAccountToken == true
  c := input.spec.template.spec.containers[_]
  msg := sprintf("container %q should not automount the service account token", [c.name])
}
```

Manifest written to violate it:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: violates-extra-policy
spec:
  replicas: 1
  selector:
    matchLabels: { app: violates-extra-policy }
  template:
    metadata:
      labels: { app: violates-extra-policy }
    spec:
      automountServiceAccountToken: true
      containers:
        - name: juice
          image: bkimminich/juice-shop:20.0.0
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits: { cpu: "500m", memory: "512Mi" }
          ports:
            - containerPort: 3000
          readinessProbe:
            httpGet: { path: /, port: 3000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /, port: 3000 }
            initialDelaySeconds: 10
            periodSeconds: 20
```

Runs with the extended policy set:

```text
juice-hardened.yaml:           34 tests, 34 passed, 0 warnings, 0 failures, 0 exceptions
violates-extra-policy.yaml:    17 tests, 15 passed, 1 warning, 1 failure, 0 exceptions
```

The violating manifest produced:

```text
WARN - labs/lab9/manifests/k8s/violates-extra-policy.yaml - k8s.security - container "juice" should not automount the service account token
FAIL - labs/lab9/manifests/k8s/violates-extra-policy.yaml - k8s.security - container "juice" must pin image by digest
```

For digest pinning, I would keep the Conftest rule if I could only have one control, because CI can stop an unpinned image before it is deployed. A runtime Falco rule still buys evidence after deployment: it can show that a running container drifted, pulled unexpected layers, or behaved suspiciously despite a previously clean manifest. CI is the better prevention point, while runtime detection is the better incident signal when prevention is bypassed.

## Bonus

Rule:

```yaml
- rule: Suspicious Mining Pool Connection
  desc: Detect a likely cryptominer process connecting to a common mining pool port
  condition: >
    evt.type=connect and container.id != host and
    (fd.sport in (3333, 4444, 5555, 7777, 14444) or fd.rport in (3333, 4444, 5555, 7777, 14444) or
     evt.arg.addr regex ".*:(3333|4444|5555|7777|14444)") and
    (proc.name in (xmrig, minerd, cpuminer, ccminer, cryptonight, nc, ncat, netcat) or proc.cmdline contains "nc -w")
  output: Suspicious mining pool connection (container=%container.name process=%proc.name command=%proc.cmdline destination=%fd.rip:%fd.rport requested_addr=%evt.arg.addr)
  priority: CRITICAL
  tags: [container, mitre_command_and_control]
```

Alert produced by the refused connection test:

```json
{"hostname":"3eaa237f5bdf","output":"2026-10-11T20:34:43.737481594+0000: Critical Suspicious mining pool connection (container=lab9-target process=nc command=nc -w 2 127.0.0.1 3333 destination=<NA>:<NA> requested_addr=127.0.0.1:3333) container_id=fe692f5abdc5 container_name=lab9-target container_image_repository=alpine container_image_tag=3.20 k8s_pod_name=<NA> k8s_ns_name=<NA>","output_fields":{"container.id":"fe692f5abdc5","container.image.repository":"alpine","container.image.tag":"3.20","container.name":"lab9-target","evt.arg.addr":"127.0.0.1:3333","evt.time.iso8601":1791750883737481594,"fd.rip":null,"fd.rport":null,"k8s.ns.name":null,"k8s.pod.name":null,"proc.cmdline":"nc -w 2 127.0.0.1 3333","proc.name":"nc"},"priority":"Critical","rule":"Suspicious Mining Pool Connection","source":"syscall","tags":["container","mitre_command_and_control"],"time":"2026-10-11T20:34:43.737481594Z"}
```

A refused connection is still enough for this kind of detection because Falco observes the process making the kernel `connect` attempt, not application-level success. The rule checks both the populated socket fields (`fd.sport`/`fd.rport`) and the syscall address argument (`evt.arg.addr`), so it can still match when the refused attempt does not produce a complete socket tuple. That means Falco sits below the application and can see intent even when no remote service accepts the connection.

Changing the port is free for an attacker, so the port list is the weakest part of the detection. Changing the process name is also cheap if they can rename a binary, but changing the overall behavior is more expensive: miners still need CPU/GPU-heavy execution, pool-like outbound traffic, and often wallet or stratum-style command lines. To catch evasion, I would add process ancestry, sustained CPU usage, unusual outbound destinations, and command-line indicators such as wallet/pool arguments instead of relying only on common ports.
