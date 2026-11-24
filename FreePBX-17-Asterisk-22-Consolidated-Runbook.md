# FreePBX 17 / Asterisk 22 installation runbook

**Ubuntu Server 26.04.1 LTS — consolidated revision, 24 November 2026**

Manual source installation for the `freepbx` lab server. This supersedes the earlier installation runbook and database addendum. It is a rebuild procedure, not a verbatim chronological transcript or a vendor-certified Ubuntu installation. Commands are intended for a root Bash shell on a fresh host unless indicated. Review each stage before proceeding; do not run the entire document as a script. Historical versions are reference points, not package holds. Reconstructed steps are explicitly identified. Never run `make samples` on an existing configured PBX.

## 1. Architecture and baseline

| Component | Observed baseline |
|---|---|
| OS | Ubuntu 26.04.1 LTS amd64, kernel 7.0.0-43-generic |
| Asterisk | 22.12.0, GCC 15.2.0, bundled PJPROJECT 2.17 |
| FreePBX framework | 17.0.33.4 |
| Core / PM2 / UCP | 17.0.18.54 / 17.0.3.4 / 17.0.10 |
| PHP | 8.3.36 from Sury; 8.3.37 candidate at capture |
| Apache | 2.4.66, MPM Event, proxy_fcgi |
| MariaDB | 11.8.6, local TCP and Unix socket |
| ODBC | unixODBC 2.3.14, MariaDB Connector/ODBC 3.2.10 |
| Node / npm / Corepack | 24.22.3 / 11.19.1 / 0.36.0 |
| Service model | Asterisk SysV-generated unit; native Apache, FPM, MariaDB units; no separate FreePBX unit |

Apache workers and PHP-FPM workers run as asterisk. PHP-FPM executes FreePBX via a Unix socket; FreePBX communicates with Asterisk via AMI and configuration files, and with MariaDB via SQL. Asterisk uses ODBC for CDR/CEL. Node processes are managed by FreePBX PM2.

## 2. Prepare Ubuntu and build dependencies

Reconstructed ordering: the historical APT log installed Node and PHP before some Asterisk dependencies; this runbook builds Asterisk first. Verify network, hostname, DNS, time and available storage before proceeding.

```bash
cat /etc/os-release
uname -r
hostnamectl
ip -br address
ip route
timedatectl
df -h
apt update
apt upgrade
```

Install the recorded build dependencies (combined from the historical APT transactions):

```bash
apt install -y build-essential git curl wget subversion pkg-config \
 autoconf automake libtool libtool-bin bison flex uuid-dev libssl-dev \
 libncurses-dev libedit-dev libxml2-dev libjansson-dev libsqlite3-dev \
 libcurl4-openssl-dev libspeexdsp-dev libogg-dev libvorbis-dev libopus-dev \
 libsrtp2-dev libspandsp-dev libical-dev libneon27-dev unixodbc-dev \
 libasound2-dev libnewt-dev sqlite3 autoconf-archive binutils-dev \
 libcap-dev libcodec2-dev libfftw3-dev libgmime-3.0-dev libgsm1-dev \
 libldap2-dev libpopt-dev libresample1-dev libsndfile1-dev libsnmp-dev \
 libspeex-dev libunbound-dev liburiparser-dev libxslt1-dev xmlstarlet
apt install -y ca-certificates gnupg sudo lsb-base
```

Optional historical administration packages: `fastfetch lm-sensors vim htop sngrep net-tools aptitude nfs-common mutt patchelf`. They are not all build prerequisites. Do not purge unrelated packages simply because the historical log did so.

## 3. Asterisk service account

Equivalent reconstruction of the recorded account (do not hardcode UID 999 or GID 1001):

```bash
groupadd asterisk
useradd -r -d /var/lib/asterisk -g asterisk -s /usr/sbin/nologin asterisk
usermod -aG dialout,audio asterisk
id asterisk
getent passwd asterisk
```

## 4. Compile and install Asterisk

Download commands reconstructed; configure invocation and installation targets confirmed. Obtain and verify the release archive from the official Asterisk distribution before extracting.

```bash
cd /usr/local/src
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22.12.0.tar.gz
tar -xzf asterisk-22.12.0.tar.gz
cd asterisk-22.12.0
./configure
make menuselect
```

