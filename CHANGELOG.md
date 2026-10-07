# Changelog

Every release is one file, `install.sh`. Its SHA-256 is listed here and in the command shown on your AlphaPool
dashboard ("My node"); the command checks it before anything runs.

## 2026-10-05.2
`sha256 b59831544f7cfc1cc493335d1a5aff7ec90e7b408d61f51b74149b4951fa738b`
- Ubuntu 22.04 and 24.04 LTS (x64). Any other system is refused before anything is changed.
- If the snapshot server is busy, the install waits for a download slot instead of failing.
- "READY" is only reported once the pool's payout list has arrived.
- Native DATUM gateway build for Ubuntu 22.04.

## 2026-10-05.1
`sha256 93c3b5fc0cb27040b9df451faf8e5fd2a23e3b74a76028014067104577cf6e9e`
- First release: Bitcoin Knots 29.4.2 and a DATUM gateway on a server you own, in one paste.
- Every download is pinned by hash and checked before use. No keys, no remote access and no update channel for AlphaPool.
- Firewall rules are only added; the install survives a lost SSH session and a reboot; `alphapool-node uninstall` removes it.
