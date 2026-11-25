# Archiviste

Renomme vos PDF, scans, photos et captures d'écran d'après leur contenu, entièrement
sur votre Mac : modèle Apple sur l'appareil (FoundationModels) et OCR Vision. Rien ne
quitte la machine.

    Scan 20261109-140943.pdf  →  2026-11-09 - Reçu de paiement Le Petit Café - Repas - 45.80 EUR.pdf
    IMG_0877.jpeg             →  2026-11-03 - Photo - Couverture du livre L'océan d'amour.jpeg

Format : `DATE - Type Émetteur - Détail - MONTANT`. Le montant n'apparaît que pour les
factures, reçus, devis, avoirs, quittances et notes de frais. Photos et captures d'écran
prennent la date de prise de vue. Noms et prompts sont en français.

**Prérequis :** Mac Apple silicon sous macOS 27 ou plus récent, Apple Intelligence activé
(Réglages → Apple Intelligence et Siri) ; Xcode 27 (Swift 6.4) seulement pour compiler.

## Installation

    curl -fsSL https://raw.githubusercontent.com/czj/archiviste/main/scripts/install.sh | zsh

Installe la dernière [version publiée](https://github.com/czj/archiviste/releases/latest) :
l'app dans `/Applications`, la commande `archiviste` dans `~/.local/bin`, puis ouvre l'app.
Relancer la même commande met à jour (`ARCHIVISTE_VERSION=1.1.0` pour une version précise).

L'app n'est pas notarisée par Apple (signature ad hoc). Ce script la télécharge avec `curl`,
qui ne la met pas en quarantaine : elle s'ouvre directement. Si vous téléchargez plutôt
`Archiviste.zip` depuis la page des versions avec un navigateur, macOS la bloque au premier
lancement : ouvrez-la une fois, puis Réglages Système › Confidentialité et sécurité ›
« Ouvrir quand même ».

### Anciennement PDF Namer

Jusqu'à la version 1.0, l'app s'appelait PDF Namer. La commande d'installation remplace
l'ancienne app et l'ancienne commande `pdf-namer`. Au premier lancement, Archiviste reprend
tout : `~/.config/pdf-namer/` devient `~/.config/archiviste/` (un lien reste à l'ancienne
place), l'historique et les préférences sont recopiés, et Archiviste s'ouvre à la connexion
si PDF Namer le faisait. Les fichiers déjà traités restent reconnus : leur marque cachée ne
change pas. macOS redemandera seulement l'autorisation des notifications.

Écrit en Swift 6.4 en mode de langage Swift 6 (concurrence vérifiée par le compilateur),
avec Approachable Concurrency : l'app et la commande vivent sur l'acteur principal, le
rendu et l'OCR passent en `@concurrent`.

## L'app de barre de menus

L'app est en français et en anglais : elle suit la langue du système (choix par app dans
Réglages Système › Général › Langue et région). Les noms de fichiers restent en français.

- Un clic sur l'icône de la barre des menus ouvre la fenêtre Archiviste : Activité
  (dépôt de fichiers, historique des renommages avec recherche, à effacer au besoin), Règles,
  Dossiers (⌘1 à ⌘3). Les préférences ont leur fenêtre Réglages (⌘,) : Général, Sauvegardes
  et ménage. Un clic droit donne un menu court : ouvrir, ranger
  maintenant, pause, quitter. Fenêtre fermée, l'app reste dans la barre des menus.
- Réglages › Général : ouverture à l'ouverture de session (`SMAppService`), icône dans la barre
  des menus (oui/non), icône dans le Dock (toujours, quand la fenêtre est ouverte, jamais).
  Tout s'applique tout de suite, sans relancer. ⌘Q demande s'il faut quitter ou laisser
  tourner en arrière-plan (sans fenêtre), sauf si on a choisi une fois pour toutes. Sans aucune icône, rouvrir l'app depuis le
  Finder, Spotlight ou Raycast affiche sa fenêtre.
- Déposez des fichiers (ou un dossier) sur l'icône ou sur la page Activité, choisissez-les
  (⌘O), ou collez-les (⌘V).
- La page **Dossiers** distingue deux sortes de dossiers surveillés ; un dossier est l'un
  ou l'autre, jamais les deux :
  - les **boîtes d'arrivée** (Téléchargements, Bureau, Scans…, clé `watchedFolders`) :
    chaque fichier qui y arrive passe par les règles, d'abord celles sur le nom, puis celles
    sur le contenu ; la première qui convient le renomme et le range. Sans règle, le modèle
    nomme les PDF et images sur place, sauf en **« Règles seulement »** (clé `rulesOnly`) :
    ce qu'aucune règle ne prend garde alors son nom, pratique pour Téléchargements ou le
    Bureau. Une notification suit : un clic montre le fichier
    dans le Finder, « Annuler » remet son nom d'origine. Une boîte d'arrivée peut
    aussi être un **relais** (« Seulement déplacer vers… », clé `moveTo`) : ce qui y arrive
    est déplacé tel quel vers un autre dossier, par exemple les scans d'une app vers le Bureau ;
  - les **classeurs** (Achats, Ventes…, clé `datedFolders`) : tout fichier posé à leur racine,
    à la main ou par une règle, part dans son sous-dossier `2026` (par année) ou `2026-11`
    (par mois). La date est celle du document, sinon celle d'un nom déjà daté, sinon celle du
    fichier. Option « Dater les noms » : préfixe `AAAA-MM-JJ - ` pour les fichiers posés à
    la main (une règle, elle, donne son propre nom). Une règle qui range dans un classeur y
    dépose directement le fichier dans le bon sous-dossier, en un seul déplacement.
