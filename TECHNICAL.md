# Baluchon — notes techniques

## Architecture

| Pièce | Rôle |
|---|---|
| `Claude.command` | Interface seule (bash + `gum`). Mac/Linux, et Windows via le bash de Git portable. |
| `lib/common.sh` | Plateforme, téléchargements vérifiés (fail-closed), mises à jour, choix du noyau, purge de repli. « Tout effacer » (`cc_wipe`) rend 0, 2 (session encore ouverte), 10 (jetons Cloudflare Access restés utilisables : `config/remote.conf` est alors gardé pour qu'une nouvelle tentative sache quel hôte oublier) ou 1, avec `CC_WIPE_NOTE` qui nomme ce qui reste ; le menu ne dit « ✓ Effacé » que sur 0. Épreuves : `scripts/effacement.test.sh <dossier-vide-absolu>`. |
| `core/` → `baluchon-core` | Noyau Rust : comptes, statut, forfait, quotas, lancement verrouillé, outils Windows, accès distant. Contrat CLI versionné (`baluchon-core --contract`). |
| `claude.cmd` / `claude-classic.cmd` | Lanceurs Windows (wizard / repli 100 % batch). |
| `install.sh` / `install.ps1` / `uninstall.sh` | Installation depuis la release signée (les deux installeurs sont eux-mêmes des assets signés de la release, et posent le marqueur `.baluchon-install`) ; désinstallation, qui refuse tout dossier sans ce marqueur, `/`, le domicile et ses parents (chemin canonique), et tout dossier dont un ANCÊTRE peut être modifié par un autre utilisateur (écriture de groupe ou du monde sans bit sticky, propriétaire étranger). L'effacement part du dossier PARENT figé (identité périphérique:inode revérifiée, nom relatif) : un maillon échangé contre un lien après le jugement donne un refus. Un ménage incomplet (jetons Access, sessions du Trousseau, dossier non supprimé en entier) sort en code 10, 11 ou 12 avec un bilan qui nomme ce qui reste, jamais « Plus aucune trace ». Épreuves : `scripts/uninstall.test.sh <dossier-vide-absolu>`. |
| `scripts/build-core.sh` | Compile `baluchon-core` pour darwin-arm64/x64, linux-x64/arm64 (musl statique), win32-x64 (zig + cargo-zigbuild). |
| `scripts/release.sh` | Assemble la release à plat, `SHA256SUMS` signé, contre-vérifié avec la clé embarquée. |
| `overlay/` | Optionnel. Une couche posée à côté du portable (voir « Couches »). Le portable n'y écrit jamais. |

Sans `baluchon-core`, le wizard reste utilisable en mode dégradé (liste des comptes,
lancement direct, purge de repli).

Le dossier d'installation par défaut est `~/.baluchon` (variable `BALUCHON_DIR`), les commandes
sont `baluchon` et `baluchon1` (2e compte) ; `ccp` et `ccp1` restent des alias.

## Comptes et identifiants

Chaque compte = un profil `config/<profil>/`, passé à Claude par `CLAUDE_CONFIG_DIR`.

- **macOS** : Claude range la session au Trousseau, service
  `Claude Code-credentials-<8 hex>` où les 8 hex = `sha256(NFC(CLAUDE_CONFIG_DIR))`.
  Un profil = un item. L'item **sans suffixe** est le Claude Code normal de la
  machine : `baluchon-core` ne l'écrit ni ne le supprime jamais (lecture seule pour
  l'inventaire). Le préfixe `Claude Code-credentials` est le nom que `claude` lui-même lit et
  écrit : c'est une chaîne de compatibilité, pas un nom de produit, et un test fige
  `service_name`.
- **Windows / Linux** : `config/<profil>/.credentials.json`.
- **Jeton déposé à la main** : un `config/<profil>/oauth.token` posé par l'utilisateur est lu au
  lancement (quota illisible, forfait déclaré dans `config/<profil>/plan`). Le wizard ne le crée,
  ne le déplace ni ne le sauvegarde jamais : ajouter un compte passe par la connexion navigateur
  de `claude`, qui range sa session lui-même.

**Jamais de copie d'identifiants entre magasins** : le refresh token tourne à chaque
renouvellement, la copie restante se fait révoquer. La réindexation fait donc une
connexion navigateur fraîche par compte (`accounts discover --missing`).

**Le nom du service Trousseau dépend du chemin d'installation.** Son suffixe est calculé
sur `CLAUDE_CONFIG_DIR`, donc sur le dossier d'installation. Déplacer ou réinstaller le
portable sous un autre chemin (par exemple de l'ancien `~/.claude-portable` vers `~/.baluchon`)
change le suffixe de CHAQUE profil : les anciens items restent au Trousseau, plus lus et plus
purgés par le nouveau noyau. Avant de changer de dossier : lancer l'ancien `uninstall.sh` (il
purge les items de l'ancien chemin), vérifier que `config/` est vide, puis seulement installer
au nouvel emplacement.

### Statut, forfait, quota

`GET api.anthropic.com/api/oauth/profile` (forfait = `rate_limit_tier`) et
`/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`), avec le jeton de l'utilisateur, en
lecture seule. Cache par profil (300 s + gigue). Un 429 = `rate_limited` (limite par IP du
point de statut, pas un compte épuisé), dernières valeurs gardées. Recommandation : marge
restante × multiplicateur (x20 = 20, x5 = 5, Pro = 1), seuil 95 %.

**Quota « En veille ».** L'édition publique ne renouvelle jamais un jeton. Un compte dont le
jeton a expiré (il n'a pas été lancé depuis des heures) s'affiche donc « En veille » : la
colonne STATUT plafonne à 26 caractères, et la ligne de détail dessous dit « Claude la
renouvellera au lancement ». Son quota n'est pas lisible tant que `claude` ne s'est pas
relancé sur ce compte ; il l'est dès que le jeton est frais. Un jeton d'accès vit environ
8 heures : au-delà, le compte n'est pas cassé, il dort.

### Lancement

`baluchon-core run <profil> --claude <bin> -- <args>` : verrou OS (`.ccp-session.lock`)
— un compte déjà ouvert renvoie le code 5. C'est `claude` qui renouvelle sa propre session.

## Éditions et couture `Extension`

### Le contrat « lecture seule » (définition exacte)

« Lecture seule » ne veut pas dire « ne supprime jamais rien ». Elle dit précisément ceci. Le
noyau PUBLIC, qui ne porte que l'édition `ReadOnly` :

1. **ne crée aucun identifiant** : il n'écrit ni `.credentials.json` ni `oauth.token`, et il ne
   crée aucun item du Trousseau (`add-generic-password` est interdit, source et binaire) ;
2. **ne renouvelle aucun jeton** : aucune requête qui échange un jeton de renouvellement
   (`grant_type`, `/v1/oauth/token` interdits), aucune requête avec un corps (`http::Method` n'a
   que `Get`) ;
3. **n'envoie aucun identifiant** hors du seul cas de la lecture : le jeton d'accès sert d'en-tête
   `Authorization` d'une requête `GET` vers l'API officielle (`api.anthropic.com`, `env.rs`) pour
   lire le profil et l'usage, jamais sous une autre forme, jamais vers un autre hôte, jamais dans
   un journal ni une sortie ;
4. **n'écrit rien dans le Trousseau ni dans les fichiers d'identifiants, sauf SUPPRIMER** les items
   de CE portable (service suffixé `Claude Code-credentials-<8 hex>`) et les fichiers de ses
   profils (`.credentials.json`, `oauth.token`…), et seulement sur DEMANDE de l'utilisateur : « Tout
   déconnecter » (`accounts purge`), une désinstallation, ou la sortie d'un ordinateur marqué
   « invité ». L'item sans suffixe (le Claude Code normal de la machine) n'est jamais touché.

Pourquoi la suppression n'entre pas dans « écrire » : décision P1 (revue Codex terminale). Effacer
SES PROPRES identifiants, localement, à la demande de leur propriétaire, n'est ni les collecter,
ni les stocker, ni les intermédier au sens des conditions d'Anthropic ; c'est l'inverse, et
c'est le geste qui protège un poste de passage. La garde (`scripts/garde-lecture-seule.sh`)
l'exprime ainsi : `delete-generic-password` n'est permis que dans `fn delete_all`, qui refuse le
service sans suffixe quoi qu'on lui passe. Tout le reste de la liste ci-dessus reste interdit
mécaniquement, y compris dans les binaires livrés.

Le noyau n'écrit aucun identifiant. Tout ce qui pourrait en écrire (renouveler un jeton,
rejouer un journal d'écriture, écrire un magasin) passe par le trait `Extension`
(`core/src/ext.rs`), que l'exécutable choisit au démarrage :
`run_with(Arc::new(ReadOnly), std::env::args_os())` dans `core/src/main.rs`.

L'édition fournie, `ReadOnly` (`about --json` : `"edition":"public"`), respecte le contrat
ci-dessus : ses points d'extension n'ont aucun effet ; le seul effet de bord du noyau est la
suppression, sur demande, de SES PROPRES identifiants.
Une édition étendue est une AUTRE crate (sans workspace commun, son propre `Cargo.lock` et son
`deny.toml`), qui dépend de la lib `baluchon_core` par chemin et appelle la même `run_with`
avec son implémentation. Le nom de la lib, `baluchon_core`, et le trait `Extension` sont l'API
de cette couture ; leur évolution suit la règle de versionnage ci-dessous.

Neuf points d'extension : `renew`, `recover` (appelé au statut et au lancement),
`is_revoked`, `secret_files`, `doctor_lines`, `extra_origins`, `external`, `edition`. Le noyau n'appelle
jamais un renouvellement en direct ; `core/tests/seam.rs` prouve que chaque point est atteint
et qu'aucune source publique ne l'appelle autrement. `http::Method` n'a que `Get`,
`HttpRequest` n'a pas de corps. Le noyau garde `rename_durable` et `sync_parent` (écriture
atomique durable) et les lectures du Trousseau. La purge refuse tout chemin fourni par une
extension hors du dossier du profil.

**Garde lecture seule** (`scripts/garde-lecture-seule.sh`, porte P6 de
`scripts/release.sh`). Elle refuse la release si `core/src` ou l'un des binaires
(`strings`) contient `PostJson`, `write_login`, `upsert`, `apply_renewal`, `Reserved`,
`grant_type`, `add-generic-password`, `/v1/oauth/token` ou un `refresh_token` hors de
l'accesseur du blob ; `delete-generic-password` n'est permis que dans `delete_all`.
Elle ferme (code 2) sur une entrée illisible. Ses épreuves
(`scripts/garde-lecture-seule.test.sh`) montrent chaque motif rouge et chaque exception
verte ; `core/tests/readonly.rs` prouve en plus, sur le binaire, « aucun POST, magasin
identique » (rouge si on le vise sur un binaire qui renouvelle :
`BALUCHON_READONLY_BIN=<binaire>`). La crate `core/testkit` porte le banc d'essai partagé
(faux serveur, bac à sable, binaire en paramètre).

### `doctor` et `about`

`baluchon-core about --json` donne `name`, `version`, `contract`, `edition`, `built_on`.
`baluchon-core doctor` dit l'édition, la version, la couche (nom, version, `built_on`, état
« utilisable », « contrat périmé », « illisible » ou « absente ») et, par profil, tout ce que
l'extension ajoute. Sur un profil qui contient un `.ccp-pending` ou un `.ccp-pending.reserve`
que l'édition publique ne sait pas rejouer, il dit : « Journal de renouvellement orphelin :
ce compte devra peut-être être reconnecté (le jeton renouvelé n'a jamais été écrit). Le public
ne le rejoue pas. » Le magasin n'est pas touché.

## Couches

Une couche est un dossier `<racine>/overlay/` posé À CÔTÉ du portable. Le portable n'y écrit
jamais : installer ou mettre à jour le portable n'écrit que `bin/` et les fichiers publics, puis
appelle le crochet `overlay/hooks/update` s'il existe. Sans cette règle, un clic sur « Mettre à
jour » remplacerait en silence le noyau d'une couche par le public.

```
overlay/
  CURRENT                        pointeur : « gen/<nom> », la génération courante
  gen/<nom>/                     UNE génération de la couche, posée en entier avant d'être visible
    LAYER                        manifeste (clé = valeur)
    bin/<plateforme>/baluchon-core[.exe]   noyau complémentaire
    profil/remote.conf           copie du profil posé (pour reconnaître une copie non modifiée)
  hooks/update                   appelé après chaque installation ou mise à jour du portable
  hooks/uninstall                appelé par uninstall.sh et « Tout déconnecter »
```

**Générations** (re-revue Codex : « aucune atomicité de génération »). Une mise à jour de la
couche ne remplace jamais un fichier de la couche en place : elle pose une NOUVELLE génération
dans `overlay/gen/<nom>/`, invisible tant que personne ne la désigne, puis remplace `overlay/CURRENT`
par un seul renommage (`rename(2)`, atomique). Un lecteur qui ne prend aucun verrou voit donc la
génération précédente entière ou la nouvelle entière. Pour que cela tienne côté lecteur, le
pointeur est lu **une seule fois** par lecture (`cc_layer_resolve` en bash, `layer::current_dir`
en Rust) et tout le reste (manifeste, noyau) se lit sous le dossier obtenu. Pourquoi un FICHIER
pointeur et non un lien symbolique : une clé exFAT/FAT n'a pas de liens, et Git Bash copie au lieu
de lier (la copie n'est pas atomique). La génération précédente est gardée (un lecteur déjà parti
peut finir de la lire, un noyau en cours d'exécution n'est pas supprimé sous ses pieds) ; les plus
anciennes sont effacées après la bascule. Un pointeur présent mais illisible (forme inattendue,
remontée `..`, lien, génération absente ou liée) = pas de couche et une ligne visible, JAMAIS un repli
sur une autre génération ni sur une couche à plat. Sans `CURRENT`, la couche est à plat directement sous
`overlay/` (posée avant les générations) : même lecture. `lib/common.sh` annonce sa capacité
(`CCP_LAYER_POINTER=1`) : un crochet refuse de poser une génération sur un lanceur qui ne l'annonce
pas, faute de quoi ce lanceur ne verrait que l'ancienne couche, en silence.

Manifeste `LAYER` : `name`, `version` (`<version publique>+<suffixe>`), `built_on` (version
publique de construction), `contract` (contrat CLI du noyau de la couche), `platforms` (liste
séparée par des virgules, jokers `*`).

**Choix du noyau au lancement** (`cc_ensure_core`, `lib/common.sh`) :

1. Pas de couche (ni `overlay/CURRENT`, ni `overlay/LAYER` à plat) : noyau public.
2. Le noyau de la couche manque pour cette plateforme, n'est pas exécutable, répond un
   `--contract` différent de `CCP_CONTRACT`, ou déclare l'édition `public` : noyau public ET
   une ligne visible à chaque écran (« Couche « nom » inutilisable (raison) : noyau public
   utilisé »).
3. Sinon : le noyau de la couche.

Un échec d'un crochet est dit, jamais fatal : la mise à jour du portable a déjà réussi et la
couche garde sa version précédente. `uninstall.sh` appelle `overlay/hooks/uninstall`, efface
les jetons Cloudflare Access (`remote forget-access`), puis supprime le dossier entier.

## Versionnage

- La version du produit vit dans `core/Cargo.toml`. Le tag git de la release est `v` + cette
  version ; `scripts/release.sh` refuse la release si le tag de `HEAD` ne la vaut pas.
- `CONTRACT` (`core/src/cli.rs`, entier) ne change que si la ligne de commande ou un format lu
  par le wizard casse ; il monte alors AVEC une version majeure. Le trait `Extension` suit la
  même règle : ajouter une méthode AVEC implémentation par défaut = version mineure ; changer
  une signature ou retirer = version majeure et `CONTRACT` + 1.
- Une couche porte `version = <publique>+<suffixe>` et `built_on = <publique>`. Le wizard compare
  `contract` du manifeste à `CCP_CONTRACT` : écart = repli sur le public, avec le message ci-dessus.

## Outils

- **Windows, logiciels** : `baluchon-core win catalog` (embarqué, surchargeable par
  `config/catalog.toml`) puis `win install <clés>` → `winget install --id … -e
  --silent`, élévation demandée en amont, « déjà installé » = succès.
- **Windows, Office** : `win office --edition <clé> --lang fr-fr --apps …` →
  Office Deployment Tool, XML généré (`ExcludeApp` pour les apps non cochées,
  `AUTOACTIVATE=0`), ≥ 5 Go vérifiés, staging effacé.
- **Accès aux agents d'un Mac** : `remote connect` → `ssh` avec
  `ProxyCommand=cloudflared access ssh` vers l'hôte du profil, clé d'hôte du Mac pré-posée
  (`StrictHostKeyChecking=yes`), une seule connexion (liste des sessions tmux → choix →
  attache). Le noyau n'a AUCUN hôte par défaut : sans `config/remote.conf` ni `--host`/`--user`,
  il refuse (code 2) et explique comment mettre en place SON Mac. `cloudflared` portable,
  version et empreintes épinglées.
- **Profil de l'accès distant** : `config/remote.conf`, lignes `clé = valeur`.
  ```
  host = mac.example.com
  user = jane
  host_key_type = ssh-ed25519
  host_key = AAAAC3NzaC1lZDI1NTE5AAAA…          # ssh-keyscan localhost, côté Mac
  label = com.example.baluchon-mac-tunnel        # LaunchAgent du tunnel, côté Mac
  ```
  La clé d'hôte du profil ne s'applique qu'à l'hôte du profil.
- **Partage d'un PC Windows** (`remote share`, non éprouvé sur Windows) : sshd
  portable temporaire sur 127.0.0.1, clés seules, tunnel retour vers le Mac,
  Job Object kill-on-close, tout retiré à la sortie.
- **Côté Mac** (`remote setup-mac --host <nom-public-du-Mac> [--check]`) : sshd, LaunchAgent du
  tunnel, journal du tunnel, Cloudflare Access devant (302 sans bannière SSH), clé des agents
  restreinte `from="127.0.0.1,::1"`. Ne crée aucun objet Cloudflare (DNS / Access passent par
  l'API, hors binaire distribué).
- **Oublier l'accès** : `remote forget-access` efface (sans les lire) les jetons Cloudflare
  Access de l'hôte du profil dans `~/.cloudflared`. Appelé par `uninstall.sh`.

## Poste invité

Le marqueur `config/.hosts/<hôte>` (`trusted` | `guest`) est demandé à la 1re
ouverture sur tout système. En quittant un poste `guest` : `accounts purge`
(Trousseau + identifiants en fichier, journal, réservation, sauvegardes,
temporaires) sous le verrou du profil. Codes : 0 = effacé ; 11 = effacé mais une
session ou un renouvellement encore vivant pourrait réécrire (le wizard demande
de la fermer et efface une 2e fois) ; 10 = échec, fichiers nommés. `remote` purge
aussi les jetons Cloudflare Access de cet hôte.

## exFAT, noexec

`chmod +x` puis test `--version` ; si le support est `noexec`, copie unique dans
`~/.cache/baluchon/` et exécution de là (même règle pour `baluchon-core`).

## Provenance des binaires

- Claude Code : `downloads.claude.ai/claude-code-releases/<version>/<plateforme>/claude[.exe]`,
  SHA256 du `manifest.json` (`platforms.<plat>.checksum`).
- `baluchon-core`, wizard, lanceurs : release GitHub `atelier-sam/baluchon`,
  `SHA256SUMS` signé `baluchon-release` (clé publique dans `install.sh`, `install.ps1`,
  `lib/common.sh` ; `release.sh` vérifie qu'elles concordent).
- `gum` 0.17.0, `cloudflared` 2026.10.7, Win32-OpenSSH 10.4.0.0p1 : empreintes
  épinglées. Git for Windows : `digest` de l'API GitHub.

Variable `CCP_DL` : adresse de la release, pour une recette locale. La signature reste exigée.

## Faire une release

```sh
git tag v$(sed -n 's/^version = "\(.*\)"$/\1/p' core/Cargo.toml | head -1)
scripts/build-core.sh && scripts/release.sh   # dist/release/ signé et contre-vérifié
```
`release.sh` joue d'abord la règle de versionnage (tag = `v` + version), puis
`cargo deny --locked check` (`core/deny.toml` : licences permissives seulement, avis
RUSTSEC, sources crates.io seules, OpenSSL/native-tls interdits) et s'arrête avant de signer
si une porte refuse. Prérequis : `cargo install cargo-deny --locked`, réseau (base
d'avis). Hors release : `cd core && cargo deny --locked check`. Ses épreuves, hors ligne :
`scripts/release.test.sh <dossier-vide-absolu>`.

Les deux scripts servent à toute édition sans être copiés : `build-core.sh` lit `CORE_DIR`,
`BIN_NAME` et `DIST_DIR` ; `release.sh` lit `CCP_SIGN_KEY`, `CCP_SIGNER_ID`, `CCP_SIGNER_SRC`,
`CCP_SIGNER_COPIES`, `CCP_ASSETS`, `CCP_OUT`, `CCP_DENY_DIRS`, `CCP_GATES` et `CCP_TAG` (voir
l'en-tête du script).

Puis publier `dist/release/*` comme assets d'une release : les installeurs lisent
`github.com/atelier-sam/baluchon/releases/latest/download/`. `install.sh` et `install.ps1`
font partie des assets (donc des sommes signées) : un script qui doit lancer l'installeur
sans le télécharger depuis une branche le prend dans `releases/download/<tag>/`, vérifie
`SHA256SUMS` contre la clé publique `baluchon-release` (`ssh-keygen -Y verify -n file`), puis
contrôle l'empreinte de l'installeur, avant de l'exécuter. Garde de périmètre : l'identité
`baluchon-release` (ou sa clé) fait toujours juger l'ensemble des assets par
`scripts/garde-lecture-seule.sh`, même avec `CCP_ASSETS` : une release à périmètre élargi ne
peut pas être signée avec la clé publique.
