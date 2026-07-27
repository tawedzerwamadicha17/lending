# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Frappe Lending — an open-source Loan Management System packaged as a **Frappe app** that installs on top of **ERPNext** (`required_apps = ["erpnext"]`, both pinned to `>=17.0.0-dev,<18.0.0`). It is not a standalone Python project: nothing here runs without a `frappe-bench` install. There is no `setup.py`/`requirements.txt` to `pip install` — the app is installed into a bench site.

## Development commands

All commands run from the bench directory (`~/frappe-bench`), not from this repo:

```bash
bench get-app /path/to/lending          # install this working copy into the bench
bench --site <site> install-app lending
bench --site <site> migrate             # after changing DocType JSON or adding patches
bench --site <site> console             # interactive shell with frappe bootstrapped
bench build --app lending               # rebuild lending.bundle.js
```

Tests (a site with `allow_tests: true` is required; `bench --site <site> set-config allow_tests true`):

```bash
# whole app
bench --site <site> run-tests --app lending --lightmode

# single module — pass the dotted path to the test file
bench --site <site> run-tests --module lending.loan_management.doctype.loan.test_loan --lightmode

# single test
bench --site <site> run-tests --module lending.loan_management.doctype.loan.test_loan --test test_loan_repayment

# how CI shards it
bench --site <site> run-parallel-tests --app lending --total-builds 3 --build-number 1 --lightmode
```

