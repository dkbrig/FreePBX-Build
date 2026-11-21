# FreePBX 17 Installation and Configuration Runbook

## Ubuntu Server 26.04.1 LTS · Asterisk 22.12.0 · FreePBX 17.0.33

**Document purpose:** Record the installation-specific configuration, commands, service integration, and verification procedures for this FreePBX server.

---

## 1. System overview

### 1.1 Installed software

| Component | Installed version / configuration |
|---|---|
| Operating system | Ubuntu Server 26.04.1 LTS |
| Architecture | amd64 / x86_64 |
| Kernel | 7.0.0-43-generic |
| Asterisk | 22.12.0, compiled from source |
| FreePBX | 17.0.33 |
| PHP | 8.3 |
| PHP execution | PHP-FPM |
| Apache | 2.4.66 |
| Apache MPM | Event |
| Database | MariaDB 11.8.6 |
| MariaDB ODBC driver | MariaDB Connector/ODBC 3.2.10 |
| Node.js | 24 planned for FreePBX |

### 1.2 Important paths

| Purpose | Path |
|---|---|
| Asterisk executable | `/usr/sbin/asterisk` |
| Asterisk modules | `/usr/lib/asterisk/modules` |
| Asterisk configuration | `/etc/asterisk` |
| FreePBX configuration | `/etc/freepbx.conf` |
| FreePBX compatibility configuration | `/etc/amportal.conf` |
| FreePBX web interface | `/var/www/html/admin` |
| Web root | `/var/www/html` |
| PHP-FPM configuration | `/etc/php/8.3/fpm/php.ini` |
| PHP-FPM pool | `/etc/php/8.3/fpm/pool.d/www.conf` |
| MariaDB socket | `/run/mysqld/mysqld.sock` |
| ODBC driver registration | `/etc/odbcinst.ini` |
| ODBC DSN configuration | `/etc/odbc.ini` |
| Asterisk ODBC configuration | `/etc/asterisk/res_odbc.conf` |

### 1.3 Operating principles

- Apache uses MPM Event and PHP-FPM, not mod_php.
- PHP-FPM runs as the `asterisk` user and group.
- FreePBX manages its generated Asterisk configuration.
- Use the FreePBX configuration API or supported custom configuration files rather than manually editing generated files.
- MariaDB is the database backend; SQLite CDR/CEL modules are not used.
- PJSIP is used; the legacy `chan_sip` module is disabled.

---

## 2. Apache and PHP 8.3 PHP-FPM

### 2.1 Apache architecture

The intended configuration is:

- Apache MPM Event
- `proxy` and `proxy_fcgi`
- PHP-FPM through a Unix socket
- Apache `rewrite` support
- No Apache PHP module

The following commands establish the required Apache module configuration:

```bash
a2dismod php8.3
a2dismod mpm_prefork

a2enmod mpm_event
a2enmod proxy
a2enmod proxy_fcgi
a2enmod setenvif
a2enmod rewrite

a2enconf php8.3-fpm
```

`libapache2-mod-php8.3` was checked and was **not installed**, so there was no need to purge it.

### 2.2 Verify Apache modules

```bash
apache2ctl -M | grep -E 'mpm_|proxy|rewrite|php'
```

Expected relevant modules:

```text
mpm_event_module
proxy_module
proxy_fcgi_module
rewrite_module
```

There should be no `php_module` loaded.

Check the PHP-FPM Apache configuration:

```bash
ls -l /etc/apache2/conf-enabled/php8.3-fpm.conf
```

The enabled configuration uses:

```text
/run/php/php8.3-fpm.sock
```

### 2.3 PHP-FPM configuration

File:

`/etc/php/8.3/fpm/php.ini`

The following values were configured:

```ini
memory_limit = 256M
upload_max_filesize = 120M
post_max_size = 128M
```

These are PHP-FPM settings. The CLI PHP configuration is separate:

```text
/etc/php/8.3/cli/php.ini
```

### 2.4 PHP-FPM pool configuration

File:

`/etc/php/8.3/fpm/pool.d/www.conf`

The configured pool:

```ini
[www]
user = asterisk
group = asterisk

listen = /run/php/php8.3-fpm.sock
listen.owner = asterisk
listen.group = asterisk
listen.mode = 0660

pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
```

Important details:

