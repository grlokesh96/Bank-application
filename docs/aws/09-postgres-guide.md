# Phase 9 — PostgreSQL Database Guide

This guide explains how to connect to the PostgreSQL database running inside the
EKS cluster and query the tables belonging to the banking platform's Go
microservices.

It is the **post-deploy companion** to `docs/aws/01–08` — once Argo CD is green
and the `banking` pods are Ready, every command below works as-is.

---

## How the database is set up

The platform runs **1 PostgreSQL pod** (`postgres-0`) as a StatefulSet inside the
`banking` namespace. Every microservice points at **one shared database called
`banking`**.

Unlike a "schema-per-service" layout, isolation here is done with **per-service
table *prefixes*** — all tables live in the default `public` schema, and each
service owns tables named `<prefix>_<name>` (e.g. `account_accounts`,
`ledger_entries`, `auth_users`). Each service also keeps its own migration
bookkeeping table `<service>_service_goose_version` (goose migrations).

| Service | Table(s) | What it stores |
|---|---|---|
| **auth-service** | `auth_users` | Login identity — email, bcrypt hash, roles, name |
| **authz-service** | `authz_roles`, `authz_permissions`, `authz_role_permissions`, `authz_user_roles` | RBAC — roles, permissions, mappings |
| **customer-service** | `customer_customers` | Customer records |
| **profile-service** | `profile_profiles` | Editable customer profiles |
| **kyc-service** | `kyc_verifications` | KYC verification records |
| **document-service** | `document_documents` | Document metadata (S3 object refs) |
| **account-service** | `account_accounts` | Bank accounts (number, type, currency, status) |
| **ledger-service** ⭐ | `ledger_accounts`, `ledger_entries`, `ledger_transactions` | **Double-entry ledger** — balances, DEBIT/CREDIT lines, tx headers |
| **transaction-service** | `transaction_transactions` | Deposits / withdrawals / transfers |
| _(shared outbox)_ | `outbox_events` | Transactional outbox → Kafka (written by transaction-service) |
| **beneficiary-service** | `beneficiary_beneficiaries` | Saved payees |
| **payment-service** | `payment_payments` | Payments |
| **wallet-service** | `wallet_wallets`, `wallet_transactions` | Wallets + wallet ledger |
| **card-service** | `card_cards` | Issued cards |
| **loan-service** | `loan_loans` | Loans |
| **emi-service** | `emi_installments` | EMI schedules |
| **fixed-deposit-service** | `fd_deposits` | Fixed deposits |
| **recurring-deposit-service** | `rd_deposits` | Recurring deposits |
| **investment-service** | `inv_holdings` | Investment holdings |
| **currency-exchange-service** | `fx_rates` | FX rates |
| **fraud-service** | `fraud_alerts` | Fraud alerts |
| **audit-service** | `audit_events` | Audit trail |
| **notification-service** | `notification_notifications` | Notifications |
| **email-service** | `email_messages` | Outbound emails |
| **sms-service** | `sms_messages` | Outbound SMS |
| **reports-service** | `reports_daily` | Daily rollups |
| **analytics-service** | `analytics_metrics` | Aggregated metrics |
| **search-service** | `search_index` | Search index rows |
| **statement-service** | `statement_entries` | Account statement lines |
| **support-service** | `support_tickets` | Support tickets |
| **admin-service** | `admin_settings` | Admin settings |

> ⭐ **The double-entry ledger is the heart of the system.** `ledger-service`
> owns three tables: `ledger_accounts` (current balance per account),
> `ledger_entries` (one row per DEBIT/CREDIT — every transaction produces a
> balanced pair), and `ledger_transactions` (the transaction header). Balances are
> **derived** from entries; the transaction-service only records intent.

> 💡 **Prefix ≠ owner name always.** A couple of prefixes are short forms:
> `fx_rates` is owned by **currency-exchange-service**, `fd_deposits` by
> **fixed-deposit-service**, `rd_deposits` by **recurring-deposit-service**, and
> `inv_holdings` by **investment-service**.

> 💡 The `*_service_goose_version` tables (one per service) are **migration
> bookkeeping** — ignore them in day-to-day queries.

