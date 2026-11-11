// dblore_tds.c
// FreeTDS db-lib shim of the SQL Server plugin (see dblore_tds.h).
//
// Configuration: db-lib has no LOGINREC option for the CA file or the certificate host name (the
// login copies neither to the connection), so every open hands FreeTDS a configuration file the
// Swift driver wrote for that open alone, through db-lib's `dbsetifile`. Its section always
// matches, so FreeTDS stops there and never looks for freetds.conf ($FREETDSCONF, $FREETDS,
// ~/.config/freetds.conf, ~/.freetds.conf, the built-in path). A missing file would send it
// searching there, so the open fails unless the file is a regular file just before `dbopen`.
// It is not the only input: after the file, FreeTDS applies the environment variables TDSVER,
// TDSPORT, TDSHOST and TDSDUMP (`tds_fix_login`), and TDSDUMPCONFIG opens a dump of the search
// before it. OpenSSL starts with OPENSSL_INIT_NO_LOAD_CONFIG, so no openssl.cnf is read either.
//
// Handlers: db-lib's error and message handlers are process-wide. Each function below names its
// connection in a thread-local before calling db-lib, and the handlers write into that
// connection's error text. Passwords never reach them.
//
// Cancel: `dblore_tds_request_cancel` sets an atomic flag. db-lib polls the socket once a second
// and calls the interrupt check, which then answers INT_CANCEL; db-lib reports that as a timeout
// (SYBETIME) to the error handler, which answers INT_TIMEOUT, so libtds sends the TDS attention
// and keeps reading until the server acknowledges it. Any other answer to SYBETIME would close
// the socket. Rows that keep arriving never time out, so the row loop checks the flag itself.
// The client statement timeout takes the same path: its deadline turns into the same attention.
//
// Encryption downgrade: under `encryption = require`, FreeTDS 1.5.21 (`tds71_do_login` in
// src/tds/login.c) fails a pre-login answer of ENCRYPT_NOT_SUP, but on ENCRYPT_OFF it encrypts
// the login packet only and then drops TLS (`encrypt_single_packet`, `tds_ssl_deinit`): the
// session goes on in clear text, and db-lib reports success. Every OpenSSL `SSL` object created
// during an open is counted through an ex_data index (its new and free callbacks), so an open
// that required encryption and ends without a live `SSL` is closed again and fails.
//
// Cells: `dblore_tds_cell_get` hands Swift db-lib's own bytes; only money, decimal and the date
// and time types are repacked into the fixed little-endian layouts of dblore_tds.h. Nothing is
// converted to text.

#include "dblore_tds.h"

#include <sybfront.h>
#include <sybdb.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum { DBLORE_TEXT_SIZE = 1024 };

/// libtds' bytes of a TDS_NUMERIC (sign byte included) per precision; the magnitude after the
/// sign byte is big-endian in that many bytes minus one
extern const int tds_numeric_bytes_per_prec[];

struct dblore_tds_conn {
  DBPROCESS *dbproc;
  atomic_bool cancel_requested;
  /// The attention for the current cancel went out; set on the connection's own thread
  bool attention_sent;
  char server_error[DBLORE_TEXT_SIZE];
  char client_error[DBLORE_TEXT_SIZE];
  char message[2 * DBLORE_TEXT_SIZE + 4];
  int error_number;
  int error_state;
  /// Client statement timeout in seconds (0: none) and the running statement's deadline
  int statement_timeout;
  uint64_t deadline_ns;
  bool timed_out;
  bool timeout_reported;
  /// `SSL` objects of this open still alive, counted while the open runs (see the top); an
  /// object that could not be marked as this open's makes the count unknown
  int live_tls;
  bool tls_untracked;
  /// A repacked cell (money, decimal, date and time)
  unsigned char cell[40];
};

