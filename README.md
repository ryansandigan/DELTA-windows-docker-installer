# DELTA for Windows — Docker installer

Installs DELTA on a Windows machine as three containers: NGINX in front, the
DELTA application, and PostgreSQL 17 with PostGIS. You run one script; it
checks the machine, sets up Docker if it has to, generates the configuration,
starts the stack in the right order, secures the administrator account, and
tells you where DELTA is.

You do not need to know anything about Docker to run it, and you never manage a
Linux system: the containers run on Docker Desktop's WSL2 backend, which is
Docker's own and which the installer never touches.

---

## Quick installation guide

Follow these steps for a standard DELTA installation. Each step is explained in
more detail later in this document.

> **Before you begin, the machine needs:**
>
> - **Windows 11, or Windows Server 2022 / 2025** — 64-bit.
> - **About 20 GB free** on the system volume.
> - **Internet access to `ghcr.io` and `docker.io`** for the first run.
>
> Hardware virtualization is also required; step 4 covers how to check and
> enable it. Everything else the installer needs, it installs or checks itself.
>
> On Windows Server, note that Docker Desktop is not officially supported there
> by Docker. DELTA has been tested successfully with it on Windows Server 2022
> and 2025, and the installer states this and asks before installing anything.

1. **Download** the installer ZIP, `DELTA-windows-docker-installer-X.Y.Z.zip`.
   These examples assume it landed in your **Downloads** folder, which is where
   Windows browsers normally put it. If yours is set to save somewhere else,
   use that path instead — nothing below depends on the location.

2. **Unblock it *before* extracting.** Right-click the ZIP → **Properties** →
   tick **Unblock** if it is shown → **Apply**. Windows marks files that came
   from the internet; clearing the mark on the ZIP saves clearing it on every
   file inside it afterwards.

3. **Extract it** — right-click → **Extract All…** is enough. Extracting it
   where it is gives you:

   ```text
   $HOME\Downloads\DELTA-windows-docker-installer-X.Y.Z\
   ```

   containing `setup.ps1`, `uninstall.ps1`, `bin\`, `lib\` and `templates\`.
   That is the **installer directory**, and it is an example location, not a
   requirement: any local directory works. A local disk, though — not a network
   share and not a cloud-synced folder.

   > **Keep this directory after the install.** `setup.ps1` is also the
   > management utility you will use afterwards, and the scheduled tasks the
   > installer registers point at scripts inside its `bin\`. Deleting it breaks
   > both.
   >
   > It is **not** where DELTA gets installed. That is a separate directory,
   > `C:\DELTA` by default, created by the installer and holding `.env`,
   > `docker-compose.yml`, `certs\`, `uploads\`, `backups\` and the rest — see
   > [Where things are](#where-things-are).

4. **Make sure hardware virtualization is available to Windows.** Docker
   Desktop's WSL2 backend runs the Docker engine in a WSL2 utility VM, which
   cannot start without it. The installer checks this and stops with an
   explanation if it is unavailable.

   - **On a physical machine:** enable virtualization in BIOS/UEFI — Intel VT-x
     or AMD-V, usually listed as *Intel Virtualization Technology*, *SVM Mode*
     or similar.
   - **If Windows is itself running in a VM:** enable nested virtualization on
     the parent hypervisor, so the virtualization extensions are exposed to the
     Windows guest.

   On **Hyper-V**, run this on the Hyper-V host — not inside the DELTA VM — with
   the VM shut down, replacing `<VMName>` with the actual VM name:

   ```powershell
   Set-VMProcessor -VMName "<VMName>" `
       -ExposeVirtualizationExtensions $true
   ```

   On VMware, VirtualBox, Proxmox, a cloud VM or any other platform, enable that
   platform's equivalent **nested virtualization** / **expose hardware
   virtualization to the guest** setting.

5. **Open Windows PowerShell as Administrator.** Start → type
   `Windows PowerShell` → right-click it → **Run as administrator**. Elevation
   is required; the installer checks and stops if it is missing.