- PHP-FPM executes PHP as `asterisk:asterisk`.
- The FPM socket is owned by `asterisk:asterisk`.
- Socket permissions are `0660`.
- The pool uses dynamic process management.
- `pm.max_children = 5` is the current conservative setting.

### 2.5 Redis PHP extension

Redis is not installed or used by this server.

The PHP Redis extension was initially enabled, causing FreePBX to report that Redis was enabled but unavailable and that it was falling back to filesystem storage.

The extension was disabled:

```bash
phpdismod -v 8.3 redis
systemctl restart php8.3-fpm
```

Verify:

```bash
php -m | grep -i redis
php-fpm8.3 -i | grep -i redis
```

No output from these checks is expected when Redis is disabled in the respective PHP environments.

### 2.6 Restart and verify Apache/PHP-FPM

After configuration changes:

```bash
apache2ctl configtest
```

Expected:

```text
Syntax OK
```

Restart the services:

```bash
systemctl restart php8.3-fpm
systemctl restart apache2
```

Verify:

```bash
systemctl status php8.3-fpm --no-pager
systemctl status apache2 --no-pager

ss -lxnp | grep php8.3-fpm
```

---

## 3. MariaDB configuration

### 3.1 Database server

Installed database:

```text
MariaDB 11.8.6
```

Ubuntu package version observed:

```text
11.8.6-MariaDB-5ubuntu0.1
```

The MariaDB service is enabled and active. It listens locally rather than exposing the database listener to the network.

Verify:

```bash
systemctl status mariadb --no-pager

mariadb --version

ss -ltnp | grep 3306
```

The TCP listener should be on:

```text
127.0.0.1:3306
```

The Unix socket is:

```text
/run/mysqld/mysqld.sock
```

### 3.2 Database names and account

FreePBX uses these databases:

```text
asterisk
asteriskcdrdb
```

The database account used by FreePBX is:

```text
freepbxuser
```

The database password is stored separately in:

```text
/root/freepbx-db-password
```

Its permissions should remain restricted:

```bash
chmod 600 /root/freepbx-db-password
```

Do not place the database password directly in shell command history, documentation, or configuration examples.

### 3.3 Verify database access

For a local administrative login:

```bash
mariadb -u root -p
```

To inspect the databases:

```sql
SHOW DATABASES;
```

To verify the database server version:

```sql
SELECT VERSION();
```

Exit:

```sql
EXIT;
```

---

## 4. MariaDB Connector/ODBC installation

### 4.1 ODBC packages

The following UnixODBC components were installed:

```text
libodbc2
libodbccr2
libodbcinst2
unixodbc
unixodbc-common
unixodbc-dev
```

The `odbcinst` utility was also installed separately.

Verify:

```bash
odbcinst -j
```

### 4.2 Connector version and archive

The Ubuntu package `odbc-mariadb` was not used. The official MariaDB Connector/ODBC archive was used instead.

Archive:

```text
mariadb-connector-odbc-3.2.10-ubu26.04.tar.gz
```

The archive was extracted under `/root`:

```bash
cd /root

tar -xzvf mariadb-connector-odbc-3.2.10-ubu26.04.tar.gz
```

The driver was installed at:

```text
/usr/local/lib/mariadb/libmaodbc.so
```

Authentication plugins:

```text
/usr/local/lib/mariadb/plugin/
```

The installed driver dependencies were checked with:

```bash
ldd /usr/local/lib/mariadb/libmaodbc.so
```

All required shared-library dependencies were resolved. The driver uses the system MariaDB client library:

```text
/usr/lib/x86_64-linux-gnu/libmariadb.so.3
```

### 4.3 Register the ODBC driver

File:

`/etc/odbcinst.ini`

Configuration:

```ini
[MySQL]
Description = MariaDB Connector/ODBC 3.2.10
Driver = /usr/local/lib/mariadb/libmaodbc.so
Threading = 0
```

The driver is registered as `MySQL` to match the DSN configuration.

Verify:

```bash
odbcinst -q -d
```

Expected driver entry:

```text
[MySQL]
```

### 4.4 Configure the asteriskcdrdb DSN

File:

`/etc/odbc.ini`

Configuration:

```ini
[MySQL-asteriskcdrdb]
Description=MySQL connection to 'asteriskcdrdb' database
driver=MySQL
server=localhost
database=asteriskcdrdb
Port=3306
Socket=/run/mysqld/mysqld.sock
option=3
Charset=utf8
```

