# Lab 3 — Secure Git

## Task 1

### Git signing configuration

```text
gpg.format=ssh
user.signingkey=/Users/irina/.ssh/id_ed25519.pub
commit.gpgsign=true
tag.gpgsign=true
gpg.ssh.allowedSignersFile=/Users/irina/.config/git/allowed_signers
```

The `allowed_signers` entry used for local verification:

```text
irina.bychkova06@mail.ru namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIESueMTJVsUXa7/iY2oIyF0cLnm/ZtaboyeC0J4jDDoM i.bychkova@innopolis.university
```

### Signed commit proof

```text
commit dfafa9d8b1cf56915830935c8392562d8900c59a
Good "git" signature for irina.bychkova06@mail.ru with ED25519 key SHA256:<redacted>
Author: Irina <irina.bychkova06@mail.ru>
Date:   Wed Sep 16 11:11:42 2026 +0300

    test: first signed commit
```

GitHub Verified commit link: https://github.com/1r444444/DevSecOps-Intro/commit/dfafa9d8b1cf56915830935c8392562d8900c59a

With only an author line, someone could commit a malicious hook, workflow, or configuration change while making it look like it came from me. That creates a repudiation problem: the repository history can claim an identity without cryptographic proof. The Verified badge changes this by showing GitHub could validate the commit signature against a registered signing key, so forged authorship becomes visible during review.

## Task 2

### `.pre-commit-config.yaml`

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: detect-private-key
        exclude: ^labs/lab6/vulnerable-iac/ansible/configure\.yml$
      - id: check-added-large-files
        args: ["--maxkb=1024"]
```

`pre-commit run --all-files`:

```text
Detect hardcoded secrets.................................................Passed
detect private key.......................................................Passed
check for added large files..............................................Passed
```

### Blocked secret commit

```text
Detect hardcoded secrets.................................................Failed
- hook id: gitleaks
- exit code: 1

Finding:     GH_PAT=REDACTED
Secret:      REDACTED
RuleID:      github-pat
Entropy:     4.143943
File:        submissions/leak-attempt.txt
Line:        1
Fingerprint: submissions/leak-attempt.txt:github-pat:1

11:13AM INF 0 commits scanned.
11:13AM INF scanned ~48 bytes (48 bytes) in 29.3ms
11:13AM WRN leaks found: 1

detect private key.......................................................Passed
check for added large files..............................................Passed
```

Proof that it was blocked:

```text
dfafa9d test: first signed commit
```

An `[allowlist]` entry in `.gitleaks.toml` is safest when it is narrow: for example, one exact fake token or one intentionally fake test pattern. It stops being safe when the regex is broad enough to match real credentials, because then true leaks become invisible.

A path exclusion for `docs/` is useful only when the directory contains controlled examples and is reviewed with that assumption. It stops being safe when people can paste real incident notes, screenshots, copied `.env` snippets, or onboarding credentials there, because the scanner will ignore the whole location.

## Bonus

### Before rewrite

`git log --oneline`:

```text
dec086f docs: usage notes
cbde809 feat: empty log
9ed0a3c feat: add config
f492d9e init
```

Counts:

```text
git log -p | grep -c 'ghp_AAAA'    # 2
git log -p | grep -c 'REDACTED'    # 0
```

### Refusal message

```text
Aborting: Refusing to destructively overwrite repo history since
this does not look like a fresh clone.
  (expected at most one entry in the reflog for HEAD)
Please operate on a fresh clone instead.  If you want to proceed
anyway, use --force.
```

The repository was a throwaway sandbox, so I reran the command with `--force`:

```text
git filter-repo --force --replace-text /tmp/replace.txt
```

### After rewrite

`git log --oneline`:

```text
92db7c4 docs: usage notes
43c4c20 feat: empty log
305d861 feat: add config
2511675 init
```

Counts:

```text
git log -p | grep -c 'ghp_AAAA'    # 0
git log -p | grep -c 'REDACTED'    # 2
```

Rewriting history is only step one. The step that ends the incident is rotating the credential, because the original secret may already exist in clones, logs, caches, CI artifacts, or screenshots; rewriting Git history does not make the exposed token unusable.

Two things surprised me. First, `git filter-repo` refused even in a sandbox repo that had just been created, because it checks reflog entries rather than only remotes. Second, the rewrite changed all commit hashes after replacing text, which is easy to underestimate until the before/after logs are side by side.
