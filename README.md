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

That is the whole thing. It installs to `C:\DELTA` unless you say otherwise,
and it asks only what it genuinely cannot work out:

- **Ports.** If 80 and 443 are free, it takes them without asking. If something
  else already has one, it tells you what, and asks you for another port. It
  never stops or reconfigures whatever is already using the port.
- **HTTPS.** It asks whether you want none, your own certificate, or a
  self-signed one.

Useful switches:

```powershell
.\setup.ps1 -InstallRoot D:\DELTA          # install somewhere else
.\setup.ps1 -Hostname delta.example.org    # the name people will use
.\setup.ps1 -TlsMode supplied -CertificatePath C:\certs\delta.crt `
            -CertificateKeyPath C:\certs\delta.key
.\setup.ps1 -HttpPort 8080 -HttpsPort 8443
.\setup.ps1 -NonInteractive                # never prompt (for automation)
```

Run `Get-Help .\setup.ps1 -Full` for the rest.

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
  5. Configure SMTP                (a later version of this installer)
  6. Reset Administrator Password  (a later version of this installer)
  7. Certificate Management        (a later version of this installer)
  8. DELTA Access Guide
  9. View Logs
  S. Start DELTA                   (shown when something is not running)
  0. Exit
```

The entries marked *later* are placeholders in this build: choosing one says so
and returns to the menu without changing anything. Pressing Enter refreshes the
status.

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