/// The connection whose db-lib call runs on this thread; the handlers report into it
static _Thread_local dblore_tds_conn *current_conn;

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static bool init_succeeded;
static char freetds_version[32] = "unknown";
/// `dbsetifile` sets a process-wide path that `dbopen` reads
static pthread_mutex_t open_lock = PTHREAD_MUTEX_INITIALIZER;
/// The connection whose open runs on this thread: OpenSSL objects created now are its own
static _Thread_local dblore_tds_conn *opening_conn;
static int tls_index = -1;

// MARK: - Statement timeout

static uint64_t now_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}

/// Whether the running statement passed its deadline; marks it timed out once
static bool deadline_passed(dblore_tds_conn *conn) {
  if (conn->timed_out) return true;
  if (conn->deadline_ns == 0 || now_ns() < conn->deadline_ns) return false;
  conn->timed_out = true;
  return true;
}

// MARK: - Errors

static void append_text(char *buffer, size_t size, const char *text) {
  if (!text || !*text) return;
  size_t used = strlen(buffer);
  if (used > 0 && used + 2 < size) {
    strlcat(buffer, " ", size);
  }
  strlcat(buffer, text, size);
}

/// Once per statement
static void append_timeout(dblore_tds_conn *conn) {
  if (conn->timeout_reported) return;
  conn->timeout_reported = true;
  char text[96];
  snprintf(text, sizeof text, "The statement was stopped by the %d s statement timeout.",
           conn->statement_timeout);
  append_text(conn->client_error, sizeof conn->client_error, text);
}

static int handle_error(DBPROCESS *dbproc, int severity, int dberr, int oserr, char *dberrstr,
                        char *oserrstr) {
  (void)dbproc;
  (void)severity;
  dblore_tds_conn *conn = current_conn;
  if (dberr == SYBETIME) {
    // Only a cancel or the statement deadline makes db-lib time out: no db-lib timeout is set
    if (conn && (atomic_load(&conn->cancel_requested) || conn->timed_out)) {
      if (conn->timed_out) append_timeout(conn);
      conn->attention_sent = true;
      return INT_TIMEOUT;  // libtds sends the attention and keeps reading
    }
    if (conn) append_text(conn->client_error, sizeof conn->client_error, dberrstr);
    return INT_CANCEL;
  }
  // "Check messages from the SQL Server": the message handler has them
  if (dberr == SYBESMSG || !conn) return INT_CANCEL;
  append_text(conn->client_error, sizeof conn->client_error, dberrstr);
  if (oserr != DBNOERR && oserr != 0 && oserrstr && *oserrstr) {
    char os[256];
    snprintf(os, sizeof os, "(%s)", oserrstr);
    append_text(conn->client_error, sizeof conn->client_error, os);
  }
  // Never INT_EXIT, INT_CONTINUE or INT_TIMEOUT here: db-lib would exit the process
  return INT_CANCEL;
}

static int handle_message(DBPROCESS *dbproc, DBINT msgno, int msgstate, int severity,
                          char *msgtext, char *srvname, char *procname, int line) {
  (void)dbproc;
  (void)srvname;
  (void)procname;
  (void)line;
  dblore_tds_conn *conn = current_conn;
  // Severity 10 and below are informational ("Changed database context to ...")
  if (!conn || severity <= 10) return 0;
  append_text(conn->server_error, sizeof conn->server_error, msgtext);
  if (conn->error_number == 0) {
    conn->error_number = (int)msgno;
    conn->error_state = msgstate;
  }
  return 0;
}

static int check_interrupt(void *dbproc) {
  (void)dbproc;
  dblore_tds_conn *conn = current_conn;
  if (!conn || conn->attention_sent) return 0;
  return atomic_load(&conn->cancel_requested) || deadline_passed(conn);
}

static int handle_interrupt(void *dbproc) {
  (void)dbproc;
  return INT_CANCEL;
}

// MARK: - TLS tracking

/// Every `SSL` created on a thread whose open is running belongs to that open
static void tls_created(void *parent, void *ptr, CRYPTO_EX_DATA *data, int index, long argl,
                        void *argp) {
  (void)parent;
  (void)ptr;
  (void)argl;
  (void)argp;
  dblore_tds_conn *conn = opening_conn;
  if (!conn) return;
  if (CRYPTO_set_ex_data(data, index, conn)) {
    conn->live_tls++;
  } else {
    conn->tls_untracked = true;
  }
}

