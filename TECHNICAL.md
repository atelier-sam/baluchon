# Baluchon — notes techniques

## Architecture

| Pièce | Rôle |
|---|---|
| `Claude.command` | Interface seule (bash + `gum`). Mac/Linux, et Windows via le bash de Git portable. |
| `lib/common.sh` | Plateforme, téléchargements vérifiés (fail-closed), mises à jour, choix du noyau, purge de repli. « Tout effacer » (`cc_wipe`) rend 0, 2 (session encore ouverte), 10 (jetons Cloudflare Access restés utilisables, y compris ceux des hôtes notés dans `.baluchon-acces` : `config/remote.conf` et `.baluchon-acces` sont alors gardés pour qu'une nouvelle tentative sache quel hôte oublier) ou 1, avec `CC_WIPE_NOTE` qui nomme ce qui reste ; le menu ne dit « ✓ Effacé » que sur 0. Épreuves : `scripts/effacement.test.sh <dossier-vide-absolu>`. |
| `core/` → `baluchon-core` | Noyau Rust : comptes, statut, forfait, quotas, lancement verrouillé, outils Windows, accès distant. Contrat CLI versionné (`baluchon-core --contract`). |
| `winget/` → `baluchon-winget` | Moteur winget extrait du noyau : catalogue de logiciels embarqué (`catalog.toml`, dont la suite ArtCraft) avec ses packs (`[[pack]]` : listes nommées de logiciels, jamais recopiées) et leur fusion par clé (`merge_catalogue`, l'unique logique ; `merge` et `parse_file` en sont des enveloppes qui rendent les applis seules), arguments figés de `winget install`, table des codes de sortie, verdict par paquet, trait `Winget` derrière lequel l'appelant branche son exécuteur. Deux dépendances (`serde`, `toml`), aucun processus lancé, aucun fichier ouvert : un programme qui doit installer des logiciels sans tirer TLS ni clap la lie directement. Le noyau la ré-exporte sous les chemins d'avant (`win/winget.rs`, `win/catalog.rs`) ; son `Cargo.lock` est le sien, `cargo deny` du noyau couvre son arbre. |
| `texte/` → `baluchon-texte` | Texte venu d'ailleurs, rendu sûr à afficher, **sans aucune dépendance** : la liste UNIQUE des caractères de format invisibles qui trompent la lecture (marques de sens d'écriture comme U+202E qui retourne `gpj.exe` en `exe.jpg`, largeurs nulles, sélecteurs de variation, caractères de balise), `invisible_trompeur`, `sans_invisibles` et `assainir` (une ligne sans invisible ni contrôle, blancs réduits, coupée sur une frontière de caractère). `baluchon-winget` s'en sert pour les lignes qu'il rend. Une épreuve compare la table, sur tout Unicode, à l'ensemble des anciennes copies. |
| `claude.cmd` / `claude-classic.cmd` | Lanceurs Windows (wizard / repli 100 % batch). |
| `install.sh` / `install.ps1` / `uninstall.sh` | Installation depuis la release signée (les deux installeurs et `uninstall.sh` sont eux-mêmes des assets signés de la release, et posent le marqueur `.baluchon-install` ; voir « Un seul lien chez le client ») ; désinstallation, qui refuse tout dossier sans ce marqueur, `/`, le domicile et ses parents (chemin canonique), et tout dossier dont un ANCÊTRE peut être modifié par un autre utilisateur (écriture de groupe ou du monde sans bit sticky, propriétaire étranger). L'effacement part du dossier PARENT figé (identité périphérique:inode revérifiée, nom relatif) : un maillon échangé contre un lien après le jugement donne un refus. Un ménage incomplet (jetons Access, sessions du Trousseau, dossier non supprimé en entier) sort en code 10, 11 ou 12 avec un bilan qui nomme ce qui reste, jamais « Plus aucune trace » ; un Trousseau verrouillé ou inaccessible est vu AVANT toute suppression (`security show-keychain-info` ≠ 0, ou lecture d'un item refusée : code 15, rien n'est effacé) et un item qui refuse d'être supprimé arrête le script AVANT le dossier, le lien et les commandes (code 15 aussi : l'installation est conservée, la relance après déverrouillage va au bout). Épreuves : `scripts/uninstall.test.sh <dossier-vide-absolu>`. |
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
  `config/catalog.toml` peut aussi porter des `[[pack]]` (`key`, `label` et une seule source :
  `apps = [...]`, `category = "X"` ou `defaults = true`), fusionnés par clé comme les applis. Un
  pack fautif (clé citée inconnue ou retirée, pack vide, deux sources…) fait ignorer toute la
  surcharge, avec son message sur stderr, pour la liste ET pour les packs (une seule fusion).
  `win catalog` ne rend toujours que des applis ; `win catalog --format packs` rend les packs,
  `clé<TAB>libellé<TAB>clé,clé,…`, dans l'ordre du catalogue (celui de `catalog.toml` : « Essentiels
  d'un PC neuf » en tête, les packs d'une surcharge à la suite). Additif : `CONTRACT` ne bouge pas, et
  un noyau d'avant refuse `--format packs` (code 2), que le wizard lit comme « pas de packs ».
  Le wizard (`Claude.command`, `logiciels_depart`) pose « Par où commencer ? » AVANT la liste : un
  pack ne fait que PRÉ-COCHER ses logiciels dans la liste complète, qu'on ajuste avant d'installer
  (Entrée sur « Essentiels » = les cases pré-cochées d'avant les packs ; « Tout le catalogue, à cocher
  moi-même » ne pré-coche rien).
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

## Un seul lien chez le client

Un même lien installe, se reconnaît « déjà à jour », ouvre le menu et permet d'en partir. Les
définitions de « installé », « à jour » et « ce qui reste » vivent une seule fois, dans le dernier
bloc de `lib/common.sh`, partagé par `install.sh`, l'amorce de la couche (qui vit hors de ce dépôt)
et `Claude.command`.

- **Relevé de release `.baluchon-release`** (écrit EN DERNIER, après une installation ou une mise à
  jour complète, via fichier temporaire + `mv`) : `baluchon-release 1`, `sums <sha256 du SHA256SUMS
  signé>`, `tag <étiquette informative>`. L'identité d'une release est l'empreinte de ses sommes
  signées, jamais un numéro de version (deux releases qui diffèrent d'un octet ne se confondent pas).
- **À jour** (`cc_release_a_jour`, fail-closed) : marqueur d'installation valide, relevé qui porte
  l'empreinte des sommes qu'on vient d'authentifier, manifeste signé conservé identique à ces sommes,
  chaque fichier posé (menu, bibliothèque, désinstalleur, noyau) à l'empreinte que la release signe,
  `VERSION` présent, et le binaire Claude ainsi que `gum` à l'empreinte NOTÉE à l'installation (voir
  « Authentifier avant d'exécuter »). `install.sh` ne joue la bibliothèque déjà posée que si son
  empreinte est celle des sommes signées, et seulement APRÈS en avoir pris une copie privée qu'il hache
  puis source (jamais le fichier posé relu par son chemin : un remplacement entre le contrôle et la
  lecture ne passe plus). Un doute et tout est refait. À jour : rien n'est téléchargé au-delà des deux
  fichiers de signature, les commandes manquantes sont reposées, la couche (crochet `update`) n'est pas
  rejouée.
- **Authentifier avant d'exécuter** (revue Codex, 2e et 3e passes). Règle unique : aucun fichier n'est
  exécuté, sourcé ni même sondé (`--version`, `--contract`) avant d'avoir été comparé à une empreinte
  qu'une signature ou une vérification de l'installeur garantit.
  - Le **manifeste signé** de la release (`SHA256SUMS` + `.sig`) est CONSERVÉ dans l'installation
    (`.baluchon-sums`, `.baluchon-sums.sig`, copiés AVANT le relevé `.baluchon-release`). Chaque
    lecture le revérifie, sur une copie privée, avec la clé épinglée (`CCP_SIGNER`) : un manifeste
    réécrit par un tiers ne passe pas. Il authentifie le menu, la bibliothèque, le désinstalleur et
    le noyau public.
  - **`.baluchon-refs`** (une ligne `<sha256>  <chemin>`) note ce que le manifeste ne couvre pas :
    le binaire Claude (téléchargé et vérifié par l'installeur auprès de l'éditeur), `gum`, et, quand
    une couche est posée, son noyau et ses crochets (notés par l'amorce, qui seule connaît la clé de la
    couche et en a vérifié les sommes signées). Un fichier absent de ces deux listes n'est pas lancé.
  - `cc_open_menu` ne lance le menu que si `cc_installation_authentique` est vraie ; `Claude.command`
    revérifie le binaire Claude (`cc_bin_verifie`) juste avant de le lancer ; le crochet de couche est
    exécuté depuis une copie privée hachée ; le désinstalleur de même (voir « Partir »).
  - **Honnêteté sur ce que cela couvre.** `.baluchon-refs` est écrit avec les droits de l'utilisateur :
    il protège d'un fichier remplacé SEUL, pas de quelqu'un qui réécrit toute l'installation (qui n'a
    de toute façon pas besoin de nos scripts pour agir sous ce compte). Le menu et les sources sont
    lancés par leur chemin : il reste une fenêtre entre la vérification et l'exécution, plus étroite
    qu'avant mais non nulle pour un attaquant qui écrit dans le dossier au bon instant. Une
    installation d'avant cette règle n'a ni manifeste ni références : elle se ré-authentifie en
    relançant le lien d'installation une fois ; en attendant, « Partir » refuse (code 14) et le dit.
    Claude hors ligne sans référence notée : refus dit, jamais un lancement sur parole.
- **Ouvrir le menu** : `BALUCHON_OUVRIR_MENU=1` (opt-in côté `install.sh`, dont le contrat seul est
  inchangé). `cc_open_menu` lance le menu en ENFANT (l'appelant a un ménage à faire ensuite), avec
  `BALUCHON_DEPUIS_LIEN=1`, sur `/dev/tty` (`CC_TTY` en essai) : avec `curl … | bash` l'entrée
  standard est le script. Sans terminal, il dit la commande à taper et rend 0. `BALUCHON_ETAT_SORTIE`
  (chemin d'un fichier) reçoit `installe` ou `a-jour`, pour l'amorce.
- **`.baluchon-acces`** : un nom d'hôte par ligne (jamais un jeton), posé par l'amorce quand des jetons
  Cloudflare Access ont pu rester sur la machine. `cc_wipe` et `uninstall.sh` appellent `remote
  forget-access --host` pour chacun, en plus de celui de `config/remote.conf` ; le fichier n'est retiré
  que si l'oubli a réussi, et un noyau absent avec des hôtes notés donne le code 10.
- **« 🚪 Partir »** (`Claude.command`, macOS et Linux ; absent sans marqueur, sans désinstalleur ou sous
  Windows) : confirmation `gum` (« Non, annuler » par défaut) puis `cc_depart`. Celui-ci prend une
  COPIE privée (dossier `700`) de `uninstall.sh` et exige que son empreinte soit celle du manifeste
  SIGNÉ conservé (`uninstall.sh` y figure) puis `bash -n` ; sinon code 14, rien n'est effacé, et la
  raison est dite (manifeste absent ou invalide, désinstalleur modifié, ou remplacé pendant que le menu
  était ouvert). Il relève ensuite ce qu'il faudra chercher (dossier et chemin canonique, items du
  Trousseau, hôtes Access, dossiers de cache), efface les sessions (`cc_wipe`), sort du dossier
  (`cd /`), joue la copie du désinstalleur (une seule source des gardes de chemin), puis **relit le
  disque** : le menu n'écrit « Rien ne reste sur cet ordinateur » que si dossier, commandes, items du
  Trousseau, jetons Access et cache d'exécution sont réellement partis, sinon il liste le reste.
  Codes : 0 rien ne reste, 14 rien fait (désinstalleur non authentique), 15 le Trousseau refuse
  (verrouillé, accès refusé) : **l'installation est CONSERVÉE** (dossier, profils, commandes, menu), le
  menu le dit et revient, « Partir » se relance après déverrouillage (au pré-contrôle : rien n'a été
  effacé ; à la suppression d'un item : les fichiers de connexion sont effacés mais les dossiers de
  profil restent), 2 / 10 / 11 / 12 ceux d'`uninstall.sh` ou de `cc_wipe`, 13 un
  reste que personne n'avait signalé. Aucun journal n'est écrit après l'effacement (il recréerait le
  dossier). Sur un poste invité, « Partir » est en tête du menu.
  - **Niveau de confiance, dit en clair** : « Partir » fait confiance à ce que fait confiance le menu
    lui-même, ni plus ni moins. Le désinstalleur est comparé au manifeste signé conservé, lequel est
    vérifié avec la clé de la release ; quelqu'un qui peut réécrire toute l'installation (manifeste
    signé compris, avec une signature valide) a déjà gagné. Ce qui est exclu : un désinstalleur
    simplement remplacé, ou un manifeste réécrit sans la clé.
  - **Liens jamais suivis** : avant toute suppression, la racine est jugée (`cc_racine_sure` : chemin
    absolu et physique, ni `/`, ni le domicile, ni un parent du domicile, propriétaire = l'utilisateur).
    Un `config` qui est un lien symbolique n'est ni énuméré ni purgé (le noyau et le repli ne le
    suivent pas) : c'est dit, le code n'est jamais 0. Un profil lien est laissé en place et nommé. Les
    suppressions partent d'un `cd -P` dans `config` et passent par des noms relatifs. Cela vaut aussi
    pour le noyau Rust (`list_profiles` lit le type de l'ENTRÉE et non sa cible ; `purge` refuse un
    `config` lien, une entrée lien ou un profil lien AVANT de prendre le verrou, et un chemin
    d'extension qui traverse un sous-dossier lien ; le verrou de purge ne crée jamais de fichier dans
    la cible d'un lien) et pour `cc_purge_sessions` (repli bash : s'il y a un lien, le noyau n'est pas
    appelé, le repli traite les vrais profils et nomme chaque lien). `uninstall.sh` (étape 2) sort en
    code 11 en nommant les liens, supprime quand même le Trousseau des vrais profils, et son `rm -rf`
    du dossier retire le lien sans entrer dans sa cible.
  - **Aucune écriture à un nom prévisible** : `cc_ecrire` / `cc_poser` (bibliothèque) et `poser`
    (`install.sh`) écrivent dans un temporaire au nom imprévisible (`$$` + trois `$RANDOM`) ouvert en
    création exclusive (`set -C`, `O_EXCL`), par ce descripteur, puis `mv` REMPLACE la destination : un
    lien posé d'avance disparaît et sa cible reste intacte ; un dossier à la place de la destination est
    refusé. Y passent les références (`cc_ref_set`/`cc_ref_drop`), le téléchargement de Claude et du
    noyau, la mise à jour, le retour arrière, les sommes/signature/relevé de release, le relevé de
    cache, la mémoire de Claude stable et les écritures de `ACTIVE` du menu. L'installeur revérifie
    l'empreinte sur le fichier POSÉ, pas sur le téléchargement.
  - **`gum`** : tout se passe dans un dossier privé ; l'empreinte de référence est calculée sur le
    binaire EXTRAIT, le fichier posé doit avoir exactement cette empreinte (sinon il est retiré), et
    « présent » ne suffit plus sur une installation : un `gum` recréé pendant un téléchargement échoué
    n'a pas de référence, donc n'est pas accepté (`cc_ensure_gum` rend 1).
  - **Limites dites** : `symlink_metadata` puis l'action laissent une fenêtre de course (la garantie
    complète demande `openat`/`O_NOFOLLOW`/`unlinkat` par libc : non fait) ; un autre compte qui peut
    écrire dans le dossier ET lire le nom du temporaire pendant sa courte vie pourrait l'échanger ;
    Windows (jonctions) n'est pas couvert.
  - **Trousseau** : `security` répond 0 (supprimé) ou 44 (l'item n'existait pas) ⇒ « plus rien » ; toute
    autre réponse (Trousseau verrouillé, accès refusé, outil absent) n'établit RIEN : « sessions non
    vérifiées », code non nul, jamais « Rien ne reste ». Le nom d'un item se calcule depuis le dossier de
    son profil : un dossier supprimé pendant que le Trousseau refuse laisse des sessions dont plus rien ne
    dit le nom, et l'effacement ne se rejoue plus. D'où deux garanties :
    1. **Pré-contrôle, avant toute suppression** : sur macOS, `cc_depart` (après le relevé), `cc_wipe` et
       `uninstall.sh` (étape « 0) », avant tout crochet ou noyau) exigent d'abord que le Trousseau soit
       **déverrouillé** (`security show-keychain-info` : 0 = déverrouillé, 36 = verrouillé, toute réponse
       ≠ 0 est un refus ; c'est le test que Claude Code applique lui-même), puis LISENT chaque item
       (`find-generic-password`, un par profil de `config/*/` et par chemin physique : 0 ou 44 laisse
       passer, toute autre réponse arrête). La lecture seule ne suffisait pas : une recherche d'attributs
       peut répondre 0 ou 44 sur un Trousseau VERROUILLÉ, seule la suppression exige le déverrouillage.
       Un refus sort en **code 15** (« Partir », `uninstall.sh`) ou **3** (`cc_wipe`, `cc_purge_sessions`),
       rien n'est supprimé, et la relance après déverrouillage termine normalement. Sans aucun profil, rien
       n'est à protéger au Trousseau : le contrôle n'est pas joué.
    2. **Un refus à la suppression conserve l'installation** : si un item refuse d'être supprimé après ce
       pré-contrôle réussi (verrouillé entre-temps, accès refusé : toute réponse autre que 0 ou 44),
       `uninstall.sh` s'arrête AVANT de toucher au dossier d'installation, au lien qui y mène et aux
       commandes (code **15**, bilan « Rien de l'installation n'est supprimé, des sessions restent au
       Trousseau »), et `cc_wipe` laisse les dossiers de profil et `ACTIVE` en place (code **3**, qui prime
       sur 1 et 10) ; `cc_depart` rend alors 15 sans lancer le désinstalleur (ou après qu'il a rendu 15) et
       le menu dit que l'installation est conservée et qu'il faut relancer « Partir » après déverrouillage.
       Ce qui était déjà fait (crochet de la couche, noyau, fichiers de connexion purgés, jetons Access,
       cache d'exécution) reste fait ; la relance refait la suite et va au bout.
    Limites dites : (a) l'état « déverrouillé » est LU à un instant, un verrouillage ensuite n'est pas
    empêché, il est VU par la suppression (garantie 2) ; (b) ces comportements sont éprouvés avec un FAUX
    `security` seulement (jamais le vrai Trousseau) : ce que fait réellement `show-keychain-info` sur un
    Trousseau verrouillé (36) est tenu pour acquis, non vérifié par un essai ; (c) la relance rejoue le
    crochet de la couche s'il y en a un : il doit être rejouable.
  - **Cache d'exécution** : sur une clé montée sans exécution, `${XDG_CACHE_HOME:-~/.cache}/baluchon`
    reçoit des copies des binaires ; `.baluchon-cache` en note les dossiers ET, une fois, la BASE qui
    les porte (ligne `base <cache>/baluchon`) : un `XDG_CACHE_HOME` différent au moment de partir ne
    fait donc plus oublier le cache. Les bases jugées sont `~/.cache/baluchon`, celle du `XDG_CACHE_HOME`
    courant et les lignes `base` du fichier ; une base doit être absolue, sans `..`, `//`, retour à la
    ligne, finir par `/baluchon`, avoir un parent qui n'est pas `/` et ne pas être un lien. Une ligne
    qui ne tient pas ces bornes est ignorée, jamais suivie. `uninstall.sh` ne retire QUE les entrées
    notées sous une base ainsi acceptée, et seulement depuis un `cd -P` : la base est jugée (vrai dossier,
    à l'utilisateur), puis chaque dossier du chemin est ENTRÉ un par un (`cd -P ./part`, chemin physique
    contrôlé) et jugé ; la feuille est effacée par `rm -rf -- ./feuille` RELATIF, puis les parents
    devenus vides par `rmdir -- ./nom` (jamais un parent non vide). Un dossier du chemin qui est un lien,
    qui n'est pas à l'utilisateur, ou que d'autres peuvent modifier (écriture du monde, ou du groupe
    sauf groupe privé du même nom que l'utilisateur ; le bit sticky n'est PAS une exemption) fait
    refuser l'entrée : aucun `rm` n'est lancé, c'est nommé (code 12), jamais « Plus aucune trace ».
    Limite dite : entre le dernier contrôle de la feuille et le `rm -rf` relatif, un tiers qui peut
    déjà écrire dans le dossier juste au-dessus pourrait encore l'échanger ; la garantie complète
    demanderait `openat`/`O_NOFOLLOW`/`unlinkat` (libc), non faits en shell.
- **Épreuves** : `scripts/lien-unique.test.sh <dossier-vide-absolu>` (installeur contre une release
  locale signée avec une clé d'essai, faux `curl`/`gum`/`security`, HOME jetable : première
  installation, « à jour » sans téléchargement, relevé absent, fichier altéré, autre release,
  désinstalleur falsifié refusé, release sans désinstalleur, « Partir » de bout en bout, contrôle positif
  sur l'ancien `install.sh`, bibliothèque ou binaire échangés entre le contrôle et la lecture, Claude ou
  `gum` remplacés), `scripts/depart.test.sh <dossier-vide-absolu>` (le vrai menu, la vraie
  bibliothèque et le vrai désinstalleur : succès, jeton Access non effaçable, Trousseau refusé ou
  verrouillé, noyau menteur, annulation, désinstalleur illisible ou remplacé pendant le menu, manifeste
  forgé, `config` lien, cache, lien symbolique, hôte noté, contrôles positifs),
  `scripts/logiciels.test.sh <dossier-vide-absolu>` (« Installer des logiciels » : les vraies
  fonctions du wizard extraites de `Claude.command`, faux `gum` et faux noyau : menu des packs dans
  l'ordre, pré-cochage exact, décochage, « à la carte », Échap, noyau d'avant sans packs, contrôle
  positif contre l'ancien assistant),
  `scripts/uninstall.test.sh` (refus de chemins, noyau et crochet jamais lancés sans empreinte
  authentifiée, `config` lien, Trousseau verrouillé AVANT toute suppression (`show-keychain-info` ≠ 0 ou
  lecture refusée : code 15, rien supprimé, relance après déverrouillage) ou refus de la SUPPRESSION
  après des contrôles réussis (36, 51 : code 15, installation et commandes conservées, relance après
  déverrouillage), cache) et `scripts/effacement.test.sh` (`cc_wipe` et `cc_purge_sessions` : racines
  douteuses, `config` ou profil lien, Trousseau verrouillé : code 3 sans rien toucher, ou refus de la
  suppression après des contrôles réussis : code 3, profils conservés, relance qui aboutit). Chaque épreuve nouvelle est
  rejouée contre l'ancien code (lu dans l'historique git) et doit y échouer. Les essais posent une clé
  de signature JETABLE à la place de celle du produit.
- **Windows** : même chaîne. `install.ps1` n'est qu'une amorce : Git portable (digest de l'API GitHub),
  `SHA256SUMS` signé vérifié par le `ssh-keygen` de Git portable (celui de `System32\OpenSSH` ne voit pas la fin
  d'un stdin redirigé et bloque à jamais), puis `install.sh` vérifié, lancé par ce bash : wizard, noyau, Claude,
  gum, relevé signé et menu sont posés exactement comme sur Mac. Les commandes `baluchon.cmd`… enchaînent sur
  `claude.cmd` (pas de `call`). Lancé par `irm … | iex`, un échec rend l'invite (`break`) au lieu de fermer la
  fenêtre ; par `-File` (amorce de la couche), il sort avec son code.
  « Partir » sous Windows : un exécutable en cours ne s'efface pas (le `rm` de MSYS le déplace dans la Corbeille,
  où il reste). `uninstall.sh` efface donc tout sauf `git-win` et pose `.baluchon-a-finir` ; `claude.cmd` (dans un
  seul bloc, puisqu'il est lui-même effacé, sortie par `(goto) 2>nul`) ou `install.ps1`, une fois bash terminé,
  retirent `git-win` (réessais 30 s, `rmdir /s` qui ne suit pas les jonctions) puis le dossier par un `rmdir` NON
  récursif, relisent et disent « Rien ne reste » ou ce qui reste (code 12). Un départ inachevé (fenêtre fermée
  avant) est terminé par le prochain `install.ps1`. Éprouvé le 15-16/11/2026 sur Windows 11 (compte jetable) :
  installation, relance « à jour » (4,7 s), mise à jour partielle, « Partir » depuis `baluchon.cmd` (poste à
  soi) et depuis `irm | iex` (poste invité), refus d'une release altérée (`-File` : code 1 ; `iex` : invite
  rendue), départ inachevé repris ; dossier, commandes et Corbeille vides après chaque « Partir ».
- **Limite connue (Windows)** : MSYS montre tout dossier comme appartenant à l'utilisateur, sans écriture des
  autres (montage `noacl`) : le contrôle des ancêtres d'`uninstall.sh` y passe toujours et ne prouve rien. Les
  ACL Windows ne sont pas lues. Un `install.ps1` qui échoue après l'étape 1 laisse `git-win` (relance immédiate).

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
`github.com/atelier-sam/baluchon/releases/latest/download/`. `install.sh`, `install.ps1` et
`uninstall.sh` font partie des assets (donc des sommes signées ; `uninstall.sh` est toléré absent
d'une ancienne release, l'installeur le dit et le menu ne propose alors pas « Partir ») : un script qui doit lancer l'installeur
sans le télécharger depuis une branche le prend dans `releases/download/<tag>/`, vérifie
`SHA256SUMS` contre la clé publique `baluchon-release` (`ssh-keygen -Y verify -n file`), puis
contrôle l'empreinte de l'installeur, avant de l'exécuter. Garde de périmètre : l'identité
`baluchon-release` (ou sa clé) fait toujours juger l'ensemble des assets par
`scripts/garde-lecture-seule.sh`, même avec `CCP_ASSETS` : une release à périmètre élargi ne
peut pas être signée avec la clé publique.