Use the exact saved `menuselect.makeopts` in Appendix A as the baseline. Save that appendix as a file and copy it into the configured source tree, then review with `make menuselect` and resolve any unavailable dependencies before building. MENUSELECT module category variables generally record exclusions, not enabled modules. Do not infer selected modules merely from library detection. Configure detected OpenSSL, Jansson, SpanDSP/T.38, Opus, SRTP and unixODBC; bundled PJPROJECT 2.17 was downloaded and patched. Optional missing dependencies were not fatal. The external Opus transcoder is not established by this log.

```bash
make -j"$(nproc)"
make install
make samples
make config
```

Parallel build command is reconstructed. Preserve the source tree, configure logs and Menuselect file. Check `/usr/sbin/asterisk -V` and `ldd /usr/sbin/asterisk`.

## 5. Asterisk runtime and startup

Set the following in the existing `/etc/asterisk/asterisk.conf` sections (do not append duplicate sections):

```ini
[directories](!)
astcachedir => /var/cache/asterisk
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
astsbindir => /usr/sbin
[options]
runuser = asterisk
rungroup = asterisk
documentation_language = en_US
```

Set `/etc/default/asterisk` active values:

```bash
AST_USER="asterisk"
AST_GROUP="asterisk"
COLOR=yes
```

Reconstructed ownership commands for the observed layout:

```bash
mkdir -p /var/cache/asterisk /var/run/asterisk
chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/cache/asterisk /var/run/asterisk /usr/lib/asterisk/modules
chmod 0775 /etc/asterisk /var/spool/asterisk /var/log/asterisk /var/run/asterisk
chmod 0755 /var/lib/asterisk /usr/lib/asterisk/modules
```

Module ownership matches the observed FreePBX host, but writable executable modules increase the impact of an application compromise. Do not recursively change file modes. Keep secrets restricted.

`make config` installed `/etc/init.d/asterisk`; systemd generates `/run/systemd/generator.late/asterisk.service`. The script sources `/etc/default/asterisk`, creates the runtime directory and passes `-U` and `-G` to Asterisk. Do not edit the generated unit. Its `Restart=no`, `RemainAfterExit=yes` and `GuessMainPID=no` mean active status alone does not prove daemon health.

```bash
mkdir -p /etc/systemd/system/asterisk.service.d
cat > /etc/systemd/system/asterisk.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=8192
EOF
update-rc.d asterisk defaults
systemctl daemon-reload
systemctl start asterisk
asterisk -rx 'core show version'
ps -C asterisk -o pid,user,group,args
systemctl show asterisk -p LimitNOFILE
pid=$(pgrep -xo asterisk)
grep 'Max open files' /proc/"$pid"/limits
```

## 6. PHP 8.3 repository and APT policy

Do not install generic `php` or `php-cli` metapackages: Ubuntu defaults to PHP 8.5. The original repository bootstrap commands are unavailable. The following keyring bootstrap is reconstructed; verify the vendor's current distribution instructions and signing key provenance before installing.

```bash
cd /tmp
curl -fLO https://packages.sury.org/debsuryorg-archive-keyring.deb
# Verify provenance of the downloaded keyring package before proceeding.
dpkg -i debsuryorg-archive-keyring.deb
cat > /etc/apt/sources.list.d/php.list <<'EOF'
deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ resolute main
EOF
cat > /etc/apt/preferences.d/sury-php <<'EOF'
# Default: deprioritize all packages from Sury
Package: *
Pin: origin "packages.sury.org"
Pin-Priority: 100

# Allow PHP 8.3 packages from Sury
Package: php8.3* libapache2-mod-php8.3* php-common
Pin: origin "packages.sury.org"
Pin-Priority: 600
EOF
apt update
apt-cache policy php php8.3 php8.3-cli php8.3-fpm php8.5 php-common php-pear apache2 openssl
```

Observed keyring package 2025.11.18; key file root:root 0644. PHP 8.3 and php-common have priority 600, Ubuntu packages normally 500, other Sury packages 100. Priority 100 is not a prohibition: inspect dependency resolution and upgrades. The pin does not block PHP 8.5 from Ubuntu. No version holds were used.

## 7. Install PHP and Node.js

```bash
php_packages=(php8.3-cli php8.3-fpm php8.3-common php8.3-opcache php8.3-curl php8.3-mysql php8.3-gd php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl php8.3-bcmath php8.3-soap php8.3 php-pear apache2)
apt -s install "${php_packages[@]}"
# Review simulation: no PHP 8.5 or mod_php; no unexpected Sury libraries.
apt install "${php_packages[@]}"
php -v
update-alternatives --display php
php -m
```

PHP alternatives were in auto mode, only `/usr/bin/php8.3` registered (priority 83). Optional imagick, memcached and redis extensions were historically installed; omit unless needed. Redis was disabled later.

