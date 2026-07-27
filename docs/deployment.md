# Deployment

Frappe Lending on AWS, optimised for cost. One Graviton EC2 instance per
environment runs the whole stack — MariaDB, Redis, gunicorn, background
workers and nginx — under Docker Compose. There is no load balancer, no NAT
gateway and no managed database, because each of those costs more per month
than everything here combined.

## Topology

```
                 GitHub Actions
                       │  OIDC (no stored AWS keys)
                       ▼
              ┌────────────────┐
              │      ECR       │  one image, promoted by digest
              └───────┬────────┘
                      │ ssm:SendCommand
        ┌─────────────┴─────────────┐
        ▼                           ▼
  staging (t4g.small)         prod (t4g.small)
  ┌──────────────────┐        ┌──────────────────┐
  │ traefik / nginx  │        │ traefik / nginx  │
  │ gunicorn         │        │ gunicorn         │
  │ scheduler        │        │ scheduler        │
  │ queue-short/long │        │ queue-short/long │
  │ mariadb · redis  │        │ mariadb · redis  │
  └────────┬─────────┘        └────────┬─────────┘
           └──── nightly bench backup ─┴──► S3 (lifecycle-expired)
```

Each environment is a fully separate VPC, instance, database and bucket.

## Running cost

`af-south-1` on-demand, per month, at 730 hours. Unit prices pulled from the
AWS Pricing API rather than estimated.

| Item | Unit | Prod | Staging |
| --- | --- | ---: | ---: |
| EC2 t4g.small | $0.0217/hr | $15.84 | $15.84 |
| EBS gp3 (30 / 20 GiB) | $0.1047/GB-mo | $3.14 | $2.09 |
| Public IPv4 address | $0.005/hr | $3.65 | $3.65 |
| **Subtotal** | | **$22.63** | **$21.58** |

Shared: ECR ~$1.20 (10 images, lifecycle-capped), S3 backups ~$0.20.
**Total ≈ $46/month.**

`af-south-1` (Cape Town) is a comparatively expensive region — t4g.small
costs 29% more than in `us-east-1` and gp3 31% more, putting the same estate
at ~$37/month there. That premium buys latency to Southern African users,
which for an interactive loan-officer UI is usually the right trade. Moving
regions means changing `aws_region` in both Terraform stacks and `AWS_REGION`
in `cd.yml`.

Both environments run the same instance type deliberately: a staging box that
cannot reproduce prod's memory pressure will not catch the failures that
matter here.

Levers if that needs to come down further:

- **Stop staging out of hours.** An EventBridge schedule stopping it nightly
  and at weekends cuts its compute by roughly half (~$8/month saved). EBS and
  IPv4 charges continue while stopped. This is the best lever — it costs
  nothing in fidelity, since staging is idle at those times anyway.
- **Compute Savings Plan.** A 1-year no-upfront plan takes ~30% off both
  instances (~$9/month) at the cost of a commitment.
- **Drop staging entirely.** Prod-only is ~$24/month.

The single largest avoidable cost in a naive setup is a NAT gateway at
~$32/month — more than this entire estate. `network.tf` places the instance
in a public subnet specifically to avoid one.

## One-time setup

### 1. Bootstrap the account

Creates the Terraform state bucket, the ECR repository, and the GitHub OIDC
provider plus deploy role. Run once, with admin credentials.

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply -var=github_repository=tawedzerwamadicha17/lending
```

This stack uses local state. Keep `terraform.tfstate` out of git (already
gitignored) — or migrate it into the bucket it just created.

Note the three outputs.

### 2. Configure GitHub

Repository → Settings → Secrets and variables → Actions → **Variables**:

| Variable | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | `ci_role_arn` output |

Then Settings → Environments, create **`staging`** and **`production`**. Add
required reviewers to `production` — that approval is the only thing standing
between a merge to `main` and a production release.

### 3. Stand up each environment

```bash
cd infra/terraform/env

# staging
terraform init -reconfigure \
  -backend-config=bucket=<state_bucket output> \
  -backend-config=key=staging/terraform.tfstate \
  -backend-config=region=af-south-1
terraform apply -var-file=envs/staging.tfvars

# prod — note the -reconfigure and the different key
terraform init -reconfigure \
  -backend-config=bucket=<state_bucket output> \
  -backend-config=key=prod/terraform.tfstate \
  -backend-config=region=af-south-1
terraform apply -var-file=envs/prod.tfvars
```

Edit `site_name` in the tfvars first. It becomes the site directory under
`sites/`, and changing it after the first deploy strands the existing site.

The instance boots ready but empty — cloud-init installs Docker and the
backup timer, and deliberately does not deploy the app. The first CD run does
that, so there is one code path that puts an image on a box.

### 4. First deploy

Push to `main`, or run the **CD** workflow manually. The first run creates the
site (`bench new-site --install-app erpnext --install-app lending`); every
subsequent run migrates it.

Get the Administrator password:

```bash
aws ssm get-parameter --name /lending/prod/admin_password \
  --with-decryption --query Parameter.Value --output text
