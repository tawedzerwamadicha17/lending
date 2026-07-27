# Developer onboarding — Corebyte

Corebyte is a loan management system built on Frappe/ERPNext. There is one
environment, **staging**, at https://staging.corebyte.nexinfrasolutions.net.

**There are no passwords to send you.** Everything is tied to your own AWS and
GitHub accounts, and you fetch what you need with the commands below. If
someone offers to email you a `.pem` key or a database password, something has
gone wrong.

---

## 1. Access you need

Ask your admin for:

- **GitHub** — write access to `tawedzerwamadicha17/lending`
- **AWS** — an IAM user in account `685425160478`, added to the
  `corebyte-operators` group

That's it. Both are per-person and can be revoked individually.

## 2. One-time setup

Install the AWS CLI and the Session Manager plugin (this is what gives you a
server shell without SSH keys):

```bash
# macOS
brew install awscli
brew install --cask session-manager-plugin
```

Configure your credentials, using the region below:

```bash
aws configure
# AWS Access Key ID:     <from your admin>
# AWS Secret Access Key: <from your admin>
# Default region name:   af-south-1
```

Check it works:

```bash
aws sts get-caller-identity
```

## 3. Shipping a change

```bash
git clone https://github.com/tawedzerwamadicha17/lending
cd lending
git checkout -b your-change

# ... edit ...

git commit -m "fix: correct interest accrual on partial repayment"
git push -u origin your-change
```

Then open a pull request on GitHub. **Merging to `main` deploys to staging
automatically** — there is no separate deploy step to run.

Commit messages must start with a type: `feat:`, `fix:`, `chore:`, `ci:`,
`docs:`, `refactor:`, `test:`. A build check enforces this.

## 4. Watching your deploy

Go to the **Actions** tab on GitHub, or:

```bash
gh run watch
```

The **CD** workflow does three things: runs tests, builds a container image,
then deploys it to staging. Takes roughly 10–20 minutes. If it goes red, open
the failed job and read the log — the error is usually the last 20 lines.

## 5. Getting a shell on the server

```bash
aws ssm start-session --region af-south-1 --target i-08573df63249347e4
sudo -i
```

No SSH, no key file, no VPN. Your own IAM identity is the credential, and
every session is logged.

Once in, use the `stack.sh` wrapper for anything container-related:

```bash
/opt/lending/stack.sh ps                  # what is running
/opt/lending/stack.sh logs -f backend     # tail application logs
/opt/lending/stack.sh restart scheduler
```

> Use `stack.sh`, not `docker compose` directly. The compose files need
> several environment variables, so a bare `docker compose ps` just errors.
> The wrapper supplies them.

## 6. Database access

From a shell on the server:

```bash
docker exec -it corebyte-backend-1 \
  bench --site staging.corebyte.nexinfrasolutions.net mariadb
```

That drops you at a SQL prompt on the site database, already authenticated.
Frappe table names are prefixed with `tab`:

```sql
SELECT name, status FROM tabLoan LIMIT 10;
```

**Read freely. Think hard before writing.** Frappe caches heavily and
maintains links between records, so a manual `UPDATE` can leave the
application inconsistent in ways that are painful to unpick. Change data
through the UI or the Frappe API where you can.

For scripted access, `bench console` gives you a Python shell with the ORM:

```bash
docker exec -it corebyte-backend-1 \
  bench --site staging.corebyte.nexinfrasolutions.net console
```

## 7. Logging into the app

Username `Administrator`. Fetch the password with your own AWS identity:

```bash
aws ssm get-parameter --region af-south-1 \
  --name /corebyte/staging/admin_password \
  --with-decryption --query Parameter.Value --output text
```

Don't paste it into Slack — anyone who needs it can run this.

## 8. Things that will bite you

- **The `scheduler` container drives all the money.** Interest accrual, loan
  demands and classification all run from it. If it is down, nothing accrues
  and the books quietly go wrong. `stack.sh ps` should always show it running.
- **Deploys have about a minute of downtime.** Workers stop, the database
  migrates, then everything restarts. Normal.
- **Don't edit files on the server.** They are replaced on every deploy.
  Changes belong in git.
- **The box has 2 GB of RAM.** It is comfortable but not roomy. If things get
  strange, check `free -m` before assuming a code bug.
- **Backups run nightly at 01:00 UTC** to S3, kept 7 days. Staging holds no
  data anyone would miss, but don't treat it as disposable either.

## 9. Stuck?

- Deploy failed → GitHub Actions, open the red job, read the last 20 lines
- Site down → shell in, `stack.sh ps`, then `stack.sh logs backend`
- Can't connect at all → `aws sts get-caller-identity`; if that fails your AWS
  access is the problem, not the app

Deeper detail on the infrastructure is in [deployment.md](deployment.md).

---

## For the admin: onboarding someone

```bash
# 1. AWS: create the user, then grant server access
aws iam create-user --user-name <name>
aws iam add-user-to-group --group-name corebyte-operators --user-name <name>
aws iam create-access-key --user-name <name>     # send via a password manager

# 2. GitHub: write access
gh api --method PUT /repos/tawedzerwamadicha17/lending/collaborators/<github-user> \
  -f permission=push
```

`corebyte-operators` grants a shell only on instances tagged
`Project=corebyte` — it is not account-wide access, which matters because
other workloads share this account. It deliberately does **not** grant the
database root password; grant that separately if someone genuinely needs it.

To revoke: remove them from the group and from the repository. There is no
shared secret to rotate.