NodeSource bootstrap reconstructed; verify the vendor key before trusting it:

```bash
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key
gpg --show-keys --with-fingerprint /tmp/nodesource.key
# Verify fingerprint against vendor documentation.
gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.key
chmod 0644 /usr/share/keyrings/nodesource.gpg
cat > /etc/apt/sources.list.d/nodesource.sources <<'EOF'
Types: deb
URIs: https://deb.nodesource.com/node_24.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
for pkg in nodejs nsolid; do
  printf 'Package: %s\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' "$pkg" > "/etc/apt/preferences.d/$pkg"
done
apt update
apt-cache policy nodejs
apt install nodejs
node --version
npm --version
npm list -g --depth=0
```

NodeSource priority 600 for nodejs and nsolid; do not install nsolid. FreePBX manages PM2 internally; no global PM2 installation is required.

## 8. Apache and PHP-FPM

Set `/etc/apache2/envvars`:

```bash
export APACHE_RUN_USER=asterisk
export APACHE_RUN_GROUP=asterisk
```

Retain the default port 80 virtual host and `/var/www/html` DocumentRoot. In `/etc/apache2/apache2.conf` set only the relevant directory block (recommended narrower change than historical global AllowOverride changes):

```apache
<Directory /var/www/>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
```

```bash
# If prefork is enabled, disable it before enabling event.
a2enmod mpm_event proxy_fcgi setenvif rewrite
a2enconf php8.3-fpm
chown -R asterisk:asterisk /var/www/html
chmod 0775 /var/www/html
```

If mod_php is present from a previous attempt, disable it, purge its package and disable prefork before enabling event. The packaged FPM handler uses `proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost`. No Apache systemd override was used. AH00558 is a nonfatal ServerName warning; optionally set a global ServerName matching the host. The observed web interface uses HTTP; restrict access to trusted networks or configure HTTPS separately.

### 8.3 PHP-FPM configuration

File:

`/etc/php/8.3/fpm/php.ini`

The following values were configured:

```ini
max_execution_time = 30
memory_limit = 256M
upload_max_filesize = 120M
post_max_size = 128M
```

These are PHP-FPM settings. The CLI PHP configuration is separate:

```text
/etc/php/8.3/cli/php.ini
```

### 8.4 PHP-FPM pool configuration

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

### 8.5 Redis PHP extension

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

### 8.6 Restart and verify Apache/PHP-FPM

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

## 9. MariaDB and ODBC prerequisites

### 9.1 Install MariaDB

Install the MariaDB server and client packages:

```bash
apt install mariadb-server mariadb-client
```

Enable and start MariaDB:

```bash
systemctl enable --now mariadb
```

Check the installed version and service status:

```bash
mariadb --version
systemctl status mariadb --no-pager
mariadb -NBe "SELECT VERSION();"
ss -lntp | grep 3306 || true
```

The installed version for this system is MariaDB 11.8.6. MariaDB listens on `127.0.0.1:3306`.

Check the root database account:

```bash
mariadb -u root -p -e "SELECT VERSION(), USER(), CURRENT_USER();"
```

The root account was configured to use `mysql_native_password`.

### 9.2 MariaDB socket configuration

The socket used by this installation is:

```text
/run/mysqld/mysqld.sock
```

The ODBC DSN must use this path. The initial DSN configuration pointed to `/var/lib/mysql/mysql.sock`, which was incorrect for this installation.

The socket path was configured in the MariaDB configuration under `/etc/mysql/my.cnf` and `/etc/mysql/mariadb.cnf`.

Verify the active socket:

```bash
mariadb -u root -p -NBe "SHOW VARIABLES LIKE 'socket';"
```

Expected value:

```text
/run/mysqld/mysqld.sock
```

### 9.3 Create the FreePBX databases and database account

The installation uses two databases:

- `asterisk` — FreePBX and Asterisk configuration data.
- `asteriskcdrdb` — call detail records (CDR) and channel event logging (CEL).

The database account is:

```text
freepbxuser
```

The original SQL commands from the installation session were not preserved in the available command history. The following is a reproducible SQL procedure for creating the established databases and account. It is not represented as a verbatim record of the original commands.

Log in to MariaDB as root:

```bash
mariadb -u root -p
```

Execute the following SQL, replacing `REPLACE_WITH_DATABASE_PASSWORD` with the password selected for `freepbxuser`:

```sql
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb;

CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost'
IDENTIFIED BY 'REPLACE_WITH_DATABASE_PASSWORD';

GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'localhost';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'freepbxuser'@'localhost';

FLUSH PRIVILEGES;
```

