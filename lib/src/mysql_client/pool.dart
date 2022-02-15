import 'dart:async';
import 'package:mysql_client/mysql_client.dart';

/// Class to create and manage pool of database connections
class MySQLConnectionPool {
  final String host;
  final int port;
  final String userName;
  final String _password;
  final int maxConnections;
  final String? databaseName;
  final bool secure;

  final List<MySQLConnection> _activeConnections = [];
  final List<MySQLConnection> _idleConnections = [];

  /// Creates new pool
  ///
  /// Almost all parameters are identical to [MySQLConnection.connect]
  /// Pass [maxConnections] to tell pool maximum number of connections it can use
  MySQLConnectionPool({
    required this.host,
    required this.port,
    required this.userName,
    required password,
    required this.maxConnections,
    this.databaseName,
    this.secure = true,
  }) : _password = password;

  /// Number of active connections in this pool
  /// Active are connections which are currently interacting with the database
  int get activeConnectionsQty => _idleConnections.length;

  /// Number of idle connections in this pool
  /// Idle are connections which are currently not interacting with the database and ready to be used
  int get idleConnectionsQty => _idleConnections.length;

  /// Active + Idle connections
  int get allConnectionsQty => activeConnectionsQty + idleConnectionsQty;

  List<MySQLConnection> get _allConnections =>
      _idleConnections + _activeConnections;

  /// See [MySQLConnection.execute]
  Future<IResultSet> execute(String query,
      [Map<String, dynamic>? params, bool iterable = false]) async {
    final conn = await _getFreeConnection();
    final result = await conn.execute(query, params, iterable);
    _releaseConnection(conn);
    return result;
  }

  /// Closes all connections in this pool and frees resources
  Future<void> close() async {
    for (final conn in _allConnections) {
      await conn.close();
    }
    _idleConnections.clear();
    _activeConnections.clear();
  }

  /// See [MySQLConnection.prepare]
  Future<PreparedStmt> prepare(String query, [bool iterable = false]) async {
    final conn = await _getFreeConnection();
    return conn.prepare(query, iterable);
  }

  /// Get free connection from this pool (possibly new connection) and invoke callback function with this connection
  ///
  /// After callback completes, connection is returned into pool as idle connection
  /// This function returns callback result
  FutureOr<T> withConnection<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    final conn = await _getFreeConnection();
    final result = await callback(conn);
    _releaseConnection(conn);
    return result;
  }

  /// See [MySQLConnection.transactional]
  Future<T> transactional<T>(
      FutureOr<T> Function(MySQLConnection conn) callback) async {
    return withConnection((conn) {
      return conn.transactional(callback);
    });
  }

  Future<MySQLConnection> _getFreeConnection() async {
    // if there is idle connection, return it
    if (_idleConnections.isNotEmpty) {
      final conn = _idleConnections.first;
      _idleConnections.remove(conn);
      _activeConnections.add(conn);
      return conn;
    }

    if (allConnectionsQty < maxConnections) {
      final conn = await MySQLConnection.createConnection(
        host: host,
        port: port,
        userName: userName,
        password: _password,
        databaseName: databaseName,
        secure: secure,
      );

      await conn.connect();
      _activeConnections.add(conn);

      // remove connection from pool, if connection is closed
      conn.onClose(() {
        _idleConnections.remove(conn);
        _activeConnections.remove(conn);
      });

      return conn;
    } else {
      // wait for idle connection
      await Future.doWhile(() => idleConnectionsQty == 0);
      final conn = _idleConnections.first;
      _idleConnections.remove(conn);
      _activeConnections.add(conn);
      return conn;
    }
  }

  void _releaseConnection(MySQLConnection conn) {
    // remove from active
    _activeConnections.remove(conn);
    _idleConnections.add(conn);
  }
}