/// Counted down only while its open runs: later frees (on close) never touch the connection
static void tls_freed(void *parent, void *ptr, CRYPTO_EX_DATA *data, int index, long argl,
                      void *argp) {
  (void)parent;
  (void)data;
  (void)index;
  (void)argl;
  (void)argp;
  dblore_tds_conn *conn = opening_conn;
  if (conn && ptr == conn) conn->live_tls--;
}

// MARK: - Process setup

static void global_init(void) {
  // First OpenSSL init in this image: the configuration file is never loaded afterwards either
  OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
  OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
  tls_index = SSL_get_ex_new_index(0, NULL, tls_created, NULL, tls_freed);
  if (tls_index < 0) return;
  if (dbinit() == FAIL) return;
  dberrhandle(handle_error);
  dbmsghandle(handle_message);
  const char *version = dbversion();  // "freetds v1.5.21"
  const char *number = version ? strstr(version, " v") : NULL;
  if (number) strlcpy(freetds_version, number + 2, sizeof freetds_version);
  init_succeeded = true;
}

bool dblore_tds_global_init(void) {
  pthread_once(&init_once, global_init);
  return init_succeeded;
}

const char *dblore_tds_freetds_version(void) {
  dblore_tds_global_init();
  return freetds_version;
}

const char *dblore_tds_openssl_version(void) { return OpenSSL_version(OPENSSL_VERSION_STRING); }

// MARK: - Connection

dblore_tds_conn *dblore_tds_conn_create(void) {
  dblore_tds_conn *conn = calloc(1, sizeof *conn);
  if (conn) atomic_init(&conn->cancel_requested, false);
  return conn;
}

void dblore_tds_conn_destroy(dblore_tds_conn *conn) {
  if (!conn) return;
  if (conn->dbproc) {
    current_conn = conn;
    dbclose(conn->dbproc);
    current_conn = NULL;
  }
  free(conn);
}

void dblore_tds_clear_error(dblore_tds_conn *conn) {
  conn->server_error[0] = '\0';
  conn->client_error[0] = '\0';
  conn->error_number = 0;
  conn->error_state = 0;
}

const char *dblore_tds_error_message(const dblore_tds_conn *conn) {
  dblore_tds_conn *mutable_conn = (dblore_tds_conn *)conn;
  mutable_conn->message[0] = '\0';
  append_text(mutable_conn->message, sizeof mutable_conn->message, conn->server_error);
  // Client text only adds to a server error when it says something else (a lost connection)
  if (!conn->server_error[0] || dblore_tds_is_dead(conn)) {
    append_text(mutable_conn->message, sizeof mutable_conn->message, conn->client_error);
  }
  return mutable_conn->message;
}

int dblore_tds_error_number(const dblore_tds_conn *conn) { return conn->error_number; }

int dblore_tds_error_state(const dblore_tds_conn *conn) { return conn->error_state; }

bool dblore_tds_is_dead(const dblore_tds_conn *conn) {
  return !conn->dbproc || dbdead(conn->dbproc);
}