```

### 5. Enable TLS

Once DNS for `site_name` points at the `public_ip` output:

```hcl
# envs/prod.tfvars
enable_tls = true
acme_email = "ops@yourdomain.com"
```

`terraform apply`, then re-run CD. Traefik takes over ports 80/443 and issues
a Let's Encrypt certificate. Let's Encrypt validates over HTTP, so this fails
closed if DNS is not live yet — check DNS before flipping the flag.

## Everyday operations

**Shell on a box** (no SSH, no key, no open port 22):

```bash
aws ssm start-session --target <instance_id>
sudo -i && cd /opt/lending
docker compose -p lending -f compose.yaml ps
docker compose -p lending -f compose.yaml logs -f backend
```

**Redeploy without a code change:** re-run the CD workflow.

**Roll back:** re-run CD from the last good commit — the image for that SHA is
still in ECR (last 10 retained). A schema migration that already ran does not
roll back with it; if the bad deploy migrated, restore from backup instead.

**Restore:**

```bash
aws s3 ls s3://lending-prod-<account>/prod/
sudo /opt/lending/restore.sh 2026-07-27T02-00-00Z
```

Test this on staging before you need it on prod.

## How the pipeline works

`.github/workflows/cd.yml`, on push to `main`:

1. **test** — the lending suite, sharded 3 ways, same setup as `ci.yml`.
2. **build** — in parallel with tests. Clones upstream `frappe_docker` and
   builds `images/custom/Containerfile` with `docker/apps.json`, natively on
   an arm64 runner, pushing to ECR tagged with the commit SHA.
3. **deploy-staging** — needs both. Publishes the compose files and scripts
   from this commit to S3, then `ssm:SendCommand` runs `deploy.sh` on the box.
   The job polls the command to completion, so a red job means a real failure.
4. **deploy-prod** — same action, gated by the `production` environment's
   required reviewers, deploying the identical digest staging accepted.

### Why the image is built this way

Because `pyproject.toml` pins frappe/erpnext to `>=17.0.0-dev`, there is no
published `frappe/erpnext:v17` base image to layer onto. The build therefore
compiles from source via upstream's `custom` Containerfile. Two consequences
worth knowing:

- **Pin `FRAPPE_DOCKER_REF`.** It defaults to `main` so a fresh setup works,
  but leaving it there means upstream edits to the Containerfile change your
  image without a commit here.
- **The image is built from the tip of `main`, not from the triggering SHA.**
  `bench get-app` clones by branch and git cannot clone a bare SHA, so
  `apps.json` names a branch. In practice the two agree; they diverge only if
  a second push lands mid-build. Prod is safe regardless because it deploys
  the digest staging tested rather than rebuilding.
- The build injects a job-scoped `GITHUB_TOKEN` into the clone URL so private
  repos work. It expires when the job ends, which is what makes it acceptable
  to pass as a build arg.

### Why `terraform apply` is not in CI

Applying this stack creates IAM roles. A CI role permitted to create IAM roles
can grant itself administrator, so the blast radius of a compromised workflow
would be the whole account. `terraform.yml` runs `fmt` and `validate` only;
applies are operator-run. If you later want automated applies, put them behind
a separate role with an explicit permissions boundary.

## Sizing notes

2 GiB is genuinely tight for Frappe. `compose.yaml` caps MariaDB's buffer pool
at 256 MB and runs two gunicorn workers; cloud-init adds a swap file so memory
pressure degrades to slowness rather than an OOM kill.

Because staging runs the same instance type, memory problems surface there
first — which is the point. Treat swap usage on staging as a signal about
prod, not as a staging-only quirk.

Symptoms that you have outgrown a single box: sustained swap usage, the
scheduler falling behind on `Process Loan Interest Accrual` overnight, or
`bench --site X migrate` timing out during deploys. The next step is moving
MariaDB to RDS (`db.t4g.micro` in af-south-1 is $0.021/hr, ~+$15/month plus
storage), which also gets you managed point-in-time recovery.

## Known gaps

- **Deploys have downtime.** `deploy.sh` stops workers, migrates, and restarts
  — expect a minute or two of unavailability. Zero-downtime needs two hosts
  and a load balancer, which is a different cost bracket.
- **Prod is single-AZ with no standby.** Instance loss means restoring from the
  most recent nightly backup: up to 24 hours of data loss. If that is too much,
  raise backup frequency (cheap) or move to RDS with PITR (not cheap).
- **Nothing here has been executed.** The Terraform is `validate`-clean in CI
  but has not been applied, and the image build needs one real CD run to prove
  the Python 3.14 / Node 24 / `develop` combination compiles.
