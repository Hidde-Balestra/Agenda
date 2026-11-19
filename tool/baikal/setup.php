<?php
// Creates a throwaway Baïkal test setup (user alice/secret) for integration tests.
// Usage: php tool/baikal/setup.php <baikal-dir> <Digest|Basic>
[$_, $dir, $auth] = $argv;
@mkdir("$dir/config", 0777, true);
@mkdir("$dir/Specific/db", 0777, true);
$db = "$dir/Specific/db/db.sqlite";
@unlink($db);
$pdo = new PDO("sqlite:$db");
$pdo->exec(file_get_contents("$dir/Core/Resources/Db/SQLite/db.sql"));
$realm = 'BaikalDAV';
$pdo->prepare('INSERT INTO users (username, digesta1) VALUES (?, ?)')
    ->execute(['alice', md5("alice:$realm:secret")]);
$pdo->prepare('INSERT INTO principals (uri, email, displayname) VALUES (?, ?, ?)')
    ->execute(['principals/alice', 'alice@example.com', 'Alice']);
$pdo->exec("INSERT INTO calendars (synctoken, components) VALUES (1, 'VEVENT,VTODO')");
$id = $pdo->lastInsertId();
$pdo->prepare('INSERT INTO calendarinstances (calendarid, principaluri, displayname, uri, calendarcolor, access, transparent, share_invitestatus) VALUES (?, ?, ?, ?, ?, 1, 0, 2)')
    ->execute([$id, 'principals/alice', 'Standaard', 'default', '#FF2968FF']);
$yaml = <<<Y
system:
  configured_version: '0.13.0'
  timezone: 'Europe/Amsterdam'
  card_enabled: true
  cal_enabled: true
  dav_auth_type: '$auth'
  admin_passwordhash: 'x'
  failed_access_message: 'user %u authentication failure for Baikal'
  auth_realm: '$realm'
  base_uri: ''
  invite_from: ''
database:
  sqlite_file: '$db'
  backend: 'sqlite'
  mysql_host: ''
  mysql_dbname: ''
  mysql_username: ''
  mysql_password: ''
  encryption_key: 'testkey'
Y;
file_put_contents("$dir/config/baikal.yaml", $yaml);
echo "ok ($auth)\n";
