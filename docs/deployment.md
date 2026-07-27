# Deployment

Corebyte — the Frappe Lending deployment for `nexinfrasolutions.net` — on AWS,
optimised for cost.

> **Naming.** `corebyte` is the product and the AWS resource prefix (ECR repo,
> buckets, IAM roles, instance tags, SSM parameter paths, Docker Compose
> project). The Frappe app inside the image is still `lending`, because that is
> upstream `frappe/lending` and renaming it would mean renaming every module,
> doctype and hook, permanently breaking merges from upstream.

> **Staging only.** There is currently no production environment, by
> decision. The stack is parameterised by environment, so adding one later
> means restoring `envs/prod.tfvars` and the `deploy-prod` job from git
> history, widening the `environment` validation in `variables.tf`, and
> re-adding the prod subject to the CI role's OIDC trust policy.

A single Graviton EC2 instance runs the whole stack — MariaDB, Redis,
gunicorn, background workers and nginx — under Docker Compose. There is no
load balancer, no NAT gateway and no managed database, because each of those
costs more per month than everything here combined.

## Topology

```
                 GitHub Actions
                       │  OIDC (no stored AWS keys)
                       ▼
              ┌────────────────┐
              │      ECR       │  tagged by commit SHA
              └───────┬────────┘
                      │ ssm:SendCommand
                      ▼
              staging (t4g.small)
              ┌──────────────────┐
              │ traefik / nginx  │
              │ gunicorn         │
              │ scheduler        │
              │ queue-short/long │
              │ mariadb · redis  │
              └────────┬─────────┘
                       └── nightly bench backup ──► S3 (lifecycle-expired)
```

The environment is a self-contained VPC, instance, database and bucket.

## Running cost

`af-south-1` on-demand, per month, at 730 hours. Unit prices pulled from the
AWS Pricing API rather than estimated.

| Item | Unit | Staging |
| --- | --- | ---: |
| EC2 t4g.small | $0.0217/hr | $15.84 |
| EBS gp3 (20 GiB) | $0.1047/GB-mo | $2.09 |
| Public IPv4 address | $0.005/hr | $3.65 |
| ECR (10 images, lifecycle-capped) | | ~$1.20 |
| S3 backups | | ~$0.20 |
| **Total** | | **≈ $23/month** |

`af-south-1` (Cape Town) is a comparatively expensive region — t4g.small
costs 29% more than in `us-east-1` and gp3 31% more. That premium buys
latency to Southern African users, which for an interactive loan-officer UI
is usually the right trade. Moving regions means changing `aws_region` in
both Terraform stacks and `AWS_REGION` in `cd.yml`.

`t4g.small` (2 GiB) is the floor for the full stack — MariaDB plus gunicorn
plus three workers does not fit in 1 GiB without constant swapping.

Levers if that needs to come down further:

- **Stop the instance out of hours.** An EventBridge schedule stopping it
  nightly and at weekends cuts compute by roughly half (~$8/month saved). EBS
  and IPv4 charges continue while stopped.
- **Compute Savings Plan.** A 1-year no-upfront plan takes ~30% off the
  instance (~$5/month) at the cost of a commitment.

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

Creating the `staging` environment in Settings → Environments is optional —
GitHub creates it implicitly on first use. Note that creating environments
requires **admin** on the repository; write is not enough.

### 3. Stand up each environment

```bash
cd infra/terraform/env

# staging
terraform init -reconfigure \
  -backend-config=bucket=corebyte-tfstate-685425160478 \
  -backend-config=key=staging/terraform.tfstate \
  -backend-config=region=af-south-1
terraform apply -var-file=envs/staging.tfvars

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
aws ssm get-parameter --name /corebyte/staging/admin_password \
  --with-decryption --query Parameter.Value --output text
```

### 5. Enable TLS

Once DNS for `site_name` points at the `public_ip` output:

```hcl
# envs/staging.tfvars
enable_tls = true
acme_email = "ops@yourdomain.com"
```

`terraform apply`, then re-run CD. Traefik takes over ports 80/443 and issues
a Let's Encrypt certificate. Let's Encrypt validates over HTTP, so this fails
closed if DNS is not live yet — check DNS before flipping the flag.

## Giving someone shell access

There is no EC2 key pair in this project and no inbound port 22 — check
`network.tf`, the security group has no rule for it. Do not create one.

Access is per person, through SSM Session Manager:

```bash
aws iam add-user-to-group --group-name corebyte-operators --user-name <them>
```

They install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
and connect:

