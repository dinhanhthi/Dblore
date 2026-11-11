// dblore_tds.h
// The SQL Server plugin's narrow C interface over FreeTDS db-lib and OpenSSL: an opaque
// connection handle and plain C types only, so Swift never sees db-lib's macros or global state.
//
// Threads: every function taking a connection runs on that connection's own serial queue, except
// `dblore_tds_request_cancel`, which any thread may call while the connection exists.

#ifndef DBLORE_TDS_H
#define DBLORE_TDS_H

#include <stdbool.h>
#include <stddef.h>

typedef struct dblore_tds_conn dblore_tds_conn;

/// Process-wide setup, done once: OpenSSL without its configuration file, db-lib's `dbinit`, and
/// the error, message and interrupt handlers. False when db-lib could not start.
bool dblore_tds_global_init(void);

/// "1.5.21": the FreeTDS version compiled in
const char *dblore_tds_freetds_version(void);
/// "3.5.9": the OpenSSL version linked in
const char *dblore_tds_openssl_version(void);

dblore_tds_conn *dblore_tds_conn_create(void);
/// Closes the connection when open, then frees the handle
void dblore_tds_conn_destroy(dblore_tds_conn *conn);

/// Logs in. `conf_path` is a FreeTDS configuration file the caller wrote for this open alone,
/// whose `[section]` holds the host, port and TLS settings; it is the only configuration file
/// FreeTDS reads (no freetds.conf), though the TDSVER, TDSPORT, TDSHOST and TDSDUMP environment
/// variables still override it (see dblore_tds.c). It must be a regular file (not a link) when
/// the open starts. The user, password and database go through the LOGINREC only.
/// `require_encryption`: the session must stay encrypted after the login (encryption require or
/// strict); one that FreeTDS left in clear text is closed again (see dblore_tds.c).
/// Opens are serialized process-wide (the configuration file location is db-lib global state).
/// The client charset is UTF-8. 1 when connected; 0 when db-lib tried the server and the login
/// failed; -1 when it failed before that (setup, login fields, configuration file); -2 when the
/// login succeeded without encryption although it was required, and the connection was closed.
/// The reason of a failure is in `dblore_tds_error_message`.
int dblore_tds_connect(dblore_tds_conn *conn, const char *conf_path, const char *section,
                       const char *user, const char *password, const char *database,
                       bool require_encryption);

/// The messages of the last failed call as plain text (server errors first), "" when none
const char *dblore_tds_error_message(const dblore_tds_conn *conn);
/// The server's error number of the last failed call (its first error), 0 when none
int dblore_tds_error_number(const dblore_tds_conn *conn);
/// The state of that server error, 0 when none
int dblore_tds_error_state(const dblore_tds_conn *conn);
void dblore_tds_clear_error(dblore_tds_conn *conn);
/// True once the connection to the server is gone
bool dblore_tds_is_dead(const dblore_tds_conn *conn);

/// Any thread: asks the running statement to stop. Within about a second the interrupt handler
/// turns it into a TDS attention; the statement then fails and `dblore_tds_cancel_requested`
/// tells why.
void dblore_tds_request_cancel(dblore_tds_conn *conn);
/// Clears a cancel request before the next statement
void dblore_tds_reset_cancel(dblore_tds_conn *conn);
bool dblore_tds_cancel_requested(const dblore_tds_conn *conn);

/// The client statement timeout of the following statements, in seconds (0: none). A statement
/// still running when it passes is stopped like a cancel (TDS attention) and fails with a
/// timeout message. The time is counted from `dblore_tds_execute`.
void dblore_tds_set_statement_timeout(dblore_tds_conn *conn, int seconds);

/// Sends a batch and waits for its first result. False on failure.
bool dblore_tds_execute(dblore_tds_conn *conn, const char *sql);
/// 1: the next result is ready; 0: no more results; -1: the result failed
int dblore_tds_next_result(dblore_tds_conn *conn);
/// Columns of the current result; 0 when it returns no rows
int dblore_tds_column_count(dblore_tds_conn *conn);

/// One column of the current result
typedef struct dblore_tds_column {
  /// "" when it has none; valid until the next result
  const char *name;
  /// The type its cells carry (`dblore_tds_cell.type`)
  int type;
  /// The type the server declared (TDS type code: 231 nvarchar, 38 an int of `max_length` bytes,
  /// 241 xml, ...), 0 when unknown
  int server_type;
  /// The server's user type (80: timestamp)
  int user_type;
  /// The server's maximum length in bytes
  int max_length;
} dblore_tds_column;

/// The 1-based column of the current result; false when out of range
bool dblore_tds_column_get(dblore_tds_conn *conn, int column, dblore_tds_column *info);

/// 1: a row is ready; 0: no more rows in this result; -1: failure, also when a cancel or the
/// statement timeout came while rows kept arriving
int dblore_tds_next_row(dblore_tds_conn *conn);

/// One cell of the current row: db-lib's own bytes, never converted to text. `data` stays valid
/// until the next call on the connection. Layouts by `type` (db-lib type codes, little-endian):
/// - 47 char, 35 text (also xml), 103 nvarchar, and the server's character types: UTF-8 text
/// - 45 binary, 34 image, and the server's other byte types (udt): the bytes
/// - 48 tinyint u8, 52 smallint i16, 56 int i32, 127 bigint i64, 50 bit u8,
///   59 real f32, 62 float f64
/// - 60 money: i64 in ten-thousandths; 122 smallmoney: i32 in ten-thousandths
/// - 61 datetime: i32 days since 1900-01-01, u32 ticks of 1/300 s since midnight
/// - 58 smalldatetime: u16 days since 1900-01-01, u16 minutes since midnight
/// - 106 decimal, 108 numeric: u8 precision, u8 scale, u8 sign (1: negative), then the
///   magnitude as an unsigned big-endian integer (the rest of `length`)
/// - 40 date, 41 time, 42 datetime2, 43 datetimeoffset: 16 bytes: u64 time of day in 100 ns
///   units, i32 days since 1900-01-01 (negative before it), i16 offset in minutes, u8 time
///   precision (0-7), u8 flags (1 has time, 2 has date, 4 has offset); the time and date of a
///   datetimeoffset are UTC
/// - 36 uniqueidentifier: 16 bytes, u32, u16, u16, then 8 bytes as they are
/// - 98 sql_variant: the inner value's bytes; db-lib does not tell the inner type
typedef struct dblore_tds_cell {
  int type;
  bool is_null;
  long length;
  const unsigned char *data;
} dblore_tds_cell;

/// The current row's 1-based cell; false when out of range
bool dblore_tds_cell_get(dblore_tds_conn *conn, int column, dblore_tds_cell *cell);

/// Rows the current result affected (DBCOUNT), -1 when the server did not say
long dblore_tds_rows_affected(dblore_tds_conn *conn);
/// Drops whatever is left of the current batch (db-lib `dbcancel`), so the next one can run
void dblore_tds_discard_results(dblore_tds_conn *conn);

/// Whether a server presents a certificate when a client opens TLS straight away, as encryption
/// strict (TDS 8.0) does: 1 when it does, 0 when the TCP connection opened but no certificate
/// came (servers without TDS 8.0 answer a ClientHello with a reset or garbage), -1 when the TCP
/// connection could not be opened. No certificate is verified; nothing is sent after the
/// handshake.
int dblore_tds_server_presents_certificate(const char *host, int port, int timeout_seconds);

#endif
