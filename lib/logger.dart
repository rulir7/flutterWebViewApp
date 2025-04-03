import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'dart:io';
import 'dart:convert';

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

    try {
      // Criar breadcrumb para contexto
      final Map<String, dynamic> breadcrumbData = {};

      // Adicionar extra data com tratamento de erros
      if (extra != null) {
        extra.forEach((key, value) {
          try {
            // Se o valor for uma string com formato JSON, tentar converter para Map
            if (value is String &&
                value.startsWith('{') &&
                value.endsWith('}')) {
              try {
                // Tenta parsear, se falhar usa a string original
                final jsonData = jsonDecode(value);
                breadcrumbData[key] = jsonData;
              } catch (_) {
                // Se falhar o parsing, usar a string como está
                breadcrumbData[key] = value;
              }
            } else {
              // Outros tipos de dados (inteiros, booleanos, mapas, etc)
              breadcrumbData[key] = value;
            }
          } catch (e) {
            // Em caso de erro, usar uma versão segura do valor
            breadcrumbData[key] = value.toString();
          }
        });
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
    } catch (e) {
      // Em caso de falha ao enviar para o Sentry, apenas logar localmente
      _logToConsole(_levelError, "Erro ao enviar para o Sentry: $e");

      // Tentar enviar um evento mais simples sem dados extras
      try {
        await Sentry.captureMessage(
          "Logger error: $message",
          level: sentryLevel,
        );
      } catch (_) {
        // Se ainda falhar, desistir silenciosamente
      }
    }
  }
}