The socket path is important. The initial DSN used an incorrect socket path:

```text
/var/lib/mysql/mysql.sock
```

It was corrected to:

```text
/run/mysqld/mysqld.sock
```

### 4.5 Test the ODBC connection

Load the database password without displaying it:

```bash
DBPASS=$(< /root/freepbx-db-password)
```

Run:

```bash
isql -v MySQL-asteriskcdrdb freepbxuser "$DBPASS"
```

At the SQL prompt, verify the selected database:

```sql
SELECT DATABASE();
```

Expected:

```text
asteriskcdrdb
```

Verify the server version:

```sql
SELECT VERSION();
```

Exit:

```sql
QUIT
```

Clear the shell variable:

```bash
unset DBPASS
```

---

## 5. Asterisk ODBC configuration

### 5.1 FreePBX-managed ODBC configuration

The main file:

`/etc/asterisk/res_odbc.conf`

includes:

```ini
#include res_odbc_custom.conf
#include res_odbc_additional.conf
```

The custom file is:

```text
/etc/asterisk/res_odbc_custom.conf
```

It is currently empty.

The additional file is generated by FreePBX:

```text
/etc/asterisk/res_odbc_additional.conf
```

The generated connection definition is:

```ini
[asteriskcdrdb]
enabled=>yes
dsn=>MySQL-asteriskcdrdb
pre-connect=>yes
max_connections=>5
username=>freepbxuser
password= <configured database password>
database=>asteriskcdrdb
```

**Do not manually edit `res_odbc_additional.conf`.** FreePBX manages this file.

### 5.2 CEL ODBC configuration

File:

`/etc/asterisk/cel_odbc.conf`

Configuration:

```ini
[cel]
connection=asteriskcdrdb
loguniqueid=yes
table=cel
usegmtime=no
#include cel_odbc_custom.conf
```

### 5.3 Verify ODBC from Asterisk

After correcting the DSN, Asterisk was restarted.

Run:

```bash
asterisk -rx "odbc show"
```

The verified connection showed:

```text
Name: asteriskcdrdb
DSN: MySQL-asteriskcdrdb
Number of active connections: 1 (out of 5)
Cache Usage: 1 cached out of 5
```

Verify CEL:

```bash
asterisk -rx "cel show status"
```

The expected status includes:

```text
CEL Logging: Enabled
CEL Event Subscriber: ODBC CEL backend
```

The ODBC connection and CEL backend were verified. A separate end-to-end call and database-record test remains a useful functional check.

---

## 6. FreePBX configuration and filesystem integration

### 6.1 Required configuration files

The following configuration files are present:

```text
/etc/asterisk/
/etc/freepbx.conf
/etc/amportal.conf
```

The `/etc/asterisk` directory was established so FreePBX could read and write its Asterisk configuration.

The installation encountered earlier errors involving:

```text
ASTLOGDIR
Class "FreePBX" not found
```

These were resolved during the configuration-directory and FreePBX bootstrap work.

The PHP-FPM process runs as `asterisk`, allowing FreePBX to access the Asterisk configuration files under the configured ownership and permissions.

### 6.2 Verify the configuration files

```bash
ls -ld /etc/asterisk
ls -l /etc/freepbx.conf /etc/amportal.conf
```

Check the FreePBX configuration can be loaded as the Asterisk user:

```bash
runuser -u asterisk -- php -r '
require "/etc/freepbx.conf";
echo "FreePBX configuration loaded successfully\n";
'
```

Expected:

```text
FreePBX configuration loaded successfully
```

### 6.3 Use the FreePBX ConfigFile API

FreePBX-generated configuration should be changed through FreePBX itself whenever possible.

The following example loads the FreePBX environment and accesses the `modules.conf` configuration object:

```bash
runuser -u asterisk -- php -r '
require "/etc/freepbx.conf";

$config = \FreePBX::create()->ConfigFile("modules.conf");
'
```

This API was used for the module configuration changes described below.

---

## 7. Asterisk module configuration

### 7.1 Final modules.conf

File:

`/etc/asterisk/modules.conf`

The final configuration established during this installation is:

