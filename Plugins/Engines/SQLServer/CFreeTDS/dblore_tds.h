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
/// Opens are serialized process-wide (the configuration file location is db-lib global state).
/// The client charset is UTF-8. 1 when connected; 0 when db-lib tried the server and the login
/// failed; -1 when it failed before that (setup, login fields, configuration file). The reason of
/// a failure is in `dblore_tds_error_message`.
int dblore_tds_connect(dblore_tds_conn *conn, const char *conf_path, const char *section,
                       const char *user, const char *password, const char *database);

/// The messages of the last failed call as plain text (server errors first), "" when none
const char *dblore_tds_error_message(const dblore_tds_conn *conn);
/// The server's error number of the last failed call, 0 when none
int dblore_tds_error_number(const dblore_tds_conn *conn);
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

/// Sends a batch and waits for its first result. False on failure.
bool dblore_tds_execute(dblore_tds_conn *conn, const char *sql);
/// 1: the next result is ready; 0: no more results; -1: the result failed
int dblore_tds_next_result(dblore_tds_conn *conn);
/// Columns of the current result; 0 when it returns no rows
int dblore_tds_column_count(dblore_tds_conn *conn);
/// 1-based column name, "" when it has none
const char *dblore_tds_column_name(dblore_tds_conn *conn, int column);
/// 1-based column type name as db-lib names it ("int", "char", ...)
const char *dblore_tds_column_type_name(dblore_tds_conn *conn, int column);
/// 1: a row is ready; 0: no more rows in this result; -1: failure
int dblore_tds_next_row(dblore_tds_conn *conn);
/// The current row's 1-based cell as UTF-8 text in `*text` (valid until the next call), and its
/// length; -1 for NULL; -2 when the value could not be converted to text, or its text form is
/// over 512 MiB
long dblore_tds_cell_text(dblore_tds_conn *conn, int column, const char **text);
/// Rows the current result affected, -1 when the server did not say
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