6. **Run these three lines**, with the installer directory from step 3 in the
   first one and the real version in place of `X.Y.Z`:

   ```powershell
   cd "$HOME\Downloads\DELTA-windows-docker-installer-X.Y.Z"
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\setup.ps1
   ```

   `$HOME` is PowerShell's own variable for your user profile directory, so
   that first line works as written for any account — there is no username to
   substitute. If you extracted somewhere else, `cd` there instead.

   The middle line is not optional housekeeping — without it, most Windows
   machines answer `.\setup.ps1` with **"running scripts is disabled on this
   system"**, because blocking `.ps1` files is the default. It is also the
   smallest possible concession:

   - `-Scope Process` applies to **that one PowerShell window**. Close the
     window and it is gone.
   - It does **not** change the execution policy for your account
     (`CurrentUser`) or for the machine (`LocalMachine`). Check with
     `Get-ExecutionPolicy -List` before and after if you want to see that for
     yourself.
   - The installer never writes an execution-policy change of its own, at any
     scope, at any point.

   > If your organisation enforces the execution policy by **Group Policy**,
   > this will not help and nothing else in this installer can override it —
   > `MachinePolicy` and `UserPolicy` outrank the process scope by design. Ask
   > whoever administers that policy.

   **A short pause before the first message is normal.** On some machines there
   is a gap of a few seconds between opening PowerShell — or pressing Enter on
   `.\setup.ps1` — and DELTA's banner appearing. That gap is PowerShell itself
   starting up and loading the installer's modules, before any of DELTA's code
   is running, so the installer cannot draw anything during it. Once the banner
   is up, every operation that takes noticeable time shows a spinner and an
   elapsed counter:

   ```text
       \ Pulling container images (1m 14s)
   ```

   so from that point on you can always tell the difference between working and
   stuck. If nothing at all appears after a minute or so, something is wrong —
   see [When something goes wrong](#when-something-goes-wrong).

7. **Answer the prompts** — hostname, database password, administrator
   password, HTTPS, and one SMTP question at the end. Enter takes a sensible
   default for every one of them.

   If Docker Desktop is not already on the machine, you are shown Docker's
   licensing terms and asked before anything is installed; accept, and the
   installer installs it for you. If Docker Desktop is already there, the
   installer uses it and asks nothing about it.

8. **If it asks to restart Windows, let it.** Docker Desktop and the WSL2
   platform need a restart before the installation can go on. After you sign
   back in, DELTA **tries** to pick up where it left off:

   - a **DELTA Setup** dialog appears — click **OK**;
   - approve the Windows administrator permission (UAC) prompt if one appears;
   - the installer resumes in a PowerShell window.

   Leave that PowerShell window open while setup continues. If the resume does
   not happen, finish it by hand — both paths are set out in
   [The restart part-way through](#the-restart-part-way-through).

9. **Wait for it to finish.** The first run takes a few minutes, most of it
   pulling images. It verifies the database, the administrator credential and
   the published URL as it goes, and stops rather than reporting success it
   cannot back up.

10. **Record the DELTA administrator password** in the closing summary. It is
    shown once, stored nowhere, and cannot be recovered.

11. **Open the DELTA URL** the installer prints.

Afterwards, running `.\setup.ps1` again opens the
[management utility](#running-setupps1-again--the-management-utility) — update,
backup, SMTP, certificates, domains, logs — rather than installing a second
time.

And after a Windows restart there is nothing to run at all: DELTA comes back on
its own, though not the instant the desktop appears — see
[After a Windows restart](#after-a-windows-restart).

---

## Installing

From an elevated PowerShell prompt, in the extracted installer directory — the
one containing `setup.ps1`, `$HOME\Downloads\DELTA-windows-docker-installer-X.Y.Z`
in the examples here:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

That is the whole thing. It installs to `C:\DELTA` unless you say otherwise —
a *different* directory from the one you are running from, and the one that
ends up holding `.env`, the Compose file, the certificates and the data. You do
not prepare a configuration file, create a database, create an administrator
account, start any container, or touch Docker directly.

Expect a few seconds of nothing before the banner appears while PowerShell
starts and loads the installer's libraries; after that, any operation that
takes noticeable time shows a spinner and an elapsed counter.

### What you will be asked

Five things, all at the start, before the installer does anything slow:

| Question | Default if you just press Enter |
|---|---|
| **Installation directory** — where DELTA and its data live | `C:\DELTA` |
| **Hostname or domain** — the name people will use in a browser | `localhost` |
| **Database password** — for the PostgreSQL database it creates for DELTA | a strong one is generated |
| **DELTA administrator password** — for signing in as `admin@admin.com` | option 2, a generated one, shown once at the end |
| **HTTPS** — none, your own certificate, or a self-signed one | none (plain HTTP) |

The installation directory is asked first, as a plain yes/no:

```
Use C:\DELTA as the installation directory? [Y/n]:
```

**Enter, or Y,** takes `C:\DELTA` — the right answer on most machines, and the
one the rest of this document assumes. **N** opens a Windows folder-selection
dialog, the same kind of picker the certificate questions use below: you browse
to a directory, you do not type a path. Cancelling the dialog puts you back at
this question with `C:\DELTA` still on offer — it does not cancel the install.
A directory that cannot hold an installation (a network share, a removable or
mapped drive, somewhere this account cannot write) is refused with the reason,
and you are asked again.

You are only asked on a *new* installation. Passing `-InstallRoot` answers it
in advance, a machine that already has DELTA installed keeps the root it is
installed at, and `-NonInteractive` uses `C:\DELTA` without asking. If Windows
cannot show a dialog at all — Server Core, for instance — the question is
skipped rather than asked with no way to answer it, and `-InstallRoot` is how
you choose somewhere else there.

`localhost` is a deliberate default, not a placeholder. It lets you install
DELTA on a machine and try it from that machine immediately, without owning a
DNS name or a certificate. Nothing looks the name up, so a hostname whose DNS
entry does not exist yet is accepted — you can point DNS at it later.

The **database password** is asked as a choice, not as a prompt with a hidden
default:

```
Database password

    The installer creates the PostgreSQL database for DELTA and protects it
    with this password. The database is not published to the network.

Choose how to set the password:

  1. Enter a password
  2. Generate a strong password automatically

Choose 1 or 2 [2]:
```

**Enter, or 2,** generates one. That is a perfectly good answer: the database is
never published to the network and nothing outside this machine can reach it.
**1** asks you to type it, masked, twice; the two entries must match, and a
mismatch is reported and asked again rather than accepted. Choose 1 if you want
a password you can also use to connect with other tooling.

Nothing but `1`, `2` or Enter is accepted here. In particular a password typed
at this question is refused as a choice — it does not become your database
password, and it is not echoed back while it is being refused.

A generated database password is 32 characters. Unlike the administrator
credential it is never displayed, because nothing asks you to type it in later:
the installer writes it to `POSTGRES_PASSWORD` in the installation's `.env`,
which is where you can read it if you need it.

The **DELTA administrator password** is asked the same way, and for the same
reason — except that this is the credential you will actually sign in with:

```
DELTA administrator password

    The password for signing in to DELTA as admin@admin.com. The image ships a
    publicly known default, so the installer always replaces it before DELTA is
    reachable.

Choose how to set the password:

  1. Enter a password
  2. Generate a strong password automatically

Choose 1 or 2 [2]:
```

**Enter, or 2,** has a strong one generated and shown to you once in the closing
summary. **1** asks you to type it, masked, twice; the two entries must match,
and a mismatch is reported and asked again rather than accepted. Nothing else is
taken as an answer here — a password typed at this question is refused as a
choice, not accepted as your credential. A password you chose yourself is never
displayed, because you already know it.

For both credentials, every password entry is masked, and neither password —
typed or generated — is ever written to the installer's log. The transcript
records which method you chose and nothing else.

Answering the HTTPS question with **your own certificate** opens two Windows
file-selection dialogs, one for the certificate and one for the private key —
the same pickers [Certificate Management](#choosing-the-files) uses after the
install. You browse to the files; you do not type paths. Cancelling either
dialog puts you back at the HTTPS question, with self-signed and plain HTTP
still on offer and nothing changed.

### What you will *not* be asked

- **Ports.** If port 80 (and 443 with HTTPS) is free, the installer takes it
  without asking. You are only asked for another port when something else
  genuinely owns it — and then you are told *what* owns it. Nothing already
  using the port is ever stopped, moved or reconfigured.
- **SMTP / email, before the install.** No mail server has to exist for DELTA to
  install. The installer sets `EMAIL_TRANSPORT=file`, which writes mail to the
  container log instead of sending it, and a placeholder `EMAIL_FROM` — DELTA
  requires both to be set even when it is not sending anything. You are offered
  SMTP once at the *end*, after DELTA is up (below), and you can decline and do
  it later from [Configuring email](#configuring-email).
- **How people sign in.** `AUTHENTICATION_SUPPORTED=form` is set for you, which
  is normal local sign-in with an email address and password. (DELTA also
  accepts `sso_azure_b2c`, which additionally requires three Azure settings —
  that is a hand edit of `.env`, not something the installer offers.)
- **Anything about Docker.** Compose project names, internal ports, volumes and
  image digests are the installer's business, not yours.

Everything after those five questions runs unattended: the installer creates the
folder layout, generates the configuration, pulls and pins the images, starts
PostgreSQL, lets DELTA initialise its own schema and verifies that it did,
replaces the published default administrator credential *before* anything is
reachable, starts NGINX, requests the site to prove it answers, opens the
firewall for the port it published, and configures unattended startup. The only
thing asked after that is the optional SMTP question below, and it comes after
DELTA is already up.

### One question at the end: SMTP

With DELTA installed and answering, the installer asks once:

```
Configure SMTP now? [y/N]:
```

**Y** runs the same [Configure SMTP](#configuring-email) flow as menu option 5 —
same prompts, same connection check, same rollback if applying it fails. If it
does fail, you are offered a retry, and declining that just leaves email
unconfigured.

**N, or Enter,** skips it. DELTA keeps working: outgoing email messages are
written to the DELTA container log instead of being sent, which you can read
with menu option 10, *View Logs*. Set email up whenever you like by running
`setup.ps1` again and choosing **5. Configure SMTP**.

Either way the installation is already finished and successful before this is
asked — nothing about SMTP can undo it.

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

### The restart part-way through

Docker Desktop's WSL2 backend needs Windows features that only take effect
after a restart. When the installer finds one missing it enables it, stops
before touching Docker at all, and offers to restart Windows for you.

Say yes and it registers a **one-time** continuation for your account, then
restarts. Nothing is scheduled permanently: Windows runs the entry once and
deletes it, whatever the outcome.

When you sign back in:

1. A console window appears saying **"DELTA setup is continuing after the
   restart."**
2. It waits for the desktop to finish signing in. This is not instant — give it
   up to a minute or so.
3. A **DELTA Setup - Continue Installation** dialog appears, asking whether to
   go on. Click **OK**. This is a dialog rather than another line of console
   text on purpose: the PowerShell window is where the installer's own output
   goes, and anything that needs *you* is a Windows dialog you cannot miss
   under a screen of scrolling text.
4. **Windows shows a UAC elevation prompt.** You must approve it. The installer
   cannot continue without administrator rights, and the window in front of you
   does not have them. (If you signed in to an account that is already running
   elevated, there is no prompt, and the dialog does not claim there will be
   one.)
5. The installation carries on in a PowerShell window, from the state it finds
   — the same installation folder, the same answers. You are not asked the
   installation questions again. **Leave that window open** until setup
   finishes or asks you something.

Clicking **Cancel** on the dialog is safe and changes nothing: nothing is
elevated, nothing is restarted, and the partial installation is left exactly as
it is. You are told so, and the commands to continue later are printed in the
console window behind it.

**This is an attempt, not a guarantee.** The elevation prompt can be declined,
and Windows sometimes cancels its own prompt when it is asked for one while the
desktop is still coming up. Either way you get the same message —
`The operation was canceled by the user` — because Windows reports both the
same way. You are then asked, once, whether to **ask Windows again**; say yes
and the prompt comes back. That is worth doing once if you did not decline it
yourself. It never asks again on its own.

Nothing is lost if it gives up. The installation resumes from the machine's
actual state whenever you next run `setup.ps1`, which is exactly what the
automatic path does.

#### If the restart does not continue by itself

Open **Windows PowerShell as Administrator** — Start → type
`Windows PowerShell` → right-click → **Run as administrator** — and run, with
your own installer directory in the first line:

```powershell
cd "$HOME\Downloads\DELTA-windows-docker-installer-X.Y.Z"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup.ps1
```

That first line is the example location from the
[quick installation guide](#quick-installation-guide) — the directory you
extracted the ZIP to, the one holding `setup.ps1`, not `C:\DELTA`. You do not
have to work it out from here: the continuation window prints the exact three
lines to run, with the real directory already filled in.

`-Scope Process` applies to that one PowerShell window only and is forgotten
when you close it; it changes nothing for your account or for the machine. It
is there because Windows blocks `.ps1` files by default, which is the
`running scripts is disabled on this system` error.

If you chose an installation folder other than `C:\DELTA`, add it — the
continuation window prints the exact line to use, including the folder:

```powershell
.\setup.ps1 -InstallRoot "D:\Program Files\DELTA"
```

### Running setup.ps1 again

Once DELTA is installed, `.\setup.ps1` opens the
[management utility](#running-setupps1-again--the-management-utility) instead of
installing. It does not ask the installation questions again, does not
regenerate anything, and does not recreate any container just because you
opened it.

Most settings are changed from the menu itself and need no installer run:

| To change | Use |
|---|---|
| HTTPS on or off, the certificate, the HTTPS port | [Certificate Management](#https-and-certificates) — menu option 7 |
| Hostnames, and which one is canonical | [Domain Management](#managing-domains) — menu option 8 |
| Email | [Configure SMTP](#configuring-email) — menu option 5 |
| The administrator password | [menu option 6](#resetting-the-administrator-password) |

What is left for the installer flow is the **HTTP port**:

```powershell
.\setup.ps1 -Reconfigure -HttpPort 8080
```

It deliberately does **not** re-ask either password: the database password is
applied only when the database is first created, so changing it there would not
change what PostgreSQL expects, and the administrator credential is left to
menu option 6, which is the operation that actually knows how to replace it.

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

Two separate places: the folder you extracted the installer into, and the
installation it creates.

**The extracted installer** — keep it. `setup.ps1` is also the management
utility and the uninstaller lives beside it. Wherever you extracted the ZIP;
`$HOME\Downloads\DELTA-windows-docker-installer-X.Y.Z\` in the examples in this
document:

```
DELTA-windows-docker-installer-X.Y.Z\
  setup.ps1                 install, and afterwards the management menu
  uninstall.ps1             remove DELTA (always backs up first)
  bin\                      scripts the scheduled tasks run
    start-delta.ps1           brings DELTA back after a restart
    rotate-nginx-logs.ps1     the daily access-log trim
  lib\                      the installer's own libraries
  templates\                .env, docker-compose.yml and NGINX templates
  logs\installer\           transcripts of every run, secrets redacted
```

The two scheduled tasks the installer registers point into `bin\` **by absolute
path**, so moving or renaming this folder after installing leaves them aimed at
scripts that are no longer there. Both reconcile themselves when the menu is
opened — after moving the folder, run this from its new location:

```powershell
.\setup.ps1                # opens the menu, which re-points both tasks
```

Each notices that the registered command line no longer matches and replaces
the task; neither creates a duplicate, and a task that is already correct is
left exactly as it is.

**The installation:**

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

If you chose option 2 at the administrator-password question — or pressed Enter,
which is the same answer — the installer generates the new password and shows it
**once**, at the end of the install:

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
  Restart        Configured    automatic startup enabled
```

The Restart row is measured, not remembered. Every refresh checks Task Scheduler
itself — the task must exist, be enabled, carry both of its triggers, and point
at a script that is still there — so an installation whose startup task has gone
is reported as `Not set up` however confidently the installation record claims
otherwise. Once a real unattended restart has been recovered from, the row
becomes `Verified  automatic startup verified`.

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
  8. Domain Management
  9. DELTA Access Guide
 10. View Logs
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
- **Certificate Management** turns HTTPS on and off and manages the certificate —
  see [HTTPS and certificates](#https-and-certificates).
- **Domain Management** adds and removes the hostnames DELTA answers to, and
  chooses which one is canonical — see [Managing domains](#managing-domains).
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
   action    bin\rotate-nginx-logs.ps1 -InstallRoot C:\DELTA
```

It renames the current log to `access.log.<timestamp>`, tells NGINX to reopen
its log so writing continues at the same path, and keeps the seven most recent
rotations. It touches nothing else in that folder, and an empty log is simply
nothing to do. Run it by hand at any time:

```powershell
.\bin\rotate-nginx-logs.ps1 -InstallRoot C:\DELTA
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

This is the same flow the installer offers once at the end of a fresh install
([One question at the end](#one-question-at-the-end-smtp)); answering **N**
there and coming here later gets you exactly the same screens.

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
sender@example.org
"DELTA" <sender@example.org>
DELTA Notifications <sender@example.org>
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

### HTTPS and certificates

Menu option **7**, **Certificate Management**, owns HTTPS for this installation:
enabling it, replacing the certificate, inspecting it, and turning it off again.
All of it happens inside the management utility — you are never sent away to run
`.\setup.ps1 -Reconfigure` to get HTTPS.

The screen adapts to what it finds.

**On an HTTP installation:**

```
========================================================================
Certificate Management
C:\DELTA
========================================================================

HTTPS
  Disabled - NGINX serves HTTP on port 80

Primary domain
  delta.example.org

Configured domains
  delta.example.org   (primary)
  delta.internal.example.org

Certificate
  None active

  1. Enable HTTPS
  0. Return
```

**On an HTTPS installation:**

```
HTTPS
  Enabled on port 443

Primary URL
  https://delta.example.org

Certificate
  Subject        CN=delta.example.org
  Issuer         CN=Example CA
  Valid from     2026-01-04
  Expires        2027-01-04  (312 day(s) remaining)
  Thumbprint     3A7C...
  Private key    Available

Domain coverage
  delta.example.org            (primary)     Covered
  delta.internal.example.org   (additional)  NOT COVERED

  1. Replace Certificate
  2. Inspect Certificate
  3. Disable HTTPS
  0. Return
```

#### Certificate sources

Two, and the menu offers exactly those:

```
Where is the certificate coming from?

  1. Use an existing certificate and private key
     Select a certificate (.crt/.cer/.pem) and private key (.key).
     Recommended for production certificates issued by your
     organization or certificate provider.

  2. Generate a self-signed certificate
     For testing or internal use. Browsers will warn unless trusted.

  0. Cancel
```

When you are re-enabling HTTPS after disabling it, a third option appears —
*Reuse the certificate already in `certs\`* — offering the pair that was
preserved. It is validated again from scratch before it is used.

#### Choosing the files

Option 1 opens **two Windows file-selection dialogs**, one after the other — the
same flow the native NGINX installer uses. You browse to the files; you do not
type paths.

```
Select the SSL certificate file     Certificate files (*.crt;*.cer;*.pem)
Select the SSL private key file     Private key files (*.key;*.pem)
```

Each dialog also offers *All files*, so a correctly-named certificate in an
unusual location is still reachable — the extension is checked afterwards either
way.

**Cancelling either dialog cancels the whole operation** and returns you to the
menu with the installation untouched. Nothing is validated, staged or changed
until both files have been chosen.

These are the same two dialogs the installer opens when you answer its HTTPS
question with *I have a certificate* — one implementation, so the two flows
cannot drift apart. The only difference is where cancelling lands you: here, the
menu; during an install, back at the HTTPS question.

> On a session that cannot show a dialog at all — Server Core, or PowerShell
> running on a non-STA thread — the installer says so and asks you to type the
> two paths instead, so a headless host is not left unable to install a
> certificate.

**PEM is the only format accepted.** NGINX serves PEM files directly, so that is
what you supply and that is what gets installed: nothing is converted on the way
in, and there is no transformation step between your files and the ones being
served.

PKCS#12 (`.pfx`/`.p12`), DER, PKCS#7 and the Windows certificate store are not
accepted. This installer terminates TLS from mounted PEM files and has no
involvement with the Windows certificate store at all. If your certificate
provider gave you a `.pfx`, convert it once with the tool of your choice and
supply the resulting certificate and key — for example:

```
openssl pkcs12 -in delta.pfx -nokeys  -clcerts -out delta.crt
openssl pkcs12 -in delta.pfx -nocerts -nodes   -out delta.key
```

Supplying a `.pfx` where a certificate is expected is refused by extension, with
a message saying so, before anything is parsed or changed.

An encrypted private key is refused rather than accommodated: NGINX cannot use
one without an `ssl_password_file` holding the passphrase in plaintext beside
it, which gains nothing. Because no accepted format carries a password, **there
is no certificate password anywhere in this flow** — none is asked for, held,
or written.

#### What is validated before anything is touched

- both files exist and can be read;
- the certificate parses as X.509;
- the private key parses and is not passphrase-protected;
- **the key matches the certificate** — the check that matters, because a
  mismatch otherwise surfaces as a cryptic NGINX failure;
- the certificate is currently valid — not expired, not post-dated — with a
  warning if it expires within 30 days;
- **it covers the primary domain.**

That last one is a **refusal, not a warning**. `PUBLIC_URL` is the address DELTA
calls itself by; configuring it as `https://delta.example.org` while serving a
certificate that fails hostname validation for `delta.example.org` would mean
every browser reaching DELTA at its own canonical address gets a security
warning. A certificate that does not cover the primary domain is not installed,
and you are told what it *is* valid for.

#### When the certificate names a different domain

A certificate that validates perfectly but names a different host than your
current primary domain is usually not a mistake — it is the right certificate
arriving before the domain has been made primary. Installing DELTA on
`localhost` and then being handed a certificate for `delta.example.org` is the
ordinary way this happens.

The refusal above still stands. What you are offered next is the chance to
change the thing that makes it a refusal, using the names the certificate
already carries:

```
The certificate does not cover the current primary domain:

    localhost

The certificate is valid for:

    delta.example.org

Would you like to use delta.example.org as the primary domain?

  1. Yes - Make it the primary domain and continue
  2. No  - Keep the current primary domain

Selection:
```

Answer **Yes** and the installer, through Domain Management's own operations:

1. adds the domain to the configured set if it is not there already;
2. makes it the primary domain, keeping the previous primary (`localhost` here)
   as an additional domain, so links using it keep working;
3. **reuses the certificate and key you already chose** — the file dialogs do
   not open a second time;
4. carries on with the HTTPS transaction exactly as it would have, so
   `PUBLIC_URL`, the NGINX `server_name` and the published ports all end up
   consistent with the new primary domain.

Answer **No** and nothing changes: the certificate is refused exactly as it was
before, and the primary domain is untouched.

If the certificate carries **several** usable names, they are listed and you
choose which one becomes primary — the installer does not pick the first SAN on
your behalf. Only names that pass DELTA's ordinary domain rules are offered, so
a wildcard entry like `*.example.org` is never proposed as a primary domain, and
neither is anything malformed.

> **If anything fails afterwards, the promotion is undone.** The domain change
> is made before the HTTPS transaction it exists to enable, so if that
> transaction fails the installer puts the primary domain back and removes a
> domain it added only for this operation. A failed *Enable HTTPS* does not
> leave the installation renamed.

Uncovered **additional** domains are different: they are aliases, so an
uncovered one warns and HTTPS still goes ahead for the correctly-covered
primary. See [Managing domains](#managing-domains).

Coverage is read from the certificate's subjectAltName DNS entries (falling back
to the common name only when there is no SAN at all), matched case-insensitively,
with wildcards honoured the way browsers honour them — `*.example.org` covers
`a.example.org` but not `example.org` or `a.b.example.org`. If the names cannot
be read on this host, that is reported as **could not be determined** and never
as "not covered".

#### Enable HTTPS

1. The HTTPS port is settled through the same resolver installation uses, so a
   port something else already holds is reported and refused rather than DELTA
   being recreated onto a port it cannot bind.
2. The certificate and private key are collected, validated and gated.
3. The NGINX configuration for HTTPS is generated and **validated with `nginx -t`
   inside the still-running HTTP container** — which can read the new certificate
   and key, because `certs\` is mounted in both shapes. Nothing is recreated
   until that passes.
4. `.env` gains `TLS_ENABLED=true`, `TLS_MODE`, the HTTPS port, and a
   `PUBLIC_URL` whose scheme becomes `https`.
5. `docker-compose.yml` is regenerated to publish the HTTPS port, and validated.
6. **NGINX is recreated** — `up -d --no-deps nginx`. This is genuinely necessary,
   not defensive: the published ports and the healthcheck are both
   container-creation-time properties and a reload cannot express either.
7. **The DELTA container is recreated** — `PUBLIC_URL` is in its environment and
   is read at start.
8. The installer's own HTTPS firewall rule is added for that port.
9. The endpoint is actually requested, and the certificate NGINX is presenting is
   read back and compared with the one installed.

The database, its volume, the uploads and every unrelated container are not
touched at any point.

Afterwards HTTP keeps listening and issues a `301` to the HTTPS URL, including a
non-standard port when there is one.

**What "verified" means.** The installer requests the site over loopback, which
proves this machine terminates TLS and that DELTA answers through it. It does
**not** prove a browser elsewhere will trust the certificate or that your
hostname resolves — those depend on DNS and on that machine trusting the issuer.
The report says exactly that rather than implying more.

#### Replace Certificate

Available while HTTPS is on, and it does **not** require disabling HTTPS first.
The same collection, validation and primary-domain gate apply. Then the current
certificate and key are copied aside with a timestamp, the new pair is installed
with the same restricted permissions, and:

```
nginx -t          runs inside the running NGINX container
nginx -s reload    only if nginx -t passed
```

**No container is recreated** — not NGINX, not DELTA, not the database. A reload
signals the running NGINX process, so established connections are drained rather
than dropped and the site does not go down.

**If `nginx -t` rejects the new certificate**, NGINX is never signalled — it
carries on serving the old certificate from memory — the previous files are put
back, and the restored configuration is re-tested. If the reload or the endpoint
check fails, the previous certificate is restored and reloaded. The known-good
certificate is never destroyed first.

#### Inspect Certificate

A read-only view: subject, issuer, serial number, thumbprint, whether it is
self-signed, validity dates and days remaining, the public-key algorithm and
size, the signature algorithm, the SAN names, whether the private key file is
present, and per-domain coverage of the configured domain set.

Fields this host could not read are omitted rather than shown blank or guessed
at. **No private key material, no certificate password and no `.env` value is
ever printed** — the private key is never opened; its presence is answered from
the filesystem.

#### Disable HTTPS

Returns the installation to plain HTTP. You are told what will happen before you
confirm: `PUBLIC_URL` reverts to `http://`, the HTTPS listener and published port
go away, HTTP serves DELTA directly instead of redirecting, and the installer's
HTTPS firewall rule is retired.

**The certificate and key are not deleted.** Preservation is the safe default —
you may be about to turn HTTPS back on, and you may not have another copy. The
recorded HTTPS port is kept too, so re-enabling offers the port this installation
already chose.

Disabling HTTPS on an installation that is already HTTP is a no-op that says so.

#### Enable HTTPS again

Re-enabling offers the preserved certificate back as *"Reuse the certificate
already in `certs\`"*. It is **validated again from scratch** — a certificate
that was valid in March is not necessarily valid in December, and an expired,
mismatched or wrong-domain one is refused exactly as any other would be.

#### Interaction with Domain Management

Ownership is split and neither side reaches into the other:

| | Owns |
|---|---|
| **Certificate Management** (7) | HTTPS on/off, the certificate and key, `TLS_ENABLED`, the HTTPS port, the *scheme* half of `PUBLIC_URL`, the HTTPS firewall rule |
| **Domain Management** (8) | which hostnames exist, which one is primary — the *host* half of `PUBLIC_URL` |

Adding or removing a domain never issues, replaces or deletes a certificate.
Installing a certificate changes a domain **only** when you answer Yes to the
offer described in
[When the certificate names a different domain](#when-the-certificate-names-a-different-domain)
— and when it does, it performs that change through Domain Management's own
operations rather than writing the domain configuration itself. There is one
implementation of adding and promoting a domain, and both menus use it.

They meet at one invariant: **an HTTPS `PUBLIC_URL` must never knowingly point at
a hostname the certificate serving it does not cover.** So on a TLS-enabled
installation, *Set Primary Domain* **refuses** to promote a domain the
certificate demonstrably does not cover, and tells you to install a covering
certificate first. The domain stays configured as an additional domain
meanwhile, so NGINX still answers to it.

The promotion offer satisfies the same invariant from the other direction —
it only ever proposes domains the certificate being installed *does* cover, and
the coverage is judged against that incoming certificate rather than the
outgoing one.

#### Firewall

Only the installer's own two rules, named after this installation's Compose
project, are ever touched. Enabling HTTPS adds the HTTPS rule for the port in
use; disabling retires it. Repeated operations replace rather than duplicate. A
domain change alone never rewrites a firewall rule. A host whose policy forbids
local firewall rules still gets a working installation — it just is not reachable
from other machines yet, and the installer says so.

#### If something fails

Every TLS change is one transaction over a snapshot of `.env`, the Compose file,
the NGINX configuration and the certificate material. Any failure restores all of
it and brings the runtime back to it, then reports honestly whether DELTA is
answering again. You should never end up with `TLS_ENABLED=true` and an HTTP-only
NGINX, a `PUBLIC_URL` that says `https` while HTTPS is unavailable, or a
certificate replaced under a configuration that was never validated.

There is no automatic renewal and no ACME/Let's Encrypt client. Replacing a
certificate is a deliberate operator action.

#### Self-signed certificates

Offered, and labelled as what they are. A generated certificate covers the whole
configured domain set — the primary and every additional domain — plus
`localhost` and `127.0.0.1`. Browsers will warn until it is trusted or replaced.
It is suitable for internal testing, not for public use, and both the screen and
the completion report say so.

### Managing domains

Menu option **8** manages the hostnames this installation answers to, without
editing `.env`, the NGINX configuration or `docker-compose.yml` by hand, and
without leaving the management utility.

#### Primary URL, primary domain, additional domains

Three different things, and the distinction is the whole point:

| | What it is |
|---|---|
| **Primary URL** | `PUBLIC_URL` — the one canonical address DELTA calls itself by. Used for links, redirects and anything DELTA generates that has to be absolute. There is exactly one, always. |
| **Primary domain** | The host part of that URL. Exactly one, always. |
| **Additional domains** | Further hostnames NGINX accepts. They are **not** additional public URLs — DELTA still calls itself by the primary URL. |

`PUBLIC_URL` never becomes a list. NGINX may accept many hostnames; DELTA has
one canonical address. So an installation can look like this:

```
PUBLIC_URL=https://delta.example.org

server_name delta.example.org delta.internal.example.org delta-old.example.org;
```

#### The screen

```
========================================================================
Domain Management
C:\DELTA
========================================================================

Primary URL
  https://delta.example.org
  The one canonical address DELTA uses for itself. There is exactly one.

Primary domain
  delta.example.org

Additional domains
  delta.internal.example.org
  delta-old.example.org

  1. Add Domain
  2. Remove Domain
  3. Set Primary Domain
  0. Return
```

With no additional domains it says so in a sentence rather than printing an
empty list.

#### Add Domain

Enter **one hostname** — no scheme, no port, no path. `https://delta.example.org`,
`delta.example.org:443`, `delta.example.org/path`, `user@delta.example.org` and
`*.example.org` are all refused, with the reason. Comparison is
case-insensitive, so `DELTA.Example.org` cannot be added alongside
`delta.example.org`, and a domain already configured is rejected rather than
duplicated.

Adding a domain **does not change `PUBLIC_URL`**:

```
before   PUBLIC_URL=https://delta.example.org
         server_name delta.example.org;

add      delta.internal.example.org

after    PUBLIC_URL=https://delta.example.org           (unchanged)
         server_name delta.example.org delta.internal.example.org;
```

**No container is recreated.** The NGINX configuration is regenerated, validated
with `nginx -t` inside the running container, and applied with `nginx -s reload`.
DELTA and the database are not involved at all.

#### Remove Domain

Pick one of the **additional** domains from a numbered list — no retyping. The
**primary domain is not offered and cannot be removed here**: that is what
guarantees the installation can never end up with no primary domain. To stop
using the current primary, make another domain primary first; the old one
becomes an additional domain and can then be removed.

**Removing a domain never touches certificate material.** A certificate that
still covers a hostname NGINX no longer accepts is not a problem, and deleting
key material because a name left a list would be well outside what this
operation owns. Certificates belong to Certificate Management.

#### Set Primary Domain

Choose any configured domain — primary or additional — to become the canonical
one:

```
before   PUBLIC_URL=https://delta.example.org
         delta.example.org             primary
         delta.internal.example.org    additional

set      delta.internal.example.org

after    PUBLIC_URL=https://delta.internal.example.org
         delta.internal.example.org    primary
         delta.example.org             additional
```

The old primary is kept as an additional domain rather than dropped, so links
using it keep working.

**The scheme is preserved.** An HTTPS installation stays HTTPS and an HTTP one
stays HTTP — this operation swaps a hostname and nothing else. It cannot enable
or disable TLS, change ports, or alter firewall rules. Turning HTTPS on is still
the certificate/installer workflow.

This is the one domain operation that recreates a container: `PUBLIC_URL` is
part of DELTA's environment and is read at start, so the application container
is recreated (`up -d --no-deps delta`) to pick up the new canonical URL, then
waited on for health and re-checked through NGINX. The database and its volume
are not touched.

#### HTTP, HTTPS and certificate coverage

Domain Management manages hostnames. It does **not** own TLS enablement, and it
never issues, replaces or deletes a certificate.

On an HTTPS installation it does answer the question that matters when a
hostname is added: **does the active certificate cover it?** You are told one of
three things, and they are three different facts:

```
The active certificate covers delta.internal.example.org.

The active certificate does not cover delta.internal.example.org.
  It is valid for: delta.example.org
  ...Replace it through Certificate Management (menu option 7).

Certificate coverage for delta.internal.example.org could not be determined.
```

"Could not be determined" is never reported as "not covered". Coverage is read
from the certificate's subjectAltName entries (falling back to the common name
when there is no SAN), matched case-insensitively, with wildcards honoured the
way browsers honour them — `*.example.org` covers `a.example.org` but not
`example.org` or `a.b.example.org`.

Adding an uncovered domain is allowed, and NGINX will serve it. Browsers
reaching DELTA by that hostname will warn until the certificate is replaced.

When the installer generates a **self-signed** certificate, it covers the whole
configured domain set rather than the primary alone.

#### localhost

`http://localhost` is a legitimate configuration and nothing here breaks it. A
localhost installation opens Domain Management showing exactly that. Adding a
real domain while localhost is primary **does not silently promote it** — the
new domain is accepted by NGINX, `PUBLIC_URL` still says `http://localhost`, and
promoting it is a separate, explicit **Set Primary Domain**. Whether localhost
stays as an additional accepted hostname afterwards is likewise your explicit
choice.

#### What it does not change

Ports. Firewall rules. TLS enablement. Certificates. Secrets. The database, its
volume, or the uploads. Any container other than the application container, and
that one only when `PUBLIC_URL` genuinely changed. Any NGINX installation or
Docker resource that is not this installation's.

#### Idempotency and safety

Opening Domain Management and leaving it again **changes nothing** — no file is
written for having looked. Adding a domain twice is rejected the second time,
including a case variant. Setting the current primary as primary is a no-op that
says so. Removing something that is not configured changes nothing. Repeated
runs never duplicate a `server_name` entry.

Every change follows the same order:

```
build candidate -> nginx -t -> nginx -s reload -> persist -> verify
```

An invalid configuration is never left in the live path. If `nginx -t` rejects
the candidate, NGINX is never signalled — it carries on serving the previous
domains from memory — the previous file is put back and nothing is recorded. If
the reload fails, or the change cannot be recorded, NGINX is put back and
reloaded so that what is served and what is recorded still agree. There is no
failure that leaves "recorded but not served" or "served but not recorded".

Configured domains are stored in `.delta-install.json` under `domains`. The
primary is **not** duplicated there — it is `DELTA_HOSTNAME` in `.env`, where it
has always been, so there is no second copy to drift. An installation created
before this feature existed has no `domains` record and needs no migration: it
simply resolves to its existing hostname as primary, with no additional domains.

Domain input is **data, never NGINX syntax**. Every hostname passes a single
boundary before it can become part of a `server_name` directive, and anything
that is not a plain hostname stops the operation rather than being escaped or
quoted.

### Changing the HTTP port

The HTTP port is the one networking setting the management utility does not
own. To change it, run the installer flow against the existing installation:

```powershell
.\setup.ps1 -Reconfigure -HttpPort 8080
```

It is as non-destructive as any other re-run: your data, secrets, certificates,
image pins, **your TLS state and your configured domains** are all preserved — a
rerun regenerates `server_name` from the recorded domain set and the Compose
file from the recorded TLS state, so neither is lost.

**HTTPS enablement and the HTTPS port are no longer this flow's job.** Use
[Certificate Management](#https-and-certificates) (menu option 7), which does
the whole transition and can undo it.

The hostname no longer needs this flow: use **Domain Management** (menu option
8) instead.

---

## Removing DELTA

```powershell
.\uninstall.ps1
```

It backs everything up first, and only then removes DELTA. When it finishes:

```
C:\DELTA                              gone
C:\DELTA-backups\DELTA-<date>.zip     present, and verified
```

That ZIP is how your data is preserved. Nothing is deleted until it exists and
has been checked.

### What happens, in order

1. **It proves this is a DELTA installation it created**, by reading
   `C:\DELTA\.delta-install.json`. A directory without that file is refused.
2. **It backs up the database** — `pg_dump` inside the database container, then
   `pg_restore --list` to prove the dump is readable. Same implementation as
   menu option 2.
3. **It stops the containers**, so nothing is writing to `uploads\` or `logs\`
   while they are being read. Stopped, not removed: if a later step fails, the
   installation is completely intact and `setup.ps1` brings it back.
4. **It archives the whole of `C:\DELTA`** into
   `C:\DELTA-backups\DELTA-<timestamp>.zip`.
5. **It verifies the archive** by opening it and confirming what has to be
   there actually is — including reading the database dump back out of the ZIP
   and checking it really is a PostgreSQL dump.
6. **Only then** does it remove the containers, the network, the database
   volume, the two scheduled tasks, the firewall rules and `C:\DELTA` itself.

**If step 2, 4 or 5 fails, the uninstall stops and nothing is removed.** There
is no "continue anyway" and no switch that skips the backup — not for
convenience, not for automation. Deleting data you could not back up is the one
thing this script is built to make impossible.

### What is in the archive

Everything under the installation root, with nothing excluded:

| | |
|---|---|
| `backups\delta-<timestamp>.dump` | the **fresh** database dump taken for this uninstall, plus every earlier one |
| `uploads\` | every file your users uploaded |
| `certs\` | the certificate and its private key |
| `.env` | configuration and secrets |
| `docker-compose.yml` | the stack definition |
| `nginx\conf.d\delta.conf` | the generated NGINX site |
| `.delta-install.json` | what the installation was — ports, hostname, image digests |
| `logs\` | application, access and installer logs |

Nothing is left out. In this architecture the DELTA application itself lives in
the Docker image and comes back with `docker pull`, so unlike a from-source
install there is no dependency tree or build cache in the installation folder to
skip — every byte of it is either configuration, secrets or data.

> `C:\DELTA-backups` is also where the **non-Docker** DELTA uninstaller writes
> its archives, deliberately: one place to look. Both use
> `DELTA-<timestamp>.zip`, so archives from the two sit side by side in
> timestamp order.

### Bringing DELTA back

Install it again, then restore the dump from inside the archive:

```powershell
# 1. Install DELTA again.
.\setup.ps1

# 2. Get the dump out of the archive.
Expand-Archive C:\DELTA-backups\DELTA-20260821-013000.zip -DestinationPath C:\temp\delta-restore
```

Then follow [Restoring the database](#restoring-the-database) with the extracted
`backups\delta-<timestamp>.dump`. Copy `uploads\` back into `C:\DELTA\uploads`
at the same time if you had any.

The old `.env` is in the archive too. Do not copy it over the new one wholesale
— the new installation has its own database password and session secret — but
it is there if you need to read a setting off it.

### What it never touches

Docker Desktop, WSL, Hyper-V, Windows features, Git, PowerShell. None of them
are removed. They are shared with the rest of the machine, and the fact that
`setup.ps1` can install Docker Desktop does not make Docker Desktop DELTA's to
delete.

Nor does it touch any Docker resource it did not create. It identifies this
installation from its own state file — not by looking for names that resemble
DELTA's — so another Compose project, another container, another volume or a
similarly named scheduled task is never a candidate. Point it somewhere it does
not belong and it refuses:

```powershell
.\uninstall.ps1 -InstallRoot C:\Some\Other\Folder
# No DELTA Docker installation was found. Nothing was changed.
```

### Docker has to be running

The database backup runs inside the database container, so without a working
Docker engine there is no way to produce the dump the archive must contain —
and therefore no way to reach a state where deleting anything is allowed. If
Docker is down, the script says so and stops, without touching the scheduled
tasks or firewall rules. Start Docker Desktop and run it again.

### Options

```powershell
.\uninstall.ps1 -InstallRoot D:\DELTA           # a different installation
.\uninstall.ps1 -BackupRoot E:\delta-archives   # put the ZIP somewhere else
```

`-BackupRoot` may not be inside the installation root; an archive written into
the directory being archived is refused rather than worked around.

For scripted teardown:

```powershell
.\uninstall.ps1 -ConfirmDataDeletion
```

`-ConfirmDataDeletion` is the non-interactive equivalent of typing `DELETE`, and
it is spelled that way on purpose. It authorises the deletion; it does **not**
skip the backup. The archive is still created and still verified, and the
uninstall still stops if either fails.

### If something could not be removed

The uninstaller distinguishes *removed*, *already absent*, *preserved*,
*failed* and *could not verify*, and will not report success when something
survived:

```
PARTIAL - DELTA was not completely removed.

These were not removed, or could not be checked:
  DELTA (Docker) - delta - HTTP - The rule exists and could not be removed. ...
```

The archive still exists and is still valid — it was made before any of this.
Re-run the script once the cause is resolved; it continues from wherever the
installation actually is, and takes a fresh archive when it does.

---

## After a Windows restart

**DELTA starts itself — give it a moment.** Once it is installed, a Windows
restart needs no administrator action in the normal case. It is simply not ready
the instant the Windows desktop appears: several things have to happen in order
first, and each one waits for the one before it.

```text
Windows starts
  → the startup task runs, 60 seconds after boot
    (and again 30 seconds after the installing account signs in)
  → Docker Desktop starts
  → the Docker engine becomes ready, in Linux-container mode
  → the DELTA containers start, each waiting for the one before it
  → DELTA becomes accessible
```

Docker Desktop's WSL2 backend runs the Docker engine inside a WSL2 utility VM,
and that engine has to be up before it can run any container. So there is a
period after boot during which DELTA is still starting and will not answer. How
long depends on the host — disk speed, memory, whatever else starts with
Windows, and how long Docker Desktop takes to bring the WSL2 backend and the
engine up — so no fixed time can be promised. The startup script waits up to five minutes for the engine
before giving up, which is the outside of what it expects to need.

**Wait for that to finish before assuming something is wrong.** Most reports of
"DELTA is down after a reboot" are a check made too early. To see where things
stand:

```powershell
cd C:\DELTA
docker compose ps
```

The three services should end up running and healthy. If `docker` itself does
not answer yet, Docker Desktop has not finished initialising the engine — wait
and run it again. `C:\DELTA\logs\installer\startup.log` records every boot and
is the place to look if they never do.

Under normal restart behaviour you do **not** need to run `setup.ps1` again,
start the containers by hand, or choose **Start DELTA** from the menu. Those are
for a first install or for recovering from an actual failure; reaching for them
while Docker Desktop is still coming up achieves nothing.

The rest of this section is how that works, and how to prove it on your own
machine.

Docker Desktop, as Docker ships it on Windows, starts when somebody **signs in**
— there is no Docker service that runs the engine at boot. `com.docker.service`,
where it exists, is Docker's privileged helper for a signed-in user: it starts
neither Docker Desktop, nor the WSL2 utility VM, nor the Docker engine. On its own
that would mean DELTA stays down after an overnight patch reboot until a person
signs in to the machine.

So the installer registers **one scheduled task** of its own, and does not
delegate this to any mechanism it cannot verify:

```
DELTA (Docker) - <project> - Startup
   triggers  at Windows startup, 60 seconds after boot
             at logon of the installing account, 30 seconds after sign-in
   runs as   the account that installed DELTA, logon type S4U — whether or not
             it is signed in, with no password stored anywhere
   action    bin\start-delta.ps1 -InstallRoot C:\DELTA -FromStartupTask
```

Both triggers, because each covers what the other cannot. Docker Desktop's WSL2
backend is brought up by a **per-user desktop application** — its Docker-managed
WSL2 environment is registered under the installing account and
`com.docker.backend` is a child of that application — so a task running at boot,
before any session exists, cannot be relied on to start it. The logon trigger recovers the machine
the moment that account signs in, which on a server administered over RDP is how
anybody reaches it. Whichever fires first does the work; the other finds the
stack already up and does nothing, and the task never runs twice at once.

The task runs the script once and exits. It starts Docker, waits for the engine,
verifies Linux-container mode, checks the database volume is still there, brings
the three containers up in order, and confirms DELTA answers. It prompts for
nothing — there is nobody to answer at boot — and if Docker is in
Windows-container mode it reports that and stops rather than switching engines
unasked. It is not a service and it supervises nothing.

**What the installer will and will not claim.** The status row tells you whether
the mechanism is registered on this host *now*, and separately whether a real
unattended restart has ever been recovered from. Until one has, it reads
`Configured  automatic startup enabled` — the mechanism is in place and has not
yet demonstrated anything. `Verified  automatic startup verified` appears only
after the task has genuinely brought a down engine and a down stack back up by
itself. Running the task by hand on a machine where Docker is already up records
nothing, because it demonstrated nothing.

To confirm it yourself, the only test that counts:

1. Restart Windows.
2. **Do not sign in.** Wait a couple of minutes.
3. From another machine, request `http://<your-host>/`.

If it answers 200 without anybody signing in, the boot trigger recovered the
host. If it does not, sign in to the machine as the account that installed DELTA
and wait a minute: the logon trigger then recovers it, which is the expected
result on a host where Docker Desktop needs a session to start. Either way the
status row moves to `Verified` and the log below says which trigger did it.

Then read the log, which records every boot:

```powershell
Get-Content C:\DELTA\logs\installer\startup.log
```

You can also run it by hand at any time — the same code path the task uses:

```powershell
.\bin\start-delta.ps1 -InstallRoot C:\DELTA
```

Two things worth knowing:

- **Docker Desktop will have no window or tray icon** after an unattended start,
  because it was started before anyone signed in. Docker and DELTA both work
  normally; if you want the Docker Desktop interface back, stop it and start it
  from the Start menu. When somebody *does* sign in after a restart, Docker
  Desktop's own AutoStart — which the installer enables — brings it up the
  ordinary way, so briefly seeing the Docker Desktop window during startup is
  expected and is not an error.
- **Other containers on this machine are not this installer's business.** The
  task starts DELTA's Compose project and nothing else. Anything else you run in
  Docker comes back only if its own restart policy says so.

**If you would rather DELTA did not start by itself**, disable or delete that one
scheduled task — nothing else depends on it. Be aware that it does not stay that
way: both the installer and the management utility treat a missing, disabled or
out-of-date startup task as something to repair, so the next time `setup.ps1` is
run for any reason it is registered again and re-enabled. There is no switch that
keeps the installation in place with automatic startup permanently off.

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
  Deletion happens only through `uninstall.ps1`, which cannot reach it until it
  has written and verified a full archive — see
  [Removing DELTA](#removing-delta).
- **There is no way to uninstall without a backup.** No switch, no flag, no
  prompt. If the database dump or the archive verification fails, the uninstall
  stops with the installation untouched.
- **The uninstaller does not remove Docker Desktop, WSL or any prerequisite.**
  Those are shared with everything else on the machine. Removing them is your
  decision, made in Windows, not a side effect of removing DELTA.
- **It does not manage anything it did not create.** Other Docker projects,
  other containers, IIS or whatever else holds a port are identified and
  reported, never stopped or reconfigured.
- **It does not renew certificates.** There is no ACME/Let's Encrypt client and
  no scheduled renewal — replacing a certificate is an operator action
  (menu option 7).
- **Domain Management does not manage certificates.** Adding a domain reports
  whether the active certificate covers it and stops there: no certificate is
  issued, replaced or deleted because a hostname was added or removed. Enabling
  HTTPS is [Certificate Management](#https-and-certificates), menu option 7.
- **Certificate Management does not manage domains.** It reads the configured
  domain set to decide coverage and never changes it.
- **It does not configure DNS.** A hostname does not have to resolve to be
  configured, and nothing here creates, checks or updates a DNS record —
  reaching DELTA by a name from another machine additionally depends on DNS and
  the firewall.
- **It does not send test email.** Configuring SMTP checks that the server
  resolves and accepts a connection; it does not verify credentials or delivery.
- **It does not roll back an update.** DELTA's schema migrations are
  forward-only, so recovery from a bad migration is a restore from the backup
  the update took first — which is why that backup cannot be skipped.
- **It does not install or manage a Linux distribution.** No Ubuntu, no
  general-purpose distribution, nothing for you to log into or patch. The
  Docker-managed WSL2 environment behind the engine is Docker's; the installer
  only talks to `docker`, `docker compose` and `docker desktop`.

---

## Cutting a release

For maintainers of this repository, not for installing DELTA.

Releases are automated. There are two steps:

1. **Write the release notes and commit them.** The installer's own version
   lives in `lib\Delta.Version.ps1`; release notes live in `CHANGELOG.md`. Add
   the `## [X.Y.Z]` section for the version you are about to cut, along with
   whatever development changes belong in it, and commit — `release.ps1`
   refuses to release a version that has no notes.
2. **Run the one release command.**

```powershell
.\release.ps1                  # bump the patch version (1.0.0 -> 1.0.1)
.\release.ps1 -Version 1.1.0   # release exactly 1.1.0 (intentional minor/major)
.\release.ps1 -DryRun          # show what would happen, change nothing
```

That is the whole release. Everything after the tag push is automatic — you do
not build the ZIP, generate the checksum, create the GitHub Release, copy the
release notes, or upload assets by hand.

### What each half does

`release.ps1` bumps `lib\Delta.Version.ps1`, commits it as
`build: bump installer version to X.Y.Z`, pushes, then creates and pushes an
annotated `vX.Y.Z` tag. It checks everything before it changes anything: you
must be in a Git repository, on `main`, with a clean working tree, a version
file that parses as `X.Y.Z`, a `vX.Y.Z` tag that does not already exist, and a
non-empty `## [X.Y.Z]` section in `CHANGELOG.md`. Any failure stops with the
version file and Git state untouched.

Pushing that tag triggers `.github\workflows\release.yml`, which runs on
`windows-latest` and:

1. re-checks the tag against `lib\Delta.Version.ps1` and fails on any
   disagreement;
2. extracts the tag's `## [X.Y.Z]` section from `CHANGELOG.md` as the release
   body — never commit messages, never GitHub's auto-generated notes;
3. runs `tools\build-release.ps1 -Version X.Y.Z`;
4. verifies both expected artifacts exist;
5. publishes the GitHub Release for the tag with both attached:

```
DELTA-windows-docker-installer-X.Y.Z.zip
DELTA-windows-docker-installer-X.Y.Z.zip.sha256
```

Every one of those steps fails the run rather than publishing something
incomplete. Because `release.ps1` enforces the same tag, version and
`CHANGELOG.md` contracts locally before pushing, a tag it created should never
fail these checks — they catch tags pushed by hand, outside `release.ps1`.

`-DryRun` runs every local check, prints the current and next version, the Git
commands it would run, and what the workflow would then do — and writes
nothing: no file change, no commit, no tag, no push.

### First release from an unreleased version

When the requested version is the one `lib\Delta.Version.ps1` already declares —
the bootstrap case, where the file was authored at `1.0.0` before `release.ps1`
ever ran — there is no bump to make. `release.ps1` skips the version-file
rewrite and the bump commit entirely and tags the current `HEAD` instead, rather
than manufacturing an empty commit. The tag is published exactly as any other:

```powershell
.\release.ps1 -Version 1.0.0
```

This relaxes nothing. An existing `v1.0.0` tag still refuses the release.

### Building the package by hand (development only)

Not part of the release procedure above — the workflow runs this for you. It is
useful for inspecting what a release package would contain:

```powershell
.\tools\build-release.ps1 -Version 1.0.0
```

It copies an explicit whitelist of production files into
`release\DELTA-windows-docker-installer-<Version>\`, zips it, and writes a
matching `.sha256`. `release\` is deleted and recreated on every run, so a
rebuild never mixes in leftovers. It downloads nothing and publishes nothing —
Docker Desktop and the container images are still obtained at install time.
It is the single source of truth for package contents: the workflow calls it
rather than restating the file list in YAML.

### Release infrastructure tests

`tools\Test-Release.ps1` exercises `release.ps1` against disposable Git
repositories under `%TEMP%`, each with its own local bare `origin`, so nothing
it does can reach this repository or GitHub:

```powershell
.\tools\Test-Release.ps1
```

`tools\Test-ReleaseWorkflow.ps1` covers `.github\workflows\release.yml` itself.
Each step's `run:` block is extracted from the workflow file, its `${{ ... }}`
expressions are substituted the way GitHub Actions would, and the result runs
against disposable fixtures — so a test fails when the workflow's real text
breaks, not when a copy of it does. Nothing is tagged, pushed or published:

```powershell
.\tools\Test-ReleaseWorkflow.ps1
```

`tools\Test-VirtualizationPrerequisite.ps1` covers the hardware-virtualization
prerequisite: physical hosts, guest VMs on five hypervisors, locally fixable
feature gaps, and the case that motivated it — a Hyper-V guest reporting
`HypervisorPresent = True` with no nested virtualization exposed. Every probe
is injected, so all of it runs offline on any machine and changes nothing on
the host:

```powershell
.\tools\Test-VirtualizationPrerequisite.ps1
```

`tools\Test-DockerInstallerAcquisition.ps1` covers how the installer obtains
`Docker Desktop Installer.exe` — the `-DockerInstallerPath` → `installers\` →
automatic-download order, and the verification that stands between a
downloaded binary and running it. `Invoke-WebRequest` and
`Get-AuthenticodeSignature` are replaced with scripted stand-ins, so it runs
offline on a machine that already has Docker and never executes an installer:

```powershell
.\tools\Test-DockerInstallerAcquisition.ps1
```

`tools\Test-RuntimeSequencing.ps1` covers the order the runtime stage does
things in, and the Docker detection that order depends on: a prerequisite that
needs a restart must stop the run before any Docker prompt or download, the
licensing disclosure must appear exactly once and only when an installation is
about to be attempted in that same run, and Docker Desktop installed / CLI
visible / engine ready must stay three separate facts. Every host probe is a
scripted stand-in, so all six scenarios — clean machine, resume after restart,
Docker already installed, stale PATH, engine still starting, and a plain rerun —
run offline and change nothing:

```powershell
.\tools\Test-RuntimeSequencing.ps1
```

`tools\Test-ActivityIndicator.ps1` covers the generic terminal activity
indicator — the animated line a long-running operation shows while it is in
progress. What it proves is the contract every caller depends on rather than
any particular operation: the wrapped operation runs exactly once, its result
comes back unchanged for every shape a PowerShell operation can return, an
exception propagates untouched, and the animation is gone on the success path,
the throwing path and the early-return path with no leftover dots and no stray
newline. It also asserts what makes the line continuous rather than
intermittent — a polling operation still animating after each of its sleeps, an
intermediate status line suspending the animation and never ending it, a nested
inner operation taking the line over and handing it straight back, and an
operation marked as part of a larger one drawing nothing of its own — and the
two properties that keep a captured run readable: a redirected or
non-interactive run emits one static line per announced operation and not a
single control character, and the transcript records the operation once and
never a frame. At the instant any shared prompt is displayed it asserts both
halves of the prompt rule: nothing is animating, and the operation that asked
the question is still in progress, so it resumes once the answer is in. The
animation never touches the real console: it is written to a `StringWriter` and
the emitted characters are read back and checked. No test asserts an exact frame
count, so it does not become flaky on a loaded machine:

```powershell
.\tools\Test-ActivityIndicator.ps1
```

`tools\Test-InstallRootSelection.ps1` covers the installation-directory question:
that Enter and `Y` accept `C:\DELTA`, that declining opens the folder dialog and
installs into what it returns, that cancelling the dialog returns to the question
rather than cancelling the install or silently falling through to the default,
that `-InstallRoot` asks nothing, that `-NonInteractive` never opens a window,
and that the chosen root survives the prerequisite restart:

```powershell
.\tools\Test-InstallRootSelection.ps1
```

`tools\Test-RebootContinuation.ps1` covers the resume after the prerequisite
restart. It reads the real `Register-DeltaLogonContinuation` out of `setup.ps1`
with the PowerShell parser, decodes the script that function registers, and then
actually runs it with every host call replaced by a recorder — so the assertions
are about behaviour, not about the shape of the source. It asserts that the
entry is a self-deleting `RunOnce` value under `HKCU`, that both the launcher
and the relaunched `setup.ps1` get `-NoProfile -ExecutionPolicy Bypass`, that
neither `setup.ps1` nor the generated script ever writes a `LocalMachine`,
`CurrentUser`, `MachinePolicy` or `UserPolicy` execution policy, that an
unelevated logon gets exactly one `-Verb RunAs` and an already-elevated one gets
none, that the script waits for the desktop shell instead of sleeping a fixed
interval, that a cancelled UAC prompt is offered again only when the operator
asks and never on its own, and that the fallback text it prints is a runnable
three-line sequence carrying the real installer folder and the real
`-InstallRoot`. Installer paths and installation roots containing spaces — and
an apostrophe — are exercised throughout, and the generated script is required
to parse. Nothing is written to the real `RunOnce` key and no process is
started:

```powershell
.\tools\Test-RebootContinuation.ps1
```

> This suite cannot show a UAC prompt and cannot restart Windows. A green run
> says the continuation is built correctly; it does not say the resume works on
> your machine. See
> [Validating the restart by hand](#validating-the-restart-by-hand).

`tools\Test-UnattendedStartup.ps1` covers automatic startup after a Windows
restart and the `Restart` status row. It asserts that a mechanism which cannot
start the engine — `com.docker.service` — never satisfies the measurement and
never suppresses DELTA's own task, that the registered task carries both its
triggers and runs the startup script non-interactively as the installing
account, that a task which has gone or would fail is never reported as
`Configured` however confidently the installation record claims otherwise, and
that `Verified` requires a real unattended recovery. Task Scheduler is replaced
by an in-memory stand-in, so nothing is registered, replaced or removed on the
host, and the NGINX rotation task is pinned as untouched:

```powershell
.\tools\Test-UnattendedStartup.ps1
```

`tools\Test-AdministratorPasswordChoice.ps1` covers the question a new
installation asks about the DELTA administrator credential. It asserts that the
choice is displayed in full with option 2 as the default, that Enter selects
generation and nothing else does so implicitly, and that an answer which is
neither 1 nor 2 is refused and asked again — including a password typed at the
menu by mistake, which must never be accepted as the credential. For option 1 it
asserts the two masked entries, the match requirement, the retry after a
mismatch, and that a mismatch never continues with either value or with a
generated one; for option 2, that the installer's own CSPRNG generator is called
at the length this credential has always used. It also proves that neither a
typed nor a generated password reaches the terminal or the transcript, that an
installation whose administrator is already secured is not asked at all, and
that nothing animates while any of the three questions is on screen. Read-Host
is replaced per case with a stand-in replaying scripted answers, so nothing is
typed and nothing on this host changes:

```powershell
.\tools\Test-AdministratorPasswordChoice.ps1
```

### Validating the restart by hand

No test in this repository restarts Windows, signs a user in, or shows a UAC
prompt, and none can. The resume after the prerequisite restart is therefore
**not** verified by a green test run — it is verified by doing it, on a machine
that has not had Docker Desktop or the WSL2 platform installed yet. Windows 11
is the case worth doing, because that is where the auto-cancelled elevation was
first seen.

**The happy path**

1. On a clean Windows 11 machine, extract the installer to a folder — include a
   space in the path (`C:\Program Files\DELTA Installer`) if you want to check
   the quoting at the same time.
2. Open Windows PowerShell as Administrator, `cd` to it, run
   `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`, then
   `.\setup.ps1`.
3. Let it reach the prerequisite restart and answer **Y** to
   `Restart Windows now?`.
4. Before it goes down, confirm the entry was written:

   ```powershell
   Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name DELTASetupContinue
   ```

5. Let Windows restart and sign in as the **same account**.
6. **Expected:** a console window titled *DELTA setup - continuing after
   restart* appears and says it is continuing. It then pauses — this is the
   wait for the desktop shell, and it is allowed to take up to about 90 seconds.
7. **Expected:** a **DELTA Setup - Continue Installation** dialog, on top of
   whatever else is on screen, offering **OK** and **Cancel**. Click **OK**.
8. **Expected:** exactly **one** UAC prompt, for `Windows PowerShell`. Approve
   it.
9. **Expected:** an elevated window opens, `Checking privileges` reports
   `Running elevated.`, and the installer continues without re-asking the
   installation questions or the Docker licence. If you used a custom
   installation folder, confirm the banner names that folder and not `C:\DELTA`.
10. Confirm the entry removed itself:

   ```powershell
   Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name DELTASetupContinue -ErrorAction SilentlyContinue
   ```

   This should return nothing.

**The cancel path**

Do this on a second run, or re-arm it by answering **Y** to a restart again.

1. At step 8 above, click **No** on the UAC prompt.
2. **Expected:** the console reports
   `This command cannot be run due to the error: The operation was canceled by the user.`,
   and a dialog explains that Windows cancels its own prompt sometimes and asks
   **Ask Windows for administrator permission again?**
3. Click **Yes**. **Expected:** the UAC prompt returns. Approve it this time
   and the installation continues as above.
4. Repeat, and this time click **No**. **Expected:** the console window prints
   the three-line manual sequence with your real installer folder in the `cd`
   line, the `Set-ExecutionPolicy -Scope Process` line, and `.\setup.ps1` (with
   `-InstallRoot` if your folder is not `C:\DELTA`) — then waits on
   *Press Enter to close this window.*
5. Copy those three lines into an elevated Windows PowerShell and confirm they
   work as printed.

**The Cancel path**

Re-arm the continuation, and at step 7 click **Cancel** instead of OK.

1. **Expected:** no UAC prompt at all, and a second dialog saying
   *DELTA installation is still incomplete.*
2. **Expected:** the console window behind it prints the same three-line manual
   sequence, and the RunOnce entry is gone (step 10's check returns nothing).
3. **Expected:** nothing on the machine changed — no container started, no
   restart, and the partial installation untouched.
4. Run the three printed lines and confirm the installation resumes normally.

**What must not happen, on either path**

- More than one UAC prompt for a single approval.
- A prompt that returns on its own after being declined.
- The continuation firing again at a later logon.
- `Get-ExecutionPolicy -List` differing before the install and after it. Record
  it first and compare — `CurrentUser` and `LocalMachine` must be unchanged.
