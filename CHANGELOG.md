# Changelog

## Unreleased

- `alphapool-node upgrade check` says whether a newer installer is published (it downloads it and runs nothing);
  `alphapool-node upgrade <sha256>` downloads it, refuses it unless the sha256 is the one you give, then runs its
  upgrade. Nothing updates by itself and AlphaPool cannot push one (README "Updates").
- A release that every node must run from a given block (a soft fork) can pin `KNOTS_REQUIRED_VER` /
  `KNOTS_REQUIRED_BY_HEIGHT`: `alphapool-node status` then shows an UPDATE line until the node runs it, the installer
  and the upgrade warn, and the heartbeat (agent v6) reports the installed bitcoind and installer versions.
- MIT license.
- The UTXO snapshot comes over BitTorrent first when the installer pins its info hash (two optional columns in the
  snapshot table; `tools/make-torrent.py` prints them): other installing nodes and the seeders share the load, the
  https download is the fallback (`--no-torrent`: https only). After the download the node seeds the file to other
  installing nodes for up to 2 hours (`--no-seed`). No info hash is pinned for the 910,000 file yet: until then
  nothing changes for a default install.
- The fast start's Bitcoin Knots build (29.4.2 + PR #444, snapshot 976000) is now verified like the official release:
  `SHA256SUMS` and `SHA256SUMS.asc` are published next to its archive and must carry a valid signature from a pinned
  release builder key (chrisguida's, one of the seven 29.4.2 builders, so far; the attestations live on
  https://github.com/chrisguida/guix.sigs/tree/assumeutxo976000 and more are being solicited). The sha256 pin stays as
  the second check. The mode's label and trust notice say so; nothing else changes.

## 2026-10-09.1

- Flush the complete plan before asking for confirmation; print each console step once without redrawing the login prompt. Linux console output is English only; SSH retains Chinese.
- Add `alphapool-node status --watch`: one progress line per minute, measured time left, explicit stalled progress, and the rig address at READY. Ctrl-C stops the watch only. The final handover lines explain how to keep watching or log out.
- Use the same one-to-two-day estimate for the signed 910000 option in the installer and page.

- Make the sha256-pinned Knots 29.4.2 + PR444 build and snapshot 976000 the default fast start; keep the signed 910000 route with `--start official`.
- Show the developer-build notice and later signed-release upgrade path in English and Chinese; keep measured progress in status.
- No torrent; downloads retain their exact SHA256 checks. Existing nodes keep their start mode and chain state on upgrade.

## 2026-10-08.6

- An installer retry checks for an existing snapshot import before networking recovery, startup planning and
  snapshot-file handling. A running import, including a newly started one, or an unknown live-node state produces
  AP-416 and leaves the node and pending recovery files in place. Run the same command again after the import
  finishes or the inspection problem is resolved. A confirmed stopped node can still recover after reboot.
- AP-416 does not run failure cleanup or upgrade rollback. The existing networking recovery checks and all
  Knots, gateway and snapshot pins remain unchanged.

## 2026-10-08.5

- A validated start records a root-owned recovery marker before pausing Bitcoin Knots networking. If the installer
  worker is killed during the load, the same command or the resume unit restores networking before completing the
  install, including when Knots already has the snapshot. Restoration must succeed and Knots must confirm that
  networking is enabled before the marker or validated-start journal is removed.
- Failed recovery keeps the marker and journal and reports AP-415 with `sudo alphapool-node repair`. A node that was
  deliberately offline without an installer recovery marker stays offline. This revision changes the installer;
  its pinned Knots, gateway and snapshot are unchanged.
- The My node guide retains the reviewed one-to-two-day catch-up estimate. The installer's `--pins start_about`
  wording remains about half a day; the page uses the guide's estimate.

## 2026-10-08.4

- **AlphaPool's gateway build now has public source.** The installer pins the Ubuntu 24.04 and 22.04 archives
  built from `90f01b76625f5936febdc2389759c462467a750a` of
  [alphaminetech/datum_gateway](https://github.com/alphaminetech/datum_gateway), branch `alphapool`. Each archive
  and its gateway binary is checked against its pinned sha256. The help, status and upgrade plan name the source.
- An upgrade moves an earlier AlphaPool gateway build to this one, with one gateway restart. Bitcoin Knots is
  not stopped; the chain data, gateway settings and identity key are kept. The official Bitcoin Knots 29.4.2
  release and validated start from block 910,000 are the same.

## 2026-10-08.2

- **The time left is no longer wrong right after the snapshot is loaded.** In the first quarter of an hour after the
  load, `alphapool-node status`, the login screen and the installer said "under 5 min at the current speed" for a
  catch-up of half a day, and the installer kept watching for that long before it handed over. The node's speed had
  been measured across the load of the snapshot. Now nothing is measured until the load is done: at first the blocks
  left are shown without a time, and the time appears once it has really been measured.

## 2026-10-08.1

**Your node now validates its chain itself.**

- **The validated start is the default, and AlphaPool's pre-synced chain copy is gone.** A new node loads the UTXO
  snapshot of block 910,000 (9.6 GB), whose block and content hash are compiled into Bitcoin Knots 29.4.2, and then
  validates every block since then by itself: about half a day on a small server. The history before the snapshot
  is checked in the background. `--sync snapshot` and `--snapshot-url` are no longer offered (AP-105). A node that
  is installed already keeps its chain data: nothing is replaced.
- **Keep mining where you are until READY.** The installer says so before it starts, shows the blocks left and the
  time left, and returns when the node has loaded the snapshot. `alphapool-node status` and the login screen of the
  web console then show `NOT READY yet` with the blocks left and the time left, and `READY` when the gateway has
  AlphaPool's job. The gateway starts by itself at the chain tip.
- **A start that fails never becomes a silent sync of the whole chain.** The installed Bitcoin Knots is asked
  whether it knows the snapshot before anything is downloaded; the file's sha256 and header are checked; and if the
  node does not take the snapshot, the node is stopped and the error says what to do (new codes AP-122, AP-309,
  AP-411, AP-412, AP-413). The same command goes on where it stopped, also after a reboot.
- **Start modes.** A Bitcoin Knots build and the snapshot it starts from are one piece of data in the installer, a
  start mode, with a label and one sentence that says what you trust. This version has one mode, `official` (the
  release signed by the Bitcoin Knots builders); `--start NAME` chooses a mode, `--help` lists them. A release with
  a newer block is a change of that data; nodes that are installed keep their mode and need nothing.
- **An upgrade never leaves a node on a Bitcoin Knots that cannot run its chain.** A node that started from a
  snapshot needs a build that knows the snapshot's block until its history check is done. An upgrade or switch to a
  build that does not is refused before anything is stopped (AP-414); if it could not be told beforehand, the
  previous programs are put back and the message says why.
- **`alphapool-node status` never hangs on a busy node:** every question to the node is given 4 seconds.
- **One command for everything that comes later.** The upgrade command now also renews the `alphapool-node`
  command, the gateway starter and the service units to the new installer's version, with no new sync and no
  restart of the node. A gateway pin moves together with Bitcoin Knots in one step with a way back; the gateway's
  settings and identity key are not touched. A node never has to be installed again.
- **cloud-init user data passes every option on** (`--sync`, `--utxo-*`, `--knots-*`, `--gateway-*`, ports,
  firewall); `--knots-dir` and `--gateway-file`, which name local files, are refused there (AP-131).

Fixes from a second independent review of 2026-10-07.2:

- **Root never works through the node user's folders or through `/var/log`.** Whatever is in
  `/home/alphapool` is read, written and removed by a process of the `alphapool` user; whatever root owns lives in
  directories of root's. In detail:
  - the gateway program installed there is copied by that user's process when the installed programs are saved as
    the way back, and `bitcoin.conf` is read by it, so a link planted there can no longer make root copy a file
    that only root may read;
  - leftovers of an earlier unpack, a gateway source folder and, at uninstall, the home itself are cleaned by that
    user's process;
  - the snapshot file is handed to the node in `/var/lib/alphapool-handover` (root's; the node user may only read
    it), never through the node's own folder;
  - every log (install, upgrade, package installs, uninstall, first boot) is in `/var/lib/alphapool/log`, which only
    root can enter. The old `/var/log/alphapool-node.log` is no longer written; remove it if you like.
- **An upgrade that was cut short and finished later reports the same as one that ran through:** if the gateway ran
  before and is not back, the command ends with exit code 3 (AP-513) and says that your rigs have no work until it
  is back. A re-run of the installer no longer goes on over an upgrade that could not be settled (AP-517).
- An upgrade cut off by a signal is put back and recorded (AP-516).
- A `bitcoin.conf` that the node user cannot read (for example after it was replaced as root) is said plainly, and
  the gateway keeps its RPC login.

## 2026-10-07.2

Fixes from an independent review of 2026-10-07.1.

- **Downloads and staging only where root alone can write.** Everything the installer downloads or unpacks is kept
  in `/var/lib/alphapool` (0700, root). An existing path is used only if it is a real directory that belongs to
  root and that nobody else can write to; otherwise the installer stops (AP-211). `/var/tmp/alphapool` is no longer
  used, and no download and no log is written through a link. A partial snapshot download of an earlier version is not continued.
- **Root no longer writes inside the `alphapool` user's home.** Files there (`bitcoin.conf`, the gateway config,
  the link to the gateway program) are written by that user's own process.
- **The upgrade is a transaction.** The new programs are a complete, verified set in a directory of their own;
  one rename makes the set active; a journal records the step. If anything fails, the previous set is made active
  again and started. An upgrade that is killed, or cut off by a power cut or a reboot, is finished or undone at the
  next start of the server or the next run of the command. The command reports success only when the node and the
  gateway run the new programs. New codes: AP-513 (exit code 3: done, the gateway is not back yet), AP-515, AP-517.
- **Where the programs are:** `/usr/local/bin/bitcoind`, `/usr/local/bin/bitcoin-cli` and
  `/home/alphapool/datum_gateway/datum_gateway` are now links into the active software set under
  `/usr/local/lib/alphapool/sets/`. A node installed by an earlier version is taken over at its next upgrade, without
  changing what runs.
- **A `bitcoin-cli` you replaced is yours.** `bitcoind` and `bitcoin-cli` count as a pair: if either is not the one
  the installer put there, an upgrade leaves both alone unless you add `--knots alphapool`.
- **One at a time.** One lock covers every mode, from before the first change. A second install, upgrade or
  uninstall started meanwhile changes nothing.
- **The signed SHA256SUMS must name the archive exactly once.** A list that names it twice is refused (AP-407).
- **Documentation:** with `--knots-sha256` your own sha256 decides, and missing or invalid builder signatures are
  then only a warning. The README and `--help` now say this in so many words; the behaviour did not change.

## 2026-10-07.1

- **Bitcoin Knots is verified against its release builders' signatures**, at install and at upgrade: the release's
  `SHA256SUMS.asc` must carry a valid signature from one of 7 builder keys pinned in the installer, the signed
  `SHA256SUMS` must list the archive, and the archive must still match the pinned sha256. The installer prints which
  keys signed. New errors: AP-406, AP-407, AP-308.
- **One-command upgrade, in place:** `sudo bash ap-node.sh --upgrade` (and `alphapool-node upgrade`). Chain data,
  settings, firewall and your edits are not touched; no new sync. If the new node does not start, the previous one is
  put back automatically (AP-511; gateway: AP-512). Your own Knots or gateway build is left alone unless you add
  `--knots alphapool` / `--gateway alphapool`.
- `alphapool-node status` shows "newer pinned version available" when the installer on the server pins a newer
  version than the one running.
- Re-running a newer installer in the normal way now upgrades through the same protected path.
- `--knots-url` / `alphapool-node switch knots url`: the sha256 is optional when `SHA256SUMS.asc` is next to the
  archive (the builder signatures are checked); without it the sha256 is required and a warning is printed.
- An installer older than the one a node's software came from never downgrades it.

## 2026-10-05.2

- Ubuntu 22.04 LTS is supported next to 24.04 LTS (its own gateway build); any other system stops with AP-202.
- When the snapshot server has no free download slot, the installer waits ("waiting for a download slot (N min)")
  instead of failing.
- READY, `alphapool-node status` and the optional heartbeat count only payouts to addresses other than your own.

## 2026-10-05.1

- First version: Bitcoin Knots + DATUM gateway on your own server, one paste or cloud-init, pinned downloads,
  no AlphaPool access, optional heartbeat, your own software if you want it.