- Ce qui est arrivé pendant que l'app était fermée est rattrapé à son lancement (date d'ajout
  du Finder). Un dossier qu'on vient d'ajouter part de zéro, sans reprendre les fichiers déjà là.
- **Ranger maintenant** (⇧⌘R) s'occupe des fichiers déjà là : les règles sur ceux des boîtes
  d'arrivée, le classement par date sur ceux laissés en vrac à la racine des classeurs. Un
  aperçu montre où chacun irait, « Tout ranger » (⌘↩) les range. Le modèle ne renomme rien
  pendant ce passage ; les fichiers sans règle restent en place.
- L'historique se manipule comme le Finder : Espace pour l'aperçu Quick Look, double-clic
  pour ouvrir, glisser un fichier vers une autre app, clic droit pour partager, copier le
  nom ou le chemin, ou annuler le renommage (plusieurs à la fois avec ⇧ ou ⌘).
- Tous les raccourcis figurent dans les menus (Fichier, Présentation, Renommage, Règles) ;
  pause : ⌥⌘P.
- Chaque renommage peut être modifié ou annulé. L'option « Valider avant de renommer »
  attend votre accord pour les fichiers déposés.
- Dans une boîte d'arrivée, un fichier renommé ou rangé par Archiviste n'est plus jamais repris, même si son nom n'a
  pas de date ou a été retouché à la main : une marque cachée (attribut étendu
  `com.github.czj.pdf-namer.renamed`, du nom d’avant de l’app, qui garde le nom d’origine) le signale. Le modèle ne
  renomme pas non plus les fichiers déjà nommés `AAAA-MM-JJ - …`. Un classeur, lui, range tout fichier posé à sa racine ; en direct, un nom déjà daté garde sa date (seul « Ranger maintenant », avec son aperçu, la corrige d'après le document).

## Les règles de rangement

Avant tout passage par le modèle, chaque fichier est confronté aux **règles** : d'abord
celles qui ne portent que sur le nom, puis celles qui lisent le texte, chaque groupe dans
l'ordre de la liste. La première qui correspond le renomme et le range, sans appel au
modèle. Une règle porte sur le nom du fichier (expression régulière), sur son texte (toutes
les expressions données, majuscules et accents ignorés : PDF, scans, images, fichiers
Excel), ou les deux. Elle range le fichier dans un dossier, sous un nouveau nom,
éventuellement préfixé par la date du document (lue par le modèle, sinon la date de
création du fichier). Le sous-dossier d'année ou de mois n'est pas réglé dans la règle :
c'est celui du dossier de destination quand c'est un classeur. L'éditeur de règle l'affiche
et permet de le changer, pour toutes les règles qui y rangent.

La page **Règles** de la fenêtre Archiviste (⌘2) les liste, les cherche,
les trie, les réordonne et les modifie (⌘N, ⌘D, ⌫, ⌥⌘↑/↓, Espace, ⌘Z). Le testeur (⌥⌘T, un fichier choisi par ⌥⌘O, ou
un fichier déposé sur la page) montre quelle règle prend un fichier, et ce qui manque aux
règles qui ont failli le prendre. Elles sont enregistrées dans `~/.config/archiviste/rules.json` :

```json
{
  "rules": [
    {
      "name": "Électricité",
      "filename": "^Facture_EDF_",
      "contains": [],
      "folder": "~/Documents/Factures",
      "rename": "Facture EDF",
      "datePrefix": true
    },
    {
      "name": "Hébergement",
      "contains": ["Example Hosting", "Facture"],
      "folder": "~/Documents/Factures",
      "rename": "Facture Example Hosting"
    }
  ]
}
```

`folder` vide laisse le fichier sur place, `rename` vide garde son nom. Un ancien fichier
peut porter une clé `subfolder` (`year`, `yearMonth`) : elle est toujours lue, et l'app la
transfère une fois pour toutes au classeur du dossier (`datedFolders` dans
`config.local.json`), sans changer la destination d'aucun fichier. Contrairement à `config.json`, l'app écrit ce fichier : s'il
est versionné avec chezmoi, lancez `chezmoi re-add` après l'avoir modifié dans l'app.

## La commande `archiviste`

    archiviste facture.pdf                  # affiche le nom proposé (par une règle ou le modèle)
    archiviste facture.pdf --json
    archiviste --rename *.pdf               # range par règle, sinon renomme (avec sauvegarde)
    archiviste --rename --dry-run *        # simulation ; avec des règles, tout type de fichier
    archiviste --rename --force *.pdf       # reprend aussi les fichiers déjà traités ou nommés
    archiviste --rules *.pdf                # quelle règle prend chaque fichier, et pourquoi pas les autres
    archiviste --text scan.pdf              # ce que lit le modèle : texte, dates et montants candidats
    archiviste --eval corpus/synthetique    # note le modèle sur un corpus étiqueté (voir « Qualité des noms »)

## Sauvegardes et configuration

Avant chaque renommage, l'original est copié sous `RENAME BACKUP <date> - <nom>`
dans le dossier de sauvegarde, puis supprimé au bout de 6 mois.

L'app et la commande lisent deux fichiers dans `~/.config/archiviste/` (ou
`$XDG_CONFIG_HOME/archiviste/`) :