Exit the MariaDB prompt:

```sql
EXIT;
```

**Password handling:** The database password for this installation is stored in:

```text
/root/freepbx-db-password
```

The file is protected with mode `0600`. Do not put the actual password in this runbook or in shell command history.

Verify the databases and account:

```bash
mariadb -u root -p -e "SHOW DATABASES;"
mariadb -u root -p -e "SELECT User, Host FROM mysql.user WHERE User='freepbxuser';"
```

### 9.4 Install MariaDB Connector/ODBC

The Ubuntu `odbc-mariadb` package was not used. Instead, the official MariaDB Connector/ODBC 3.2.10 package for Ubuntu 26.04, x86_64, was installed.

Package archive:

```text
mariadb-connector-odbc-3.2.10-ubu26.04.tar.gz
```

The archive was extracted under:

```text
/root/mariadb-connector-odbc-3.2.10-ubu26.04
```

The installed driver is:

```text
/usr/local/lib/mariadb/libmaodbc.so
```

The authentication plugins are installed under:

```text
/usr/local/lib/mariadb/plugin/
```

The driver depends on the system MariaDB client library, `libmariadb.so.3`, supplied by the Ubuntu `libmariadb3` package.

Verify the driver and its dependencies:

```bash
ls -l /usr/local/lib/mariadb/libmaodbc.so
ldd /usr/local/lib/mariadb/libmaodbc.so
```

Check that the output does not contain any `not found` dependencies.

### 9.5 Install and configure unixODBC

The following unixODBC packages were installed:

```text
libodbc2
libodbccr2
libodbcinst2
unixodbc
unixodbc-common
unixodbc-dev
```

The `odbcinst` utility was also installed.

Verify the installation:

```bash
odbcinst -j
```

### Register the MariaDB ODBC driver

File:

```text
/etc/odbcinst.ini
```

Configuration:

```ini
[MySQL]
Description = MariaDB Connector/ODBC 3.2.10
Driver = /usr/local/lib/mariadb/libmaodbc.so
Threading = 0
```

The driver is registered under the name `MySQL` to match the DSN configuration.

Verify registration:

```bash
odbcinst -q -d
```

Expected driver entry:

```text
[MySQL]
```

### Configure the asteriskcdrdb DSN

File:

```text
/etc/odbc.ini
```

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

Verify the DSN is registered:

```bash
odbcinst -q -s
```

Expected DSN:

```text
[MySQL-asteriskcdrdb]
```

### 9.6 Test the ODBC connection

Load the database password from the protected file and test the DSN:

```bash
DBPASS="$(cat /root/freepbx-db-password)"
isql -v MySQL-asteriskcdrdb freepbxuser "$DBPASS"
unset DBPASS
```

A successful connection displays an SQL prompt.

Run these queries at the `SQL>` prompt:

```sql
SELECT DATABASE();
SELECT VERSION();
```

The database query should identify `asteriskcdrdb`, and the version query should report MariaDB 11.8.6.

Exit:

```sql
quit
```

Reconstructed driver installation commands (after obtaining the verified vendor archive):

```bash
cd /root
tar -xzf mariadb-connector-odbc-3.2.10-ubu26.04.tar.gz
cd mariadb-connector-odbc-3.2.10-ubu26.04
apt install unixodbc unixodbc-dev odbcinst libmariadb3
install -d /usr/local/lib/mariadb/plugin
install -m 0755 lib/mariadb/libmaodbc.so /usr/local/lib/mariadb/
install -m 0755 lib/mariadb/plugin/*.so /usr/local/lib/mariadb/plugin/
ldd /usr/local/lib/mariadb/libmaodbc.so
```

Perform these commands before registering/testing the DSN above. Use the system libmariadb.so.3. For a fresh database, root socket authentication is acceptable; the historical root account used mysql_native_password, but changing it is not required for the dedicated application account. Verify both socket and TCP access (`mariadb -h 127.0.0.1 -u freepbxuser -p asterisk`) before installing FreePBX. If TCP does not match the localhost grant, inspect account matching and create an explicit 127.0.0.1 grant only if necessary. Keep MariaDB bound to loopback. Password arguments in isql and the installer can be visible in process listings.

## 10. Install FreePBX 17

Regular archive confirmed by Bash history (HTTPS substituted for historical HTTP). The latest archive is mutable; retain the original archive and checksum if exact version reproduction is required.