---

## Step 1: Connect to the pod

Make sure your `kubectl` context points at the cluster:

```bash
aws eks update-kubeconfig --name banking-dev --region us-east-1

# Sanity-check: pod should be Running 1/1
kubectl -n banking get pod postgres-0
```

The DB credentials are the dev defaults (`banking` / `banking`), so pass the
password via `PGPASSWORD`. Two ways to query — pick what fits.

### Option A — Run a single query (quick one-liner)
```bash
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking \
  psql -U banking -d banking -c "<SQL query>"
```
**Example:**
```bash
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking \
  psql -U banking -d banking -c "SELECT id, email, roles FROM auth_users;"
```

### Option B — Interactive `psql` shell (exploration)
```bash
kubectl -n banking exec -it postgres-0 -- env PGPASSWORD=banking \
  psql -U banking -d banking
```
You'll get the `banking=#` prompt. Useful commands:
```sql
\dt                       -- list ALL tables (they're in public, so this just works)
\dt account_*             -- only the account-service tables
\d account_accounts       -- columns + indexes + constraints
\d+ ledger_entries        -- + storage stats
SELECT * FROM auth_users LIMIT 5;
\q                        -- exit
```
> 💡 Unlike a schema-per-service layout, plain `\dt` **works here** — every table
> lives in `public`. Use `\dt <prefix>_*` to filter to one service.

---

## Step 2: Query the core tables

### auth-service — `auth_users`
Login identity (what `/api/v1/auth/register` and `/login` write).

| Column | Type | Description |
|---|---|---|
| `id` | uuid | User ID — the JWT `sub`; referenced as `customer_id` on accounts |
| `email` | text | Unique login email |
| `password_hash` | text | bcrypt hash (never the raw password) |
| `full_name` | text | Display name |
| `roles` | text | Comma-separated roles (e.g. `customer`) |
| `created_at` | timestamptz | Signup time |

```bash
# Every registered account
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT id, email, roles, created_at FROM auth_users ORDER BY created_at DESC;"

# Count total accounts
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT COUNT(*) AS total_users FROM auth_users;"

# Find one user by email
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT id, email, roles FROM auth_users WHERE email = 'demo@bank.io';"

# Signups today
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT id, email, created_at FROM auth_users WHERE created_at::date = CURRENT_DATE;"
```

### account-service — `account_accounts`
Bank accounts. `customer_id` = the owner's `auth_users.id`.

| Column | Type | Description |
|---|---|---|
| `id` | uuid | Account ID — the key used by transactions and the ledger |
| `account_number` | text | 12-digit human-facing number (shown in the UI) |
| `customer_id` | text | Owner (`auth_users.id`) |
| `type` | text | `SAVINGS` / `CURRENT` |
| `currency` | text | `USD` / `INR` / … |
| `status` | text | `ACTIVE` / … |
| `created_at` | timestamptz | When opened |

```bash
# All accounts
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT account_number, id, customer_id, type, currency, status FROM account_accounts ORDER BY created_at DESC;"

# Accounts for one customer (replace CUSTOMER_ID = auth_users.id)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT account_number, type, currency, status FROM account_accounts WHERE customer_id = 'CUSTOMER_ID';"

# Accounts joined to the owner's email (cross-service join)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT u.email, a.account_number, a.type, a.currency
      FROM account_accounts a JOIN auth_users u ON u.id::text = a.customer_id
      ORDER BY u.email;"

# Accounts by type/currency
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT type, currency, COUNT(*) FROM account_accounts GROUP BY type, currency ORDER BY 3 DESC;"
```

### ⭐ ledger-service — the double-entry ledger

`ledger_accounts` (balances), `ledger_entries` (DEBIT/CREDIT lines),
`ledger_transactions` (headers). `account_id` matches `account_accounts.id`.

**`ledger_accounts`** — current balance per account
| Column | Type | Description |
|---|---|---|
| `account_id` | uuid | = `account_accounts.id` (a system account exists per currency for deposits) |
| `currency` | text | Account currency |
| `balance` | numeric | Current balance |
| `created_at` | timestamptz | First seen |

