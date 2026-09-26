# Privacy by design

How any app or script here handles personal data: what it collects, keeps, shares and deletes.
The data tiers in [security & privacy §1](security-and-privacy.md#1-principles-and-data-tiers)
decide *where data sits relative to git*. This doc decides *how the running code treats it*.
Secure coding: [secure development](secure-development.md). Assistants and connectors:
[AI and external services](ai-and-external-services.md).

**Data you never collect cannot leak, be subpoenaed, or need deleting.** Minimization is the
cheapest control there is; every rule below is a fallback for what was collected anyway.

---

## 1. Classify before storing

Every field an app stores, and every dataset a script processes, gets one class:

| Class | Examples | Rules |
|---|---|---|
| **Public** | Published content, public profiles, open datasets | No restriction beyond licence |
| **Internal** | Config, aggregate metrics, non-personal logs | Not published; no special handling |
| **Personal** | Name, email, account ID, IP address, device ID, usage history | §2–§6 apply |
| **Sensitive** | Health, finance, precise location, government IDs, biometrics, contacts, private messages, photos of people, **any data about people other than the user** | Everything for Personal, plus §5; local-only by default |

- **Take the stricter class when unsure**, as the policy does for sensitivity in general.
- **Derived data carries the class of its source.** Embeddings, indexes, summaries and caches
  built from Sensitive data are Sensitive.
- **Combination raises the class.** Separately harmless fields (timestamps + coarse location +
  device) can identify a person together.

## 2. Minimize

- **Each Personal or Sensitive field has a stated purpose**, in the schema comment or the
  project's README. A field with no purpose is not collected.
- **Prefer less precise forms**: year of birth over date, city over coordinates, a hash or
  internal ID over an email wherever joining is all that's needed.
- **Don't collect for "later".** Adding a field later is a migration; removing one after a leak
  is too late.
- **Scripts over personal exports** (email, messages, bookmarks, contacts) read the minimum
  columns and write only the result, not a full working copy.

## 3. Where it lives and who can reach it

- **Encrypt at rest where the platform allows it** (managed Postgres, object storage and
  FileVault do by default; a SQLite file on a shared volume does not).
- **Access is least privilege**: application roles read only the tables they need; admin access is
  separate from application access.
- **Local-only data stays out of synced folders** (iCloud Drive, Dropbox, Google Drive) unless
  syncing it is the intent. A synced folder is a third party (§6).
- **Test and development use synthetic data**, per Tier C in the policy. Real Personal data never
  goes into a fixture, a screenshot or a bug report.

## 4. Retention and deletion

- **Every Personal and Sensitive store has a retention period** and a mechanism that enforces it: a
  scheduled delete, a TTL, or a documented manual step with a date.
- **Deletion is a tested path**, not a promise. For an app with users: deleting an account
  removes or anonymizes their rows, uploaded files and derived data, and the test proves it.
- **Logs and analytics count.** Default log retention: 30 days unless a reason is recorded.
- **Backups are copies.** Deleted data survives in backups until they rotate; retention on the
  backup destination must be finite and known ([backups](backups.md)).
- **Raw exports are deleted once processed** unless they are the canonical original (then they
  are backed up deliberately, per the backups policy).

## 5. Other people's data

Contacts, message histories, shared photos, family archives and anything else about people who
did not choose to be in it is **Sensitive by default**, whatever its content.

- **Tier A only** (outside the tree) — never Tier B, even gitignored.
- **Never sent to a hosted service**, LLM APIs included, without a decision entry in the project's
  `DECISIONS.md` naming the service and what it receives. Local processing is the default route
  ([AI and external services](ai-and-external-services.md#2-what-may-go-to-a-hosted-model)).
- **No publication of derived output** (charts, quotes, statistics about named people) without
  their consent.

## 6. Third parties

Each project that handles Personal data keeps a **processor list** in its README:

| Processor | Purpose | Data it receives | Region / retention |
|---|---|---|---|
| e.g. hosting, database, email, analytics, error tracking, LLM API | | | |

- **No analytics, tracking pixels, session replay or third-party fonts/scripts that phone home**
  unless asked for. Where analytics is wanted, prefer cookieless, aggregate, first-party tools.
- **Error trackers receive personal data by default** (request bodies, user emails, IPs). Turn
  that off (`sendDefaultPii: false` or equivalent) and scrub before sending.
- **Check each processor's training and retention terms** before sending Personal data. "Free
  tier" often means "your data trains the model".

## 7. Telling people

A public app with users states, in plain language on a page they can find: what is collected and
why, which processors receive it, how long it is kept, and how to get it deleted. If that page
would be embarrassing to write, the design is wrong, not the page.

## 8. Checklist for a new project or feature touching personal data

1. Each new field classified (§1) with a purpose (§2).
2. Retention period set and enforcement in place (§4); the delete path tested.
3. Processor list updated (§6); no new tracking added unasked.
4. Other people's data? Tier A, local processing, decision entry (§5).
5. Logs and error reports checked for leaked Personal data
   ([secure development §6](secure-development.md#6-errors-and-logging)).
