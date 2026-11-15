# Baluchon

*Lanceur portable pour Claude Code.* [English version](./README.en.md)

Baluchon met le Claude Code officiel (le binaire natif d'Anthropic) dans un **wizard de
terminal** : plusieurs comptes, **statut réel, forfait et quota 5 h / 7 j de chaque compte
dès l'accueil**, lancement du compte qui a le plus de marge, mode `bypass permissions`.
Pour Windows, il ajoute l'installation de logiciels à cocher (Office par version,
LibreOffice, Chrome, Firefox, WinRAR…) et un accès à tes sessions tmux d'un Mac, depuis un
autre PC. Windows · macOS · Linux.

Baluchon n'est pas un produit d'Anthropic et n'est pas affilié à Anthropic. « Claude » et
« Claude Code » sont des marques d'Anthropic ; ici elles ne servent qu'à dire ce que le
lanceur lance.

## Installer

**macOS / Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.sh | bash
```

**Windows** (PowerShell)
```powershell
irm https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.ps1 | iex
```

Puis : `baluchon` (wizard) — `baluchon1` (2e compte). `ccp` et `ccp1` restent des alias.

Le même lien sert à tout. Rejoué sur une installation déjà à jour (même release signée,
tous les fichiers intacts), l'installeur ne télécharge rien : il le dit, remet les commandes
si elles manquent et s'arrête. Avec `BALUCHON_OUVRIR_MENU=1`, il ouvre ensuite le menu
(sur le terminal, jamais sur son propre flux) :

```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/install.sh | BALUCHON_OUVRIR_MENU=1 bash
```

Sans terminal, il ne fait pas d'erreur : il dit la commande à taper.

Tout vient de la **dernière release signée** du dépôt : `SHA256SUMS` est signé
(`ssh-keygen -Y`, clé `baluchon-release`), chaque fichier est vérifié avant d'être posé,
le binaire Claude est vérifié contre le manifest officiel d'Anthropic, `gum`, Git
portable et `cloudflared` contre des empreintes épinglées. Une seule vérification
ratée **arrête** l'installation.

Tout s'installe dans `~/.baluchon` (sessions comprises).

## Désinstaller

Depuis le menu (macOS / Linux) : **« 🚪 Partir : tout effacer et désinstaller »**, avec une
confirmation (« Non, annuler » par défaut). Le menu efface les sessions, lance le
désinstalleur vérifié, puis **relit le disque** : il n'annonce « Rien ne reste sur cet
ordinateur » que si le dossier, les commandes, les items du Trousseau et les jetons Access
sont vraiment partis ; sinon il liste ce qui reste. Sur un poste invité, « Partir » est en
tête du menu.

Ou sans menu :

```sh
curl -fsSL https://raw.githubusercontent.com/atelier-sam/baluchon/main/uninstall.sh | bash
```

Supprime le dossier, les commandes `baluchon`, `baluchon1`, `ccp` et `ccp1` (seulement si
elles lancent ce dossier), l'item du Trousseau macOS de chaque profil du portable et les
jetons Cloudflare Access laissés par la liaison avec un Mac. L'item « Claude
Code-credentials » sans suffixe, celui de ton Claude Code habituel, n'est jamais touché.
Pour effacer seulement tes comptes : dans le wizard, « Tout déconnecter ».

Garde-fou : la désinstallation n'efface qu'un dossier qui porte le marqueur
`.baluchon-install` (posé par l'installeur) et refuse `/`, ton domicile et tout dossier qui le
contient, après résolution des liens et des `.` / `..`. Une installation d'avant ce marqueur :
réinstalle, ou crée le marqueur toi-même (le message de refus donne la commande).

## Ce que fait le wizard

- **Accueil** : un tableau par compte — email, forfait (Max x20 / x5 / Pro),
  quota 5 h et 7 jours, reprise, état (`valide`, `En veille`, `à reconnecter`,
  `limité`…).
- **Ajouter un compte** : une connexion navigateur, faite par `claude` lui-même. Baluchon ne
  te demande jamais un jeton, n'en reçoit aucun et n'en range aucun.
- **Réindexer mes comptes** : retrouve les logins Claude déjà présents sur l'ordinateur
  et les reconnecte proprement dans le portable (une connexion navigateur par compte ;
  on ne copie jamais d'identifiants, une copie se fait révoquer). L'email connecté est
  vérifié.
- **Lancer le compte recommandé** (marge restante × forfait) ou un autre ; un compte
  déjà ouvert ailleurs n'est pas relancé.
- **Outils** — Windows : logiciels à cocher (winget, silencieux), Microsoft Office au
  choix (365, LTSC 2024/2021, Famille…) en français, sans clé (« non activé ») ; partager
  ce PC avec les sessions de ton Mac (temporaire). Partout : te connecter à tes sessions
  tmux sur un Mac que tu as configuré (tunnel Cloudflare + code e-mail, puis mot de passe du
  Mac — rien d'installé sur le PC). macOS : configurer ce Mac comme poste distant.
- **Mise à jour** de Claude (stable / dernière) avec retour arrière, et du portable.
- **Poste invité** : à la 1re ouverture, « cet ordinateur est-il à toi ? » ; si non,
  toutes les connexions sont effacées en quittant.

## Pourquoi un compte est « En veille »

Baluchon affiche le quota d'un compte en lisant **en lecture seule** le jeton que
`claude` a rangé pour ce compte, et en l'envoyant aux seuls points d'accès officiels
d'Anthropic. Il ne renouvelle jamais ce jeton, ne le copie pas, ne le stocke nulle part
d'autre : le renouveler est le travail de `claude`.

Un jeton d'accès vit environ 8 heures. Si tu n'as pas lancé un compte depuis plus longtemps,
son jeton a expiré ; Baluchon l'affiche **« En veille »** (le compte n'est pas cassé) et
ne peut pas lire son quota. Dès que tu lances ce compte, Claude renouvelle sa session, et le
quota réapparaît à l'accueil suivant.

## Sécurité

Aucun secret dans ce dépôt ni dans les releases. Les sessions vivent sur la machine :
Trousseau macOS (un item par profil, jamais celui de ton Claude Code normal) ou
`~/.baluchon/config/<compte>/` ailleurs. Quota et forfait sont lus via les endpoints OAuth
officiels avec le jeton du compte, en lecture seule. Une garde de release
(`scripts/garde-lecture-seule.sh`) refuse de livrer un binaire qui saurait écrire ou
renouveler un identifiant.

## Détails techniques

Voir [`TECHNICAL.md`](./TECHNICAL.md) : architecture, comptes et Trousseau, couches
optionnelles, versionnage, release.

## Licence

[MIT](./LICENSE).
