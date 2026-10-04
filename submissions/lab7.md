# Lab 7 - Container and Kubernetes Hardening

## Environment

- Docker `28.4.0`
- Trivy `0.74.0`
- kubectl client `v1.34.1`
- k3d `v5.9.0`
- jq `1.7.1`

## Task 1

### Image Vulnerability Counts

Command:

```bash
trivy image bkimminich/juice-shop:v20.0.0 --severity HIGH,CRITICAL \
  --format json --output labs/lab7/results/trivy-image.json
```

| Severity | Trivy count | With a fixed version |
| --- | ---: | ---: |
| CRITICAL | 11 | 8 |
| HIGH | 74 | 69 |

### Trivy vs Grype From Lab 4

| Tool | CRITICAL | HIGH | Total HIGH+CRITICAL |
| --- | ---: | ---: | ---: |
| Trivy image scan | 11 | 74 | 85 |
| Grype from Lab 4 SBOM | 14 | 85 | 99 |

The totals differ because the tools use different vulnerability databases, matching logic, severity sources, and package evidence. The SBOM-based Grype result also depends on what the Lab 4 SBOM captured, while Trivy scanned the current local image directly with its current database.

### Top Ten Fixable Findings

```text
CRITICAL  CVE-2023-46233  crypto-js 3.3.0 -> 4.2.0
CRITICAL  CVE-2026-71851  crypto-js 3.3.0 -> 4.0.0
CRITICAL  CVE-2015-9235   jsonwebtoken 0.1.0 -> 4.2.2
CRITICAL  CVE-2015-9235   jsonwebtoken 0.4.0 -> 4.2.2
CRITICAL  CVE-2019-10744  lodash 2.4.2 -> 4.17.12
CRITICAL  CVE-2026-59873  tar 4.4.19 -> 7.5.19
CRITICAL  CVE-2026-59873  tar 6.2.1 -> 7.5.19
CRITICAL  CVE-2026-59873  tar 7.5.15 -> 7.5.19
HIGH      CVE-2026-14456  libssl3t64 3.5.5-1~deb13u2 -> 3.5.7-1~deb13u2
HIGH      CVE-2026-45447  libssl3t64 3.5.5-1~deb13u2 -> 3.5.6-1~deb13u2
```

### Dockerfile Findings

| ID | Severity | Finding | Attacker impact |
| --- | --- | --- | --- |
| DS-0001 | MEDIUM | `FROM node:latest` uses a moving tag. | A rebuild can silently pick up a different base image, changing code, packages, and vulnerabilities without review. |
| DS-0002 | HIGH | The final user is `root`. | A successful exploit inside the container gets root inside the container and has a better chance of abusing writable mounts, kernel bugs, or weak runtime settings. |
| DS-0004 | MEDIUM | Port 22 is exposed. | It advertises an unnecessary remote administration surface and can encourage SSH access into a workload that should be rebuilt, not logged into. |
| DS-0026 | LOW | No `HEALTHCHECK`. | The platform has less signal when the process is wedged, so broken containers may stay in service longer. |

### No-Fix Vulnerabilities

For vulnerabilities with no released fixed version, I would not open fake "upgrade" tickets. I would record them as accepted short-term risk with compensating controls: non-root execution, dropped capabilities, restricted Pod Security admission, NetworkPolicy egress limits, image pinning by digest, and runtime monitoring. I would also track upstream package and image releases so the backlog reopens when a real fix appears. To a manager, I would say the number is not zero because some advisories do not have a vendor patch yet; the actionable question is whether exploitable paths are reduced and whether we can update quickly when fixes land.

## Task 2

### Namespace Labels

`labs/lab7/k8s/namespace.yaml` enforces, warns, and audits the `restricted` Pod Security profile:

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```

### Security Contexts

Pod-level security context from `labs/lab7/k8s/deployment.yaml`:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
```

Container-level security context in the main restricted deployment:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

The image user was verified with:

```bash
docker inspect bkimminich/juice-shop:v20.0.0 --format '{{.Config.User}}'
```

Output:

```text
65532
```

The image is pinned as:

```text
bkimminich/juice-shop@sha256:fd58bdc9745416afce8184ee0666278a436574633ea7880365153a63bfd418b0
```

### Running Proof

Commands:

