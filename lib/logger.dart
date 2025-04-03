import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'dart:io';

// Classe centralizada para gerenciamento de logs
class Logger {
  // Níveis de log
  static const String _levelDebug = 'DEBUG';
  static const String _levelInfo = 'INFO';
  static const String _levelWarning = 'WARNING';
  static const String _levelError = 'ERROR';
  static const String _levelCritical = 'CRITICAL';

  // Tags comuns
  static Map<String, String> _defaultTags = {
    'platform': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'app': 'bemall_promocoes',
  };

  // Configurar tags padrão
  static void setDefaultTags(Map<String, String> tags) {
    _defaultTags = {..._defaultTags, ...tags};
  }

  // Adicionar informações do usuário
  static void setUserContext(
      {String? id,
      String? email,
      String? username,
      Map<String, dynamic>? data}) {
    Sentry.configureScope(
      (scope) => scope.setUser(
        SentryUser(
          id: id,
          email: email,
          username: username,
          data: data,
        ),
      ),
    );
  }

  // Métodos de log
  static void debug(String message,
      {Map<String, dynamic>? extra, String? category}) {
    _log(message, _levelDebug, extra: extra, category: category);
  }

  static void info(String message,
      {Map<String, dynamic>? extra, String? category}) {
    _log(message, _levelInfo, extra: extra, category: category);
  }

  static void warning(String message,
      {Map<String, dynamic>? extra, String? category}) {
    _log(message, _levelWarning, extra: extra, category: category);
  }

  static void error(String message,
      {Map<String, dynamic>? extra, String? category}) {
    _log(message, _levelError, extra: extra, category: category);
  }

  static void critical(String message,
      {Map<String, dynamic>? extra, String? category}) {
    _log(message, _levelCritical, extra: extra, category: category);
  }

  // Capturar exceções
  static Future<void> captureException(
    dynamic exception, {
    StackTrace? stackTrace,
    Map<String, dynamic>? extra,
    String? category,
  }) async {
    // Log local
    final errorMessage = exception.toString();
    _logToConsole(_levelError, errorMessage);

    // Adicionar tags como extra data se não fornecido
    extra ??= {};
    extra['tags'] = _defaultTags;
    if (category != null) {
      extra['category'] = category;
    }

    // Enviar para o Sentry
    await Sentry.captureException(
      exception,
      stackTrace: stackTrace,
      hint: {
        'extra': extra,
      } as Hint,
    );
  }

  // Função central de log
  static void _log(
    String message,
    String level, {
    Map<String, dynamic>? extra,
    String? category,
  }) {
    // Log local
    _logToConsole(level, message);

    // Para níveis mais graves, enviar para Sentry
    if (level == _levelWarning ||
        level == _levelError ||
        level == _levelCritical) {
      _sendToSentry(message, level, extra: extra, category: category);
    }

    // Aqui pode adicionar outros destinos de log (Firebase, arquivo local, etc.)
  }

  // Log para console local
  static void _logToConsole(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    if (kDebugMode) {
      print('[$timestamp][$level] $message');
    }
  }

  // Enviar para o Sentry
  static Future<void> _sendToSentry(
    String message,
    String level, {
    Map<String, dynamic>? extra,
    String? category,
  }) async {
    SentryLevel sentryLevel;

    // Converter nível local para nível do Sentry
    switch (level) {
      case _levelDebug:
        sentryLevel = SentryLevel.debug;
        break;
      case _levelInfo:
        sentryLevel = SentryLevel.info;
        break;
      case _levelWarning:
        sentryLevel = SentryLevel.warning;
        break;
      case _levelError:
        sentryLevel = SentryLevel.error;
        break;
      case _levelCritical:
        sentryLevel = SentryLevel.fatal;
        break;
      default:
        sentryLevel = SentryLevel.info;
    }

    // Criar breadcrumb para contexto
    final Map<String, dynamic> breadcrumbData = {};
    if (extra != null) {
      breadcrumbData.addAll(extra);
    }

    // Adicionar breadcrumb para dar contexto ao evento
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: category ?? 'app',
        level: sentryLevel,
        data: breadcrumbData,
      ),
    );

    // Enviar evento para o Sentry
    await Sentry.captureMessage(
      message,
      level: sentryLevel,
    );
  }
}