**`ledger_entries`** — one row per DEBIT/CREDIT (always balanced per tx)
| Column | Type | Description |
|---|---|---|
| `id` | uuid | Entry ID |
| `transaction_id` | uuid | Groups the entries of one transaction |
| `account_id` | uuid | Affected account |
| `direction` | text | `DEBIT` or `CREDIT` |
| `amount` | numeric | Entry amount |
| `currency` | text | Currency |
| `created_at` | timestamptz | Posted |

```bash
# Balances (yours + the per-currency system accounts)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT account_id, currency, balance FROM ledger_accounts ORDER BY balance DESC;"

# Balance of a specific account (replace ACCOUNT_ID = account_accounts.id)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT balance, currency FROM ledger_accounts WHERE account_id = 'ACCOUNT_ID';"

# All entries for one transaction (should net to zero: DEBIT == CREDIT)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT account_id, direction, amount FROM ledger_entries WHERE transaction_id = 'TX_ID' ORDER BY direction;"

# INVARIANT CHECK — every transaction must balance (this should return 0 rows)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT transaction_id,
             SUM(CASE WHEN direction='DEBIT'  THEN amount ELSE 0 END) AS debits,
             SUM(CASE WHEN direction='CREDIT' THEN amount ELSE 0 END) AS credits
      FROM ledger_entries GROUP BY transaction_id
      HAVING SUM(CASE WHEN direction='DEBIT' THEN amount ELSE 0 END)
           <> SUM(CASE WHEN direction='CREDIT' THEN amount ELSE 0 END);"

# Recent ledger activity for one account
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT direction, amount, currency, created_at FROM ledger_entries
      WHERE account_id = 'ACCOUNT_ID' ORDER BY created_at DESC LIMIT 20;"
```

### transaction-service — `transaction_transactions`
The business-level record of each money movement (the ledger is the accounting side).

| Column | Type | Description |
|---|---|---|
| `id` | uuid | Transaction ID |
| `idempotency_key` | text | Dedup key — safe retries replay the same result |
| `type` | text | `DEPOSIT` / `WITHDRAWAL` / `TRANSFER` |
| `from_account_id` | uuid | Source (null for deposits) |
| `to_account_id` | uuid | Destination (null for withdrawals) |
| `amount` | numeric | Amount |
| `currency` | text | Currency |
| `status` | text | `POSTED` / … |
| `reference` | text | Free-text note |
| `created_at` | timestamptz | When posted |

```bash
# Every transaction
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT type, from_account_id, to_account_id, amount, currency, status, created_at
      FROM transaction_transactions ORDER BY created_at DESC;"

# Count + volume by type
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT type, COUNT(*), SUM(amount) AS volume FROM transaction_transactions GROUP BY type;"

# All transactions touching one account (in or out)
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT type, amount, currency, status, created_at FROM transaction_transactions
      WHERE from_account_id = 'ACCOUNT_ID' OR to_account_id = 'ACCOUNT_ID' ORDER BY created_at DESC;"
```

### outbox — `outbox_events`
The **transactional outbox**: events written in the same DB tx as the state
change, then relayed to Kafka. `sent_at` is set once published.

| Column | Type | Description |
|---|---|---|
| `id` | uuid | Event ID |
| `source` | text | Producing service |
| `topic` | text | Kafka topic |
| `key` | text | Partition key (usually an account ID) |
| `payload` | bytea | Event body (JSON bytes) |
| `created_at` | timestamptz | When enqueued |
| `sent_at` | timestamptz | When published to Kafka (null = pending) |

```bash
# Recent events + whether they've been published
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT source, topic, key, created_at, sent_at FROM outbox_events ORDER BY created_at DESC LIMIT 20;"

# Unpublished (stuck) events — should be ~0 in a healthy system
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT COUNT(*) AS pending FROM outbox_events WHERE sent_at IS NULL;"

# Decode a payload to readable text
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT topic, convert_from(payload,'UTF8') AS json FROM outbox_events ORDER BY created_at DESC LIMIT 1;"
```

