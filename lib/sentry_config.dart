// Arquivo de configuração do Sentry
// Mova estas configurações para um arquivo .env em produção

class SentryConfig {
  // Substitua pelo DNS fornecido pelo terceiro
  static const String dsn =
      'https://5573f26d70d7e90910b448932b8d0626@o4508931864330240.ingest.us.sentry.io/4508931871866880';

  // Substitua pelo seu Project ID
  static const String projectId = '4508931871866880';

  // Substitua pela sua Public Key
  static const String publicKey = '5573f26d70d7e90910b448932b8d0626';

  // Configurações do ambiente
  static const String environment =
      'production'; // Ou 'development', 'staging', etc.
  static const String release =
      'bemall_promocoes@0.1.0'; // Nome do app + versão
  static const String dist = '1'; // Identificador de distribuição

  // Outras configurações
  static const bool debug = false;
  static const double tracesSampleRate = 1.0;
  static const bool attachScreenshot = true;
  static const bool attachViewHierarchy = true;
  static const bool enableAutoPerformanceTracing = true;
  static const bool enableUserInteractionTracing = true;
  static const bool autoAppStart = true;

  // Gera o DSN completo caso precise ser montado manualmente
  static String get fullDsn {
    if (dsn.isNotEmpty) return dsn;
    return 'https://$publicKey@o$projectId.ingest.sentry.io/$projectId';
  }
}