```ini
[modules]
autoload=yes
preload = pbx_config.so
preload = func_db.so
preload = res_odbc.so
preload = res_config_odbc.so
preload = cdr_adaptive_odbc.so
noload = chan_woomera.so
noload = pbx_gtkconsole.so
noload = pbx_kdeconsole.so
noload = app_intercom.so
noload = chan_modem.so
noload = chan_modem_bestdata.so
noload = chan_modem_i4l.so
noload = app_trunkisavail.so
noload = chan_alsa.so
noload = chan_oss.so
noload = app_directory_odbcstorage.so
noload = app_voicemail_odbcstorage.so
noload = chan_modem_aopen.so
noload = cdr_radius.so
noload = cel_radius.so
noload = cdr_mysql.so
noload = res_phoneprov.so
noload = res_config_ldap.so
noload = res_config_sqlite3.so
noload = res_clialiases.so
noload = chan_mgcp.so
noload = cdr_custom.so
noload = app_minivm.so
noload = cel_custom.so
noload = chan_sip.so
noload = res_mwi_external.so
noload = res_ari_mailboxes.so
noload = res_stasis_mailbox.so
noload = res_pjsip_phoneprov_provider.so
noload = res_hep_pjsip.so
noload = cdr_sqlite3_custom.so
noload = cel_sqlite3_custom.so
load = format_wav.so
load = format_pcm.so
load = res_musiconhold.so
```

### 7.2 Explanation of important module decisions

| Module / group | Configuration | Reason |
|---|---|---|
| `chan_sip.so` | Disabled | PJSIP is used instead of legacy chan_sip |
| `chan_local.so` | Preload removed | Local channels are built into Asterisk core since Asterisk 12; there is no separate loadable `chan_local.so` module in Asterisk 22 |
| `res_mwi_external.so` | Disabled | Conflicted with the voicemail provider registered by `app_voicemail` |
| `cdr_sqlite3_custom.so` | Disabled | SQLite CDR backend is not used |
| `cel_sqlite3_custom.so` | Disabled | SQLite CEL backend is not used |
| `res_ari_mailboxes.so` | Disabled | Not required for this installation |
| `res_stasis_mailbox.so` | Disabled | Not required for this installation |
| `res_pjsip_phoneprov_provider.so` | Disabled | PJSIP phone provisioning provider is not required |
| `res_hep_pjsip.so` | Disabled | HEP/PJSIP integration is not used |
| `cdr_adaptive_odbc.so` | Preloaded | ODBC-based CDR integration |
| `res_odbc.so` | Preloaded | ODBC support |
| `res_config_odbc.so` | Preloaded | ODBC realtime configuration support |
| `format_wav.so` | Explicitly loaded | WAV format support |
| `format_pcm.so` | Explicitly loaded | PCM format support |
| `res_musiconhold.so` | Explicitly loaded | Music-on-hold support |

### 7.3 Remove the obsolete chan_local preload

The FreePBX-generated configuration originally contained a preload entry for `chan_local.so`.

Remove it through the FreePBX API:

```bash
runuser -u asterisk -- php -r '
require "/etc/freepbx.conf";

\FreePBX::create()->ConfigFile("modules.conf")->removeEntry(
    "modules",
    "preload",
    "chan_local.so"
);
'
```

### 7.4 Disable the conflicting external MWI provider

The following error occurred:

```text
Voicemail provider already registered by res_mwi_external.
app_voicemail declined to load.
```

Disable the external MWI provider through the FreePBX API:

```bash
runuser -u asterisk -- php -r '
require "/etc/freepbx.conf";

\FreePBX::create()->ConfigFile("modules.conf")->addEntry(
    "modules",
    "noload=res_mwi_external.so"
);
'
```

### 7.5 Disable SQLite CDR/CEL modules

SQLite is not being used for CDR or CEL storage.

Add the following entries through the FreePBX API:

```bash
runuser -u asterisk -- php -r '
require "/etc/freepbx.conf";

$config = \FreePBX::create()->ConfigFile("modules.conf");

$config->addEntry("modules", "noload=cdr_sqlite3_custom.so");
$config->addEntry("modules", "noload=cel_sqlite3_custom.so");
'
```

### 7.6 Apply module changes

Restart Asterisk after module-loading changes:

```bash
systemctl restart asterisk
```

Verify service status:

```bash
systemctl status asterisk --no-pager
```

Inspect module loading:

