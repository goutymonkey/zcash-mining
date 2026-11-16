# Security reporting

Please use GitHub's private vulnerability reporting for this repository
(`github.com/goutymonkey/zcash-mining`). Do not put credentials, wallet
keys or exploitable details in a public issue.

Include the affected commit, a minimal reproducer, expected and observed
behavior, and the likely impact. Use synthetic credentials and workloads.
No response-time commitment or bug bounty is currently offered.

Security fixes are developed on `main`; older development tags do not have
a separate maintenance guarantee. Releases are experimental. The repository
does not store wallet funds, and using the miner does not require wallet
spending keys or seed phrases.

Pool communication currently uses plain TCP. Do not reuse sensitive passwords
as pool credentials. Restrict testing to systems you control or have
permission to test. Hardware simulation and formal checks do not establish
electrical, thermal or manufacturing safety; see [the status](docs/STATUS.md).