```bash
cd /usr/local/src
wget https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar -xzf freepbx-17.0-latest.tgz
cd freepbx
systemctl start asterisk
asterisk -rx 'core show version'
DBPASS=$(cat /root/freepbx-db-password)
./install \
    --dbengine=mysql \
    --dbname=asterisk \
    --cdrdbname=asteriskcdrdb \
    --dbhost=127.0.0.1 \
    --dbport=3306 \
    --dbuser=freepbxuser \
    --dbpass="$DBPASS" \
    --user=asterisk \
    --group=asterisk \
    --webroot=/var/www/html
unset DBPASS
fwconsole chown
fwconsole reload
fwconsole ma list
```

Installer invocation is confirmed; surrounding verification commands are recommended. Review installer output before continuing. Use GUI Module Admin to install required modules, including core, framework, manager, certman, pm2, ucp, cdr, cel and voicemail, as appropriate. Do not blindly install all optional modules. Complete GUI administrator setup on the trusted network.

## 11. PHP-FPM filesystem integration

Apply only after all paths exist and the installer has created the FreePBX bootstrap files. `ProtectSystem=full` made `/etc` read-only in the FPM namespace despite correct Unix permissions. Preserve all other service protections.

```bash
ls -ld /etc/asterisk
ls -l /etc/freepbx.conf /etc/amportal.conf
mkdir -p /etc/systemd/system/php8.3-fpm.service.d
cat > /etc/systemd/system/php8.3-fpm.service.d/freepbx.conf <<'EOF'
[Service]
ReadWritePaths=/etc/asterisk
ReadWritePaths=/etc/freepbx.conf
ReadWritePaths=/etc/amportal.conf
EOF
systemctl daemon-reload
systemctl restart php8.3-fpm
systemctl show php8.3-fpm -p ProtectSystem -p ReadWritePaths
```

### 11.1 Required configuration files

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

### 11.2 Verify the configuration files

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

### 11.3 Use the FreePBX ConfigFile API

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

## 12. Asterisk module configuration

### 12.1 Final modules.conf

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

### 12.2 Explanation of important module decisions

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

### 12.3 Remove the obsolete chan_local preload

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

### 12.4 Disable the conflicting external MWI provider

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

### 12.5 Disable SQLite CDR/CEL modules

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

### 12.6 Apply module changes

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

## 13. Voicemail configuration

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

## 14. FreePBX and Asterisk operational verification

