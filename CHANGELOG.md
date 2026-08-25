# Changelog

All notable changes to the DELTA Windows Docker Installer will be documented in this file.

## [Unreleased]

Nothing yet.

## [1.0.0]

First release. Everything below describes what the installer does; there is no earlier version for it to have changed from.

### Added

- The Docker-based DELTA installer for Windows. `setup.ps1` is the single operator entry point: it chooses between installation and management from the installation state it detects on disk, rather than from a switch. Interactive and `-NonInteractive` runs are both supported.
- Installation deploys DELTA as three containers — NGINX in front, the DELTA application, and PostgreSQL 17 with PostGIS — from a generated Compose project with pinned image digests.
- Docker Desktop is detected, and installed when absent, after its licensing terms are disclosed and accepted. Windows edition and build, hardware virtualization, disk space and the WSL2 backend are validated before anything on the machine is changed.
- When a prerequisite needs a Windows restart, the installer asks for it in a dialog before the machine goes down and resumes by itself at the next sign-in, with printed instructions that work if the automatic resume cannot run.
- The installation directory is chosen rather than assumed: `C:\DELTA` is offered as the default, declining it opens a folder-selection dialog, and an explicit `-InstallRoot` is used without asking. The chosen root survives a prerequisite restart.
- Configuration is generated rather than hand-written — `.env`, the Compose file and the NGINX site configuration are produced from templates for the ports, hostname and TLS mode of this installation.
- The DELTA administrator and database credentials are each chosen explicitly, either typed or generated as a strong secret. The administrator credential is applied and then verified against the running application, and the default credential published in the DELTA image is confirmed no longer to authenticate.
- HTTP and HTTPS ports are checked for conflicts and resolved with the operator, and Windows Firewall rules are created for the published ports.
- TLS supports three modes: plain HTTP, an operator-supplied certificate and key, or a generated self-signed certificate. A supplied key is proven to match its certificate before it reaches the live configuration.
- Persistent data survives container recreation: the database in a Docker-managed volume, uploads and logs on the Windows filesystem under the installation root. Those directories, and the certificate staging area, are given explicit ACLs restricted to Administrators, SYSTEM and the installing account instead of inheriting whatever the parent carried.
- A management utility covering status, stack lifecycle, logs, database backup, in-place update, SMTP configuration, administrator credential reset, Domain Management and Certificate Management.
- Updates take a verified database backup first, verify the schema migration afterwards, and confirm the site answers over HTTP before reporting success.
- DELTA starts on its own after a Windows restart, through a scheduled task that starts Docker, waits for the engine and brings the stack up. A second scheduled task rotates the NGINX access logs. The management screen re-registers either task if it is found missing, and reports what is actually registered on the host rather than what an earlier run recorded.
- `uninstall.ps1` archives the entire installation root and a fresh, verified database dump to `C:\DELTA-backups\DELTA-<timestamp>.zip`, verifies that archive, and only then removes the containers, the network, the database volume, the scheduled tasks, the firewall rules and the installation directory itself. There is no switch or prompt that removes an installation without a verified backup, an installation that is merely stopped is uninstalled in one invocation, and a run that leaves anything behind reports `PARTIAL` rather than success.
- The uninstall never removes Docker Desktop, WSL, a Windows feature, or any container, volume, network, scheduled task or firewall rule that this installation did not create.
- Long-running operations show an animated activity indicator with an elapsed counter, so a step that takes minutes reads as running rather than as a stopped terminal. Transcripts record one static line per operation instead.
- Releases are published as `DELTA-windows-docker-installer-<version>.zip` with a matching `.zip.sha256`.

### Changed

- Nothing. First release.

### Fixed

- Nothing. First release.
