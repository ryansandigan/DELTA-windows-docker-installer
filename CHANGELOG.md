# Changelog

All notable changes to the DELTA Windows Docker Installer will be documented in this file.

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