```bash
asterisk -rx "module show"
```

Check individual modules as needed:

```bash
asterisk -rx "module show like res_odbc"
asterisk -rx "module show like cdr_adaptive_odbc"
asterisk -rx "module show like app_voicemail"
asterisk -rx "module show like res_mwi_external"
```

---

## 8. Voicemail configuration

A voicemail configuration warning was encountered:

```text
maxsilence should be less than minsecs
```

The values were corrected through the FreePBX GUI.

The resulting values are:

```ini
maxsilence=1
minsecs=2
```

These values satisfy the requirement that `maxsilence` be less than `minsecs`.

Verify the values in the generated voicemail configuration if needed:

```bash
grep -nE '^(maxsilence|minsecs)=' /etc/asterisk/voicemail.conf
```

Use the FreePBX GUI to make future changes rather than editing generated configuration directly.

---

## 9. FreePBX and Asterisk operational verification

### 9.1 Verify installed versions

```bash
asterisk -rx "core show version"
fwconsole --version
php -v
apache2 -v
mariadb --version
```

Expected principal versions:

```text
Asterisk 22.12.0
FreePBX 17.0.33
PHP 8.3
Apache 2.4.66
MariaDB 11.8.6
```

### 9.2 Verify services

```bash
systemctl is-active asterisk
systemctl is-active apache2
systemctl is-active php8.3-fpm
systemctl is-active mariadb
```

All four should return:

```text
active
```

Check whether services are enabled at boot:

```bash
systemctl is-enabled asterisk
systemctl is-enabled apache2
systemctl is-enabled php8.3-fpm
systemctl is-enabled mariadb
```

### 9.3 Verify FreePBX framework

```bash
fwconsole --version
fwconsole ma list
```

The second command displays installed FreePBX modules and their statuses.

### 9.4 Verify Asterisk configuration and channels

```bash
asterisk -rx "core show settings"
asterisk -rx "core show channels"
asterisk -rx "pjsip show endpoints"
```

### 9.5 Verify CDR/CEL and ODBC

```bash
asterisk -rx "odbc show"
asterisk -rx "cel show status"
```

### 9.6 Review recent service logs

Asterisk:

```bash
journalctl -u asterisk -n 100 --no-pager
```

Apache:

```bash
journalctl -u apache2 -n 100 --no-pager
```

PHP-FPM:

```bash
journalctl -u php8.3-fpm -n 100 --no-pager
```

MariaDB:

```bash
journalctl -u mariadb -n 100 --no-pager
```

---

## 10. Recommended functional acceptance tests

The following tests provide a useful final check after the configuration work.

### 10.1 Web interface

- Open the FreePBX administration interface.
- Log in successfully.
- Navigate between the major administration pages.
- Confirm there are no PHP fatal errors or blank pages.
- Confirm Apache and PHP-FPM remain active.

### 10.2 FreePBX configuration writes

- Make a harmless test configuration change through the GUI.
- Apply the configuration.
- Confirm FreePBX completes the reload successfully.
- Verify the relevant generated Asterisk configuration is updated.

### 10.3 Asterisk

- Confirm Asterisk starts without module-loading failures.
- Confirm PJSIP endpoints load.
- Confirm voicemail loads.
- Confirm music on hold and WAV/PCM format modules load.

### 10.4 Database and ODBC

- Confirm `isql` can connect to `MySQL-asteriskcdrdb`.
- Confirm Asterisk reports an active ODBC connection.
- Place a test call.
- Confirm the expected CDR and CEL records are written to MariaDB.

For example, after a test call, inspect the database:

```bash
mariadb -u root -p asteriskcdrdb
```

Then:

```sql
SELECT calldate, src, dst, disposition
FROM cdr
ORDER BY calldate DESC
LIMIT 10;

SELECT eventtype, eventtime, cid_num, exten
FROM cel
ORDER BY eventtime DESC
LIMIT 10;
```

Exit:

```sql
EXIT;
```

---

## 11. Important maintenance notes

### 11.1 Generated versus custom configuration

FreePBX owns and regenerates many files under `/etc/asterisk`.

Avoid manually editing generated files such as:

```text
/etc/asterisk/res_odbc_additional.conf
```

For FreePBX-managed configuration, use:

- The FreePBX GUI
- The FreePBX `ConfigFile` API
- Supported `*_custom.conf` files

