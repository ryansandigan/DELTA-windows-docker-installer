# Changelog

All notable changes to the DELTA Windows Docker Installer will be documented in this file.

## [Unreleased]

### Fixed

- The Docker Desktop licensing disclosure is no longer shown twice. It used to be presented before the WSL platform was checked, so a host that needed WSL accepted the licence, installed WSL, was told to restart, and was asked to accept the same licence again on the way back. Backend prerequisites are now satisfied first, and the disclosure appears only when an installation is genuinely about to be attempted in that same run.
- Docker Desktop is no longer reported missing because the current PowerShell process cannot see it. "Docker Desktop is installed", "the `docker` command resolves here", "the engine is running" and "the engine is ready for Linux containers" are now measured as four separate facts: installation is read from the Windows registration (per machine *and* per user) and from Docker's own program directories, and the process PATH is repaired from the discovered install location before the CLI is judged absent. A stale PATH, a stopped engine, or an engine that is still starting can no longer trigger a second installation or a second licence prompt.
- An installation whose files are present but whose `docker.exe` cannot be found is now reported, with the three ways to resolve it, instead of being reinstalled over.
- A successful Docker Desktop installation no longer forces a restart unconditionally. The run continues to engine readiness when Docker's own installer did not ask for one, and stops cleanly for a restart when it did.

### Changed

- A new interactive installation now asks where to install rather than assuming `C:\DELTA` silently: `Use C:\DELTA as the installation directory? [Y/n]`. Enter accepts the default; declining opens a Windows folder-selection dialog — the same picker convention the certificate questions use, so no filesystem path is ever typed at a prompt. Cancelling the dialog returns to the question instead of cancelling the installation, and a directory that fails validation is refused with its reason and asked again.
- The chosen root is resolved before the prerequisite-restart continuation is registered, so an installation that restarts Windows part-way through resumes into the directory the operator chose.
- Unchanged in every other case: an explicit `-InstallRoot` is used without asking, `-NonInteractive` never opens a window, an existing installation keeps the root it is installed at, and a host that cannot show a dialog uses the default rather than asking a question it could not accept a second answer to.

## [1.0.0]

### Added

- First release of the Docker-based DELTA installer for Windows. `setup.ps1` is the single operator entry point: it chooses between installation and management from the installation state it detects on disk, rather than from a switch.
- Installation deploys DELTA as three containers — NGINX in front, the DELTA application, and PostgreSQL 17 with PostGIS — from a generated Compose project with pinned image digests.
- Docker Desktop is detected, and installed when absent, after its licensing terms are disclosed and accepted. Windows prerequisites, virtualization and the WSL2 backend are validated before anything is changed on the machine.
- Configuration is generated rather than hand-written: `.env`, the Compose file and the NGINX site configuration are produced from templates, with strong secrets generated for the database and the DELTA administrator account.
- HTTP and HTTPS ports are detected and conflicts resolved with the operator; the Windows firewall rules for the published ports are created.
- TLS supports three modes — plain HTTP, an operator-supplied certificate and key, or a generated self-signed certificate. A supplied key is verified to match its certificate before it reaches the live configuration.
- A management utility covering status, stack lifecycle, logs, database backup, in-place update, SMTP configuration, administrator credential reset, Domain Management and Certificate Management.
- Updates take a database backup first, verify the schema migration afterwards, and confirm the site answers over HTTP before reporting success.
- DELTA starts automatically after a Windows restart through a startup task that brings Docker and then the stack up, and NGINX access logs are rotated on a schedule.
- `uninstall.ps1` archives the database and the installation and verifies that archive before it is able to remove anything; there is no path that removes an installation without one.

### Changed

- Nothing. First release.

### Fixed

- Nothing. First release.
