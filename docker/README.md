# Dblore Docker databases

Local database servers to connect the app to and to run the integration tests against. Run
every command from the repository root. Test ports are bound to `127.0.0.1`, the passwords are
for local testing only, and data stays in Docker volumes until `docker compose -f <file> down -v`.

## Servers

| Server | Compose file | Port | Login |
|--------|--------------|------|-------|
| PostgreSQL dev (sample data) | `postgresql/docker-compose.yml` | 5433 | `postgresql://dblore:dblore123@localhost:5433/dblore` |
| PostgreSQL test | `postgresql/docker-compose.test.yml` | 5435 | user `dblore_test`, password `dblore123`, database `dblore_test` |
| PostgreSQL mTLS | `postgresql/docker-compose.mtls.yml` | 5436 | user `dblore_mtls`, password `dblore123`, database `dblore_mtls` |
| MySQL 8.4 / MariaDB 11.4 | `mysql/docker-compose.test.yml` | 3307 / 3308 | user `root` (or `dblore_test`), password `dblore123`, database `dblore_test` |
| MongoDB 8.0 | `mongodb/docker-compose.test.yml` | 27018 | `mongodb://root:dblore123@localhost:27018/?authSource=admin` |
| MongoDB 8.0 TLS | same, `--profile tls` | 27019 | `mongodb://root:dblore123@localhost:27019/?authSource=admin&tls=true` |
| SSH tunnel stack | `postgresql/docker-compose.ssh.yml` | 2222 / 2223 | see [SSH tunnel stack](#ssh-tunnel-stack) |

Start everything (the certificate and key scripts are needed once):

```sh
cp -n docker/postgresql/.env.example docker/postgresql/.env
docker/postgresql/scripts/gen-mtls-certs.sh
docker/postgresql/scripts/gen-ssh-fixtures.sh
docker/mongodb/scripts/gen-mongo-tls.sh
for f in docker/postgresql/docker-compose{,.test,.mtls,.ssh}.yml docker/mysql/docker-compose.test.yml; do
  docker compose -f "$f" up -d --wait
done
docker compose -f docker/mongodb/docker-compose.test.yml --profile tls up -d --wait
```

Or start one server with `docker compose -f docker/<compose file> up -d --wait`.

## TLS and certificates

The generated certificates are gitignored.

- **PostgreSQL mTLS**: `docker/postgresql/scripts/gen-mtls-certs.sh`, then connect with SSL
  Verify Full, CA `docker/postgresql/data/mtls/ca.crt`, client certificate `client.crt` and
  key `client.key` from the same folder.
- **MySQL and MariaDB**: `docker/mysql/scripts/gen-mysql-tls.sh`, recreate the containers with
  `--force-recreate`, then connect with SSL Verify Full and CA `docker/mysql/data/tls/ca.crt`.
- **MongoDB**: `docker/mongodb/scripts/gen-mongo-tls.sh` writes a test CA and a server
  certificate for `localhost` and `127.0.0.1` into `docker/mongodb/tls/`; connect with CA
  `docker/mongodb/tls/ca.crt`. The TLS container copies them when it starts, so after
  generating new ones recreate it with `--force-recreate mongo-tls-test`. A plain `up` never
  starts `mongo-tls-test`.

## PostgreSQL dev database

Port 5433 avoids a local PostgreSQL on 5432. Credentials and port come from
`docker/postgresql/.env` (copied from `.env.example`). On first start, `init/` creates six
tables (`customers`, `products`, `orders`, `order_items`, `employees`, `analytics_events`)
and two views with sample data. Init scripts only run on an empty volume.

Helper scripts, run from `docker/postgresql`:

```sh
./scripts/psql.sh                        # interactive psql shell
./scripts/add-data.sh file.sql           # apply a SQL file (for example from migrations/)
./scripts/backup-db.sh                   # dump to backups/
./scripts/restore-db.sh backups/file.sql # drop the schema, restore and check row counts
./scripts/reset-db.sh                    # back to the init scripts (deletes all data)
```

## MongoDB

`init/01-users.js` creates these users in `admin` (connect with `authSource=admin`), all with
the password `dblore123`. The root user is `root` / `dblore123`.

| User | Roles | Login |
|------|-------|-------|
| `dblore_test` | `readWrite` and `dbAdmin` (collMod) on `dblore_test` and `dblore_test_other` (create / drop database), `clusterMonitor` | SCRAM-SHA-256 |
| `dblore_reader` | `read` on `dblore_test` | SCRAM-SHA-256 |
| `dblore_sha1` | `readWrite` on `dblore_test` | SCRAM-SHA-1 |

For more data, load MongoDB's sample datasets into the 27018 server:

```sh
curl -o /tmp/sampledata.archive https://atlas-education.s3.amazonaws.com/sampledata.archive
docker cp /tmp/sampledata.archive dblore-mongo-test:/tmp/sampledata.archive
docker exec dblore-mongo-test mongorestore -u root -p dblore123 --authenticationDatabase admin \
  --archive=/tmp/sampledata.archive --drop
```

## SSH tunnel stack

An SSH server in front of databases that publish no port, so they are reachable only through
an SSH tunnel. Generate the keys and certificates once with
`docker/postgresql/scripts/gen-ssh-fixtures.sh` (written to `docker/postgresql/data/ssh/`),
then start it without `--project-directory`, so `./data` resolves next to the compose file.

| Service | Reach | Details |
|---------|-------|---------|
| `sshd` | `localhost:2222` | ed25519 host key; user `dblore`, password `dblore-ssh-123` or the generated keys |
| `sshd-rsa` | `localhost:2223` | same, with an RSA-only host key, which the app refuses |
| `postgres` | tunnel target `postgres:5432` | PostgreSQL 16, user, password and database `dblore_ssh` / `dblore123` / `dblore_ssh`; use SSL Disable (self-signed certificate) |
| `mysql-ssh` | tunnel target `mysql-ssh:3306` | MySQL 8.4, user, password and database `dblore_ssh` / `dblore123` / `dblore_ssh` |
| `mongo-ssh` | tunnel target `mongo-ssh:27017` | MongoDB 8.0, user `root`, password `dblore123`, Auth Source `admin` |

If certificates are missing or out of date, delete `data/ssh/ca.*`, `data/ssh/mysql/` and
`data/ssh/mongo/` together and run the script again.

## Integration tests

A plain `xcodebuild test` needs no container: every suite that needs a live database is
skipped unless its gate is on. Put the gate in front of `xcodebuild` (it passes
`TEST_RUNNER_<NAME>` to the tests as `<NAME>`, so in an Xcode scheme set `<NAME>` instead).
`SKIP_INTEGRATION_TESTS=true` turns every gate off.

| Gate | Server |
|------|--------|
| `TEST_RUNNER_POSTGRES_TESTS=1` | PostgreSQL test (5435) |
| `TEST_RUNNER_MTLS_TESTS=1` | PostgreSQL mTLS (5436) |
| `TEST_RUNNER_MYSQL_TESTS=1` | MySQL 8.4 and MariaDB 11.4 |
| `TEST_RUNNER_MYSQL_TLS_TESTS=1` | MySQL and MariaDB, after `gen-mysql-tls.sh` |
| `TEST_RUNNER_MONGO_TESTS=1` | MongoDB (27018) |
| `TEST_RUNNER_MONGO_TLS_TESTS=1` | MongoDB TLS (27019) |
| `TEST_RUNNER_SSH_TESTS=1` | SSH tunnel stack |

The default hosts, ports and logins match the servers above. Override them the same way,
for example `TEST_RUNNER_TEST_DB_PORT` (PostgreSQL), `TEST_RUNNER_TEST_MYSQL_PORT`,
`TEST_RUNNER_TEST_MARIADB_PORT` and `TEST_RUNNER_TEST_MONGO_PORT`.

```sh
docker compose -f docker/postgresql/docker-compose.test.yml up -d --wait
TEST_RUNNER_POSTGRES_TESTS=1 xcodebuild test -project Dblore.xcodeproj -scheme Dblore \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO \
  -parallel-testing-enabled NO -skipPackagePluginValidation -skipMacroValidation
```

## CI live databases

The `integration` job of `.github/workflows/ci.yml` runs the PostgreSQL, MySQL/MariaDB and
MongoDB suites on the self-hosted runner. `scripts/ci-live-databases.sh` starts a separate
copy of the test servers under the compose project `dblore-ci` (containers, volumes and
networks named `dblore-ci-*`), so the local `dblore-*-test` containers and their data are
never touched. `mysql` starts both MySQL and MariaDB; `mongo` starts only the plain server.

```sh
scripts/ci-live-databases.sh start postgres mysql mongo
TEST_RUNNER_MYSQL_TESTS=1 TEST_RUNNER_MONGO_TESTS=1 TEST_RUNNER_TEST_DB_PORT=15435 \
  TEST_RUNNER_TEST_MYSQL_PORT=13307 TEST_RUNNER_TEST_MARIADB_PORT=13308 \
  TEST_RUNNER_TEST_MONGO_PORT=13018 \
  xcodebuild test -project Dblore.xcodeproj -scheme Dblore -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation
scripts/ci-live-databases.sh stop postgres mysql mongo   # removes containers, networks and volumes
```

| Database | Local port | CI port | Override (compose and script) |
|----------|------------|---------|-------------------------------|
| PostgreSQL 16 | 5435 | 15435 | `DBLORE_PG_TEST_PORT` |
| MySQL 8.4 | 3307 | 13307 | `DBLORE_MYSQL_TEST_PORT` |
| MariaDB 11.4 | 3308 | 13308 | `DBLORE_MARIADB_TEST_PORT` |
| MongoDB 8.0 | 27018 | 13018 | `DBLORE_MONGO_TEST_PORT` |

`DBLORE_TEST_NAME_PREFIX` (default `dblore`) names the containers, volumes and networks.
`start` fails with a clear message when Docker is not reachable or a CI port is taken. The
MySQL TLS, MongoDB TLS, mTLS, SSH and DuckDB plugin suites stay local-only.
