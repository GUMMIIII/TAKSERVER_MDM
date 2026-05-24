# Security Policy

## Reporting a Vulnerability

If you find a security issue in this project, **please do not open a public GitHub issue**. Instead, report it privately so it can be fixed before details become public.

### Preferred: GitHub Security Advisory

Use the **[private vulnerability reporting form](https://github.com/GUMMIIII/TAKSERVER_MDM/security/advisories/new)** on this repository. This routes directly to the maintainer and lets us track the fix without exposing the issue.

### Alternative

If GitHub advisories are not an option for you, open a regular issue titled `Security: please contact me` (without any technical detail) and I'll reach out so we can move the conversation to a private channel.

## What to include in a report

- Affected component (e.g. `nginx.conf.vps.template`, `add_user.sh`, a specific service)
- Affected version / commit hash
- Steps to reproduce — or a minimal proof-of-concept
- Impact: what an attacker could do with this
- Suggested fix, if you have one

## What to expect

This is a solo-maintained hobby project. I aim to:

- Acknowledge your report within a few days
- Assess and triage within a week
- Ship a fix as soon as I reasonably can — critical issues take priority over feature work

I'll credit you in the changelog and release notes unless you ask me not to. Once the fix is released, the vulnerability details can be made public.

## Scope

This policy covers the code in this repository (installer, configs, scripts). Vulnerabilities in upstream components (Nextcloud, Synapse, TAKServer, Authelia, Collabora, Headwind MDM, etc.) should be reported to those projects directly.

## Out of scope

- Self-inflicted misconfigurations (weak passwords in `.env`, exposed VPN keys, etc.)
- Issues that require an attacker to already have shell or admin access
- Denial-of-service via flooding the public endpoints (this is a single-server hobby setup, not a hardened service)