```bash
k3d cluster create lab7 --image rancher/k3s:v1.33.0-k3s1
kubectl apply -f labs/lab7/k8s/namespace.yaml
kubectl apply -f labs/lab7/k8s/
kubectl -n juice-shop wait --for=condition=ready pod -l app=juice-shop --timeout=180s
kubectl -n juice-shop get pod -l app=juice-shop -o yaml > labs/lab7/results/pod-spec.yaml
kubectl -n juice-shop exec deploy/juice-shop -- \
  /nodejs/bin/node -e 'console.log(`uid=${process.getuid()} gid=${process.getgid()}`)'
```

Proof:

```text
NAME                        READY   STATUS    RESTARTS   AGE   IP           NODE
juice-shop-5f5f57d8-vw754   1/1     Running   0          15s   10.42.0.12   k3d-lab7-server-0
uid=65532 gid=65532
```

### Trivy Kubernetes Summary

Plain namespace:

```text
Namespace     Resource          Vulnerabilities C/H   Misconfigurations C/H   Secrets C/H
juice-plain   Deployment/juice  11 / 74                0 / 3                 0 / 2
```

Restricted namespace:

```text
Namespace    Resource               Vulnerabilities C/H   Misconfigurations C/H   Secrets C/H
juice-shop   Deployment/juice-shop  11 / 74                0 / 1                 0 / 2
```

The vulnerability counts did not change because both deployments run the same Juice Shop image. Misconfiguration counts improved because the hardened manifest sets the restricted-profile controls: non-root user, seccomp, no privilege escalation, dropped capabilities, service account token disabled, resource limits, and a NetworkPolicy. The one remaining HIGH misconfiguration is `KSV-0014 Root file system is not read-only`, which is outside the restricted profile and handled in the bonus manifest.

One thing `restricted` blocked during the manifest design is a pod that allows privilege escalation or keeps default Linux capabilities. One control the profile does not require that I added anyway is a default-deny NetworkPolicy with only HTTP ingress and DNS egress reopened.

## Bonus

The read-only Docker run failed as expected:

```text
Error: EROFS: read-only file system, copyfile '/juice-shop/data/static/legal.md' -> '/juice-shop/ftp/legal.md'
ConnectionError [SequelizeConnectionError]: SQLITE_CANTOPEN: unable to open database file
```

Trimmed `docker diff` paths that matter:

```text
C /juice-shop/frontend/dist/frontend
A /juice-shop/frontend/dist/frontend/assets/public/images/hackingInstructor.png
A /juice-shop/frontend/dist/frontend/assets/public/images/ChatbotAvatar.png
A /juice-shop/frontend/dist/frontend/assets/public/videos/owasp_promo.vtt
C /juice-shop/frontend/dist/frontend/index.html
C /juice-shop/ftp
A /juice-shop/ftp/legal.md
C /juice-shop/data
A /juice-shop/data/juiceshop.sqlite
C /juice-shop/logs
A /juice-shop/logs/access.log.2026-10-04
A /juice-shop/logs/audit.json
C /juice-shop/i18n
A /juice-shop/i18n/*.json
C /juice-shop/.well-known/csaf/provider-metadata.json
```

Bonus manifest: `labs/lab7/k8s/deployment-readonly.yaml`.

Final volume layout:

| Mount | Why it is writable |
| --- | --- |
| `/juice-shop/data` | SQLite database and static source files used during startup live here. |
| `/juice-shop/ftp` | Startup restores files such as `legal.md` into this directory. |
| `/juice-shop/i18n` | The app writes generated translation JSON files. |
| `/juice-shop/frontend/dist/frontend` | Startup writes frontend assets and updates `index.html`. |
| `/juice-shop/.well-known` | Startup modifies CSAF provider metadata. |
| `/juice-shop/logs` | Access and audit logs are written at runtime. |
| `/tmp` | General process scratch space. |

The directories that could not simply be replaced by an empty volume were the ones that already contain shipped application files, especially `/juice-shop/data`, `/juice-shop/ftp`, `/juice-shop/i18n`, `/juice-shop/frontend/dist/frontend`, and `/juice-shop/.well-known`. I solved that by using an init container from the same pinned image to copy the image contents into emptyDir volumes under `/seed/*`, then mounting those seeded volumes over the writable paths in the main container. The init command uses `/nodejs/bin/node -e` because this image has no `/bin/sh`.

Proof:

```text
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE
juice-shop-67d5c99948-vk52r   1/1     Running   0          17s   10.42.0.13   k3d-lab7-server-0

readOnlyRootFilesystem: true
container ready: true
HTTP 200
```
