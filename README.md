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

Getest met de structuur van Nextcloud, Radicale, Baïkal en iCloud (gebruik bij iCloud een app-specifiek wachtwoord, server `caldav.icloud.com`).

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