Linting is pre-commit driven (flake8 + flake8-bugbear, isort, check-ast, YAML). Run `pre-commit run --all-files` from this repo. CI additionally runs semgrep with [frappe/semgrep-rules](https://github.com/frappe/semgrep-rules) — `# nosemgrep` comments in the codebase are deliberate suppressions, don't remove them.

`.github/helper/install.sh` is the authoritative reference for bootstrapping a working environment (frappe + erpnext + payments + mariadb setup). Note it maps branches: `version-1*` → frappe/erpnext `version-15`, `version-16*` → `version-16`, anything else → `develop`.

## Conventions

- **Tabs, not spaces**, in Python and JS (`.editorconfig`); black line-length 99, flake8 max-line 200.
- isort has custom sections: stdlib → thirdparty → **frappe** → **erpnext** → **lending** → firstparty. Import order in existing files follows this; keep it.
- Commits must be [conventional](commitlint.config.js) (`feat:`, `fix:`, `chore:`, …) — enforced on PRs, and semantic-release derives versions from them.
- Pre-commit blocks direct commits to `develop`. Backports to release branches happen via Mergify labels (`backport version-16`, etc.).
- `require_type_annotated_api_methods = True` in hooks.py — every `@frappe.whitelist()` function must have annotated params.
- The `# begin: auto-generated types` blocks in DocType controllers are generated from the JSON; regenerate rather than hand-edit.

## Architecture

Two Frappe modules (`lending/modules.txt`): **Loan Management** (nearly everything) and **Loan Origination** (lead → application intake).

### The document lifecycle

The core money flow is a chain of submittable documents, each generating GL entries:

1. **Loan Lead** / **Loan Application** (origination, workflow-driven) → converts to a **Loan**.
2. **Loan** — the master record. Status flows `Draft → Sanctioned → Partially Disbursed → Disbursed → Active → Loan Closure Requested → Closed`, with `Written Off` / `Settled` terminals.
3. **Loan Repayment Schedule** — generated per disbursement. `repayment_schedule_type` on **Loan Product** drives amortization: `Monthly as per repayment start date`, `Pro-rated calendar months`, `Monthly as per cycle date`, `Line of Credit`, `Flat Interest Rate`.
4. **Loan Disbursement** — releases funds, may create a new schedule (LOC loans disburse repeatedly).
5. **Loan Interest Accrual** — accrues interest per day/period. Frequency (`Daily`/`Weekly`/`Monthly`) and day-count convention (`Actual/365`, `30/360`, …) are Company-level settings.
6. **Loan Demand** — turns accrued/scheduled amounts into a receivable. `demand_type` ∈ `EMI | Penalty | Normal | Charges | BPI | Additional Interest`, with `demand_subtype` (`Principal`/`Interest`/charge name). **Demands are the unit of what is owed** — repayment allocation operates on them, not on the schedule.
7. **Loan Repayment** — allocates `amount_paid` across open demands via `allocate_amount_against_demands` → `apply_allocation_order`. The order comes from a **Loan Demand Offset Order** selected on the Company based on asset classification (standard / sub-standard / written-off / settlement) and `collection_offset_logic_based_on` (`NPA Flag` or `Days Past Due`).
8. Terminal/adjustment docs: **Loan Write Off**, **Loan Refund**, **Loan Balance Adjustment**, **Loan Restructure**, **Loan Transfer**, **Loan Adjustment**.

Secured lending runs in parallel: **Loan Security** → **Loan Security Assignment** (formerly "Pledge") → **Loan Security Price** → **Loan Security Shortfall** → **Loan Security Release** (formerly "Unpledge"). The old pledge/unpledge names survive in function names and patches.

### Process\_\* doctypes are the batch drivers

`Process Loan Interest Accrual`, `Process Loan Demand`, `Process Loan Classification`, `Process Loan Security Shortfall`, `Process Loan Restructure Limit`, `Process Loan Statement of Accounts` are scheduler entry points (see `scheduler_events` in hooks.py). They batch over open loans and create the per-loan documents. When debugging "why wasn't interest accrued / demand raised", start at the Process doc, not the Loan.

### Repost machinery

Backdated entries are handled by **Loan Repayment Repost** and **Loan Accrual Repost**: they cancel forward documents, replay them in order, and rebuild demands/GL. `frappe.flags.on_repost` suppresses notifications during replay. Any change to allocation or accrual logic has to work under repost as well as fresh posting.

### Extension into ERPNext

This app is heavily integrated rather than self-contained — read `hooks.py` first:

- `lending/install.py` injects **custom fields** into `Sales Invoice`, `Company`, `Customer`, `Item Default`, `Journal Entry`, `GL Entry` on install. Company-level loan configuration (classification ranges, IRAC provisioning, offset orders, accrual frequency, `enable_loan_accounting`) lives in these custom fields, **not** in a Lending Settings doctype (`Lending Settings` only holds origination/portal config).
- `doc_events` hooks into `Sales Invoice` submit/cancel to generate and reverse demands for charges, and into `Company.validate`.
- `lending/overrides/` holds those hook implementations plus GL/journal-entry tweaks (e.g. the `value_date` field propagated into GL dicts).
- `lending/loan_management/utils.py` supplies ERPNext bank-reconciliation and bank-clearance overrides so Loan Repayments/Disbursements reconcile like payment entries.
- `LoanController` (`lending/loan_management/controllers/loan_controller.py`) subclasses ERPNext's `AccountsController` and is the base for all GL-making loan doctypes. It short-circuits `make_gl_entries` when loan accounting is disabled for the company or when documents are being imported — so imported historical loans carry balances without GL.

### Tests

`lending/tests/utils.py` builds all shared master data (loan accounts, products, securities, customers, demand offset orders) at **import time** via `BootStrapTestData()`, then exposes `LendingTestSuite` (subclass of ERPNext's `ERPNextTestSuite`). Test classes subclass `LendingTestSuite`; factory helpers (`create_loan`, `create_demand_loan`, `create_repayment_entry`, `create_loan_product`, …) live in `lending/tests/test_utils.py`. `before_tests` hook points at `lending.tests.test_utils.before_tests`.

Because tests share bootstrapped master data, prefer the existing factories over hand-building documents.

### Deployment

Full runbook in `docs/deployment.md`. Shape of it:

- `docker/apps.json` lists what goes in the image (payments, erpnext, lending). CI builds it with upstream `frappe_docker`'s `images/custom/Containerfile` rather than a Dockerfile in this repo — the v17-dev pin means no published base image exists to layer onto.
- `docker/compose.yaml` is the whole runtime: MariaDB, two Redises, gunicorn, `scheduler`, `queue-short`, `queue-long`, nginx frontend. `compose.traefik.yaml` layers on TLS. Tuned for a 2 GiB host, so worker counts and `innodb-buffer-pool-size` are deliberately low.
- `infra/terraform/bootstrap/` is account-level and applied once (state bucket, ECR, GitHub OIDC role). `infra/terraform/env/` is applied per environment with `envs/{prod,staging}.tfvars` and separate state keys.
- `.github/workflows/cd.yml` runs tests and image build in parallel, deploys staging, then promotes the same digest to prod behind the `production` environment's approval gate. Deploys reach the box via `ssm:SendCommand` — there is no SSH and no inbound port 22.

Two things worth knowing before changing any of it: the scheduler container is what drives all of `scheduler_events` in `hooks.py`, so if it is down no interest accrues and no demands are raised; and `deploy.sh` stops workers before `bench migrate`, so deploys are not zero-downtime.

### Patches

`lending/patches.txt` splits into `[pre_model_sync]` and `[post_model_sync]`. Version folders under `lending/patches/` (`v1_0`, `v15_0`, `v16_0`) record the rename history — `Loan Type → Loan Product`, `Loan Security Pledge → Loan Security Assignment`, `Process Asset Classification → Process Loan Classification`. New data migrations go in the current version folder and get appended to the right section of `patches.txt`.
