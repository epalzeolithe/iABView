# iABView

iABView est une application SwiftUI multiplateforme consacrée à la lecture et à l’analyse de vols. Elle synchronise les vidéos embarquées avec les données de télémétrie afin de restituer le vol sous forme de tableau de bord, de carte et de scènes 3D.

## Fonctionnalités

- lecture synchronisée des caméras avant et arrière ;
- visualisation de la trajectoire GPS sur une carte (vue satellite possible) et dans une scène 3D ;
- représentation 3D de l’attitude de l’avion (modèle USDZ texturé, ou STL à défaut) à partir des quaternions enregistrés ;
- chase cam 3D : caméra de poursuite avec avion, traînée et trajectoire GPS, lissage du GPS, incrustation et plusieurs cadrages (Dynamique, Proche, Standard, Large, Côté, Dessus) ;
- prise en charge d’un second jeu de données GPS (GPS2) avec décalage réglable ;
- affichage des instruments et de la télémétrie : altitude, vitesses, cap, vitesse verticale, accélérations et facteur de charge ;
- timeline énergétique avec zoom et navigation rapide ;
- statistiques de vol et détection de phases remarquables ;
- création, rechargement et navigation entre des favoris ;
- calibration du montage de la caméra ;
- récupération des METAR historiques de LFMT et recalcul de la vitesse indiquée ;
- création de bundles `.abv` depuis des sources brutes (macOS) : vidéos Insta360 (X4 et X6), GPX, NMEA et logs de capteurs iPhone ;
- vues détachables et enregistrement vidéo de la fenêtre (Capture REC) sur macOS ;
- interface adaptée à macOS et à l’iPhone.

## Prérequis

- Xcode 27 ou une version ultérieure ;
- macOS 27 ou iOS 27 comme cible de déploiement (macOS, iPhone et iPad ; visionOS n’est pas pris en charge) ;
- aucune dépendance tierce dans le code.

Le projet repose exclusivement sur les frameworks Apple, notamment SwiftUI, AVFoundation, MapKit et SceneKit.

Le créateur d’ABV (macOS uniquement) s’appuie sur des outils externes : `exiftool`, `ffmpeg`, `gyro2bb` et Gyroflow. Si l’un d’eux est introuvable, l’application l’indique et la création s’interrompt.

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
gps2_lat, gps2_lon, gps2_alt, gps2_speed, gps2_heading, gps2_fpm, gps2_ias,
x4_acc_x, x4_acc_y, x4_acc_z,
x4_quat_w, x4_quat_x, x4_quat_y, x4_quat_z
```

Les colonnes `gps2_*` sont facultatives : leur présence active le second GPS.

Les vidéos sont synchronisées à partir de leurs métadonnées de date de création. En leur absence, l’application utilise le début de la vidéo comme origine.

## Utilisation

1. Cliquez sur l’icône de dossier et sélectionnez un bundle `.abv`.
2. Utilisez la timeline ou les commandes de lecture pour parcourir le vol.
3. Ouvrez les vues carte, trajectoire 3D ou chase cam 3D selon vos besoins.
4. Ajoutez des favoris pour retrouver rapidement les moments importants.

### Créer un bundle `.abv` (macOS)

Le créateur d’ABV assemble un vol à partir de fichiers sources déposés dans la fenêtre : vidéos `.insv` (Insta360), traces `.gpx`, journaux NMEA (GNS3000) et fichiers `sensorlog` CSV de l’iPhone. Il convertit les vidéos avec ffmpeg et calcule l’attitude (quaternion) avec Gyroflow. Les options principales sont :

- la source des accélérations : Gyroflow (par défaut) ou gyro2bb ;
- la méthode d’intégration du gyroscope de Gyroflow ;
- l’option haute résolution, proposée pour les vidéos X6 ;
- la conservation de la vidéo convertie, la pause et l’annulation de la conversion.

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
- `Aircraft3DView.swift`, `FlightPath3DView.swift` et `ChaseCam3DView.swift` assurent les rendus 3D ;
- `AircraftModelLoader.swift` et `STLGeometryLoader.swift` chargent le modèle de l’avion (USDZ ou STL) ;
- `ABVCreator.swift` et `ABVCreatorView.swift` gèrent la création de bundles `.abv` sur macOS ;
- `METARHistoryService.swift` récupère et applique les données météo historiques ;
- `ScreenRecorder.swift` gère l’enregistrement de l’interface sur macOS.

## Contribuer

Les contributions sont les bienvenues. Créez une branche dédiée, apportez vos changements, vérifiez que le projet compile sur les plateformes concernées, puis ouvrez une pull request en décrivant clairement la modification.

## Licence

Aucune licence n’est actuellement fournie avec ce dépôt. Tous droits réservés par défaut.
