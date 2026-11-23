Contains run book for FreePBX 17 and Asterisk 22 build

The install-sip-chilimac-cert.sh is a script that gets called after a new certificate is generated from Lets Encrypt.  It copies it into place on the Asterisk/FreePBX server and
restarts Asterisk with 'fwconsole restart'