- **`config.json`** : la configuration commune, écrite à la main, à versionner avec ses
  dotfiles (chezmoi, stow…). L'app ne la modifie jamais, donc un `chezmoi apply` n'écrase
  rien.
- **`config.local.json`** : ce qui est propre à ce Mac. La fenêtre de réglages y écrit
  seulement les réglages qui diffèrent de `config.json`. À ne pas versionner.

Les clés de `config.local.json` remplacent celles de `config.json`, une par une. L'app
recharge toute seule quand l'un des deux change. Toutes les clés sont facultatives :

```json
{
  "backupDir": "~/Documents/Archives",
  "backupMaxAgeDays": 180,
  "expireMaxAgeDays": 548,
  "watchedFolders": [
    { "path": "~/Documents/Scans", "enabled": true },
    { "path": "~/Downloads", "enabled": false }
  ],
  "confirmBeforeRename": false
}
```

| Clé | Défaut | Rôle |
|---|---|---|
| `backupDir` | `~/Documents/Archiviste/Originaux` | où sont copiés les originaux |
| `backupMaxAgeDays` | `180` | âge au-delà duquel les sauvegardes sont supprimées (`0` = jamais) |
| `expireMaxAgeDays` | `0` | met à la corbeille les **autres** fichiers du dossier de sauvegarde ajoutés depuis plus longtemps : pratique si ce dossier sert aussi de « à jeter plus tard » (`0` = jamais) |
| `watchedFolders` | `[]` | boîtes d’arrivée : règles puis modèle, règles seulement (`rulesOnly`), ou relais (`moveTo`) |
| `datedFolders` | `[]` | classeurs : `path`, `subfolder` (`year`, `yearMonth`, `none`), `datePrefix`, `enabled` |
| `confirmBeforeRename` | `false` | fichiers déposés : attendre « Renommer » |
| `myNames` | `[]` | vous et vos sociétés : le destinataire, jamais pris pour l’émetteur (Réglages › Général) |

## Qualité des noms

Le prompt se mesure sur un corpus étiqueté plutôt qu'à l'œil. `corpus/synthetique/` contient
18 documents fictifs (facture de marketplace, avoir avec le destinataire en en-tête, fiche de
paie, ordonnance, avis d'impôt avec date limite, ticket de caisse…) : leur texte et les champs
attendus sont dans `corpus.json`, les PDF en sortent par `swift tools/make_corpus.swift corpus/synthetique`.

    archiviste --eval corpus/synthetique   # chaque écart, puis le score par champ

Un corpus privé se monte de la même façon hors du dépôt (un dossier, ses fichiers et un
`corpus.json`) et se passe à la même commande. Pour qu'un score dise quelque chose, on ajuste
le prompt sur `corpus/synthetique` et on le **mesure** sur les autres, sans les relire pour
corriger : sinon ils deviennent aussi flatteurs que lui.

Un corpus public complète : 100 factures françaises fictives étiquetées
([N-Mehdi/french-invoices-synth](https://huggingface.co/datasets/N-Mehdi/french-invoices-synth),
Apache-2.0), téléchargées dans `corpus/public/` (non versionné) :

    uv run --with pyarrow --with huggingface_hub python tools/fetch_public_corpus.py
    archiviste --eval corpus/public/french-invoices-synth

## Compiler

    scripts/build-app.sh               # build release, signe ad hoc, installe dans /Applications
                                       # et la commande dans ~/.local/bin
    scripts/build-app.sh --no-install  # seulement build/Archiviste.app
    scripts/release.sh 1.1.0 notes.md  # depuis main propre : tests, build, release GitHub (tag v1.1.0)
    swift test

Xcode doit être sélectionné (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`) :
le script compile l'icône (`Resources/AppIcon.icon`, format Icon Composer à calques
Liquid Glass, modifiable dans Icon Composer) avec `actool`. On peut aussi ouvrir
`Package.swift` dans Xcode.

## Origine

Portage d'un script Python personnel. `swift test` vérifie que les règles de nommage
(casse, nettoyage, montants, dates candidates, nom final) donnent exactement les mêmes
résultats que le script sur ~2 500 cas, enregistrés dans
`Tests/ArchivisteCoreTests/Fixtures/parity.json` par `tools/gen_parity.py`.
Seul écart voulu : l'OCR Vision tourne en mode précis.

## Licence

MIT
