import 'package:dotenv/dotenv.dart';
import 'package:postgres/postgres.dart';

final env = DotEnv(includePlatformEnvironment: true)..load();

class Database {
  static final pool = Pool.withEndpoints(
    [
      Endpoint(
        host: env['DB_HOST'] ?? 'localhost',
        port: int.parse(env['DB_PORT'] ?? '5433'),
        database: env['DB_NAME'] ?? 'checkmate',
        username: env['DB_USER'] ?? 'checkmate',
        password: env['DB_PASSWORD'] ?? '',
      ),
    ],
    settings: const PoolSettings(
      maxConnectionCount: 5,
      sslMode: SslMode.disable,
    ),
  );
}