### 14.1 Verify installed versions

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
FreePBX 17.0.33.4
PHP 8.3
Apache 2.4.66
MariaDB 11.8.6
```

### 14.2 Verify services

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

### 14.3 Verify FreePBX framework

```bash
fwconsole --version
fwconsole ma list
```

The second command displays installed FreePBX modules and their statuses.

### 14.4 Verify Asterisk configuration and channels

```bash
asterisk -rx "core show settings"
asterisk -rx "core show channels"
asterisk -rx "pjsip show endpoints"
```

### 14.5 Verify CDR/CEL and ODBC

```bash
asterisk -rx "odbc show"
asterisk -rx "cel show status"
```

### 14.6 Review recent service logs

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

## 15. Asterisk ODBC and CEL integration

### 15.1 Configure Asterisk ODBC

FreePBX manages the generated ODBC configuration. Do not directly edit the generated file:

```text
/etc/asterisk/res_odbc_additional.conf
```

The main configuration file is:

```text
/etc/asterisk/res_odbc.conf
```

It includes the custom and generated configuration files:

```ini
#include res_odbc_custom.conf
#include res_odbc_additional.conf
```

The generated `res_odbc_additional.conf` contains the `asteriskcdrdb` connection. Its effective settings are:

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

The password is intentionally not reproduced here.

The custom file is:

```text
/etc/asterisk/res_odbc_custom.conf
```

It was left empty.

### 15.2 Configure CEL ODBC logging

File:

```text
/etc/asterisk/cel_odbc.conf
```

Configuration:

```ini
[cel]
connection=asteriskcdrdb
loguniqueid=yes
table=cel
usegmtime=no
#include cel_odbc_custom.conf
```

The `cdr_adaptive_odbc.so` module is preloaded in the Asterisk module configuration.

### 15.3 Restart Asterisk and verify ODBC

After correcting the DSN and completing the ODBC configuration, restart Asterisk:

```bash
systemctl restart asterisk
```

Check the ODBC connection from the Asterisk CLI:

```bash
asterisk -rx "odbc show"
```

The established connection reported:

```text
Name: asteriskcdrdb
DSN: MySQL-asteriskcdrdb
Number of active connections: 1 (out of 5)
Cache Usage: 1 cached out of 5
```

Check CEL status:

```bash
asterisk -rx "cel show status"
```

The expected status includes:

```text
CEL Logging: Enabled
CEL Event Subscriber: ODBC CEL backend
```

### 15.4 Database and ODBC configuration file summary

| File | Purpose |
|---|---|
| `/etc/mysql/my.cnf` | MariaDB configuration |
| `/etc/mysql/mariadb.cnf` | MariaDB configuration |
| `/root/freepbx-db-password` | Protected database password |
| `/etc/odbcinst.ini` | ODBC driver registration |
| `/etc/odbc.ini` | ODBC DSN definition |
| `/etc/asterisk/res_odbc.conf` | Main Asterisk ODBC configuration |
| `/etc/asterisk/res_odbc_custom.conf` | Custom ODBC configuration |
| `/etc/asterisk/res_odbc_additional.conf` | FreePBX-generated ODBC connection |
| `/etc/asterisk/cel_odbc.conf` | CEL ODBC backend configuration |

**Important:** FreePBX-generated configuration files should be managed through FreePBX rather than edited directly. Keep the database password out of documentation and protect the password file from unauthorized access.

## 16. Node processes, AMI and boot verification

```bash
fwconsole pm2 --list
asterisk -rx 'manager show connected'
ss -lntp | grep -E ':(5038|8001|8003)\b'
```

Observed PM2 processes: core-calltransfer-monitor, core-fastagi and ucp, all online with zero restarts. AMI should be bound to 127.0.0.1:5038 for this local-only architecture. The UCP module created a dedicated ucp_events account; verify local access without exposing credentials. No separate FreePBX systemd unit was present. Asterisk's SysV service alone does not establish that PM2 will start after a reboot. Reboot in the lab and verify all processes; if absent, run `fwconsole start` and investigate FreePBX startup integration before declaring boot acceptance. Do not add a competing service without testing.

## 17. Conditional AppArmor correction

Earlier troubleshooting established recurring `who` profile denials for /etc/nsswitch.conf and /etc/passwd. If reproduced, verify the profile includes the local override and the nameservice-strict abstraction exists, then apply the observed correction:

```bash
mkdir -p /etc/apparmor.d/local
# Merge with existing local rules rather than overwriting them.
printf '%s\n' 'include <abstractions/nameservice-strict>' >> /etc/apparmor.d/local/who
chmod 0644 /etc/apparmor.d/local/who
apparmor_parser -r /etc/apparmor.d/who
journalctl -k --since '10 minutes ago' | grep -E 'apparmor.*(DENIED|profile_replace)'
```

Add the include only once. AppArmor remains enforced. No reboot required for this fix.

## 18. Recommended functional acceptance tests

The following tests provide a useful final check after the configuration work.

### 18.1 Web interface

- Open the FreePBX administration interface.
- Log in successfully.
- Navigate between the major administration pages.
- Confirm there are no PHP fatal errors or blank pages.
- Confirm Apache and PHP-FPM remain active.

### 18.2 FreePBX configuration writes

- Make a harmless test configuration change through the GUI.
- Apply the configuration.
- Confirm FreePBX completes the reload successfully.
- Verify the relevant generated Asterisk configuration is updated.

### 18.3 Asterisk

- Confirm Asterisk starts without module-loading failures.
- Confirm PJSIP endpoints load.
- Confirm voicemail loads.
- Confirm music on hold and WAV/PCM format modules load.

### 18.4 Database and ODBC

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

## 19. Important maintenance notes

### 19.1 Generated versus custom configuration

FreePBX owns and regenerates many files under `/etc/asterisk`.

Avoid manually editing generated files such as:

```text
/etc/asterisk/res_odbc_additional.conf
```

For FreePBX-managed configuration, use:

- The FreePBX GUI
- The FreePBX `ConfigFile` API
- Supported `*_custom.conf` files

### 19.2 Restarting services

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

### 19.3 Database password handling

The FreePBX database password is stored in:

```text
/root/freepbx-db-password
```

Keep the file restricted:

```bash
chmod 600 /root/freepbx-db-password
```

Do not copy the password into this runbook.

### 19.4 ODBC driver maintenance

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

## 20. Final configuration checklist

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

## 21. Rebuild acceptance and evidence limitations

- Confirm PHP 8.3 only, APT priorities and simulated upgrades; third-party repository priority 100 is not an absolute block.
- Verify Asterisk process health and actual limits after reboot, not just systemd status.
- Verify all three PM2 processes after reboot; automatic startup was not independently established.
- Verify GUI login, configuration write and reload, PJSIP registration and two-way test call.
- Verify actual CDR and CEL rows after a test call. ODBC connectivity and CEL subscription were confirmed, but the recorded evidence does not establish this end-to-end test.
- Review service and Asterisk logs; optional proprietary G.729/G.723 codecs and their executable-stack compatibility are outside the baseline.
- Back up configuration, databases, source archives and Menuselect file. Protect secrets and private keys; test restore separately.

Evidence: original installation runbook, database addendum, config.log, configure.log, menuselect.makeopts, APT history.log, repository policy capture and subsequent server command outputs. Missing original repository bootstrap, exact initial SQL, exact parallel build invocation and some intermediate commands are reconstructed, not claimed as historical facts. This consolidated procedure has not been executed on a second clean host. The original source archive and package versions may no longer be available; verify downloads and dependency resolution before use.

## Appendix A — exact saved Asterisk Menuselect configuration

Save the following as `menuselect.makeopts` (without Markdown fences). It is specific to Asterisk 22.12.0 and the recorded build environment.

```makefile
MENUSELECT_ADDONS=chan_mobile chan_ooh323 format_mp3 res_config_mysql 
MENUSELECT_APPS=app_flash app_skel app_speech_utils app_voicemail_imap app_voicemail_odbc app_ivrdemo app_jack app_saycounted app_statsd app_adsiprog app_getcpeid app_meetme 
MENUSELECT_BRIDGES=binaural_rendering_in_bridge_softmix 
MENUSELECT_CDR=cdr_beanstalkd cdr_pgsql cdr_radius cdr_tds 
MENUSELECT_CEL=cel_custom cel_beanstalkd cel_pgsql cel_radius cel_tds 
MENUSELECT_CHANNELS=chan_dahdi chan_motif chan_console chan_unistim 
MENUSELECT_CODECS=codec_dahdi codec_silk codec_siren7 codec_siren14 codec_g729a 
MENUSELECT_FORMATS=
MENUSELECT_FUNCS=
MENUSELECT_PBX=pbx_ael pbx_lua 
MENUSELECT_RES=res_aeap res_mwi_external_ami res_pjsip_pidf_digium_body_supplement res_pjsip_pidf_eyebeam_body_supplement res_pjsip_stir_shaken res_speech_aeap res_stasis_test res_stir_shaken res_timing_dahdi res_xmpp res_ael_share res_calendar res_calendar_caldav res_calendar_ews res_calendar_exchange res_calendar_icalendar res_chan_stats res_cliexec res_config_ldap res_config_pgsql res_corosync res_endpoint_stats res_hep_rtcp res_pjsip_aoc res_prometheus res_remb_modifier res_smdi res_snmp res_statsd res_timing_kqueue res_adsi res_digium_phone res_pjsip_config_sangoma ENABLE_SRTP_AES_192 ENABLE_SRTP_AES_256 ENABLE_SRTP_AES_GCM 
MENUSELECT_TESTS=test_abstract_jb test_acl test_aeap test_aeap_speech test_aeap_transaction test_aeap_transport test_amihooks test_aoc test_app test_ari test_ari_model test_ast_format_str_reduce test_astobj2 test_astobj2_thrash test_astobj2_weaken test_bridging test_bucket test_callerid test_capture test_cdr test_cel test_channel test_channel_feature_hooks test_config test_conversions test_core_codec test_core_format test_crypto test_data_buffer test_db test_devicestate test_dlinklists test_dns test_dns_naptr test_dns_query_set test_dns_recurring test_dns_srv test_endpoints test_event test_expr test_file test_format_cache test_format_cap test_func_file test_gosub test_hashtab_thrash test_heap test_http_media_cache test_jitterbuf test_json test_linkedlists test_locale test_logger test_media_cache test_message test_mwi test_named_lock test_netsock2 test_optional_api test_pbx test_performance test_poll test_res_pjsip_scheduler test_res_pjsip_session_caps test_res_rtp test_res_stasis test_sched test_scope_trace test_scoped_lock test_security_events test_skel test_sorcery test_sorcery_astdb test_sorcery_memory_cache_thrash test_sorcery_realtime test_stasis test_stasis_channels test_stasis_endpoints test_stasis_state test_stream test_stringfields test_strings test_substitution test_taskpool test_taskprocessor test_threadpool test_time test_uri test_utils test_uuid test_vector test_voicemail_api test_websocket_client test_xml_escape test_codec_translations test_res_prometheus 
MENUSELECT_CHANNELSTORAGE=channelstorage_cpp_map_name_id 
MENUSELECT_CFLAGS=BUILD_NATIVE OPTIONAL_API 
MENUSELECT_UTILS=astcanary astdb2sqlite3 astdb2bdb 
MENUSELECT_AGIS=
MENUSELECT_CORE_SOUNDS=CORE-SOUNDS-EN-GSM 
MENUSELECT_MOH=MOH-OPSOUND-WAV 
MENUSELECT_EXTRA_SOUNDS=
MENUSELECT_BUILD_DEPS=bridge_holding app_cdr func_periodic_hook app_confbridge res_agi res_stasis res_ari res_audiosocket res_stasis_broadcast res_odbc res_cdrel_custom res_crypto res_pjsip res_pjsip_pubsub res_pjsip_session res_rtp_multicast res_http_websocket res_websocket_client res_format_attr_opus res_curl app_chanspy func_cut func_groupcount func_uri res_speech res_ari_model res_stasis_recording res_stasis_playback res_stasis_answer res_stasis_snoop res_stasis_device_state res_stasis_mailbox func_curl res_odbc_transaction res_sorcery_config res_pjproject res_sorcery_memory res_sorcery_astdb res_geolocation res_pjsip_outbound_publish chan_pjsip res_mwi_external res_fax res_hep res_phoneprov DONT_OPTIMIZE G711_NEW_ALGORITHM 
MENUSELECT_DEPSFAILED=MENUSELECT_APPS=app_flash
MENUSELECT_DEPSFAILED=MENUSELECT_APPS=app_jack
MENUSELECT_DEPSFAILED=MENUSELECT_CDR=cdr_beanstalkd
MENUSELECT_DEPSFAILED=MENUSELECT_CDR=cdr_pgsql
MENUSELECT_DEPSFAILED=MENUSELECT_CDR=cdr_radius
MENUSELECT_DEPSFAILED=MENUSELECT_CDR=cdr_tds
MENUSELECT_DEPSFAILED=MENUSELECT_CEL=cel_beanstalkd
MENUSELECT_DEPSFAILED=MENUSELECT_CEL=cel_pgsql
MENUSELECT_DEPSFAILED=MENUSELECT_CEL=cel_radius
MENUSELECT_DEPSFAILED=MENUSELECT_CEL=cel_tds
MENUSELECT_DEPSFAILED=MENUSELECT_CHANNELS=chan_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_CHANNELS=chan_motif
MENUSELECT_DEPSFAILED=MENUSELECT_CHANNELS=chan_console
MENUSELECT_DEPSFAILED=MENUSELECT_CODECS=codec_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_PBX=pbx_lua
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_pjsip_stir_shaken
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_stasis_test
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_stir_shaken
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_timing_dahdi
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_xmpp
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_calendar_exchange
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_config_pgsql
MENUSELECT_DEPSFAILED=MENUSELECT_RES=res_timing_kqueue
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_abstract_jb
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_acl
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_speech
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_transaction
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aeap_transport
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_amihooks
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_aoc
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_app
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ari
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ari_model
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_ast_format_str_reduce
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_astobj2_weaken
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_bridging
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_bucket
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_callerid
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_capture
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_cdr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_cel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_channel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_channel_feature_hooks
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_config
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_conversions
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_core_codec
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_core_format
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_crypto
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_data_buffer
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_db
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_devicestate
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dlinklists
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_naptr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_query_set
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_recurring
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_dns_srv
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_endpoints
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_event
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_expr
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_file
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_format_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_format_cap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_func_file
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_gosub
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_hashtab_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_heap
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_http_media_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_jitterbuf
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_json
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_linkedlists
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_locale
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_logger
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_media_cache
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_message
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_mwi
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_named_lock
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_netsock2
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_optional_api
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_pbx
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_performance
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_poll
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_pjsip_scheduler
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_pjsip_session_caps
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_rtp
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_stasis
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sched
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_scope_trace
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_scoped_lock
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_security_events
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_skel
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_astdb
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_memory_cache_thrash
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_sorcery_realtime
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_channels
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_endpoints
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stasis_state
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stream
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_stringfields
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_strings
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_substitution
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_taskpool
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_taskprocessor
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_threadpool
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_time
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_uri
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_utils
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_uuid
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_vector
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_voicemail_api
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_websocket_client
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_xml_escape
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_codec_translations
MENUSELECT_DEPSFAILED=MENUSELECT_TESTS=test_res_prometheus
```
