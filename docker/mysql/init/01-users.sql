-- Runs once per fresh volume on both MySQL 8.4 and MariaDB 11.4.
-- dblore_test itself comes from MYSQL_USER / MARIADB_USER: caching_sha2_password
-- on MySQL (server default), mysql_native_password on MariaDB (pinned below).

/*M! ALTER USER 'dblore_test'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('dblore123') */;

-- mTLS user: needs a client certificate signed by data/tls/ca.crt
-- (scripts/gen-mysql-tls.sh). Created even without certs so a later
-- gen + recreate needs no volume reset.
CREATE USER IF NOT EXISTS 'dblore_x509'@'%' IDENTIFIED BY 'dblore123' REQUIRE X509;
GRANT ALL PRIVILEGES ON dblore_test.* TO 'dblore_x509'@'%';
