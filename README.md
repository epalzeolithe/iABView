# iABView

iABView est une application SwiftUI multiplateforme consacrée à la lecture et à l’analyse de vols. Elle synchronise les vidéos embarquées avec les données de télémétrie afin de restituer le vol sous forme de tableau de bord, de carte et de scènes 3D.

## Fonctionnalités

- lecture synchronisée des caméras avant et arrière ;
- visualisation de la trajectoire GPS sur une carte et dans une scène 3D ;
- représentation 3D de l’attitude de l’avion à partir des quaternions enregistrés ;
- affichage des instruments et de la télémétrie : altitude, vitesses, cap, vitesse verticale, accélérations et facteur de charge ;
- timeline énergétique avec zoom et navigation rapide ;
- statistiques de vol et détection de phases remarquables ;
- création, rechargement et navigation entre des favoris ;
- calibration du montage de la caméra ;
- récupération des METAR historiques de LFMT et recalcul de la vitesse indiquée ;
- vues détachables et enregistrement vidéo de la fenêtre sur macOS ;
- interface adaptée à macOS et à l’iPhone.

## Prérequis

- Xcode 27 ou une version ultérieure ;
- macOS 27 ou iOS 27 comme cible de déploiement ;
- aucune dépendance tierce.

Le projet repose exclusivement sur les frameworks Apple, notamment SwiftUI, AVFoundation, MapKit et SceneKit.

## Installation

1. Clonez le dépôt :

   ```bash
   git clone <URL-DU-DÉPÔT>
   cd iABView
   ```

2. Ouvrez `iABView.xcodeproj` dans Xcode.
3. Sélectionnez la cible `iABView`, puis un Mac ou un simulateur iPhone compatible.
4. Lancez l’application avec `⌘R`.

Si vous exécutez l’application sur un appareil physique, configurez votre équipe de signature dans l’onglet **Signing & Capabilities** de la cible.

## Format d’un vol

iABView ouvre un dossier ou un paquet portant l’extension `.abv`. Sa structure attendue est la suivante :

```text
MonVol.abv/
├── merged_data.csv        # obligatoire : télémétrie horodatée
├── front.mp4              # caméra avant
├── back.mp4               # caméra arrière, facultative
├── bookmark.csv           # favoris, facultatif
├── metar.csv              # relevés météo, facultatif
├── inverted.txt           # orientation de la caméra, généré par l’app
└── mounting_pitch.txt     # calibration du tangage, générée par l’app
```

`merged_data.csv` doit au minimum contenir une colonne `timestamp` exploitable. iABView reconnaît également les colonnes suivantes :

```text
timestamp_ms, gps_lat, gps_lon, gps_alt, gps_speed, gps_heading,
gps_fpm, gps_ias, era5_wind_speed, era5_wind_direction,
x4_acc_x, x4_acc_y, x4_acc_z,
x4_quat_w, x4_quat_x, x4_quat_y, x4_quat_z
```

Les vidéos sont synchronisées à partir de leurs métadonnées de date de création. En leur absence, l’application utilise le début de la vidéo comme origine.

## Utilisation

1. Cliquez sur l’icône de dossier et sélectionnez un bundle `.abv`.
2. Utilisez la timeline ou les commandes de lecture pour parcourir le vol.
3. Ouvrez les vues carte, trajectoire 3D ou caméra de poursuite selon vos besoins.
4. Ajoutez des favoris pour retrouver rapidement les moments importants.

Sur macOS, l’actualisation des METAR modifie `metar.csv` et recalcule `gps_ias` dans `merged_data.csv`. Une autorisation d’écriture sur le bundle peut être demandée.

## Raccourcis clavier

| Raccourci | Action |
|---|---|
| `Espace` | Lecture / Pause |
| `←` / `→` | Reculer / avancer de 10 secondes |
| `⇧←` / `⇧→` | Reculer / avancer de 2 secondes |
| `⌃←` / `⌃→` | Favori précédent / suivant |
| `⌃B` | Ajouter un favori |
| `⌃R` | Recharger `bookmark.csv` |
| `Z` | Activer ou désactiver le zoom de la timeline |
| `I` | Inverser le montage de la caméra |
| `M` | Couper ou réactiver le son |
| `⌃W` | Fermer la fenêtre |

## Structure du projet

- `ContentView.swift` compose l’espace de travail principal ;
- `FlightViewModel.swift` gère la lecture, la synchronisation et l’état du vol ;
- `FlightModels.swift` définit les modèles et charge les fichiers CSV ;
- `Aircraft3DView.swift` et `FlightPath3DView.swift` assurent les rendus 3D ;
- `METARHistoryService.swift` récupère et applique les données météo historiques ;
- `ScreenRecorder.swift` gère l’enregistrement de l’interface sur macOS.

## Contribuer

Les contributions sont les bienvenues. Créez une branche dédiée, apportez vos changements, vérifiez que le projet compile sur les plateformes concernées, puis ouvrez une pull request en décrivant clairement la modification.

## Licence

Aucune licence n’est actuellement fournie avec ce dépôt. Tous droits réservés par défaut.
