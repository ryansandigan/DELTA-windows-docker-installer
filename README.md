# DELTA for Windows — Docker installer

Installs DELTA on a Windows machine as three containers: NGINX in front, the
DELTA application, and PostgreSQL 17 with PostGIS. You run one script; it
checks the machine, sets up Docker if it has to, generates the configuration,
starts the stack in the right order, secures the administrator account, and
tells you where DELTA is.

You do not need to know anything about Docker to run it, and you never manage a
Linux machine: Docker Desktop brings its own, and the installer never touches
it.

---

## Before you start

- **Windows Server 2022 / 2025, or Windows 11.** 64-bit, and virtualization
  enabled in firmware. The installer checks and tells you if something is
  missing.
- **Administrator rights.** Run the script from an elevated PowerShell window.
- **Docker Desktop.** If it is already installed, the installer uses it. If it
  is not, the installer shows Docker's licensing terms, asks you to accept
  them, installs Docker Desktop silently, and asks you to restart Windows and
  run it again.
  > Docker documents that Docker Desktop is not supported on Windows Server
  > editions. It installs and runs correctly there and DELTA was validated on
  > Server 2025 — but if Docker Desktop itself misbehaves, support for it comes
  > from this project, not from Docker. The installer discloses this before
  > installing anything.
- **About 20 GB free** on the system volume, and internet access to
  `ghcr.io` and `docker.io` for the first run.

---

## Installing

From an elevated PowerShell prompt, in the folder containing `setup.ps1`:

```powershell
.\setup.ps1
```

That is the whole thing. It installs to `C:\DELTA` unless you say otherwise.
You do not prepare a configuration file, create a database, create an
administrator account, start any container, or touch Docker directly.

### What you will be asked

Four things, all at the start, before the installer does anything slow:

| Question | Default if you just press Enter |
|---|---|
| **Hostname or domain** — the name people will use in a browser | `localhost` |
| **Database password** — for the PostgreSQL database it creates for DELTA | a strong one is generated |
| **DELTA administrator password** — for signing in as `admin@admin.com` | a generated one, shown once at the end |
| **HTTPS** — none, your own certificate, or a self-signed one | none (plain HTTP) |

`localhost` is a deliberate default, not a placeholder. It lets you install
DELTA on a machine and try it from that machine immediately, without owning a
DNS name or a certificate. Nothing looks the name up, so a hostname whose DNS
entry does not exist yet is accepted — you can point DNS at it later.

Both password prompts are masked, and a password you type is asked for twice
and must match. Choosing "generate" is a perfectly good answer for the database
password: the database is never published to the network and nothing outside
this machine can reach it. Type your own if you want to connect with other
tooling.

### What you will *not* be asked

- **Ports.** If port 80 (and 443 with HTTPS) is free, the installer takes it
  without asking. You are only asked for another port when something else
  genuinely owns it — and then you are told *what* owns it. Nothing already
  using the port is ever stopped, moved or reconfigured.
