# FreePBX 17 Database and ODBC Setup

This section documents the MariaDB database configuration, ODBC driver installation, and Asterisk database integration for the FreePBX 17 / Asterisk 22 installation on Ubuntu Server 26.04.1 LTS.

## 1. Install MariaDB

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

## 2. MariaDB socket configuration

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

## 3. Create the FreePBX databases and database account

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

## 4. Install MariaDB Connector/ODBC

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

## 5. Install and configure unixODBC

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

## 6. Test the ODBC connection

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

## 7. Configure Asterisk ODBC

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

## 8. Configure CEL ODBC logging

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

## 9. Restart Asterisk and verify ODBC

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

## 10. Database and ODBC configuration file summary

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

## 11. Final verification checklist

- [ ] MariaDB service is enabled and running.
- [ ] MariaDB reports version 11.8.6.
- [ ] Databases `asterisk` and `asteriskcdrdb` exist.
- [ ] Database account `freepbxuser` exists.
- [ ] MariaDB socket is `/run/mysqld/mysqld.sock`.
- [ ] MariaDB Connector/ODBC driver is registered as `MySQL`.
- [ ] ODBC DSN `MySQL-asteriskcdrdb` is registered.
- [ ] `isql` successfully connects to `asteriskcdrdb`.
- [ ] Asterisk reports an active `asteriskcdrdb` ODBC connection.
- [ ] CEL logging is enabled and the ODBC CEL backend is subscribed.

**Implementation note:** The ODBC connection and CEL subscription were verified. A separate end-to-end test that places a call and confirms the resulting CDR and CEL rows in MariaDB should be performed as a final functional test.