int dblore_tds_connect(dblore_tds_conn *conn, const char *conf_path, const char *section,
                       const char *user, const char *password, const char *database,
                       bool require_encryption) {
  current_conn = conn;
  dblore_tds_clear_error(conn);
  if (!dblore_tds_global_init()) {
    append_text(conn->client_error, sizeof conn->client_error, "FreeTDS could not start.");
    current_conn = NULL;
    return -1;
  }
  LOGINREC *login = dblogin();
  if (!login) {
    append_text(conn->client_error, sizeof conn->client_error, "Out of memory.");
    current_conn = NULL;
    return -1;
  }
  bool ok = DBSETLUSER(login, user) == SUCCEED && DBSETLPWD(login, password) == SUCCEED &&
            DBSETLAPP(login, "Dblore") == SUCCEED && DBSETLCHARSET(login, "UTF-8") == SUCCEED &&
            (!database[0] || DBSETLDBNAME(login, database) == SUCCEED);
  DBPROCESS *dbproc = NULL;
  bool tried = false;
  if (ok) {
    ERR_clear_error();
    pthread_mutex_lock(&open_lock);
    // Without the file FreeTDS would search for freetds.conf: fail closed instead
    struct stat info;
    if (lstat(conf_path, &info) == 0 && S_ISREG(info.st_mode)) {
      tried = true;
      conn->live_tls = 0;
      conn->tls_untracked = false;
      opening_conn = conn;
      dbsetifile((char *)conf_path);
      dbproc = tdsdbopen(login, section, 1);
      dbsetifile(NULL);
      opening_conn = NULL;
    } else {
      append_text(conn->client_error, sizeof conn->client_error,
                  "The connection configuration file is missing.");
    }
    pthread_mutex_unlock(&open_lock);
  } else {
    append_text(conn->client_error, sizeof conn->client_error,
                "The user name, password or database name is too long.");
  }
  dbloginfree(login);
  if (!dbproc) {
    // OpenSSL's reason for a failed handshake ("certificate verify failed")
    unsigned long tls_error = tried ? ERR_peek_last_error() : 0;
    if (tls_error) {
      const char *reason = ERR_reason_error_string(tls_error);
      if (reason) {
        char text[256];
        snprintf(text, sizeof text, "(TLS: %s)", reason);
        append_text(conn->client_error, sizeof conn->client_error, text);
      }
    }
    ERR_clear_error();
    if (!conn->server_error[0] && !conn->client_error[0]) {
      append_text(conn->client_error, sizeof conn->client_error, "Could not connect.");
    }
    current_conn = NULL;
    return tried ? 0 : -1;
  }
  if (require_encryption && (conn->live_tls <= 0 || conn->tls_untracked)) {
    // FreeTDS dropped TLS after the login (a pre-login answer of ENCRYPT_OFF): never used
    dbclose(dbproc);
    append_text(conn->client_error, sizeof conn->client_error,
                "The server did not keep the connection encrypted, which this connection "
                "requires, so Dblore closed it.");
    current_conn = NULL;
    return -2;
  }
  conn->dbproc = dbproc;
  dbsetinterrupt(dbproc, check_interrupt, handle_interrupt);
  current_conn = NULL;
  return 1;
}

// MARK: - Cancel

void dblore_tds_request_cancel(dblore_tds_conn *conn) {
  atomic_store(&conn->cancel_requested, true);
}

void dblore_tds_reset_cancel(dblore_tds_conn *conn) {
  atomic_store(&conn->cancel_requested, false);
  conn->attention_sent = false;
}

bool dblore_tds_cancel_requested(const dblore_tds_conn *conn) {
  return atomic_load(&((dblore_tds_conn *)conn)->cancel_requested);
}

void dblore_tds_set_statement_timeout(dblore_tds_conn *conn, int seconds) {
  conn->statement_timeout = seconds > 0 ? seconds : 0;
}

// MARK: - Statements

bool dblore_tds_execute(dblore_tds_conn *conn, const char *sql) {
  current_conn = conn;
  dblore_tds_clear_error(conn);
  conn->attention_sent = false;
  conn->timed_out = false;
  conn->timeout_reported = false;
  conn->deadline_ns =
      conn->statement_timeout > 0 ? now_ns() + (uint64_t)conn->statement_timeout * 1000000000u : 0;
  dbfreebuf(conn->dbproc);
  bool ok = dbcmd(conn->dbproc, sql) == SUCCEED && dbsqlexec(conn->dbproc) == SUCCEED;
  // A statement stopped by its timeout fails, whatever db-lib made of the attention
  if (conn->timed_out) {
    append_timeout(conn);
    ok = false;
  }
  current_conn = NULL;
  return ok;
}