- **SMTP / email.** DELTA works without it. The installer sets
  `EMAIL_TRANSPORT=file`, which writes mail to the container log instead of
  sending it, and a placeholder `EMAIL_FROM` — DELTA requires both to be set
  even when it is not sending anything, so the installer supplies them.
  Configure a real mail server afterwards, when you want one, from
  [Configuring email](#configuring-email). Installing DELTA does not require a
  mail server to exist.
- **How people sign in.** `AUTHENTICATION_SUPPORTED=form` is set for you, which
  is normal local sign-in with an email address and password. (DELTA also
  accepts `sso_azure_b2c`, which additionally requires three Azure settings —
  that is a hand edit of `.env`, not something the installer offers.)
- **Anything about Docker.** Compose project names, internal ports, volumes and
  image digests are the installer's business, not yours.

Everything after those four questions runs unattended: the installer creates the
folder layout, generates the configuration, pulls and pins the images, starts
PostgreSQL, lets DELTA initialise its own schema and verifies that it did,
replaces the published default administrator credential *before* anything is
reachable, starts NGINX, requests the site to prove it answers, opens the
firewall for the port it published, configures unattended startup, and prints
the access details.

Useful switches:

```powershell
.\setup.ps1 -InstallRoot D:\DELTA          # install somewhere else
.\setup.ps1 -Hostname delta.example.org    # the name people will use
.\setup.ps1 -TlsMode supplied -CertificatePath C:\certs\delta.crt `
            -CertificateKeyPath C:\certs\delta.key
.\setup.ps1 -HttpPort 8080 -HttpsPort 8443
.\setup.ps1 -NonInteractive                # never prompt (for automation)
```

Anything you supply as a switch is not asked for again. `-NonInteractive` asks
nothing at all: the hostname falls back to `localhost` and both passwords are
generated, which is the same generation the interactive prompts offer — it does
not invent a weaker default to avoid a question. A generated administrator
password is still printed once at the end of the run, so capture the output.

Run `Get-Help .\setup.ps1 -Full` for the rest.

### Running setup.ps1 again

Once DELTA is installed, `.\setup.ps1` opens the
[management utility](#running-setupps1-again--the-management-utility) instead of
installing. It does not ask the installation questions again, does not
regenerate anything, and does not recreate any container just because you
opened it.

To change installation-level settings — hostname, ports, HTTPS — run the
installer flow explicitly:

```powershell
.\setup.ps1 -Reconfigure
```

That re-offers the hostname and the HTTPS choice. It deliberately does **not**
re-ask either password: the database password is applied only when the database
is first created, so changing it there would not change what PostgreSQL expects,
and the administrator credential is left to
[menu option 6](#resetting-the-administrator-password), which is the operation
that actually knows how to replace it.

### What a first install does

1. Checks Windows, virtualization, disk space and Docker.
2. Creates the installation folder and generates `.env`, `docker-compose.yml`
   and the NGINX configuration.
3. Resolves the ports and the certificate.
4. Downloads the three images and pins them by digest, so a restart can never
   quietly change what runs.
5. Starts PostgreSQL, waits until it is genuinely ready, then starts DELTA.
6. Checks that DELTA's own database setup actually succeeded — not just that
   the container is running.
7. **Replaces the administrator credential** (see below) *before* NGINX
   publishes anything.
8. Starts NGINX, checks that DELTA answers over HTTP or HTTPS, opens the
   firewall for those ports, and prints a summary.

The first run takes a few minutes, most of it downloading images.

---

## Where things are

```
C:\DELTA\
  .env                      configuration and secrets (locked down)
  docker-compose.yml        generated - regenerated on every run
  .delta-install.json       what this installation is (no secrets)
  nginx\conf.d\delta.conf   generated NGINX site
  certs\                    the certificate and its private key
  uploads\                  everything users upload
  logs\                     DELTA, NGINX and installer logs
  backups\                  database backups
```

The **database itself** lives in a Docker-managed volume (`delta_pgdata`), not
in this folder. That is deliberate: it is measurably faster, its durability
guarantees are not translated through a Windows filesystem layer, and antivirus
cannot reach into it. The portable copy of your data is a backup file in
`backups\`, never the raw database folder.

---

## First access

The summary at the end of the install prints the exact URLs. They look like:

| | |
|---|---|
| Application | `https://your-host` |
| Administrator sign-in | `https://your-host/en/admin/login` |
| User sign-in | `https://your-host/en/user/login` |

### The administrator credential

The DELTA image ships with a built-in administrator, `admin@admin.com`, whose
password is public — it is inside an image anyone can download. **The installer
replaces it during installation, before DELTA is reachable on any port**, and
verifies that the replacement actually took effect. If that step fails, the
installer stops and does not publish the application at all.

Unless you choose to type your own, the installer generates the new password
and shows it **once**, at the end of the install:

> Record it then. It is not written to `.env`, not written to the installer's
> log, and not stored anywhere on the machine. Nothing can recover it — a lost
> administrator password is replaced, not retrieved.

Re-running the installer later does **not** change the credential again.

### If you chose a self-signed certificate

Browsers will warn about it until you replace it with a real one or trust it on
the machines that use DELTA. That is expected, and the installer says so.

### If you chose no HTTPS

Plain HTTP is fine for trying DELTA out on the machine itself. It is not fine
for real use: DELTA marks its session cookies `Secure`, so people reaching the
server by hostname over plain HTTP will not stay signed in.

---

## Firewall

The installer adds inbound rules for the ports it actually published, named
after this installation, for example:

```
DELTA (Docker) - delta - HTTP     TCP 18080
DELTA (Docker) - delta - HTTPS    TCP 18443
```

Nothing else is opened. DELTA's own port 3000 and PostgreSQL's 5432 are never
reachable from the network — not from other machines, and not from this one.

If your machine's policy forbids adding firewall rules, the installer says so
and carries on: DELTA is installed and works locally, it is simply not reachable
from elsewhere until someone allows those ports.

---

## Antivirus and backup software

The database is inside Docker's own storage, where Windows-side scanners cannot
reach it. What does sit on your disk is:

```
C:\DELTA\uploads
C:\DELTA\logs
C:\DELTA\backups
```

If this machine runs an endpoint-protection product, exclude those three folders
from real-time scanning. Also keep the installation folder out of OneDrive or
any other redirected or synced folder — a sync client holding files open behind
a running application causes problems that are hard to diagnose.

Do not disable your antivirus. The exclusions above are enough.

---

## Running setup.ps1 again — the management utility

Once DELTA is installed, running `setup.ps1` again does **not** install it a
second time. It opens the management utility instead:

```powershell
.\setup.ps1
```

There is no `-Install` or `-Manage` switch to remember. The script looks at what
is on disk and decides: a complete installation gets the menu, anything else
gets the installer. Re-running is safe either way — it never deletes the
database, uploads, certificates or configuration, never regenerates the session
secret or the database password, and never changes the administrator credential
again. If a previous install stopped part-way, the next run picks up from there.

### Status

The menu opens with what is actually true right now, read in one query:

```
Status
  DELTA          installed     C:\DELTA  installed 2026-08-19T15:43:04Z, DELTA schema 0.2.3
  Docker         Running       engine 29.6.2, linux containers, backend wsl-2
  db             Running       healthy
  delta          Running       healthy   image prod-latest @aa180b0
  nginx          Running       healthy
  Access                       http://localhost
                               reachable - GET http://localhost/ returned HTTP 200
  Restart        Configured    startup-task - CONFIGURED but NOT YET PROVEN by a real restart
```

"Reachable" is not a guess: the utility requests the configured address and
reports what came back. If DELTA is not answering it says so, even when all
three containers are up — containers running and an application serving are
different claims.

### The menu

```
  1. Update DELTA
  2. Backup Database
  3. Stop DELTA
  4. Restart DELTA
  5. Configure SMTP
  6. Reset Administrator Password
  7. Certificate Management
  8. DELTA Access Guide
  9. View Logs
  S. Start DELTA                   (shown when something is not running)
  0. Exit
```

Pressing Enter refreshes the status. Every operation returns to this menu when
it finishes, when you cancel it, and when it fails.

- **Start DELTA** starts Docker Desktop if it is not running, checks the
  database volume is still there, brings the three containers up in order, and
  confirms DELTA answers. It is the same code the startup task runs after a
  reboot, so recovering by hand and recovering automatically cannot behave
  differently.
- **Stop DELTA** stops the containers. It does not remove them, the network, the
  data volume, the uploads or anything else — starting again brings the same
  installation back.
- **Restart DELTA** is a stop followed by a start, with all the same checks. It
  reports success only after the database, the application and NGINX are healthy
  *and* the configured address has answered.
- **Update DELTA** checks whether a new application image has been published
  and, if so, updates to it safely — see [Updating DELTA](#updating-delta) below.
- **Backup Database** writes a verified dump to `C:\DELTA\backups\` — see
  [Backing up the database](#backing-up-the-database) below.
- **Configure SMTP** sets how DELTA sends email — see
  [Configuring email](#configuring-email).
- **Reset Administrator Password** replaces the administrator credential — see
  [Resetting the administrator password](#resetting-the-administrator-password).
- **Certificate Management** replaces the TLS certificate — see
  [Replacing the TLS certificate](#replacing-the-tls-certificate).
- **DELTA Access Guide** shows the real URLs for this installation, tests the
  endpoint, and tells you plainly if it did not answer.

### If Docker is not running

The utility still opens, and stays useful. It shows the installation, its
configuration, the addresses it is set up to serve, and what it can tell you
about why Docker is not answering — and it offers **Start DELTA**, which starts
Docker Desktop first. The operations that cannot work without the engine are not
offered rather than offered and then failing. Nothing about the installation is
changed because Docker happens to be down.

### View Logs

```
  1. DELTA Application Logs      docker compose logs -f delta
  2. NGINX Access Log            C:\DELTA\logs\nginx\access.log
  3. NGINX Error Log             docker compose logs -f nginx
  4. PostgreSQL Logs             docker compose logs -f db
  5. All Container Logs          docker compose logs -f
  S. Installer / startup log     C:\DELTA\logs\installer\startup.log
  0. Back
```

NGINX's **access** log is a file on Windows you can also open in any editor;
its **error** output goes to `docker compose logs nginx`. That split is
deliberate: the request log is worth keeping on disk, and errors are worth
having where you look when something is broken.

> **Ctrl+C stops the log view, not DELTA.** Following a log is something your
> machine does to a stream — the containers are not involved and are not
> signalled. Press Ctrl+C (or Q) to go back to the menu; the utility then runs
> `docker compose ps` and shows you the containers still running, so you do not
> have to take its word for it.

### NGINX access-log rotation

`C:\DELTA\logs\nginx\access.log` would otherwise grow forever — NGINX rotates
only when it is told to, and a full system volume takes the database down with
it. So the management utility registers one scheduled task:

```
DELTA (Docker) - <project> - NGINX log rotation
   trigger   daily at 03:30
   runs as   the account that installed DELTA, whether or not it is signed in
   action    rotate-nginx-logs.ps1 -InstallRoot C:\DELTA
```

It renames the current log to `access.log.<timestamp>`, tells NGINX to reopen
its log so writing continues at the same path, and keeps the seven most recent
rotations. It touches nothing else in that folder, and an empty log is simply
nothing to do. Run it by hand at any time:

```powershell
.\rotate-nginx-logs.ps1 -InstallRoot C:\DELTA
```

### Updating DELTA

Menu option **1** updates the DELTA application to the current published image.

**How it decides whether there is anything to do.** DELTA is published under the
tag `prod-latest`, and that tag *moves* — the same tag name points at different
images over time. So "is the tag the same?" is not a useful question. The
installer compares **image digests** instead: the exact content identity of what
your container is running against the content identity the registry currently
serves for `prod-latest`.

```
==> Checking for a new DELTA image
    The registry is queried for the tag digest only. Nothing is downloaded.
    running   sha256:aa180b0d7948e09f301fac2148f6f9134507387e017a5475a61eb32f771692f5
    registry  sha256:aa180b0d7948e09f301fac2148f6f9134507387e017a5475a61eb32f771692f5
```

That check reads the registry manifest only — **nothing is downloaded**, and the
DELTA image is around 214 MB, so this costs a second rather than several
minutes. If the two digests match, the utility says so and **stops**: no backup,
no pull, no container recreation, nothing changed at all.

If the registry cannot be reached, the utility says *that*, and stops. It will
not report "you are up to date" when the truth is "I could not find out".

**Before anything changes** you get a summary — where the installation is, which
tag it tracks, both digests in full, and what is about to happen — and you have
to confirm. Pressing Enter without typing anything means no. Cancelling changes
nothing whatsoever.

**Then, in this order:**

1. **A full database backup is taken and verified** (the same operation as menu
   option 2, including the `pg_restore --list` check). This is not optional and
   there is no way to skip it. **If the backup fails for any reason, the update
   stops right there** — before anything is pulled and before any container is
   replaced.
2. Your current `.env` is copied to `C:\DELTA\backups\env-<timestamp>.bak`.
3. `DELTA_IMAGE` in `.env` is repinned to the exact digest that was compared, and
   the new image is pulled **by digest** — so what you install is what you were
   shown, even if the tag moves in the meantime. If the pull fails, `.env` is put
   back and nothing has been recreated.
4. **Only the DELTA application container is recreated.** The database container,
   its data volume, NGINX, your uploads, certificates and configuration are not.
5. NGINX is told to re-resolve the application's address (a signal to the running
   process — it is not restarted).
6. DELTA runs its own schema migration as it starts, and that migration is
   **actively verified** — see below.
7. The site is actually requested, and the result reported.

**Why the backup is mandatory.** Starting the new container *is* the schema
migration, and DELTA's migrations are **forward-only** — there are no down
migrations. Putting the old image back does not put the old schema back. That
makes the pre-update backup the only route back from a bad migration, which is
why it cannot be skipped.

**Why "the container started" is not success.** DELTA's start command runs `psql`
without `ON_ERROR_STOP`, so a migration can fail half-way, `psql` still exits 0,
the application still starts, and Docker still reports the container healthy — on
a half-migrated schema. The updater therefore checks three separate things: that
the log shows a migration branch for *this* start, that it contains no `psql`
errors, and that `dts_system_info.version_no` can actually be read back. All
three must hold before the update is called a success.

**If the update fails**, you are told which stage it reached and what is true
afterwards. The pre-update backup is always preserved and its path is printed. On
a migration failure the utility states plainly that **reverting the image is not
sufficient** and that the recovery path is
[restoring the database](#restoring-the-database) from that backup. Nothing here
performs an automatic rollback, and nothing claims to.

### Backing up the database

Menu option **2** takes a full logical backup of the DELTA database:

```
C:\DELTA\backups\delta-20260820-092752.dump
```

`pg_dump -Fc` runs **inside the database container** — its client matches the
server, whereas the client inside the DELTA application container is an older
major version and refuses to talk to it at all. The dump is streamed straight
out of the container into the Windows file, byte for byte, and nothing is
written inside the container or copied out afterwards. PostgreSQL is never
published on a host port; the backup goes through Docker.

A file appearing in `backups\` is not what makes a backup. Before the utility
reports success it confirms that `pg_dump` exited cleanly, that the file exists
and is not empty, and that `pg_restore --list` can parse it — read back through
the same container. **If any of that fails, the file is deleted** and the
failure is reported with PostgreSQL's own error text. That guarantee matters:
nothing left in `backups\` is a dump that was never read back.

```
Backup complete and verified.
    File           C:\DELTA\backups\delta-20260820-092752.dump
    Size           324.6 KB
    Taken in       0.5s
    Verification   pg_restore --list parsed the archive: 234 table-of-contents entries.
    Retention      0 old dump(s) removed, 2 retained, 0 bytes reclaimed.
```

**Retention.** After a successful backup, old dumps are tidied. A dump is
deleted only when **both** of these are true:

- it is not one of the newest **10** dumps, **and**
- it is more than **30 days** old.

So the ten most recent survive however old they are, everything from the last
month survives however many there are, and only the old surplus goes. Only files
named `delta-YYYYMMDD-HHmmss.dump` in this installation's own `backups\` folder
are ever considered — anything else you keep there is left alone. The space
reclaimed is reported.

**What is and is not in the dump.** The dump contains the DELTA database:
schema, data, and the `CREATE EXTENSION postgis` that makes the geometry columns
work. It does **not** contain your uploads (`C:\DELTA\uploads\`), your
configuration (`C:\DELTA\.env`) or your certificates (`C:\DELTA\certs\`). Those
are ordinary Windows folders — copy them with whatever you already use, and read
[Antivirus and backup software](#antivirus-and-backup-software) first.

### Restoring the database

**There is no restore menu entry, and that is deliberate.** Restoring replaces
the live database. It is a rare, deliberate, destructive act, and it belongs in
your hands rather than one keystroke away in a menu.

> **Stop the DELTA application container first.** DELTA runs its own schema
> initialisation and migration *every time its container starts*, and its restart
> policy will bring it back on its own. If it comes back while a restore is only
> half done, it will run a migration against a half-restored schema — and those
> migrations are forward-only, so there is no undo. Leave the database container
> running: that is what performs the restore.

Run these from an elevated PowerShell prompt. Replace the file name with the
backup you want, and `delta` with your `POSTGRES_USER` / `POSTGRES_DB` if you
changed them in `C:\DELTA\.env`.

```powershell
cd C:\DELTA

# 0. Take a fresh backup first, if the database is still readable at all.
#    Menu option 2 in setup.ps1.

# 1. Stop ONLY the application. The database stays up.
docker compose stop delta

# 2. Confirm the dump you are about to restore actually parses.
cmd /c "docker compose exec -T db pg_restore --list < C:\DELTA\backups\delta-20260820-092752.dump"

# 3. Restore it, dropping the objects it replaces as it goes.
cmd /c "docker compose exec -T db pg_restore -U delta -d delta --clean --if-exists < C:\DELTA\backups\delta-20260820-092752.dump"

# 4. Check what came back before letting the application near it.
docker compose exec -T db psql -U delta -d delta -c "select version_no from dts_system_info;"
docker compose exec -T db psql -U delta -d delta -c "select postgis_lib_version();"

# 5. Start the application again. It will run its migration check on start.
docker compose start delta
docker compose ps
```

`cmd /c "... < file"` is used for steps 2 and 3 because PowerShell's own `<` and
`|` convert the stream to text, which corrupts a binary dump. `cmd`'s redirect
passes the bytes through unchanged. If you prefer, `Get-Content -Encoding Byte`
piping is **not** a safe substitute on Windows PowerShell 5.1.

Notes:

- `--clean --if-exists` drops each object before recreating it, so restoring
  over an existing database works. Some `DROP ... IF EXISTS` notices during the
  restore are normal.
- The dump records `CREATE EXTENSION postgis`, not PostGIS itself, so the target
  must be a PostGIS-capable server. The `postgis/postgis:17-3.5` image this
  installer uses is exactly that, which is why restoring into this stack works.
- To restore into a **different** or empty database rather than over the live
  one — which is the safer way to inspect a backup — create it first:
  ```powershell
  docker compose exec -T db psql -U delta -d postgres -c "CREATE DATABASE delta_check TEMPLATE template0;"
  cmd /c "docker compose exec -T db pg_restore -U delta -d delta_check < C:\DELTA\backups\delta-20260820-092752.dump"
  docker compose exec -T db psql -U delta -d delta_check -c "select version_no from dts_system_info;"
  docker compose exec -T db psql -U delta -d postgres -c "DROP DATABASE delta_check;"
  ```
- If the restore fails part-way, **do not start `delta`**. Fix the restore or
  restore an older dump first. An application started against a half-restored
  schema will migrate it.

### Configuring email

Menu option **5** sets how DELTA sends mail. It shows what is configured now,
asks for the transport, and — for SMTP — for the server settings.

DELTA supports two transports:

| Transport | What it does |
|---|---|
| **File** | Mail is written to the container log instead of being sent. This is DELTA's own default and is what a test installation wants. |
| **SMTP** | Mail is sent through a mail server you configure. |

For SMTP you are asked for the from address, server host, port, whether to use
implicit TLS on connect (`true` for port 465, `false` for 587 and 25), the
username, and the password. **All of them are required** when the transport is
`smtp`: DELTA reports each missing one as a configuration error on the login
page, so an unauthenticated relay cannot be expressed here. That is DELTA's
constraint, not the installer's. Anything already configured is offered as the
default — press Enter to keep it.

**The from address takes either form**, because DELTA passes it straight to its
mail library and its own built-in default uses the second one:

```
onboarding@resend.dev
"DELTA" <onboarding@resend.dev>
DELTA Notifications <onboarding@resend.dev>
```

The quotes and the display name are stored and delivered to DELTA exactly as
you typed them. What is still rejected is anything genuinely malformed — no
`@`, a domain with no dot, an unbalanced `<`, spaces in a bare address — and
the message names which part is wrong.

Switching back to **File** leaves the SMTP server settings in `.env` untouched,
so you can switch to `smtp` again later without retyping them.

**The password is never displayed.** It is typed masked, entered twice and
required to match. If a password is already configured, pressing Enter at that
prompt keeps it — the existing value is not read back, not shown and not
rewritten. Nothing in this flow prints the password, writes it to a log or puts
it in the state file; it goes into `C:\DELTA\.env` and nowhere else, and `.env`
stays restricted to Administrators and SYSTEM.

**Before anything is written**, the installer checks that the SMTP host resolves
and accepts a connection on the port you gave. That is a sanity check on what
you typed — it does not test your credentials and it does not send mail. If it
fails you are told exactly why and offered the settings again; nothing has been
written at that point.

**Applying the change recreates the DELTA application container.** That is not
optional and it is not the same as restarting it: environment variables are
fixed when a container is created, so `docker compose restart` would restart the
same container with the same settings and change nothing. The database
container, its data volume, NGINX, your uploads and your certificates are not
touched. Afterwards the installer reads the settings back **out of the running
container** and shows them, so you can see that the change actually took effect
rather than just that a file was written.

**If applying fails**, the previous SMTP settings are written back to `.env` and
the container is recreated with them. The result is reported as two separate
facts, because they are two separate things:

```
.env: the previous SMTP values were written back.
Runtime: the container was recreated with the previous configuration and is healthy.
```

If the second line cannot be said truthfully, it is not said. A full timestamped
copy of the previous `.env` is kept in the installation root either way.

Cancelling at the transport screen changes nothing at all.

### Resetting the administrator password

Menu option **6** replaces the stored credential for the DELTA administrator
account (`admin@admin.com`). It is the same operation the installer runs during
a first install.

It asks for confirmation first, then whether to generate a password or let you
type one. A typed password is entered twice and must match. A generated password
is shown **once**, at the end — record it then, because nothing on the machine
keeps a copy.

- The password never appears in a log, in `.env`, or in the state file.
- It never appears on a command line, so it cannot be read out of a process
  list: it is passed to PostgreSQL through the process environment and read by
  `psql` itself.
- Success is not assumed. The installer confirms that exactly the intended
  account was updated, that the stored credential actually changed, and that the
  new password verifies against what is now stored. If any of those is not true,
  it reports failure rather than success.

**No container is restarted or recreated**, and no other configuration changes —
this operation touches one database row.

If the account cannot be found, that is reported and nothing is created or
changed. Cancelling at either prompt leaves the credential alone.

### Replacing the TLS certificate

Menu option **7** replaces the certificate and private key that NGINX serves.

It first shows what is in use — subject, issuer, expiry and thumbprint — then
asks for the replacement certificate and key. Both must be **PEM** files, and
the key must not be passphrase-protected (NGINX cannot use one without the
passphrase stored in plaintext next to it, which gains nothing).

Before anything is touched, the replacement is validated:

- both files exist and can be read;
- the certificate parses as X.509;
- the private key parses;
- **the key matches the certificate** — this is the check that matters, because
  a mismatch otherwise surfaces as a cryptic NGINX failure;
- the certificate is currently valid, with a warning if it expires within 30 days.

A defect is reported **by name** — you are told which of the two files is wrong
and how — and nothing is changed.

If it validates, the current certificate and key are copied aside with a
timestamp, the new pair is installed with the same restricted permissions the
old key had, and then:

```
nginx -t          runs inside the running NGINX container
nginx -s reload    only if nginx -t passed
```

**No container is recreated** — not NGINX, not DELTA, not the database. A reload
signals the running NGINX process, so established connections are drained rather
than dropped and the site does not go down.

Afterwards the installer requests the site over HTTPS and reads back the
certificate NGINX is actually presenting, confirming it is the new one. The
thumbprint and expiry are recorded in `.delta-install.json`; the private key is
never read into the installer, never logged and never stored anywhere but
`certs\`.

**If `nginx -t` rejects the new certificate**, NGINX is never signalled — it
carries on serving the old certificate from memory — the previous files are put
back, and the restored configuration is re-tested. If the reload or the endpoint
check fails, the previous certificate is restored and reloaded. The site stays
up throughout.

> **If HTTPS is not enabled** for this installation, this option says so and
> stops: there is no certificate in use to replace. Turning HTTPS on changes the
> published ports and regenerates the NGINX configuration, which is the
> installer flow — `.\setup.ps1 -Reconfigure`.

There is no automatic renewal and no ACME/Let's Encrypt client. Replacing a
certificate is a deliberate operator action.

### Changing ports, hostname or TLS

Those are settled during installation, and the management utility deliberately
does not re-ask. To change them, run the installer flow again against the
existing installation:

```powershell
.\setup.ps1 -Reconfigure -HttpPort 8080
```

That re-resolves ports and TLS and regenerates the generated files. It is as
non-destructive as any other re-run: your data, secrets, certificates and image
pins are preserved.

---

## Removing DELTA

```powershell
.\uninstall.ps1
```

It shows what it found and what each choice does, then asks:

```
  1. Uninstall DELTA and preserve data
  2. Completely remove DELTA and its data
  0. Cancel
```

**Uninstalling never means deleting your data.** Option 1 is the normal answer
and it keeps everything that would hurt to lose.

### Option 1 — uninstall and preserve data

| Removed | Preserved |
|---|---|
| The `delta`, `db` and `nginx` containers | The **database**, in its Docker volume |
| The Docker network they shared | `uploads\` |
| The scheduled task that starts DELTA at boot | `backups\` — every dump you have taken |
| The scheduled task that rotates the NGINX logs | `certs\` |
| This installation's Windows Firewall rules | `logs\` |
| | `.env` and `docker-compose.yml` |
| | The installation directory itself |

To bring DELTA back afterwards, with all of that still in place:

```powershell
.\setup.ps1
```

It rebuilds the containers over the existing database. Your records, users,
uploads and administrator password are exactly as you left them; you are not
asked for a new password, because the old one still applies.

The uninstaller says so at the end rather than claiming DELTA is gone:

```
The DELTA runtime has been removed. Your data was preserved.

Preserved:
  the database        volume delta_pgdata
  C:\DELTA\uploads
  C:\DELTA\backups
  ...
```

### Option 2 — complete removal

This deletes the database volume and the whole installation directory. It
cannot be undone, so three things happen first:

1. **It lists exactly what will be destroyed** — the volume by name, and every
   directory with its size and file count.
2. **It offers a final verified backup.** The dump is taken with the database
   still running, verified with `pg_restore --list`, and written **outside** the
   installation directory so it survives the deletion. The surviving path is
   printed. A backup written inside a directory that is about to be deleted
   would not be a backup, so it is never left there.
3. **It requires you to type `DELETE`.** Not `y`, not `yes`, not Enter — the
   whole word, in capitals. Everything else cancels and changes nothing.

If you decline the backup, it says plainly that the database will be deleted
with no copy kept.

### What it never touches

Docker Desktop, WSL, Hyper-V, Windows features, Git, PowerShell — none of them
are removed, in either mode. They are shared with the rest of the machine, and
the fact that `setup.ps1` can install Docker Desktop does not make Docker
Desktop DELTA's to delete.

Nor does it touch any Docker resource it did not create. It identifies this
installation from its own `.delta-install.json`, not by looking for names that
resemble DELTA's, so another Compose project, another container, another volume
or a similarly named scheduled task is never a candidate. Point it at a
directory that is not a registered DELTA installation and it refuses:

```powershell
.\uninstall.ps1 -InstallRoot C:\Some\Other\Folder
# No DELTA Docker installation was found. Nothing was changed.
```

### Running it more than once

It is safe to re-run. Anything already gone is reported as *absent* rather than
as an error, and a partly-finished uninstall — one interrupted, or one where
Docker was not running — continues from wherever the installation actually is.
Run it on an installation that is already uninstalled and it tells you so, with
the preserved data listed, and exits without changing anything.

### If something could not be removed

The uninstaller distinguishes *removed*, *already absent*, *preserved*, *failed*
and *could not verify*, and it will not call a run successful when something
survived. If Docker is not running, for instance, the scheduled tasks and
firewall rules are still removed, but the containers and the volume are reported
as **not removed** — not as gone — and the installation record is deliberately
kept so they can still be identified:

```
PARTIAL - DELTA was not completely uninstalled.

These were not removed, or could not be checked:
  Compose project 'delta' - The Docker engine is not reachable, ...
```

Start Docker Desktop and run it again.

### For scripted teardown

```powershell
.\uninstall.ps1 -Mode preserve-data -NonInteractive
.\uninstall.ps1 -Mode complete -ConfirmDataDeletion -FinalBackupPath D:\delta-final
```

`-ConfirmDataDeletion` is the non-interactive equivalent of typing `DELETE`, and
it is spelled that way on purpose. There is no `-Force`, and no flag skips the
ownership checks — an unregistered installation root is refused either way.

---

## After a Windows restart

Docker Desktop, as Docker ships it on Windows, starts when somebody **signs in**
— there is no Docker service that runs at boot. On its own that would mean DELTA
stays down after an overnight patch reboot until a person signs in to the
machine.

So the installer measures what this machine actually has, and if nothing on it
starts Docker before a sign-in, it registers **one scheduled task**:

```
DELTA (Docker) - <project> - Startup
   trigger   at Windows startup, 60 seconds after boot
   runs as   the account that installed DELTA, whether or not it is signed in
   action    start-delta.ps1 -InstallRoot C:\DELTA
```

The task runs the script once and exits. It starts Docker, waits for the engine,
checks the database volume is still there, brings the three containers up in
order, and confirms DELTA answers. It is not a service and it supervises
nothing.

**What the installer will and will not claim.** The summary at the end of an
install tells you which mechanism is configured, and whether a *real* restart
has ever confirmed it. Until one has, it says "configured but not yet proven" —
it will not tell you DELTA comes back on its own until that has been
demonstrated on your machine.

To confirm it yourself, the only test that counts:

1. Restart Windows.
2. **Do not sign in.**
3. From another machine, request `http://<your-host>/`. It should answer 200
   within a couple of minutes of boot.

Then read the log, which records every boot:

```powershell
Get-Content C:\DELTA\logs\installer\startup.log
```

You can also run it by hand at any time — the same code path the task uses:

```powershell
.\start-delta.ps1 -InstallRoot C:\DELTA
```

Two things worth knowing:

- **Docker Desktop will have no window or tray icon** after an unattended start,
  because it was started before anyone signed in. Docker and DELTA both work
  normally; if you want the Docker Desktop interface back, stop it and start it
  from the Start menu.
- **Other containers on this machine are not this installer's business.** The
  task starts DELTA's Compose project and nothing else. Anything else you run in
  Docker comes back only if its own restart policy says so.

If you would rather DELTA did not start by itself, disable or delete that one
scheduled task — nothing else depends on it. Opening the management utility does
not put it back; `.\setup.ps1 -Reconfigure` does, because the installer treats
"nothing starts Docker at boot" as something to fix.

The management utility shows the same distinction on its status line: it says
*configured but not yet proven* until a real restart has confirmed it.

---

## When something goes wrong

The installer explains what it found and what to do about it, and writes a full
transcript to `logs\installer\` next to `setup.ps1`. Secrets are redacted from
that transcript.

A few things it will deliberately refuse to do:

- **Install into a folder it did not create.** If `C:\DELTA` already holds
  something else, it stops rather than adopting it.
- **Start the stack when the database volume has gone missing** on an
  installation that had one. Starting would create an empty database and look
  successful while all the data was gone.
- **Publish DELTA when the administrator credential could not be replaced.**
- **Continue when DELTA's database setup reported errors**, even if the
  container looks healthy.

In each case nothing is deleted, and running the installer again after fixing
the cause continues from where it stopped.

---

## What this installer does not do

Stated plainly so it is not mistaken for a gap:

- **Nothing deletes your data by accident.** `setup.ps1` and the management
  menu never remove a database volume, and no code path anywhere reaches
  `docker compose down -v`, `docker volume prune` or `docker system prune`.
  Removal happens only through `uninstall.ps1`, which preserves data unless you
  explicitly choose otherwise — see [Removing DELTA](#removing-delta).
- **The uninstaller does not remove Docker Desktop, WSL or any prerequisite.**
  Those are shared with everything else on the machine. Removing them is your
  decision, made in Windows, not a side effect of removing DELTA.
- **It does not manage anything it did not create.** Other Docker projects,
  other containers, IIS or whatever else holds a port are identified and
  reported, never stopped or reconfigured.
- **It does not renew certificates.** There is no ACME/Let's Encrypt client and
  no scheduled renewal — replacing a certificate is an operator action
  (menu option 7).
- **It does not send test email.** Configuring SMTP checks that the server
  resolves and accepts a connection; it does not verify credentials or delivery.
- **It does not roll back an update.** DELTA's schema migrations are
  forward-only, so recovery from a bad migration is a restore from the backup
  the update took first — which is why that backup cannot be skipped.
- **It does not install or manage a Linux distribution.** Docker Desktop's own
  WSL distribution is Docker's; the installer only talks to `docker`,
  `docker compose` and `docker desktop`.
