# Lab 8 - Supply Chain: Signing, Tampering, and Attestation

## Environment

- Docker `28.4.0`
- Cosign `v3.0.2` from the official Darwin arm64 release binary
- jq `1.7.1`

Note: in this environment `http://localhost:5000/v2/` returned `HTTP 403`, while `http://127.0.0.1:5000/v2/` returned `HTTP 200`. I used `127.0.0.1:5000` for the same local registry so Cosign could reach it directly.

Cosign 3.0.2 also still attempted Rekor upload unless I added `--use-signing-config=false`, so the later attestation/blob commands use both `--tlog-upload=false` and `--use-signing-config=false`.

## Task 1

### Signed Digest

Signed local-registry digest:

```text
127.0.0.1:5000/juice-shop@sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113
```

I selected the registry digest from the `Docker-Content-Digest` header for `127.0.0.1:5000/v2/juice-shop/manifests/v20.0.0`. Docker retained the original multi-platform index digest in `RepoDigests`, while the local push stored a single-platform manifest. Cosign needs the digest actually stored in the local registry.

### Successful Verification

```text
Verification for 127.0.0.1:5000/juice-shop@sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified public key
```

The verified payload reported:

```text
docker-reference: 127.0.0.1:5000/juice-shop@sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113
docker-manifest-digest: sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113
```

### Tamper Result

After overwriting the same tag with Alpine, the tag resolved to:

```text
127.0.0.1:5000/juice-shop@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d
```

Verification failed exactly as:

```text
Error: no signatures found
error during command execution: no signatures found
```

The original digest still verified afterwards. The signature is bound to the immutable manifest digest, not to the mutable tag string. If signatures were bound only to `v20.0.0`, an attacker who can move that tag could make a different image look approved; binding to the digest means the tag can move but the signed object cannot silently change.

## Task 2

### SBOM Attestation

Component counts:

| Source | Components |
| --- | ---: |
| Original `labs/lab4/juice-shop.cdx.json` from `feature/lab4` | 3068 |
| `labs/lab8/results/sbom-from-attestation.json` | 3068 |

I extracted the original committed Lab 4 SBOM without regenerating it, then
attached and verified it using the same image digest and public key:

```bash
mkdir -p /tmp/lab8-original-sbom
git archive feature/lab4 labs/lab4/juice-shop.cdx.json \
  | tar -x -C /tmp/lab8-original-sbom
cosign attest --key labs/lab8/keys/cosign.key --type cyclonedx \
  --predicate /tmp/lab8-original-sbom/labs/lab4/juice-shop.cdx.json \
  --use-signing-config=false --tlog-upload=false --allow-insecure-registry \
  --yes 127.0.0.1:5000/juice-shop@sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113
cosign verify-attestation --key labs/lab8/keys/cosign.pub \
  --insecure-ignore-tlog --allow-insecure-registry --type cyclonedx \
  127.0.0.1:5000/juice-shop@sha256:cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113 \
  | jq -r '.payload | @base64d | fromjson | .predicate' \
  > labs/lab8/results/sbom-from-attestation.json
jq -e -s '.[0] == .[1]' \
  /tmp/lab8-original-sbom/labs/lab4/juice-shop.cdx.json \
  labs/lab8/results/sbom-from-attestation.json
# true: the entire decoded SBOM matches the original, not only its count.
```

The earlier 905-component inventory was a newly generated Trivy SBOM, not the
committed Lab 4 SBOM. The corrected attestation above uses the original file.

Predicate types read from verified payloads:

```text
https://cyclonedx.org/bom
https://slsa.dev/provenance/v0.2
```

Decoded SLSA statement summary:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "subject": [
    {
      "name": "127.0.0.1:5000/juice-shop",
      "digest": {
        "sha256": "cbdfc00de875926f20ff603fac73c5b68577e37680cf2e0c324adda42ffc1113"
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v0.2"
}
```

I supplied the predicate body: builder id, build type, and config source. Cosign filled the in-toto statement wrapper, including `_type`, `subject`, and `predicateType` for the selected attestation type.

The morning after the next Log4Shell, the SBOM attestation lets me query which signed image digests contain the affected package without pulling and rescanning every image first. A signature alone only says an artifact has not changed; it does not say what is inside. For this to work at three in the morning, attestations must be generated consistently in CI, stored with the image digest, and trusted keys or identities must already be known.

## Bonus

Original blob verification:

```text
Verified OK
```

After rebuilding the tarball with a modified `install.sh`, verification failed exactly as:

```text
Error: failed to verify signature: could not verify message: invalid signature when validating ASN.1 encoded signature
error during command execution: failed to verify signature: could not verify message: invalid signature when validating ASN.1 encoded signature
```

A consumer needs the artifact and the signature bundle. The bundle may travel over the same channel as the artifact because the public key verifies it; the public key itself must come from a trusted channel or pinned identity.

Published install instructions should make verification mandatory before execution:

```bash
set -eu
# cosign.pub must already be obtained through a trusted channel.
curl -fsSLO https://downloads.example.com/my-tool.tar.gz
curl -fsSLO https://downloads.example.com/my-tool.tar.gz.bundle
cosign verify-blob --key cosign.pub \
  --bundle my-tool.tar.gz.bundle \
  --insecure-ignore-tlog my-tool.tar.gz || exit 1
tar -xzf my-tool.tar.gz
./install.sh
```

Codecov's broken pattern was not just hosting a script; it was asking users to execute unauthenticated bytes. The step many projects skip is failing closed when signature verification is absent or fails.