### 11.2 Restarting services

After changing PHP-FPM settings:

```bash
systemctl restart php8.3-fpm
```

After changing Apache configuration:

```bash
apache2ctl configtest
systemctl restart apache2
```

After changing Asterisk module-loading configuration:

```bash
systemctl restart asterisk
```

After changing MariaDB configuration:

```bash
systemctl restart mariadb
```

Asterisk restarts are appropriate when module-loading changes need to take effect.

### 11.3 Database password handling

The FreePBX database password is stored in:

```text
/root/freepbx-db-password
```

Keep the file restricted:

```bash
chmod 600 /root/freepbx-db-password
```

Do not copy the password into this runbook.

### 11.4 ODBC driver maintenance

The ODBC driver is installed outside the Ubuntu package-managed library directories:

```text
/usr/local/lib/mariadb/libmaodbc.so
```

When upgrading the driver, verify:

1. The new driver file exists.
2. Its dependencies resolve with `ldd`.
3. `/etc/odbcinst.ini` points to the intended driver.
4. The DSN in `/etc/odbc.ini` still works.
5. Asterisk can establish its ODBC connection.

---

## 12. Installation details not preserved in the command history

The following items were established or discussed during installation, but their complete original command sequences were not preserved in the available installation record. They should not be reconstructed from guesses.

| Item | Recorded state |
|---|---|
| Asterisk source compilation | Asterisk 22.12.0 compiled and installed; complete original configure/make commands not recorded here |
| FreePBX archive | `freepbx-17.0-latest-EDGE.tgz` downloaded from the official FreePBX mirror |
| FreePBX archive URL | `https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest-EDGE.tgz` |
| FreePBX source directory | `/usr/local/src/freepbx` |
| FreePBX installation | Version 17.0.33 installed |
| Node.js | Node.js 24 was planned for the FreePBX environment; exact installation commands and final PM2 configuration are not included here |
| Initial package prerequisites | Complete original `apt install` package list not preserved |
| Database creation and grants | Database names and application account are recorded; original SQL creation/grant statements are not preserved |
| Asterisk build options | Final installed version is recorded; original configure options and compiler flags are not preserved |

For a truly reproducible bare-metal rebuild, preserve the original Asterisk build command, package list, FreePBX installation command, and Node.js/PM2 setup alongside this runbook when those details are available.

---

## 13. Final configuration checklist

Use this checklist after a rebuild or major maintenance operation.

- [ ] Ubuntu Server 26.04.1 LTS installed and updated.
- [ ] Asterisk 22.12.0 installed.
- [ ] FreePBX 17.0.33 installed.
- [ ] PHP 8.3 installed.
- [ ] Apache uses MPM Event.
- [ ] Apache uses `proxy_fcgi` and PHP-FPM.
- [ ] No mod_php module is loaded.
- [ ] PHP-FPM runs as `asterisk:asterisk`.
- [ ] PHP-FPM socket is `/run/php/php8.3-fpm.sock`.
- [ ] PHP-FPM upload and memory settings are correct.
- [ ] Redis PHP extension is disabled.
- [ ] MariaDB 11.8.6 is active and listening locally.
- [ ] `asterisk` and `asteriskcdrdb` databases exist.
- [ ] MariaDB Connector/ODBC 3.2.10 is installed.
- [ ] ODBC driver is registered as `MySQL`.
- [ ] `MySQL-asteriskcdrdb` DSN connects successfully.
- [ ] Asterisk ODBC connection is active.
- [ ] CEL ODBC backend is enabled.
- [ ] FreePBX can read and write `/etc/asterisk`.
- [ ] `chan_sip.so` is disabled.
- [ ] `chan_local.so` preload is removed.
- [ ] `res_mwi_external.so` is disabled.
- [ ] SQLite CDR/CEL modules are disabled.
- [ ] Required ODBC and media modules load.
- [ ] Voicemail settings are `maxsilence=1` and `minsecs=2`.
- [ ] FreePBX GUI login and configuration reload work.
- [ ] Test call produces expected CDR/CEL database records.

---

**End of runbook**

This document records the actual FreePBX 17 / Asterisk 22 configuration decisions and integration work for this server. Where the original installation command history was incomplete, the runbook identifies that limitation instead of presenting an unverified command as fact.
