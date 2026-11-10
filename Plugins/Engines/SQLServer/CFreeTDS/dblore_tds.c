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
#include <unistd.h>

enum { DBLORE_TEXT_SIZE = 1024 };
/// Largest conversion buffer of one cell: twice the protocol's largest value (256 MiB)
#define DBLORE_CELL_TEXT_MAX ((size_t)512 << 20)

struct dblore_tds_conn {
  DBPROCESS *dbproc;
  atomic_bool cancel_requested;
  /// The attention for the current cancel went out; set on the connection's own thread
  bool attention_sent;
  char server_error[DBLORE_TEXT_SIZE];
  char client_error[DBLORE_TEXT_SIZE];
  char message[2 * DBLORE_TEXT_SIZE + 4];
  int error_number;
  char *cell;
  size_t cell_capacity;
};

/// The connection whose db-lib call runs on this thread; the handlers report into it
static _Thread_local dblore_tds_conn *current_conn;

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static bool init_succeeded;
static char freetds_version[32] = "unknown";
/// `dbsetifile` sets a process-wide path that `dbopen` reads
static pthread_mutex_t open_lock = PTHREAD_MUTEX_INITIALIZER;

// MARK: - Errors

static void append_text(char *buffer, size_t size, const char *text) {
  if (!text || !*text) return;
  size_t used = strlen(buffer);
  if (used > 0 && used + 2 < size) {
    strlcat(buffer, " ", size);
  }
  strlcat(buffer, text, size);
}

static int handle_error(DBPROCESS *dbproc, int severity, int dberr, int oserr, char *dberrstr,
                        char *oserrstr) {
  (void)dbproc;
  (void)severity;
  dblore_tds_conn *conn = current_conn;
  if (dberr == SYBETIME) {
    // Only a cancel makes db-lib time out: no query timeout is set
    if (conn && atomic_load(&conn->cancel_requested)) {
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
  (void)msgstate;
  (void)srvname;
  (void)procname;
  (void)line;
  dblore_tds_conn *conn = current_conn;
  // Severity 10 and below are informational ("Changed database context to ...")
  if (!conn || severity <= 10) return 0;
  append_text(conn->server_error, sizeof conn->server_error, msgtext);
  if (conn->error_number == 0) conn->error_number = (int)msgno;
  return 0;
}

static int check_interrupt(void *dbproc) {
  (void)dbproc;
  dblore_tds_conn *conn = current_conn;
  return conn && atomic_load(&conn->cancel_requested) && !conn->attention_sent;
}

static int handle_interrupt(void *dbproc) {
  (void)dbproc;
  return INT_CANCEL;
}

// MARK: - Process setup

static void global_init(void) {
  // First OpenSSL init in this image: the configuration file is never loaded afterwards either
  OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
  OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
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
  free(conn->cell);
  free(conn);
}

void dblore_tds_clear_error(dblore_tds_conn *conn) {
  conn->server_error[0] = '\0';
  conn->client_error[0] = '\0';
  conn->error_number = 0;
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

bool dblore_tds_is_dead(const dblore_tds_conn *conn) {
  return !conn->dbproc || dbdead(conn->dbproc);
}

int dblore_tds_connect(dblore_tds_conn *conn, const char *conf_path, const char *section,
                       const char *user, const char *password, const char *database) {
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
      dbsetifile((char *)conf_path);
      dbproc = tdsdbopen(login, section, 1);
      dbsetifile(NULL);
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

// MARK: - Statements

bool dblore_tds_execute(dblore_tds_conn *conn, const char *sql) {
  current_conn = conn;
  dblore_tds_clear_error(conn);
  dbfreebuf(conn->dbproc);
  bool ok = dbcmd(conn->dbproc, sql) == SUCCEED && dbsqlexec(conn->dbproc) == SUCCEED;
  current_conn = NULL;
  return ok;
}

int dblore_tds_next_result(dblore_tds_conn *conn) {
  current_conn = conn;
  RETCODE rc = dbresults(conn->dbproc);
  current_conn = NULL;
  if (rc == SUCCEED) return 1;
  if (rc == NO_MORE_RESULTS) return 0;
  return -1;
}

int dblore_tds_column_count(dblore_tds_conn *conn) { return dbnumcols(conn->dbproc); }

const char *dblore_tds_column_name(dblore_tds_conn *conn, int column) {
  const char *name = dbcolname(conn->dbproc, column);
  return name ? name : "";
}

const char *dblore_tds_column_type_name(dblore_tds_conn *conn, int column) {
  const char *name = dbprtype(dbcoltype(conn->dbproc, column));
  return name ? name : "";
}

int dblore_tds_next_row(dblore_tds_conn *conn) {
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
  return result;
}

static bool reserve_cell(dblore_tds_conn *conn, size_t capacity) {
  if (conn->cell_capacity >= capacity) return true;
  char *cell = realloc(conn->cell, capacity);
  if (!cell) return false;
  conn->cell = cell;
  conn->cell_capacity = capacity;
  return true;
}

long dblore_tds_cell_text(dblore_tds_conn *conn, int column, const char **text) {
  DBPROCESS *dbproc = conn->dbproc;
  BYTE *data = dbdata(dbproc, column);
  if (!data) return -1;
  DBINT length = dbdatlen(dbproc, column);
  if (length < 0) return -1;
  int type = dbcoltype(dbproc, column);
  switch (type) {
    case SYBCHAR:
    case SYBVARCHAR:
    case SYBTEXT:
    case SYBNTEXT:
    case SYBNVARCHAR:
      *text = (const char *)data;  // already UTF-8, the client charset
      return length;
    case SYBBINARY:
    case SYBVARBINARY:
    case SYBIMAGE: {
      static const char digits[] = "0123456789ABCDEF";
      if (!reserve_cell(conn, (size_t)length * 2 + 3)) return -2;
      char *out = conn->cell;
      *out++ = '0';
      *out++ = 'x';
      for (DBINT i = 0; i < length; i++) {
        *out++ = digits[data[i] >> 4];
        *out++ = digits[data[i] & 0x0F];
      }
      *out = '\0';
      *text = conn->cell;
      return (long)length * 2 + 2;
    }
    default:
      break;
  }
  // Numbers, dates, money, uniqueidentifier, ...: db-lib's own text form. The buffer grows up to
  // DBLORE_CELL_TEXT_MAX (fits a DBINT); a text form that needs more is -2.
  current_conn = conn;
  long result = -2;
  size_t capacity = 64 + (size_t)length * 4;
  for (int attempt = 0; attempt < 4; attempt++, capacity *= 4) {
    if (capacity > DBLORE_CELL_TEXT_MAX) capacity = DBLORE_CELL_TEXT_MAX;
    if (!reserve_cell(conn, capacity)) break;
    DBINT written = dbconvert(dbproc, type, data, length, SYBCHAR, (BYTE *)conn->cell,
                              (DBINT)(capacity - 1));
    if (written >= 0) {
      conn->cell[written] = '\0';
      *text = conn->cell;
      result = written;
      break;
    }
    if (capacity == DBLORE_CELL_TEXT_MAX) break;
  }
  // A failed attempt left "data conversion overflow" in the error text; it is not the statement's
  conn->client_error[0] = '\0';
  current_conn = NULL;
  return result;
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
