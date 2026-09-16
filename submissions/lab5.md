# Lab 5 - SAST and DAST

## Task 1

Target image: `bkimminich/juice-shop:v20.0.0`.

ZAP command notes:
- The unauthenticated baseline used `zap-baseline.py` against `http://juice-shop:3000`.
- The authenticated run used ZAP Automation Framework with the `admin@juice-sh.op` account, bearer-token session management, requestor-seeded authenticated API endpoints, and an active scan over that small authenticated tree. The provided full Ajax-spider plan reached 773 URLs and was killed by the local Docker runtime, so I used the same ZAP toolchain with a narrower authenticated scope to produce a complete JSON report.

| Run | Time | High | Medium | Low | Info | Total alerts | Highest risk |
|---|---:|---:|---:|---:|---:|---:|---|
| Unauthenticated baseline | 58.95s | 0 | 2 | 5 | 3 | 10 | Medium |
| Authenticated active scan | 1m 11.07s | 1 | 1 | 2 | 3 | 7 | High |

The unauthenticated baseline reported more alerts in total: 10 versus 7. The authenticated run found the more serious issue because it reached a High-risk `SQL Injection` alert on the login flow, while the baseline's highest level was Medium.

Authenticated-only alerts:

| Alert | URL | Why baseline did not reach it |
|---|---|---|
| `SQL Injection` | `http://juice-shop:3000/rest/user/login` | The authenticated automation exercised the login request as part of the JSON authentication flow and active scan; the passive baseline only crawled anonymous GET traffic and did not actively mutate the login POST body. |
| `Private IP Disclosure` | `http://juice-shop:3000/rest/admin/application-configuration` | This endpoint was seeded as an authenticated admin/API request with a bearer token. The anonymous baseline did not have an authenticated session or an explicit request to this protected API path. |

"Number of alerts" is a weak comparison metric because it mixes duplicates, passive header findings, crawler coverage, and active exploitation evidence into one flat count. Here the smaller authenticated report is more important because it includes a High-risk SQL injection, while the larger baseline mostly found repeated header/cache issues. For a team lead, I would report coverage, highest risk, exploitability, and affected endpoints rather than only the total. A pipeline whose only DAST step is `zap-baseline.py` against staging can miss authenticated and active-scan-only defects, so it should add authenticated scanning for critical workflows and fail on severity/triage policy, not raw alert count.

## Task 2

Semgrep version: `1.176.0`.

Scan command:

```bash
semgrep --config=p/owasp-top-ten --config=p/javascript --config=p/secrets \
  --severity ERROR --severity WARNING \
  --json -o labs/lab5/results/semgrep.json \
  labs/lab5/semgrep/juice-shop
```

Severity split:

| Severity | Count |
|---|---:|
| ERROR | 13 |
| WARNING | 14 |

Top rules:

| Count | Rule |
|---:|---|
| 6 | `javascript.sequelize.security.audit.sequelize-injection-express.express-sequelize-injection` |
| 5 | `yaml.github-actions.security.run-shell-injection.run-shell-injection` |
| 4 | `javascript.express.security.audit.express-check-directory-listing.express-check-directory-listing` |
| 4 | `javascript.express.security.audit.express-res-sendfile.express-res-sendfile` |
| 4 | `yaml.github-actions.security.github-actions-mutable-action-tag.github-actions-mutable-action-tag` |
| 1 | `javascript.express.security.audit.express-open-redirect.express-open-redirect` |
| 1 | `javascript.jsonwebtoken.security.jwt-hardcode.hardcoded-jwt-secret` |
| 1 | `javascript.lang.security.audit.code-string-concat.code-string-concat` |
| 1 | `yaml.github-actions.security.gha-curl-pipe-shell.gha-curl-pipe-shell` |

Error count: 38.

Workflow finding connected to Lecture 4: `yaml.github-actions.security.run-shell-injection.run-shell-injection` appears in `.github/workflows/update-challenges-www.yml:27` and related workflow files. This maps to CI/CD pipeline security from Lecture 4 because untrusted GitHub context interpolation inside `run:` can become command injection in the build runner and expose repository secrets.

False positive I would suppress: `data/static/codefixes/dbSchemaChallenge_1.ts:5`, rule `javascript.sequelize.security.audit.sequelize-injection-express.express-sequelize-injection`.

The line is:

```ts
models.sequelize.query("SELECT * FROM Products WHERE ((name LIKE '%"+criteria+"%' OR description LIKE '%"+criteria+"%') AND deletedAt IS NULL) ORDER BY name")
```

It is a real vulnerable pattern, but this path is under `data/static/codefixes/`, which contains deliberately vulnerable teaching snippets shown by Juice Shop's code-fix/challenge material rather than the runtime Express route. I would suppress that path for production triage while keeping the same rule enabled for application routes such as `routes/login.ts` and `routes/search.ts`.

If I could fix one rule's findings this sprint, I would fix `javascript.sequelize.security.audit.sequelize-injection-express.express-sequelize-injection`. It has the highest count, includes runtime files such as `routes/login.ts:34` and `routes/search.ts:23`, and corresponds to exploitable OWASP A03 Injection behavior. The fix is to replace string-interpolated SQL with parameterized Sequelize queries/replacements and add regression tests for quote/comment payloads.

## Bonus

| OWASP category | ZAP alert and URL | Semgrep rule and source |
|---|---|---|
| A03: Injection | `SQL Injection` on `POST http://juice-shop:3000/rest/user/login` | `javascript.sequelize.security.audit.sequelize-injection-express.express-sequelize-injection`, `routes/login.ts:34` |

Vulnerable source lines:

```ts
return (req: Request, res: Response, next: NextFunction) => {
  verifyPreLoginChallenges(req)
  models.sequelize.query(`SELECT * FROM Users WHERE email = '${req.body.email || ''}' AND password = '${security.hash(req.body.password || '')}' AND deletedAt IS NULL`, { model: UserModel, plain: true })
```

ZAP request evidence:
- Method: `POST`
- URL: `http://juice-shop:3000/rest/user/login`
- Parameter: `email`
- Attack payload: `'`
- Evidence: `HTTP/1.1 500 Internal Server Error`

Minimal reproducer:

```http
POST /rest/user/login HTTP/1.1
Host: juice-shop:3000
Content-Type: application/json

{"email":"'","password":"admin123"}
```

The fix I would open a PR with is to parameterize the query instead of interpolating `req.body.email` and the password hash into SQL:

```ts
models.sequelize.query(
  'SELECT * FROM Users WHERE email = $email AND password = $password AND deletedAt IS NULL',
  {
    bind: {
      email: req.body.email || '',
      password: security.hash(req.body.password || '')
    },
    model: UserModel,
    plain: true
  }
)
```

I would put the SQL injection first in the PR description. It is independently confirmed by SAST and DAST, affects an authentication endpoint, has a concrete request-level reproducer, and maps to a high-impact OWASP Top 10 category.
