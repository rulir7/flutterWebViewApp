import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import './logger.dart';

/// Utilitários específicos para iOS
class IOSUtils {
  /// Configura a câmera para comportamento ideal no iOS
  static Future<void> setupCameraForIOS(CameraController controller) async {
    if (!Platform.isIOS) return;

    try {
      // Configurar modo de foco para comportamento ideal no iOS
      await controller.setFocusMode(FocusMode.auto);

      // Configurar modo de exposição para comportamento ideal no iOS
      await controller.setExposureMode(ExposureMode.auto);

      // Ativar flash automático se disponível
      if (controller.value.flashMode != null) {
        await controller.setFlashMode(FlashMode.auto);
      }

      // Configurações específicas para iOS são efetivamente aplicadas
      debugPrint('✅ Configurações específicas do iOS aplicadas à câmera');
    } catch (e) {
      debugPrint('⚠️ Erro ao configurar câmera para iOS: $e');
    }
  }

  /// Ajusta a orientação da câmera com base na orientação do dispositivo
  static Future<void> adjustCameraOrientation(
      CameraController controller, Orientation deviceOrientation) async {
    if (!Platform.isIOS) return;

    try {
      // No iOS, às vezes precisamos ajustar a orientação manualmente
      DeviceOrientation orientation;

      switch (deviceOrientation) {
        case Orientation.portrait:
          orientation = DeviceOrientation.portraitUp;
          break;
        case Orientation.landscape:
          // Determinar se é landscape left ou right com base na orientação do sensor
          orientation = DeviceOrientation.landscapeRight;
          break;
        default:
          orientation = DeviceOrientation.portraitUp;
      }

      await controller.lockCaptureOrientation(orientation);
      debugPrint('📱 iOS: Orientação da câmera ajustada para: $orientation');
    } catch (e) {
      debugPrint('⚠️ Erro ao ajustar orientação da câmera no iOS: $e');
    }
  }

  /// Notifica o sistema para liberar recursos
  static Future<void> releaseSystemResources() async {
    if (!Platform.isIOS) return;

    try {
      // No iOS, podemos sugerir ao sistema que colete recursos não utilizados
      await SystemChannels.platform.invokeMethod<void>('System.gc');
      debugPrint('🧹 iOS: Solicitação de liberação de recursos enviada');
    } catch (e) {
      // Ignora o erro, pois isso é apenas uma sugestão ao sistema
      debugPrint('ℹ️ iOS: Liberação de recursos ignorada: $e');
    }
  }

  /// Prepara a câmera para captura de imagem no iOS
  static Future<void> prepareImageCaptureForIOS(
      CameraController controller) async {
    if (!Platform.isIOS) return;

    try {
      // No iOS, bloquear o foco antes de capturar pode melhorar a qualidade
      await controller.setFocusMode(FocusMode.locked);

      // Pequeno delay para estabilizar o foco antes da captura
      await Future.delayed(const Duration(milliseconds: 200));

      debugPrint('📸 iOS: Câmera preparada para captura');
    } catch (e) {
      debugPrint('⚠️ Erro ao preparar captura no iOS: $e');
    }
  }

  /// Restaura configurações da câmera após captura
  static Future<void> resetCameraAfterCapture(
      CameraController controller) async {
    if (!Platform.isIOS) return;

    try {
      // Restaurar modos automáticos após a captura
      await controller.setFocusMode(FocusMode.auto);
      await controller.setExposureMode(ExposureMode.auto);

      debugPrint('🔄 iOS: Câmera restaurada após captura');
    } catch (e) {
      debugPrint('⚠️ Erro ao restaurar câmera no iOS: $e');
    }
  }

  /// Detecta problemas de compatibilidade específicos do iOS
  static bool detectIOSCompatibilityIssues() {
    if (!Platform.isIOS) return false;

    try {
      // Verificar se estamos no iOS 14 ou superior (melhor compatibilidade)
      final String version = Platform.operatingSystemVersion;
      final bool isIOS14OrHigher = version.contains('14.') ||
          version.contains('15.') ||
          version.contains('16.') ||
          version.contains('17.');

      if (!isIOS14OrHigher) {
        debugPrint('⚠️ iOS: Versão anterior ao iOS 14 detectada: $version');
        Logger.warning('Versão de iOS potencialmente incompatível',
            category: 'ios_compatibility', extra: {'version': version});
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('⚠️ Erro ao verificar compatibilidade do iOS: $e');
      return false;
    }
  }

  /// Otimiza o desempenho após troca de orientação
  static Future<void> optimizeAfterOrientationChange() async {
    if (!Platform.isIOS) return;

    try {
      // No iOS, forçar um pequeno delay e limpar memória após mudança de orientação
      // pode ajudar a evitar problemas de renderização
      await Future.delayed(const Duration(milliseconds: 300));

      // Sugerir ao sistema para liberar recursos não utilizados
      await SystemChannels.platform.invokeMethod<void>('System.gc');

      // Também podemos forçar uma atualização do layout
      WidgetsBinding.instance.performReassemble();

      debugPrint('🔄 iOS: Layout reajustado após mudança de orientação');
    } catch (e) {
      debugPrint(
          '⚠️ Erro ao otimizar layout após mudança de orientação no iOS: $e');
    }
  }
}
