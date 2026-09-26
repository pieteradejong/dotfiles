# Secure development

What the code itself must do. [Security & privacy](security-and-privacy.md) governs what gets
committed and published; this governs what ships and runs. Data handling:
[privacy by design](privacy-by-design.md). Dependencies and CI: [supply chain](supply-chain.md).

**A private repo does not make a deployed app private.** Anything reachable on a URL is attacked
the same whatever the visibility of its source. Every rule below applies from the first deploy,
not from "when it has users".

---

## 1. Threat model in five lines

Any project that handles authentication, money or personal data gets one, in its README or
`CLAUDE.md`, written before the first deploy and revisited when an entry point is added:

```
Assets:        what an attacker wants (accounts, personal data, API spend, the host)
Actors:        who can reach it (anonymous internet, signed-in users, admins, CI)
Entry points:  every route, webhook, form, file upload, queue consumer, cron
Trust bounds:  where untrusted input crosses into trusted code or storage
Worst case:    the one outcome to design against first
```

Five lines that exist beat a template that doesn't. If "Worst case" is "someone else's data leaks",
the project also follows [privacy by design](privacy-by-design.md).

## 2. Authentication and authorization

- **Use the platform's auth, never hand-rolled**: Supabase Auth, Auth.js, a managed provider.
  No custom password hashing, token formats or session stores.
- **Deny by default.** A new route is private until it is deliberately opened.
- **Authorize on the server, on every request, per object.** Hiding a button is not access control.
  Check that *this* user may act on *this* record (IDOR is the common failure).
- **Supabase:** row-level security enabled on every table, with a policy per operation; a table
  without RLS is readable with the public anon key. The `service_role` key bypasses RLS and never
  leaves the server.
- **Sessions:** short-lived access tokens, server-side revocation on logout and password change.
  MFA on every admin surface.

## 3. Input, output and injection

- **Validate at the boundary** with a schema (Pydantic, zod): type, length, format, allowed values.
  Reject; don't "clean".
- **Parameterized queries only.** No SQL, shell or template built by string concatenation.
- **No `eval`, `exec`, `shell=True`, `child_process.exec` with interpolated input**, and no
  deserializing untrusted data with `pickle` or `yaml.load`.
- **Encode output for its context** (HTML, attribute, URL, JS). Frameworks do this by default;
  `dangerouslySetInnerHTML`, `v-html` and `| safe` switch it off and need a sanitizer and a reason.
- **Server-side fetches of user-supplied URLs** (webhooks, previews, importers) resolve against an
  allowlist and refuse private and link-local ranges. That is SSRF, and it reaches cloud metadata.
- **File uploads:** check type by content, cap the size, store outside the web root under a
  generated name, and serve with `Content-Disposition: attachment` unless intended for display.
- **LLM output is untrusted input.** Validate it like any other input before it reaches a query,
  a shell, a URL fetch or HTML.

## 4. Secrets at runtime

- **Environment or the platform's secret store only**: `.env` locally (gitignored, gate-enforced),
  Vercel/Supabase/GitHub encrypted variables in deployment.
- **Public prefixes publish.** `NEXT_PUBLIC_`, `VITE_` and `EXPO_PUBLIC_` values are compiled into
  the client bundle. Only values safe on a billboard get them: a Supabase anon key is fine; a
  service key, API secret or signing key never is.
- **Fail closed.** A missing secret stops startup with an error naming the variable, never falls
  back to a default or an empty string.
- **Least scope, separate per environment.** Development, preview and production get different
  keys; a key that only reads is issued read-only.
- A leaked secret follows [§8 of the policy](security-and-privacy.md#8-when-a-secret-leaks).

## 5. Web defaults

| Control | Default |
|---|---|
| Transport | HTTPS only; HSTS on custom domains |
| Headers | `Content-Security-Policy` (start from `default-src 'self'`), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `frame-ancestors 'none'` unless embedding is intended |
| Cookies | `HttpOnly`, `Secure`, `SameSite=Lax` or `Strict`; no tokens in `localStorage` when a cookie will do |
| CORS | An explicit origin allowlist; never `*` together with credentials |
| CSRF | The framework's protection on for cookie-authenticated state changes |
| Rate limits | Sign-in, sign-up, password reset, OTP, and any endpoint that costs money (LLM calls, email, SMS) |

## 6. Errors and logging

- **Clients get a generic error and a request ID**; stack traces, SQL and file paths stay in the
  server log. Debug mode never reaches a deployed environment.
- **Never log secrets, tokens, passwords, full request bodies or personal data.** Log IDs, not
  emails. Redact `Authorization` and `Cookie` headers in any request logging middleware.
- **Log security events**: sign-in success and failure, permission denials, admin actions, key
  use. They are what an incident review needs.
- Log retention follows [privacy by design § 4](privacy-by-design.md#4-retention-and-deletion).

## 7. Checks

| Check | Where | Status |
|---|---|---|
| Secret scanning | gate + gitleaks CI | Enforced ([policy §2, §9](security-and-privacy.md#9-secret-scanning-in-ci--the-standard-for-every-repo)) |
| SAST | CodeQL on public repos (free); Semgrep CE (`p/default`) on private ones | Standard for new projects; rollout to existing repos is a sweep |
| Dependency vulnerabilities | Dependabot alerts | Enforced by the GitHub baseline; response times in [supply chain](supply-chain.md#4-vulnerability-response) |
| Pre-merge review of a security-relevant change | `/security-review` in Claude Code | Before merging auth, payment, upload or data-export code |
| Pre-deploy | the pre-ship checklist below | Every first deploy and every new entry point |

A finding from any of these is fixed, or accepted in the project's `DECISIONS.md` with the reason,
never silenced in config without a note.

## 8. Per-stack notes for the templates

| Stack | Watch for |
|---|---|
| `py-fastapi` | Pydantic models on every body and query; `Depends()` auth on routers, not per route by hand; SQLAlchemy bound parameters; `docs_url=None` in production unless the API is public |
| `ts-web` (Vite) | No secret in any `VITE_` variable; the app is static, so all authorization lives in the API it calls |
| `node-express` | `helmet`, `express-rate-limit`, a body-size limit on `express.json()`; `app.disable('x-powered-by')` |
| `rn-supabase` | RLS on every table; `EXPO_PUBLIC_` is public; tokens in `expo-secure-store`, not `AsyncStorage` |
| `vercel-stack` (Next.js) | Server Actions are public endpoints, so check auth inside each one; `server-only` import on modules holding secrets; middleware is not the only authorization layer |

## 9. Pre-ship checklist

Before the first deploy, and before exposing a new entry point:

1. The threat model (§1) exists and names this entry point.
2. Every route is authenticated or deliberately public, and authorization is per object (§2).
3. `grep -rE 'NEXT_PUBLIC_|VITE_|EXPO_PUBLIC_'` shows no secret (§4).
4. Headers and cookies match §5 — check the deployed URL, not the config file
   (`curl -sI <url>`).
5. Error pages show no stack trace in the deployed environment (§6).
6. SAST and Dependabot are clean or triaged (§7).
7. The data it stores is classified, with retention set ([privacy by design](privacy-by-design.md)).
