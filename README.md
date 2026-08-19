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

## Running setup.ps1 again

It is safe. Re-running is the normal way to apply a changed setting, bring the
stack back up, or repair an installation that stopped half-way.

A re-run **never**:

- deletes the database, uploads, certificates or configuration,
- regenerates the session secret or the database password,
- changes the administrator credential again,
- reports a port that this installation already uses as a conflict.

If a previous run stopped part-way, the next one picks up from there.

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
scheduled task — nothing else depends on it. Note that running `.\setup.ps1`
again will re-register it, because the installer treats "nothing starts Docker
at boot" as something to fix.

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