int dblore_tds_next_result(dblore_tds_conn *conn) {
  current_conn = conn;
  RETCODE rc = dbresults(conn->dbproc);
  current_conn = NULL;
  if (conn->timed_out) {
    append_timeout(conn);
    return -1;
  }
  if (rc == SUCCEED) return 1;
  if (rc == NO_MORE_RESULTS) return 0;
  return -1;
}

int dblore_tds_column_count(dblore_tds_conn *conn) { return dbnumcols(conn->dbproc); }

bool dblore_tds_column_get(dblore_tds_conn *conn, int column, dblore_tds_column *info) {
  DBPROCESS *dbproc = conn->dbproc;
  int type = dbcoltype(dbproc, column);
  if (type < 0) return false;
  const char *name = dbcolname(dbproc, column);
  info->name = name ? name : "";
  info->type = type;
  DBCOL2 server;
  memset(&server, 0, sizeof server);
  server.SizeOfStruct = sizeof server;
  current_conn = conn;
  // The server fields come before the type declaration, which fails for some types; whatever
  // that failure wrote is dropped, the text before it kept
  size_t kept = strlen(conn->client_error);
  bool known = dbtablecolinfo(dbproc, column, (DBCOL *)&server) == SUCCEED || server.ServerType;
  conn->client_error[kept] = '\0';
  current_conn = NULL;
  info->server_type = known ? server.ServerType : 0;
  info->user_type = known ? (int)server.UserType : 0;
  info->max_length = known ? (int)server.ServerMaxLength : 0;
  return true;
}

int dblore_tds_next_row(dblore_tds_conn *conn) {
  // Rows that keep arriving never reach the interrupt check
  if (atomic_load(&conn->cancel_requested)) {
    append_text(conn->client_error, sizeof conn->client_error, "The statement was cancelled.");
    return -1;
  }
  if (deadline_passed(conn)) {
    append_timeout(conn);
    return -1;
  }
  current_conn = conn;
  int result;
  for (;;) {
    STATUS rc = dbnextrow(conn->dbproc);
    if (rc == REG_ROW) {
      result = 1;
    } else if (rc == NO_MORE_ROWS) {
      result = 0;
    } else if (rc > 0) {
      continue;  // a COMPUTE row: not part of the result's columns
    } else {
      result = -1;
    }
    break;
  }
  current_conn = NULL;
  if (conn->timed_out) {
    append_timeout(conn);
    return -1;
  }
  return result;
}

static void put_le(unsigned char *out, uint64_t value, int bytes) {
  for (int i = 0; i < bytes; i++) out[i] = (unsigned char)(value >> (8 * i));
}

bool dblore_tds_cell_get(dblore_tds_conn *conn, int column, dblore_tds_cell *cell) {
  DBPROCESS *dbproc = conn->dbproc;
  int type = dbcoltype(dbproc, column);
  if (type < 0) return false;
  cell->type = type;
  BYTE *data = dbdata(dbproc, column);
  DBINT length = dbdatlen(dbproc, column);
  if (!data || length < 0) {
    cell->is_null = true;
    cell->length = 0;
    cell->data = NULL;
    return true;
  }
  cell->is_null = false;
  cell->data = data;
  cell->length = length;
  switch (type) {
    case SYBMONEY: {
      DBMONEY money;
      if ((size_t)length < sizeof money) break;
      memcpy(&money, data, sizeof money);
      put_le(conn->cell, ((uint64_t)(uint32_t)money.mnyhigh << 32) | money.mnylow, 8);
      cell->data = conn->cell;
      cell->length = 8;
      break;
    }
    case SYBDECIMAL:
    case SYBNUMERIC: {
      DBNUMERIC number;
      if ((size_t)length > sizeof number) length = sizeof number;
      memset(&number, 0, sizeof number);
      memcpy(&number, data, (size_t)length);
      int bytes = number.precision >= 1 && number.precision <= 77
                      ? tds_numeric_bytes_per_prec[number.precision]
                      : 0;
      if (bytes < 2 || bytes > (int)sizeof number.array) {
        cell->is_null = true;  // never sent by a server that passed FreeTDS' own checks
        cell->length = 0;
        cell->data = NULL;
        break;
      }
      conn->cell[0] = number.precision;
      conn->cell[1] = number.scale;
      conn->cell[2] = number.array[0] ? 1 : 0;
      memcpy(conn->cell + 3, number.array + 1, (size_t)bytes - 1);
      cell->data = conn->cell;
      cell->length = 3 + bytes - 1;
      break;
    }
    case SYBMSDATE:
    case SYBMSTIME:
    case SYBMSDATETIME2:
    case SYBMSDATETIMEOFFSET: {
      DBDATETIMEALL value;
      if ((size_t)length < sizeof value) break;
      memcpy(&value, data, sizeof value);
      put_le(conn->cell, value.time, 8);
      put_le(conn->cell + 8, (uint32_t)value.date, 4);
      put_le(conn->cell + 12, (uint16_t)value.offset, 2);
      conn->cell[14] = (unsigned char)value.time_prec;
      conn->cell[15] = (unsigned char)((value.has_time ? 1 : 0) | (value.has_date ? 2 : 0) |
                                       (value.has_offset ? 4 : 0));
      cell->data = conn->cell;
      cell->length = 16;
      break;
    }
    default:
      break;
  }
  return true;
}

