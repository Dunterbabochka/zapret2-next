# Security Policy

## Supported versions

Security fixes are provided for the latest published release of Zapret 2 NEXT.

| Version | Security support |
|---|---|
| Latest release | ✅ Supported |
| Older releases | ❌ Update before reporting or testing |

The bundled upstream engine version is recorded in [`ENGINE_VERSION`](ENGINE_VERSION).

## Reporting a vulnerability

Please **do not disclose a suspected vulnerability in a public Issue, Discussion, pull request, log paste or social-media post**.

Preferred reporting method:

1. Open the repository’s **Security and quality** tab.
2. Select **Report a vulnerability**.
3. Submit the report through GitHub Private Vulnerability Reporting.

Repository maintainers should enable Private Vulnerability Reporting in:

```text
Repository Settings → Advanced Security → Private vulnerability reporting
```

If the private-reporting button is unavailable, create a public Issue titled:

```text
Security contact requested
```

Do not include technical details, exploit steps, logs, IP addresses, secrets or affected file contents in that Issue. Wait for the maintainer to provide a private channel.

## What to include

A useful report should contain:

- affected release or commit;
- affected file and approximate lines;
- vulnerability type;
- realistic impact;
- prerequisites for exploitation;
- minimal reproducible steps;
- proof of concept that does not harm third parties;
- suggested mitigation, when available;
- whether the issue also affects the upstream Zapret 2 or WinDivert project.

Please mask all secrets and personal data.

## Relevant security issues

Examples of in-scope reports:

- command or argument injection;
- arbitrary file write/read or path traversal;
- unsafe privilege escalation involving the Windows service;
- insecure service path or writable privileged binaries/configuration;
- malicious or unverified update behavior;
- release artifact or SHA256 integrity failures;
- unexpected transmission of project data to third parties;
- secret, token or personal-data exposure;
- unsafe handling of diagnostic archives;
- vulnerabilities introduced by project PowerShell, Batch or Lua code;
- CI/CD issues that allow unauthorized release modification.

## Usually out of scope

The following are normally not security vulnerabilities in this repository:

- a strategy not working with a specific provider;
- an ISP changing its filtering behavior;
- expected antivirus detection of WinDivert as RiskTool/HackTool;
- a vulnerability that exists only in an unsupported old release;
- social-engineering reports without a technical flaw;
- denial of service requiring administrator access to the same machine;
- reports consisting only of automated scanner output without validation;
- issues located entirely in upstream Zapret 2, WinDivert or Cygwin code.

Upstream issues should also be reported to the relevant upstream project.

## Diagnostic data

Compatibility Wizard and Discord Voice diagnostics may produce reports containing:

- IP addresses and ports;
- process identifiers;
- timestamps;
- local filesystem paths;
- `winws2` debug logs;
- filtered PktMon metadata;
- provider and region information.

Do not attach unreviewed diagnostic archives to public Issues.

Before sharing:

- remove or mask personal IP/MAC addresses;
- replace local paths with placeholders such as `<ROOT>`;
- remove unrelated SNI/domain history;
- remove account names, tokens, cookies and credentials;
- include only the smallest fragment needed to reproduce the issue.

Do not send raw packet captures unless a private channel has been explicitly agreed upon.

## Disclosure process

The maintainer will make a best-effort attempt to:

1. acknowledge the report;
2. validate impact and affected versions;
3. prepare and test a fix;
4. publish a patched release;
5. disclose the issue through a GitHub Security Advisory when appropriate;
6. credit the reporter unless anonymity is requested.

Please allow reasonable time for investigation and release preparation before public disclosure.

## Security bounty

This project currently has no paid bug-bounty program. Responsible reports are still appreciated and may be credited in release notes or a security advisory.

## Safe testing

Only test on systems, repositories, networks and accounts that you own or are explicitly authorized to test.

Do not:

- access third-party data;
- disrupt other users or networks;
- test leaked credentials;
- upload private diagnostics publicly;
- execute destructive actions;
- attempt persistence outside the project’s documented service behavior.
