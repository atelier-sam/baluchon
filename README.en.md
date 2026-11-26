# Baluchon

*A portable launcher for Claude Code.* [Version française](./README.md)

Baluchon puts the official Claude Code (Anthropic's native binary) inside a **terminal
wizard**: several accounts, the **real status, plan and 5 h / 7 d quota of every account on
the home screen**, one-key launch of the account with the most headroom, and
`bypass permissions` mode. On Windows it adds tick-box software installation (Office by
edition, LibreOffice, Chrome, Firefox, WinRAR…) and access, from another PC, to the tmux
sessions of a Mac you have set up. Windows · macOS · Linux.

Baluchon is not an Anthropic product and is not affiliated with Anthropic. "Claude" and
"Claude Code" are trademarks of Anthropic; they are used here only to say what the launcher
launches.

## Install

**macOS / Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.sh | bash
```

**Windows** (PowerShell)
```powershell
irm https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.ps1 | iex
```

Then: `baluchon` (wizard) — `baluchon1` (second account). `ccp` and `ccp1` remain as aliases.

The same link does everything. Replayed on an installation that is already up to date (same
signed release, every file intact), the installer downloads nothing: it says so, puts the
commands back if they are missing, and stops. With `BALUCHON_OUVRIR_MENU=1` it then opens
the menu (on the terminal, never on its own stream):

```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.sh | BALUCHON_OUVRIR_MENU=1 bash
```

With no terminal it does not fail: it prints the command to type.

Everything comes from the repository's **latest signed release**: `SHA256SUMS` is signed
(`ssh-keygen -Y`, key `baluchon-release`), every file is verified before it is put in place,
the Claude binary is checked against Anthropic's official manifest, and `gum`, portable
Git and `cloudflared` against pinned digests. A single failed check **stops** the
installation.

Everything is installed under `~/.baluchon` (sessions included).

## Uninstall

From the menu (macOS, Linux, Windows): **"🚪 Partir : tout effacer et désinstaller"** (leave:
erase everything and uninstall), with a confirmation ("Non, annuler" is the default). The
menu erases the sessions, runs the verified uninstaller, then **re-reads the disk**: it
says "Rien ne reste sur cet ordinateur" (nothing is left on this computer) only if the
folder, the commands, the Keychain items and the Access tokens are really gone; otherwise
it lists what remains. On a guest computer, "Partir" is at the top of the menu. On Windows,
Baluchon's Git tools (which run the menu) leave when the menu closes, and that is when
"Rien ne reste" is shown.

Or without the menu:

```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash
```

Removes the folder, the `baluchon`, `baluchon1`, `ccp` and `ccp1` commands (only if they
launch this folder), the macOS Keychain item of each of the portable's profiles, and the
Cloudflare Access tokens left by the link to a Mac. The unsuffixed "Claude Code-credentials"
item, the one your regular Claude Code uses, is never touched. To erase only your accounts:
in the wizard, "Tout déconnecter" (disconnect everything).

## What the wizard does

- **Home**: one table per account — email, plan (Max x20 / x5 / Pro), 5 h and 7 d quota,
  resume time, state (`valide`, `En veille`, `à reconnecter`, `limité`…).
- **Add an account**: one browser sign-in, done by `claude` itself. Baluchon never asks you
  for a token, never receives one and never stores one.
- **Re-index my accounts**: finds the Claude logins already on the computer and reconnects
  them cleanly inside the portable (one browser sign-in per account; credentials are never
  copied, a copy gets revoked). The signed-in email is checked.
- **Launch the recommended account** (remaining headroom × plan) or another one; an
  account already open elsewhere is not launched again.
- **Tools** — Windows: tick-box software (winget, silent) with starter packs ("Essentiels d'un PC
  neuf", the ArtCraft suite…) that pre-tick the list, Microsoft Office of your choice
  (365, LTSC 2024/2021, Home…) in French, without a key ("not activated"); share this PC
  with your Mac's sessions (temporary). Everywhere: connect to the tmux sessions of a Mac
  you have configured (Cloudflare tunnel + e-mail code, then the Mac's password — nothing
  installed on the PC). macOS: set this Mac up as a remote machine.
- **Updates** of Claude (stable / latest) with rollback, and of the portable itself.
- **Guest computer**: on first launch, "is this computer yours?"; if not, every sign-in is
  erased on exit.

## Why an account shows "En veille" (asleep)

Baluchon shows an account's quota by **reading** the token that `claude` stored for that
account, read-only, and sending it only to Anthropic's official endpoints. It never renews
that token, never copies it and never stores it anywhere else: renewing it is `claude`'s
job.

An access token lives about 8 hours. If you have not launched an account for longer than
that, its token has expired; Baluchon shows it as **"En veille"** (the account is not
broken) and cannot read its quota. As soon as you launch that account, Claude renews its
own session, and the quota shows again on the next home screen.

## Security

No secret in this repository or in the releases. Sessions stay on the machine: macOS
Keychain (one item per profile, never your regular Claude Code's) or
`~/.baluchon/config/<account>/` elsewhere. Quota and plan are read through the official
OAuth endpoints with the account's token, read-only. A release gate
(`scripts/garde-lecture-seule.sh`) refuses to ship a binary that could write or renew a
credential.

## Technical details

See [`TECHNICAL.md`](./TECHNICAL.md) (in French): architecture, accounts and Keychain,
optional layers, versioning, releases.

## Licence

[MIT](./LICENSE).