```bash
aws ssm start-session --region af-south-1 --target <instance-id>
```

The `corebyte-operators` group (`bootstrap/operators.tf`) permits
`ssm:StartSession` only on instances tagged `Project=corebyte`, which matters
because other workloads share this account. It also allows
`AWS-StartSSHSession`, so anyone whose tooling genuinely needs `ssh` or `scp`
can tunnel over SSM with an `ssh -o ProxyCommand=...` config — still with no
open port.

Why not just share a `.pem`:

| | Shared key pair | SSM Session Manager |
| --- | --- | --- |
| Identity | One secret, everyone is `ec2-user` | Each person's own IAM principal |
| Revoking one person | Rotate key, redeploy, notify everyone | Remove them from the group |
| Audit | Nothing attributable | Every session in CloudTrail |
| Exposure | Port 22 open to the internet | No inbound port |

The group deliberately does **not** grant access to the SSM parameters holding
the database root and Administrator passwords. Grant those separately, per
person, if someone genuinely needs them.

## Recovering credentials

Nothing is written down and nothing is emailed. Every secret is generated by
Terraform and stored in SSM Parameter Store, and you retrieve it with your own
AWS identity.

```bash
# Frappe Administrator password
aws ssm get-parameter --region af-south-1 \
  --name /corebyte/staging/admin_password \
  --with-decryption --query Parameter.Value --output text

# MariaDB root password
aws ssm get-parameter --region af-south-1 \
  --name /corebyte/staging/db_root_password \
  --with-decryption --query Parameter.Value --output text
```

### Where the Administrator password actually comes from

```
Terraform random_password.admin
    │
    ▼
SSM /corebyte/staging/admin_password  (SecureString)   <-- the only plaintext copy
    │
    ▼
deploy.sh  fetch_secret admin_password
    │
    ▼
bench new-site --admin-password ...   (runs once, on the first deploy)
    │
    ▼
Frappe stores a one-way hash in __Auth
```

**You cannot read it back out of Frappe.** Two things people assume and get
wrong:

- `site_config.json` holds database credentials only — `db_name`, `db_user`,
  `db_password`. There is no `admin_password` in it.
- `__Auth` stores `$pbkdf2-sha256$29000$...`, a one-way hash. There is nothing
  to reverse.

So `bench set-admin-password` is not a way to discover the password; it is
what you use when the plaintext is genuinely gone. While SSM holds it, you
never need it.

If SSM were somehow lost, Terraform state is the second copy:

```bash
cd infra/terraform/env
terraform state show random_password.admin
```

Only if **both** are lost do you reset — and then put the new value back so the
retrieval commands above keep working:

```bash
docker exec -it corebyte-backend-1 \
  bench --site staging.corebyte.nexinfrasolutions.net set-admin-password

aws ssm put-parameter --region af-south-1 \
  --name /corebyte/staging/admin_password \
  --value '<new password>' --type SecureString --overwrite
```

Note there is no `frappe-bench` directory on the host — everything runs in
containers, so `bench` is always reached through `docker exec`. And the site
name is `staging.corebyte.nexinfrasolutions.net`; Frappe keys sites by
directory name, so a wrong `--site` fails rather than doing anything unwanted.

## Everyday operations

**Shell on a box** (no SSH, no key, no open port 22):

```bash
aws ssm start-session --target <instance_id>
sudo -i && cd /opt/lending
docker compose -p corebyte -f compose.yaml ps
docker compose -p corebyte -f compose.yaml logs -f backend
```

**Redeploy without a code change:** re-run the CD workflow.

**Roll back:** re-run CD from the last good commit — the image for that SHA is
still in ECR (last 10 retained). A schema migration that already ran does not
roll back with it; if the bad deploy migrated, restore from backup instead.

**Restore:**

```bash
aws s3 ls s3://corebyte-staging-685425160478/staging/
sudo /opt/lending/restore.sh 2026-07-27T02-00-00Z
```

Exercise this before you need it in anger.

## How the pipeline works

`.github/workflows/cd.yml`, on push to `main`:

1. **test** — the lending suite, sharded 3 ways, same setup as `ci.yml`.
2. **build** — in parallel with tests. Clones upstream `frappe_docker` and
   builds `images/custom/Containerfile` with `docker/apps.json`, natively on
   an arm64 runner, pushing to ECR tagged with the commit SHA.
3. **deploy-staging** — needs both. Publishes the compose files and scripts
   from this commit to S3, then `ssm:SendCommand` runs `deploy.sh` on the box.
   The job polls the command to completion, so a red job means a real failure.


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