### payment-service — `payment_payments`
| Column | Type | Description |
|---|---|---|
| `id` | uuid | Payment ID |
| `payer_account_id` | uuid | Source account |
| `beneficiary_id` | text | Payee |
| `amount` / `currency` | numeric / text | Amount charged |
| `status` | text | `SUCCESS` / `FAILED` / … |
| `reference` / `idempotency_key` | text | Note / dedup key |
| `created_at` | timestamptz | When attempted |

```bash
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT id, payer_account_id, amount, currency, status, created_at FROM payment_payments ORDER BY created_at DESC;"
```

### The other services (generic pattern)
Every service follows the same shape — just swap the table name from the
inventory at the top. Examples:
```bash
# Notifications dispatched
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT * FROM notification_notifications ORDER BY 1 LIMIT 20;"

# Audit trail
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT * FROM audit_events ORDER BY 1 DESC LIMIT 20;"

# FX rates
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT * FROM fx_rates;"

# Statement lines
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT * FROM statement_entries ORDER BY 1 DESC LIMIT 20;"

# RBAC: roles and permissions
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT * FROM authz_roles;  SELECT * FROM authz_permissions;"
```
> Tip: `\d <table>` in an interactive shell shows any table's exact columns.

---

## Useful dashboard queries

```bash
# ─── Row count of EVERY data table at once (best post-deploy sanity check) ───
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT relname AS table, n_live_tup AS rows
      FROM pg_stat_user_tables
      WHERE schemaname='public' AND relname NOT LIKE '%goose_version'
      ORDER BY n_live_tup DESC, relname;"

# ─── Accounts + total money in the ledger ───
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT (SELECT COUNT(*) FROM auth_users)        AS users,
             (SELECT COUNT(*) FROM account_accounts)  AS accounts,
             (SELECT COUNT(*) FROM transaction_transactions) AS txns;"

# ─── Ledger balances by currency ───
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT currency, SUM(balance) AS total_balance FROM ledger_accounts GROUP BY currency;"

# ─── Transaction volume by type ───
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT type, COUNT(*) AS n, SUM(amount) AS volume FROM transaction_transactions GROUP BY type;"

# ─── Outbox health (pending should be ~0) ───
kubectl -n banking exec postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking \
  -c "SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE sent_at IS NULL) AS pending FROM outbox_events;"
```

---

## Quick copy-paste: interactive shell session
```bash
kubectl -n banking exec -it postgres-0 -- env PGPASSWORD=banking psql -U banking -d banking
```
Inside `psql`:
```sql
\dt                         -- all tables
\dt ledger_*                -- just the ledger

SELECT email, roles FROM auth_users LIMIT 5;
SELECT account_number, type, currency FROM account_accounts;
SELECT account_id, balance, currency FROM ledger_accounts;
SELECT type, amount, status FROM transaction_transactions ORDER BY created_at DESC LIMIT 10;
\q
```

---

## Connection details (reference)

| Setting | Value |
|---|---|
| Host (in-cluster) | `postgres.banking.svc.cluster.local` (or just `postgres` within the namespace) |
| Port | `5432` |
| Username | `banking` |
| Password | `banking` (dev default — the `POSTGRES_PASSWORD` key of the shared Secret, see [`k8s/01-secret.example.yaml`](../../k8s/01-secret.example.yaml)) |
| Database | `banking` |
| Pod | `postgres-0` |
| Namespace | `banking` |
| StatefulSet | `postgres` |
| PVC | `data-postgres-0` (2 Gi, StorageClass `gp3`) |
| Layout | single DB, **per-service table prefixes** in the `public` schema |

> 🔐 **The password is a dev default.** `banking` is fine for a learning cluster
> but is plaintext in the chart values. For production, use a real Secret (AWS
> Secrets Manager + External Secrets Operator, or a pre-created `kubectl` secret).

---

## Connecting from your laptop (optional)

To use a GUI (DBeaver, TablePlus) or local `psql`, port-forward the service:
```bash
kubectl -n banking port-forward svc/postgres 5433:5432
```
Then connect to:

| Setting | Value |
|---|---|
| Host | `localhost` |
| Port | `5433` |
| Database | `banking` |
| Username | `banking` |
| Password | `banking` |

Press `Ctrl-C` in the port-forward terminal to stop.
