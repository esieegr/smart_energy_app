# Smart Energy App — Documentation complète

> **De débutant à expert** : tout ce qu'il faut savoir pour comprendre, utiliser et modifier l'application.

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Architecture générale](#2-architecture-générale)
3. [Stack technique et dépendances](#3-stack-technique-et-dépendances)
4. [Protocole MQTT et Domoticz](#4-protocole-mqtt-et-domoticz)
5. [Structure des fichiers](#5-structure-des-fichiers)
6. [Modèles de données](#6-modèles-de-données)
   - [DomoticzMessage](#61-domoticzmessage)
   - [EnergyHistory / EnergyPoint](#62-energyhistory--energypoint)
7. [Service MQTT (MqttService)](#7-service-mqtt-mqttservice)
   - [État interne](#71-état-interne)
   - [Cycle de vie de la connexion](#72-cycle-de-vie-de-la-connexion)
   - [Réception des messages](#73-réception-des-messages)
   - [Mapping compteur → switch](#74-mapping-compteur--switch)
   - [Persistance (SharedPreferences)](#75-persistance-sharedpreferences)
   - [Commandes publiées vers Domoticz](#76-commandes-publiées-vers-domoticz)
   - [Découverte automatique des switchs](#77-découverte-automatique-des-switchs)
8. [Point d'entrée (main.dart)](#8-point-dentrée-maindart)
9. [Écrans](#9-écrans)
   - [DashboardScreen](#91-dashboardscreen)
   - [DeviceDetailScreen](#92-devicedetailscreen)
   - [SettingsScreen](#93-settingsscreen)
10. [Dialog d'association switch](#10-dialog-dassociation-switch-switch_config_dialogdart)
11. [Gestion de l'état avec ChangeNotifier](#11-gestion-de-létat-avec-changenotifier)
12. [Flux de données complet (bout en bout)](#12-flux-de-données-complet-bout-en-bout)
13. [Scénarios d'utilisation pas à pas](#13-scénarios-dutilisation-pas-à-pas)
14. [Ajouter un appareil ou une fonctionnalité](#14-ajouter-un-appareil-ou-une-fonctionnalité)
15. [Dépannage et logs de debug](#15-dépannage-et-logs-de-debug)
16. [Référence des clés SharedPreferences](#16-référence-des-clés-sharedpreferences)
17. [Référence des topics MQTT](#17-référence-des-topics-mqtt)

---

## 1. Vue d'ensemble

Smart Energy App est une application **Flutter** qui surveille en temps réel la consommation électrique d'appareils pilotés via **Domoticz** (domotique open-source) en passant **exclusivement par le protocole MQTT**.

**Fonctionnalités principales :**
- Connexion à un broker MQTT (Mosquitto ou autre) configurable
- Réception en temps réel des données des compteurs kWh (puissance instantanée + énergie totale)
- Contrôle On/Off des prises intelligentes (switches Domoticz) via MQTT
- Histogramme de consommation (50 dernières mesures par appareil)
- Association manuelle ou automatique compteur ↔ switch (sans HTTP, sans auth)
- Persistance de tous les paramètres entre les sessions

**Contrainte fondamentale :** tout passe par MQTT. Aucun appel HTTP n'est effectué.

---

## 2. Architecture générale

```
┌─────────────────────────────────────────────────────┐
│                   Flutter App                       │
│                                                     │
│  main.dart                                          │
│    └── SmartEnergyApp (MaterialApp)                 │
│          └── DashboardScreen                        │
│                ├── _KwhMeterCard  ──► DeviceDetail  │
│                ├── _QuickSwitch   ──► SwitchDialog  │
│                └── _NotConnected  ──► Settings      │
│                                                     │
│  MqttService (ChangeNotifier)                       │
│    ├── _messages        Map<int, DomoticzMessage>   │
│    ├── _histories       Map<int, EnergyHistory>     │
│    ├── _switchStates    Map<int, bool>              │
│    ├── _meterToSwitch   Map<int, int>  (prefs)      │
│    └── _discoveredSwitches Map<int, DomoticzMessage>│
└───────────────┬─────────────────────────────────────┘
                │  MQTT (TCP port 1883)
                ▼
┌───────────────────────────┐
│   Broker Mosquitto        │
│   172.20.210.173:1883     │
└───────────────┬───────────┘
                │
                ▼
┌───────────────────────────┐
│   Domoticz                │
│   topics:                 │
│   • domoticz/out  (push)  │
│   • domoticz/in   (cmds)  │
│                           │
│   idx=11  kWh Meter       │
│   idx=7   Prise Switch    │
└───────────────────────────┘
```

L'application n'a **pas de backend propre**. Elle est un client MQTT pur.

---

## 3. Stack technique et dépendances

| Package | Version | Rôle |
|---|---|---|
| `flutter` | SDK ^3.11.1 | Framework UI multiplateforme |
| `mqtt_client` | ^10.1.0 | Client MQTT (MqttServerClient) |
| `shared_preferences` | ^2.3.0 | Persistance locale clé/valeur |
| `fl_chart` | ^0.70.2 | Histogramme de consommation (BarChart) |

**`pubspec.yaml` (section dependencies) :**
```yaml
dependencies:
  flutter:
    sdk: flutter
  mqtt_client: ^10.1.0
  shared_preferences: ^2.3.0
  fl_chart: ^0.70.2
```

---

## 4. Protocole MQTT et Domoticz

### Qu'est-ce que MQTT ?

MQTT (Message Queuing Telemetry Transport) est un protocole publish/subscribe léger. Un **broker** (ici Mosquitto) centralise les messages. Les clients s'**abonnent** à des *topics* ou y **publient** des messages.

### Topics utilisés

| Topic | Direction | Contenu |
|---|---|---|
| `domoticz/out` | Domoticz → App | État de chaque appareil (JSON) |
| `domoticz/in` | App → Domoticz | Commandes de contrôle (JSON) |

### Format des messages `domoticz/out`

Chaque fois qu'un appareil change d'état, Domoticz publie un JSON sur `domoticz/out` :

```json
{
  "Battery"    : 255,
  "LastUpdate" : "2026-03-17 10:28:37",
  "RSSI"       : 12,
  "description": "",
  "dtype"      : "General",
  "hwid"       : "2",
  "id"         : "00014C4A",
  "idx"        : 11,
  "name"       : "kWh Meter",
  "nvalue"     : 0,
  "org_hwid"   : "2",
  "stype"      : "kWh",
  "svalue1"    : "68.600",
  "svalue2"    : "200.0",
  "unit"       : 1
}
```

Pour un switch (prise intelligente) :
```json
{
  "dtype"  : "Light/Switch",
  "stype"  : "Switch",
  "idx"    : 7,
  "name"   : "Switch Prise Intelligente",
  "nvalue" : 1,
  "svalue1": "0",
  "svalue2": "0"
}
```

> **Règle de détection** :
> - `stype == "kWh"` → compteur d'énergie
> - `dtype == "Light/Switch"` → switch contrôlable
> - `nvalue == 1` → switch allumé (On)

### Limitation importante de Domoticz

Domoticz ne publie sur `domoticz/out` **que lors d'un changement d'état**. Si l'app démarre et que le switch n'a pas bougé récemment, son état n'est pas connu. Solution : publier `getdeviceinfo` pour forcer Domoticz à répondre.

---

## 5. Structure des fichiers

```
lib/
├── main.dart                         # Point d'entrée, MaterialApp, auto-connect
├── models/
│   ├── domoticz_message.dart         # Désérialisation JSON du payload MQTT
│   └── energy_history.dart           # Buffer circulaire de 50 mesures
├── services/
│   └── mqtt_service.dart             # Toute la logique MQTT + état global
└── screens/
    ├── dashboard_screen.dart         # Tableau de bord principal
    ├── device_detail_screen.dart     # Détail + graphique + switch card
    ├── settings_screen.dart          # Configuration IP/port
    └── switch_config_dialog.dart     # Dialog d'association compteur ↔ switch
```

---

## 6. Modèles de données

### 6.1 DomoticzMessage

**Fichier :** `lib/models/domoticz_message.dart`

Représente un message reçu sur `domoticz/out`. C'est un objet **immuable** (`const` constructor).

```dart
class DomoticzMessage {
  final int    battery;      // niveau batterie (255 = secteur)
  final String lastUpdate;   // "2026-03-17 10:28:37"
  final int    rssi;         // force du signal radio (0–12)
  final String description;
  final String dtype;        // "General", "Light/Switch", "Usage"...
  final String hwid;         // identifiant du hardware dans Domoticz
  final String id;           // identifiant matériel hexadécimal
  final int    idx;          // identifiant unique de l'appareil dans Domoticz
  final String name;         // nom affiché
  final int    nvalue;       // valeur numérique brute (1 = On pour switch)
  final String orgHwid;
  final String stype;        // sous-type : "kWh", "Switch", "Electric"...
  final String svalue1;      // valeur 1 : énergie totale en Wh (kWh meter)
  final String svalue2;      // valeur 2 : puissance instantanée en W (kWh meter)
  final int    unit;
```

**Getters calculés :**

```dart
double get energyWh   => double.tryParse(svalue1) ?? 0.0;
double get powerWatts => double.tryParse(svalue2) ?? 0.0;
bool   get isKwhMeter => stype == 'kWh';
bool   get isSwitch   => dtype == 'Light/Switch';
bool   get isSwitchOn => nvalue == 1;
```

**Parsing JSON :**

```dart
// Tente de parser une string JSON, retourne null si échec
static DomoticzMessage? tryParse(String payload) {
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    return DomoticzMessage.fromJson(map);
  } catch (_) {
    return null;
  }
}
```

`tryParse` est appelé pour **chaque message MQTT reçu**. Si le payload n'est pas du JSON valide (ou ne correspond pas au format attendu), il retourne `null` et le message est silencieusement ignoré.

---

### 6.2 EnergyHistory / EnergyPoint

**Fichier :** `lib/models/energy_history.dart`

Buffer circulaire qui conserve les **50 dernières mesures** d'un appareil pour l'affichage du graphique.

```dart
class EnergyPoint {
  final DateTime time;        // horodatage de la réception (heure locale)
  final double   powerWatts;  // puissance au moment de la mesure
  final double   energyWh;    // énergie cumulée au moment de la mesure
}

class EnergyHistory {
  static const int maxPoints = 50;  // taille du buffer

  void add(double powerWatts, double energyWh) {
    _points.add(EnergyPoint(time: DateTime.now(), ...));
    if (_points.length > maxPoints) {
      _points.removeAt(0);  // supprime le plus ancien
    }
  }

  double get maxEnergy => ...;  // max des energyWh → borne haute du graphique
  double get minEnergy => ...;  // min des energyWh → borne basse
  double get maxPower  => ...;  // max des powerWatts
}
```

> **Note :** L'historique est **en mémoire uniquement**. Il est perdu à chaque redémarrage de l'app. Pour une persistance longue durée, il faudrait écrire dans un fichier ou une base de données locale (ex: `sqflite`, `hive`).

---

## 7. Service MQTT (MqttService)

**Fichier :** `lib/services/mqtt_service.dart`

C'est le **cœur de l'application**. Il étend `ChangeNotifier` (pattern Observer de Flutter), ce qui permet à tous les widgets qui l'écoutent de se reconstruire automatiquement quand l'état change.

### 7.1 État interne

```dart
class MqttService extends ChangeNotifier {
  static const String _topicOut = 'domoticz/out';
  static const String _topicIn  = 'domoticz/in';
  static const int _defaultPort = 1883;

  MqttServerClient? _client;  // null = non connecté

  // ── Connexion ──────────────────────────────────────────────────────────
  String _brokerIp  = '';
  int    _port      = _defaultPort;
  MqttConnectionStatus _status      = MqttConnectionStatus.disconnected;
  String               _statusMessage = 'Non connecté';

  // ── Données reçues ─────────────────────────────────────────────────────
  final Map<int, DomoticzMessage> _messages  = {};
  // Clé = idx Domoticz, valeur = dernier message reçu pour cet appareil

  final Map<int, EnergyHistory>   _histories = {};
  // Clé = idx, valeur = buffer des 50 dernières mesures (seulement kWh meters)

  // ── État des switchs ───────────────────────────────────────────────────
  final Map<int, bool> _switchStates = {};
  // Clé = idx du SWITCH (pas du compteur), valeur = true=On

  // ── Mapping compteur ↔ switch ──────────────────────────────────────────
  final Map<int, int> _meterToSwitch = {};
  // Clé = idx du compteur kWh, valeur = idx du switch associé
  // Exemple : {11: 7}  →  compteur idx=11 est contrôlé par switch idx=7
  // Persisté dans SharedPreferences sous la clé 'meter_switch_map'

  // ── Découverte automatique ─────────────────────────────────────────────
  final Map<int, DomoticzMessage> _discoveredSwitches = {};
  // Tous les appareils isSwitch=true vus sur domoticz/out
  // Alimenté automatiquement à chaque message reçu
```

**Getters publics (lecture seule) :**

```dart
String               get brokerIp          => _brokerIp;
int                  get port              => _port;
MqttConnectionStatus get status            => _status;
String               get statusMessage     => _statusMessage;
Map<int, DomoticzMessage> get messages     => Map.unmodifiable(_messages);
Map<int, EnergyHistory>   get histories    => Map.unmodifiable(_histories);
Map<int, bool>            get switchStates => Map.unmodifiable(_switchStates);
Map<int, DomoticzMessage> get discoveredSwitches => Map.unmodifiable(_discoveredSwitches);

int?             switchIdxForMeter(int meterIdx) => _meterToSwitch[meterIdx];
DomoticzMessage? switchForMeter(int meterIdx)    { ... }
```

> **`Map.unmodifiable`** : Les widgets reçoivent une vue en lecture seule des maps. Toute tentative de modification depuis l'extérieur lève une exception. Seul le service lui-même peut modifier son état.

---

### 7.2 Cycle de vie de la connexion

```dart
Future<void> connect(String ip, {int port = 1883}) async {
```

**Étapes à la connexion :**

1. **Guard** : si déjà en train de se connecter, on ignore l'appel (évite les doubles connexions)
2. **Reset** : déconnecte le client précédent proprement (supprime le callback `onDisconnected` avant pour éviter un faux event)
3. **Chargement du mapping** : `_loadPersistedMeterSwitchMap()` recharge depuis prefs le mapping compteur→switch sauvegardé lors d'une session précédente
4. **Création du client** :
   ```dart
   _client = MqttServerClient.withPort(ip, 'flutter_smart_energy', port)
     ..keepAlivePeriod = 30         // ping toutes les 30s pour maintenir la connexion
     ..connectTimeoutPeriod = 5000  // timeout 5s
     ..onDisconnected = _onDisconnected
     ..onConnected    = _onConnected
     ..onSubscribed   = _onSubscribed;
   ```
5. **Identifiant unique** : `smart_energy_{timestamp}` pour éviter les conflits si plusieurs instances tournent
6. **`startClean()`** : sessions propres, pas de messages en file d'attente
7. **Connexion TCP** : `await _client!.connect()` (bloquant, max 5s)
8. **Si connecté** :
   - S'abonne à `domoticz/out`
   - Lance l'écoute des messages : `_client!.updates!.listen(_onMessage)`
   - Pour chaque switch du mapping connu, publie `getdeviceinfo` pour obtenir l'état actuel
9. **Si échec** : met le statut en erreur avec le code de retour MQTT

**Déconnexion :**
```dart
Future<void> disconnect() async {
  _client?.onDisconnected = null;  // empêche le callback de changer le statut
  _client?.disconnect();
  _client = null;
  _setStatus(MqttConnectionStatus.disconnected, 'Non connecté');
}
```

---

### 7.3 Réception des messages

```dart
void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
  for (final event in events) {
    final publish = event.payload as MqttPublishMessage;
    final payload = MqttPublishPayload.bytesToStringAsString(
      publish.payload.message,
    );
    final msg = DomoticzMessage.tryParse(payload);
    if (msg != null) {
      _messages[msg.idx] = msg;         // stocke/écrase le dernier message

      if (msg.isKwhMeter) {
        // putIfAbsent : crée l'historique seulement si c'est la première fois
        _histories.putIfAbsent(msg.idx, () => EnergyHistory(msg.idx))
            .add(msg.powerWatts, msg.energyWh);
      }

      if (msg.isSwitch) {
        _switchStates[msg.idx]       = msg.isSwitchOn;  // met à jour l'état
        _discoveredSwitches[msg.idx] = msg;              // auto-découverte
      }

      notifyListeners();  // 🔔 notifie tous les widgets abonnés
    }
  }
}
```

> **`putIfAbsent`** : évite d'écraser un `EnergyHistory` existant lors d'un nouveau message. Sans ça, l'historique serait réinitialisé à chaque message du compteur.

> **`notifyListeners()`** : déclenche la reconstruction de **tous** les `ListenableBuilder` qui observent ce service. C'est le mécanisme central de réactivité de l'app.

---

### 7.4 Mapping compteur → switch

Le problème fondamental : un compteur kWh (idx=11) et le switch qui le contrôle (idx=7) sont **deux appareils distincts dans Domoticz**. L'app doit savoir lequel correspond à l'autre.

```dart
// Lecture du mapping
int? switchIdxForMeter(int meterIdx) => _meterToSwitch[meterIdx];
// Exemple : switchIdxForMeter(11) → 7
```

**Enregistrement d'une association :**
```dart
Future<void> setMeterSwitchMapping(int meterIdx, int switchIdx) async {
  _meterToSwitch[meterIdx] = switchIdx;   // {11: 7}
  await _persistMeterSwitchMap();          // sauvegarde en prefs
  _requestDeviceInfo(switchIdx);           // demande l'état actuel du switch
  notifyListeners();
}
```

---

### 7.5 Persistance (SharedPreferences)

Le mapping est sérialisé en JSON et stocké sous la clé `meter_switch_map`.

```dart
// Sauvegarde
Future<void> _persistMeterSwitchMap() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'meter_switch_map',
    jsonEncode(_meterToSwitch.map((k, v) => MapEntry(k.toString(), v)))
    // {11: 7} → '{"11":7}'
    // Les clés JSON sont toujours des strings, donc int → string.toString()
  );
}

// Chargement
Future<void> _loadPersistedMeterSwitchMap() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('meter_switch_map') ?? '';
  if (raw.isEmpty) return;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  // Reconvertit les clés string en int
  decoded.forEach((k, v) {
    final meterIdx = int.tryParse(k);            // "11" → 11
    final swIdx    = v is int ? v : int.tryParse(v.toString());
    if (meterIdx != null && swIdx != null) {
      _meterToSwitch[meterIdx] = swIdx;
    }
  });
}
```

> **Pourquoi JSON ?** `SharedPreferences` ne supporte pas les `Map` directement. On sérialise en String JSON, qui est un type primitif supporté.

---

### 7.6 Commandes publiées vers Domoticz

**Contrôler un switch :**
```dart
void publishSwitch(int idx, {required bool on}) {
  final command = jsonEncode({
    'command'  : 'switchlight',
    'idx'      : idx,          // doit être l'idx du SWITCH, pas du compteur !
    'switchcmd': on ? 'On' : 'Off',
  });
  final builder = MqttClientPayloadBuilder()..addString(command);
  _client!.publishMessage(_topicIn, MqttQos.atMostOnce, builder.payload!);

  // Mise à jour optimiste : on n'attend pas la confirmation de Domoticz
  _switchStates[idx] = on;
  notifyListeners();
}
```

La mise à jour **optimiste** fait que le switch UI se met à jour immédiatement. Quelques millisecondes plus tard, Domoticz publie la confirmation sur `domoticz/out`, ce qui confirme (ou corrige) l'état.

**Demander l'état actuel d'un appareil :**
```dart
void _requestDeviceInfo(int idx) {
  final cmd = jsonEncode({'command': 'getdeviceinfo', 'idx': idx});
  final builder = MqttClientPayloadBuilder()..addString(cmd);
  _client!.publishMessage(_topicIn, MqttQos.atMostOnce, builder.payload!);
}
// Domoticz répond sur domoticz/out avec le JSON complet de l'appareil
```

---

### 7.7 Découverte automatique des switchs

**Passage en direct :** tout message `isSwitch=true` reçu est automatiquement mémorisé dans `_discoveredSwitches`. Cela alimente la liste du dialog d'association sans aucune configuration.

**Scan actif :**
```dart
void scanSwitches({int from = 1, int to = 40}) {
  for (var i = from; i <= to; i++) {
    _requestDeviceInfo(i);
  }
}
```
Envoie `getdeviceinfo` pour tous les idx de 1 à 40. Domoticz répond uniquement pour les idx existants. Les appareils de type switch qui répondent sont automatiquement ajoutés à `_discoveredSwitches` via `_onMessage`.

---

## 8. Point d'entrée (main.dart)

```dart
void main() {
  runApp(const SmartEnergyApp());
}

class _SmartEnergyAppState extends State<SmartEnergyApp> {
  final MqttService _mqttService = MqttService();
  // Le service est créé ici, au plus haut niveau, et passé en prop à tous les écrans.
  // Il n'y a pas d'injection de dépendances (Provider, Riverpod...) — passage manuel.

  @override
  void initState() {
    super.initState();
    _autoConnect();  // reconnexion automatique au démarrage
  }

  Future<void> _autoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final ip   = prefs.getString('mqtt_broker_ip') ?? '';
    final port = prefs.getInt('mqtt_broker_port')  ?? 1883;
    if (ip.isNotEmpty) {
      await _mqttService.connect(ip, port: port);
      // Ce connect() va aussi charger le mapping meter→switch depuis prefs
      // et envoyer getdeviceinfo pour tous les switchs connus.
    }
  }

  @override
  void dispose() {
    _mqttService.dispose();  // déconnecte proprement à la fermeture de l'app
    super.dispose();
  }
}
```

**Thème :** Material 3, dark mode automatique selon le système, couleur primaire `#1565C0` (bleu foncé).

---

## 9. Écrans

### 9.1 DashboardScreen

**Fichier :** `lib/screens/dashboard_screen.dart`

C'est l'écran principal. Il s'actualise automatiquement via `ListenableBuilder(listenable: mqttService, ...)`.

**Logique d'affichage :**

```dart
// 1. Sépare les compteurs kWh des autres appareils
final kwhMessages = messages.values.where((m) => m.isKwhMeter).toList();

// 2. Calcule les idx de switchs déjà associés à un compteur
final associatedSwitchIdxs = kwhMessages
    .map((m) => mqttService.switchIdxForMeter(m.idx))
    .whereType<int>()  // filtre les null
    .toSet();

// 3. Les "autres" excluent les switchs déjà liés à un compteur
//    (évite l'affichage en double : switch affiché dans la card kWh ET dans "autres")
final otherMessages = messages.values
    .where((m) => !m.isKwhMeter && !associatedSwitchIdxs.contains(m.idx))
    .toList();
```

**Widgets internes :**

| Widget | Rôle |
|---|---|
| `_KwhMeterCard` | Carte principale d'un compteur kWh : nom, idx, énergie, puissance, RSSI, switch rapide |
| `_QuickSwitch` | Toggle On/Off affiché sur la carte. Gère : non-configuré (icône grise), configuré (switch + bouton ✏ de reconfig) |
| `_GenericSensorCard` | Carte simple pour les appareils non-kWh : nom, type, valeurs brutes |
| `_MetricTile` | Tuile colorée avec icône + valeur + label (énergie / puissance) |
| `_RssiChip` | Badge RSSI |
| `_NotConnectedPlaceholder` | Écran vide avec bouton "Configurer" quand non connecté |
| `_SectionHeader` | Titre de section ("Compteurs d'énergie", "Autres capteurs") |

**`_QuickSwitch` en détail :**

```dart
// Cas 1 : switch pas encore configuré pour ce compteur
if (!configured)
  IconButton(
    icon: Icon(Icons.power_settings_new_outlined, color: Colors.grey),
    onPressed: connected
        ? () => showSwitchConfigDialog(context, meterIdx, meterName, mqttService)
        : null,
  )

// Cas 2 : switch configuré → affiche le toggle + bouton ✏ de reconfig
else ...[
  Icon(isOn ? Colors.green : Colors.grey),
  GestureDetector(
    onTap: () {},  // absorbe le tap pour ne pas déclencher la navigation de la card
    child: Switch.adaptive(
      value: isOn,
      onChanged: connected ? (val) => mqttService.publishSwitch(switchIdx!, on: val) : null,
    ),
  ),
  IconButton(Icons.edit_outlined, onPressed: () => showSwitchConfigDialog(...)),
]
```

> **`GestureDetector` avec `onTap: () {}`** : La `_KwhMeterCard` est enveloppée dans un `InkWell` qui navigue vers `DeviceDetailScreen`. Sans ce `GestureDetector` absorbeur, un tap sur le switch déclencherait aussi la navigation. Le `GestureDetector` "consomme" l'événement tactile avant qu'il n'arrive au `InkWell` parent.

---

### 9.2 DeviceDetailScreen

**Fichier :** `lib/screens/device_detail_screen.dart`

Écran de détail ouvert en tapant sur une `_KwhMeterCard`. Reçoit l'`idx` du compteur et le `mqttService`.

**Contenu :**

| Widget | Contenu |
|---|---|
| `_InfoCard` | Tableau des métadonnées : type, idx, ID matériel, énergie, puissance, date MAJ, RSSI |
| `_SwitchCard` | Carte de contrôle On/Off. Adapte son apparence selon l'état de configuration |
| `_PowerChart` | Histogramme en barres des 50 dernières mesures (fl_chart BarChart) |
| `_HistoryTable` | Tableau texte des mesures, plus récent en premier |

**`_SwitchCard` — comportement selon la configuration :**

- **Non configuré** : icône grise + bouton `FilledButton.tonal("Associer")` qui ouvre le dialog
- **Configuré** : affiche le nom du switch, état On/Off coloré, Switch.adaptive, bouton ✏ pour reconfigurer

**`_PowerChart` — calcul des axes :**

```dart
final span     = (maxE - minE).clamp(1.0, double.infinity);
final chartMax = maxE + span * 0.15;  // 15% de marge haute
final chartMin = (minE - span * 0.10).clamp(0.0, double.infinity);  // 10% de marge basse, min=0
```

Cela évite que le graphique soit "collé" aux valeurs. La largeur des barres est calculée dynamiquement selon le nombre de points :
```dart
width: (260 / points.length.clamp(1, 50)).clamp(3, 18)
// Entre 3px (50 points) et 18px (peu de points)
```

---

### 9.3 SettingsScreen

**Fichier :** `lib/screens/settings_screen.dart`

Deux champs uniquement : **IP du broker** et **port MQTT**. L'association switch est intentionnellement retirée de cet écran — elle se fait depuis le dashboard directement sur chaque compteur.

**Clés SharedPreferences gérées ici :**
- `mqtt_broker_ip` (String)
- `mqtt_broker_port` (int)

**Indicateur de statut en bas :**
```dart
ListenableBuilder(
  listenable: widget.mqttService,
  builder: (context, _) {
    // Affiche une icône colorée + texte selon MqttConnectionStatus
    // Se met à jour en temps réel pendant la tentative de connexion
  },
),
```

---

## 10. Dialog d'association switch (`switch_config_dialog.dart`)

Appelé via la fonction top-level :
```dart
Future<void> showSwitchConfigDialog({
  required BuildContext context,
  required int meterIdx,        // idx du compteur à associer
  required String meterName,    // nom affiché dans le titre
  required MqttService mqttService,
}) { ... }
```

**Le dialog contient trois zones :**

### Zone 1 : Switchs auto-détectés

Liste tous les appareils `isSwitch=true` déjà vus dans `_discoveredSwitches`. Mise à jour en temps réel via `ListenableBuilder`.

Chaque `_SwitchTile` affiche :
- Icône power (vert=On, gris=Off)
- Nom + idx + dtype/stype
- Badge ⚠ orange si ce switch est déjà associé à **un autre** compteur

```dart
// Calcul des switchs utilisés ailleurs
final usedElsewhere = <int>{};
mqttService.messages.values
    .where((m) => m.isKwhMeter && m.idx != widget.meterIdx)
    .forEach((m) {
  final sw = mqttService.switchIdxForMeter(m.idx);
  if (sw != null) usedElsewhere.add(sw);
});
```

### Zone 2 : Bouton Scanner

```dart
Future<void> _scan() async {
  setState(() => _scanning = true);
  widget.mqttService.scanSwitches(from: 1, to: 40);
  await Future.delayed(const Duration(seconds: 2));  // attend les réponses
  if (mounted) setState(() => _scanning = false);
}
```

Envoie `getdeviceinfo` pour idx 1 à 40. Domoticz répond uniquement pour les idx existants. Après 2 secondes, la liste se rafraîchit automatiquement (le `ListenableBuilder` réagit aux `notifyListeners()` du service).

### Zone 3 : Saisie manuelle

Si l'utilisateur connaît l'idx (visible dans Domoticz → Appareils), il peut le taper directement. La saisie manuelle prend le dessus sur la sélection dans la liste.

**Confirmation :**
```dart
Future<void> _confirm() async {
  final swIdx = int.tryParse(_manualController.text) ?? _selectedIdx;
  if (swIdx == null || swIdx <= 0) { /* erreur */ return; }
  await widget.mqttService.setMeterSwitchMapping(widget.meterIdx, swIdx);
  // → persiste en prefs + envoie getdeviceinfo pour l'état réel
  Navigator.of(context).pop();
}
```

---

## 11. Gestion de l'état avec ChangeNotifier

L'app utilise le pattern `ChangeNotifier` + `ListenableBuilder` de Flutter sans package externe.

```
MqttService extends ChangeNotifier
    │
    │  notifyListeners()   ← appelé à chaque changement d'état
    │
    ▼
ListenableBuilder(listenable: mqttService, builder: (ctx, _) { ... })
    │
    └── se reconstruit automatiquement à chaque notifyListeners()
```

**Quand `notifyListeners()` est-il appelé ?**
- Réception d'un message MQTT (nouveau ou mis à jour)
- Changement de statut de connexion (connecting → connected → disconnected)
- Mise à jour du mapping meter→switch (setMeterSwitchMapping)
- Mise à jour optimiste de l'état d'un switch après `publishSwitch`

---

## 12. Flux de données complet (bout en bout)

### Réception d'une mesure kWh

```
Capteur physique (prise Zigbee/Z-Wave)
    │  envoie données à Domoticz
    ▼
Domoticz (idx=11, kWh Meter)
    │  publie sur domoticz/out
    ▼
Broker Mosquitto
    │  distribue aux abonnés
    ▼
MqttService._onMessage()
    │  DomoticzMessage.tryParse(payload) → isKwhMeter=true
    │  _messages[11] = msg
    │  _histories[11].add(200.0, 68.6)
    │  notifyListeners()
    ▼
Tous les ListenableBuilder se reconstruisent
    ├── _KwhMeterCard affiche "68.600 Wh / 200.0 W"
    └── _PowerChart ajoute une barre (si écran détail ouvert)
```

### Commande On/Off

```
Utilisateur tape le Switch (UI)
    │
    ▼
mqttService.publishSwitch(7, on: true)
    │  publie {"command":"switchlight","idx":7,"switchcmd":"On"}
    │  vers domoticz/in
    │  mise à jour optimiste: _switchStates[7] = true
    │  notifyListeners()
    ▼
Switch UI passe à ON (immédiatement, <16ms)
    │
    ▼  (quelques ms plus tard via réseau)
Domoticz exécute la commande physique
    │  publie confirmation sur domoticz/out
    │  {"idx":7,"nvalue":1,...}
    ▼
MqttService._onMessage()
    │  isSwitch=true, isSwitchOn=true
    │  _switchStates[7] = true  (confirmation)
    │  notifyListeners()
    ▼
Switch UI confirme l'état ON (identique, pas de flash)
```

### Premier démarrage (switch non connu)

```
App démarre
    │  _autoConnect() → connect(ip, port)
    │  _loadPersistedMeterSwitchMap() → {} vide (première fois)
    │
    ▼
Domoticz publie kWh Meter sur domoticz/out (idx=11)
    │  Dashboard affiche la carte avec icône switch grise ⏻
    │
Utilisateur tape l'icône switch grise
    │
    ▼
showSwitchConfigDialog(meterIdx=11, ...)
    │  Liste vide (aucun switch vu jusqu'ici)
    │
Utilisateur clique "Scanner"
    │  scanSwitches(1→40) : 40 × getdeviceinfo
    │  Domoticz répond pour idx=7 (Switch Prise Intelligente)
    │  _discoveredSwitches[7] = msg
    │  notifyListeners() → liste du dialog se rafraîchit en temps réel
    │
Utilisateur sélectionne idx=7 → clique "Associer"
    │
    ▼
setMeterSwitchMapping(11, 7)
    │  _meterToSwitch = {11: 7}
    │  sauvegarde en prefs → '{"11":7}'
    │  _requestDeviceInfo(7) → Domoticz envoie l'état réel du switch
    │
    ▼
_onMessage() reçoit état switch idx=7 (nvalue=1 = On)
    │  _switchStates[7] = true
    │  notifyListeners()
    ▼
Dashboard: switch passe immédiatement à l'état réel (vert = On)
Deuxième démarrage: le mapping {11:7} est rechargé depuis prefs,
getdeviceinfo est envoyé automatiquement → état correct dès la connexion
```

---

## 13. Scénarios d'utilisation pas à pas

### Première configuration

1. Lancer l'app → écran "Non connecté"
2. Appuyer sur **Connecter** (FAB) → écran Paramètres
3. Saisir l'IP du broker MQTT (ex : `172.20.210.173`) et le port (`1883`)
4. Appuyer sur **Connecter** → l'indicateur passe à orange puis vert
5. Les données arrivent en quelques secondes

### Associer un switch à un compteur (première fois)

1. Dans le dashboard, repérer une carte kWh avec une icône **⏻ grise**
2. Appuyer sur cette icône → dialog "Associer un switch"
3. **Option A** : Si le switch est déjà visible dans la liste (car il a bougé récemment) → le sélectionner
4. **Option B** : Appuyer sur **Scanner** → attendre 2s → choisir dans la liste
5. **Option C** : Taper l'idx directement (trouvable dans Domoticz → Paramètres → Appareils)
6. Appuyer sur **Associer** → l'état réel est immédiatement récupéré et affiché

### Contrôler la prise

- **Dashboard** : switch On/Off à droite de la carte (tap direct)
- **Écran détail** : grande `_SwitchCard` avec Switch.adaptive

### Voir l'historique de consommation

1. Taper sur une carte kWh → `DeviceDetailScreen`
2. Laisser tourner l'app : chaque message MQTT ajoute une barre
3. 50 barres max, les plus anciennes disparaissent automatiquement
4. Taper sur une barre → tooltip avec heure exacte + valeur en Wh

### Reconfigurer un switch (changer l'association)

- **Dashboard** : appuyer sur le bouton **✏** à droite du switch
- **Écran détail** : appuyer sur le **✏** à côté du nom du switch
- → même dialog, avec la sélection actuelle pré-remplie

---

## 14. Ajouter un appareil ou une fonctionnalité

### Nouveau type d'appareil (ex : capteur de température)

1. Dans `DomoticzMessage`, ajouter un getter :
   ```dart
   bool   get isTemperature => dtype == 'Temp';
   double get temperature   => double.tryParse(svalue1) ?? 0.0;
   ```

2. Dans `MqttService._onMessage`, ajouter un bloc :
   ```dart
   if (msg.isTemperature) {
     // stocker dans une map dédiée, notifier
   }
   ```

3. Dans `DashboardScreen`, ajouter une section avec un widget dédié (comme `_GenericSensorCard` mais typé température).

### Persistance longue durée de l'historique

Remplacer la liste en mémoire de `EnergyHistory` par une base de données locale :
- **`sqflite`** : SQLite pour Flutter — idéal pour des séries temporelles
- **`hive`** : base NoSQL très performante — simpler à utiliser
- Stocker les `EnergyPoint` (time, powerWatts, energyWh) et les recharger au démarrage

### Notifications push (alerte dépassement de seuil)

```dart
// Dans MqttService._onMessage, après mise à jour :
if (msg.isKwhMeter && msg.powerWatts > _alertThreshold) {
  flutterLocalNotificationsPlugin.show(
    0, 'Consommation élevée',
    '${msg.name} consomme ${msg.powerWatts}W',
    notificationDetails,
  );
}
```

Package : `flutter_local_notifications`.

### Authentification MQTT (username/password)

```dart
_client!.connectionMessage = MqttConnectMessage()
    .withClientIdentifier('smart_energy_$timestamp')
    .authenticateAs('username', 'password')   // ← ajouter ici
    .startClean()
    .withWillQos(MqttQos.atMostOnce);
```

Ajouter les champs login/password dans `SettingsScreen` et les passer à `connect()`.

### Support TLS/SSL (connexion chiffrée)

```dart
_client = MqttServerClient.withPort(ip, clientId, 8883)  // port TLS
  ..secure = true
  ..securityContext = SecurityContext.defaultContext;
```

---

## 15. Dépannage et logs de debug

L'app émet des logs structurés via `debugPrint` (visibles avec `flutter run` ou dans le débogueur).

| Préfixe | Signification |
|---|---|
| `[MQTT OUT] domoticz/in →` | Commande envoyée à Domoticz (switchlight, getdeviceinfo) |
| `[MQTT IN] idx=X name="..."` | Message reçu de Domoticz avec tous ses champs décodés |
| `[MQTT IN] → switch state:` | Un switch a changé d'état |
| `[MQTT] Abonné :` | Confirmation d'abonnement à un topic |
| `[PREFS] saved meterSwitchMap:` | Mapping persisté en SharedPreferences |
| `[PREFS] loaded meterSwitchMap:` | Mapping rechargé au démarrage |
| `[PREFS] parse error:` | JSON corrompu dans les prefs (effacer l'app repart de zéro) |

**Commande pour voir les logs :**
```powershell
cd smart_energy_app
flutter run -d windows 2>&1
```

**Problème : le switch ne répond pas**
1. Vérifier dans les logs : `[MQTT OUT] domoticz/in → {"command":"switchlight","idx":X,...}`
2. Vérifier que X est bien l'idx du **switch** (`Light/Switch`) et **non** celui du compteur kWh
3. Dans Domoticz → Log → vérifier que la commande est bien reçue et exécutée

**Problème : état du switch toujours inconnu au démarrage**
- Normal si le switch n'a pas changé d'état depuis la connexion
- Re-ouvrir le dialog d'association → "Rescanner" → Domoticz renvoie l'état

**Problème : liste des switchs vide dans le dialog**
- Domoticz ne publie pas spontanément l'état de tous ses appareils
- Utiliser le bouton **Scanner** pour forcer `getdeviceinfo` sur idx 1→40

**Problème : connexion échoue**
- Vérifier que Mosquitto accepte les connexions externes (pas seulement `localhost`)
- Fichier de config Mosquitto : `listener 1883 0.0.0.0` + `allow_anonymous true`

---

## 16. Référence des clés SharedPreferences

| Clé | Type | Contenu | Géré par |
|---|---|---|---|
| `mqtt_broker_ip` | `String` | Adresse IP du broker MQTT | `SettingsScreen` |
| `mqtt_broker_port` | `int` | Port MQTT (défaut : 1883) | `SettingsScreen` |
| `meter_switch_map` | `String` | JSON `{"meterIdx": switchIdx}` ex: `{"11":7}` | `MqttService` |

---

## 17. Référence des topics MQTT

### `domoticz/out` (souscription)

Publié par Domoticz à chaque changement d'état d'un appareil.

**Champs utilisés par l'app :**

| Champ JSON | Type Dart | Usage |
|---|---|---|
| `idx` | `int` | Identifiant unique de l'appareil |
| `name` | `String` | Nom affiché dans l'UI |
| `dtype` | `String` | Type principal : `"Light/Switch"`, `"General"`, `"Usage"` |
| `stype` | `String` | Sous-type : `"kWh"`, `"Switch"`, `"Electric"` |
| `nvalue` | `int` | Valeur numérique : `1`=On, `0`=Off pour les switchs |
| `svalue1` | `String` | Énergie totale en Wh pour les compteurs kWh |
| `svalue2` | `String` | Puissance instantanée en W pour les compteurs kWh |
| `RSSI` | `int` | Force du signal radio (0–12) |
| `LastUpdate` | `String` | Horodatage Domoticz de la dernière MAJ |
| `hwid` | `String` | Identifiant du hardware (utile pour regrouper les appareils d'un même module) |

### `domoticz/in` (publication)

Publié par l'app pour envoyer des commandes à Domoticz.

**Commande switchlight :**
```json
{"command": "switchlight", "idx": 7, "switchcmd": "On"}
{"command": "switchlight", "idx": 7, "switchcmd": "Off"}
```

**Commande getdeviceinfo :**
```json
{"command": "getdeviceinfo", "idx": 7}
```
→ Domoticz répond sur `domoticz/out` avec le JSON complet de l'appareil idx=7.

---

*Documentation — Smart Energy App — Mars 2026*

---

## 18. Intégration Kafka

### Architecture

```
Capteur → Domoticz → Mosquitto → Flutter App
                                      │
                               HTTP POST (fire-and-forget)
                                      │
                          Confluent REST Proxy :8082
                                      │
                             Kafka broker :9092
                                      │
                     topic: domoticz-events (rétention 7 jours)
```

Kafka est **optionnel** : si aucune IP n'est configurée, le service est silencieusement désactivé. L'app MQTT continue de fonctionner normalement.

---

### Installation sur Raspberry Pi

Le dossier `kafka_bridge/` contient tout le nécessaire.

**Prérequis :** Raspberry Pi OS 64-bit (Bullseye ou Bookworm), au moins 1 Go de RAM disponible.

**Étapes :**

```bash
# 1. Copier le dossier kafka_bridge sur le Pi
scp -r kafka_bridge/ pi@<IP_DU_PI>:~/

# 2. Se connecter au Pi
ssh pi@<IP_DU_PI>

# 3. Lancer le script d'installation (installe Docker + démarre Kafka)
cd ~/kafka_bridge
chmod +x install_kafka_pi.sh
sudo ./install_kafka_pi.sh
```

Le script détecte automatiquement l'IP du Pi et configure `KAFKA_ADVERTISED_LISTENERS` en conséquence.

À la fin, il affiche :
```
  Kafka broker   : 192.168.1.50:9092
  REST Proxy     : 192.168.1.50:8082
  Topic          : domoticz-events
```

**Commandes utiles sur le Pi :**

```bash
docker compose -f ~/kafka_bridge/docker-compose.yml logs -f      # logs en direct
docker compose -f ~/kafka_bridge/docker-compose.yml down          # arrêter
docker compose -f ~/kafka_bridge/docker-compose.yml up -d         # redémarrer

# Lire les messages du topic (consumer CLI)
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic domoticz-events \
  --from-beginning
```

---

### Configuration dans l'app Flutter

**Paramètres → section Kafka** :

| Champ | Valeur exemple |
|---|---|
| IP du serveur (REST Proxy) | `192.168.1.50` |
| Port REST Proxy | `8082` |
| Topic Kafka | `domoticz-events` |

1. Remplir les champs
2. Appuyer sur **Tester** → vérifie la connexion au REST Proxy (GET /topics)
3. Appuyer sur **Sauvegarder** → les settings sont persistés dans SharedPreferences

Pour désactiver : vider le champ IP et sauvegarder.

---

### Ce qui est publié dans Kafka

Chaque message reçu sur `domoticz/out` est republié tel quel dans le topic Kafka, avec tous ses champs :

```json
{
  "Battery"    : 255,
  "LastUpdate" : "2026-03-17 10:28:37",
  "RSSI"       : 12,
  "description": "",
  "dtype"      : "General",
  "hwid"       : "2",
  "id"         : "00014C4A",
  "idx"        : 11,
  "name"       : "kWh Meter",
  "nvalue"     : 0,
  "org_hwid"   : "2",
  "stype"      : "kWh",
  "svalue1"    : "68.600",
  "svalue2"    : "200.0",
  "unit"       : 1
}
```

---

### Fichiers Kafka

| Fichier | Rôle |
|---|---|
| `kafka_bridge/docker-compose.yml` | Stack Kafka (KRaft + REST Proxy) pour Docker |
| `kafka_bridge/install_kafka_pi.sh` | Script d'installation automatique sur Raspberry Pi |
| `lib/services/kafka_service.dart` | Client Flutter (HTTP REST Proxy) |

### Clés SharedPreferences ajoutées

| Clé | Type | Contenu |
|---|---|---|
| `kafka_broker_ip` | `String` | IP du REST Proxy |
| `kafka_broker_port` | `int` | Port (défaut : 8082) |
| `kafka_topic` | `String` | Nom du topic (défaut : `domoticz-events`) |


- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