long dblore_tds_rows_affected(dblore_tds_conn *conn) { return dbcount(conn->dbproc); }

void dblore_tds_discard_results(dblore_tds_conn *conn) {
  if (!conn->dbproc || dbdead(conn->dbproc)) return;
  current_conn = conn;
  dbcancel(conn->dbproc);
  current_conn = NULL;
}

// MARK: - Strict support probe

/// A TCP connection to `host:port` within `timeout_seconds`, or -1
static int connect_socket(const char *host, int port, int timeout_seconds) {
  char service[16];
  snprintf(service, sizeof service, "%d", port);
  struct addrinfo hints = {0};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *addresses = NULL;
  if (getaddrinfo(host, service, &hints, &addresses) != 0) return -1;
  int connected = -1;
  for (struct addrinfo *address = addresses; address && connected < 0;
       address = address->ai_next) {
    int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (fd < 0) continue;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, address->ai_addr, address->ai_addrlen);
    if (rc != 0 && errno == EINPROGRESS) {
      struct pollfd poller = {.fd = fd, .events = POLLOUT};
      int error = 0;
      socklen_t error_size = sizeof error;
      rc = (poll(&poller, 1, timeout_seconds * 1000) == 1 &&
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) == 0 && error == 0)
               ? 0
               : -1;
    }
    if (rc == 0) {
      fcntl(fd, F_SETFL, flags);
      struct timeval timeout = {.tv_sec = timeout_seconds, .tv_usec = 0};
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
      connected = fd;
    } else {
      close(fd);
    }
  }
  freeaddrinfo(addresses);
  return connected;
}

int dblore_tds_server_presents_certificate(const char *host, int port, int timeout_seconds) {
  dblore_tds_global_init();
  int fd = connect_socket(host, port, timeout_seconds > 0 ? timeout_seconds : 15);
  if (fd < 0) return -1;
  int presented = 0;
  SSL_CTX *context = SSL_CTX_new(TLS_client_method());
  SSL *ssl = context ? SSL_new(context) : NULL;
  if (ssl) {
    static const unsigned char alpn[] = {7, 't', 'd', 's', '/', '8', '.', '0'};
    SSL_set_verify(ssl, SSL_VERIFY_NONE, NULL);
    SSL_set_alpn_protos(ssl, alpn, sizeof alpn);
    SSL_set_fd(ssl, fd);
    int rc = SSL_connect(ssl);
    presented = rc == 1 || SSL_get0_peer_certificate(ssl) != NULL;
    SSL_free(ssl);
  }
  SSL_CTX_free(context);
  ERR_clear_error();
  close(fd);
  return presented;
}
