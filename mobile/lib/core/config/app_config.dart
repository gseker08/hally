/// Single place for brand and environment values. The product name is not final,
/// so never hard-code it elsewhere.
class AppConfig {
  const AppConfig._();

  static const appName = String.fromEnvironment('HALLY_APP_NAME', defaultValue: 'Hally');

  /// Backend base URL. Android emulators reach the host machine at 10.0.2.2.
  static const apiBaseUrl = String.fromEnvironment('HALLY_API_URL', defaultValue: 'http://localhost:8080');

  /// Google OAuth web client id used as serverClientId so the backend receives an ID token.
  static const googleServerClientId = String.fromEnvironment('HALLY_GOOGLE_SERVER_CLIENT_ID');

  /// Google OAuth iOS client id. The iPhone app shows Google sign-in only with it (plus the URL scheme in
  /// ios/Flutter/Secrets.xcconfig, see docs/mobile/ios.md); Android does not need it.
  static const googleIosClientId = String.fromEnvironment('HALLY_GOOGLE_IOS_CLIENT_ID');

  /// Shows the developer sign-in (backend dev provider). On by default in debug builds and off in release
  /// builds, so a store build never shows it even if the flag is forgotten.
  static const enableDevSignIn = bool.fromEnvironment('HALLY_DEV_SIGN_IN', defaultValue: !_releaseBuild);

  static const _releaseBuild = bool.fromEnvironment('dart.vm.product');

  /// development | beta | production. Tags error reports.
  static const environment = String.fromEnvironment('HALLY_ENV', defaultValue: 'development');

  /// Sentry DSN (not a secret, but environment-specific). Empty = error reporting off.
  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');
}
