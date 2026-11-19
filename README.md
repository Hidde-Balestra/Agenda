# Agenda

Flutter-agenda-app met CalDAV-synchronisatie en ondersteuning voor licht/donker thema.

## Functies

- Maand-, 2-weken- en weekweergave, met een lijst van de afspraken per dag
- Afspraken aanmaken, bewerken, verplaatsen tussen agenda's en verwijderen
- Afspraken voor de hele dag, meerdaagse afspraken en herhalingen (dagelijks, wekelijks, maandelijks, jaarlijks; complexere RRULE's van de server worden getoond en blijven bewaard)
- **CalDAV**: automatische discovery (`current-user-principal` → `calendar-home-set`, met fallback op `/.well-known/caldav`), meerdere accounts, alleen-lezen-agenda's, serverkleuren, ctag-gebaseerde sync en ETag-controle bij opslaan
- Bij bewerken blijven onbekende gegevens (alarmen, deelnemers, tijdzones, uitzonderingen) behouden
- Lokale agenda "Mijn agenda" die zonder account werkt
- Thema: systeem / licht / donker (wordt onthouden)
- Wachtwoorden staan in de veilige opslag van het platform (Keychain/Keystore)

Authenticatie: HTTP Basic en Digest (MD5, MD5-sess, SHA-256). CI test elke wijziging tegen een echte [Baïkal](https://github.com/sabre-io/Baikal)-server, in zowel Digest- als Basic-modus.

### Server-URL

| Server | URL |
| --- | --- |
| Baïkal | `https://server/dav.php` (of `https://server/baikal/html/dav.php`); alleen de hostnaam werkt ook |
| Nextcloud | `https://server/remote.php/dav` |
| iCloud | `https://caldav.icloud.com` met een app-specifiek wachtwoord |

`http://` werkt ook (bijv. Baïkal op je thuisnetwerk), maar dan gaat het verkeer onversleuteld.

## Structuur

```
lib/
  ical/        iCalendar-parser/serializer, event-codec, RRULE-expansie
  dav/         CalDAV-client (PROPFIND/REPORT/PUT/DELETE)
  data/        opslag (shared_preferences, secure storage, in-memory)
  models/      account-, agenda- en afspraakmodellen
  state/       AgendaController (sync en bewerken), SettingsController (thema)
  screens/     overzicht, editor, instellingen, account toevoegen
tool/generate_icon.dart   genereert het app-icoon
test/                     unit- en widgettests (met nep-CalDAV-server)
```

## Ontwikkelen

```sh
flutter pub get
flutter test
flutter run
```

App-icoon opnieuw genereren:

```sh
dart run tool/generate_icon.dart
dart run flutter_launcher_icons
```

## Beperkingen

- Tijden met een `TZID` worden als lokale apparaattijd gelezen; nieuwe afspraken worden in UTC opgeslagen.
- Bij een herhalende afspraak wordt altijd de hele reeks bewerkt of verwijderd.
- Sync haalt afspraken op van een jaar terug tot twee jaar vooruit.
- In de webversie blokkeert de browser CalDAV-servers zonder CORS-headers.

## Integratietests tegen Baïkal

```sh
# Baïkal-release uitpakken, testopzet maken (gebruiker alice/secret) en starten
php tool/baikal/setup.php /pad/naar/baikal Digest
php -S 127.0.0.1:8765 -t /pad/naar/baikal/html
BAIKAL_URL=http://127.0.0.1:8765 flutter test test/integration
```
