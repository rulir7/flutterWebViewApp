import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:camera/camera.dart';
import 'dart:typed_data';
import 'package:permission_handler/permission_handler.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import './logger.dart'; // Importando a classe Logger

class CameraWithQRScanner extends StatefulWidget {
  final Function(String) onQRCodeDetected;
  final Function(String) onPhotoTaken;

  const CameraWithQRScanner({
    Key? key,
    required this.onQRCodeDetected,
    required this.onPhotoTaken,
  }) : super(key: key);

  @override
  State<CameraWithQRScanner> createState() => _CameraWithQRScannerState();
}

class _CameraWithQRScannerState extends State<CameraWithQRScanner>
    with WidgetsBindingObserver {
  // Controladores para QR Scanner e Câmera
  MobileScannerController? _qrController;
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;

  // Preferência para a câmera traseira
  static const preferredCameraDirection = CameraLensDirection.back;

  // Estados
  bool _isQRMode = false; // Começar no modo câmera por padrão
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _hasCameraError = false;
  bool _previewReady = false;
  bool _attemptingPreviewFix = false;
  int _previewRetryCount = 0;
  bool _isQRScannerReady = false;
  bool _initialResetPerformed = false;

  // Controle de segurança para receivers
  bool _hasTooManyReceiversError = false;
  final int _maxInitAttempts = 2;
  int _initAttempts = 0;

  // Temporizador para auto-fechar em caso de inatividade
  Timer? _inactivityTimer;

  // Key para forçar reconstrução do preview
  final GlobalKey _cameraPreviewKey = GlobalKey();
  final GlobalKey _qrScannerKey = GlobalKey();

  // Singleton para garantir que apenas uma instância seja criada
  static bool _isInstanceActive = false;

  @override
  void initState() {
    super.initState();

    // Verificar se já existe uma instância ativa
    if (_isInstanceActive) {
      debugPrint(
          '⚠️ Tentativa de abrir múltiplas instâncias da câmera detectada');
      _hasCameraError = true;
      _showError(
          'Já existe uma câmera aberta. Feche a câmera atual antes de abrir uma nova.');
      return;
    }

    // Marcar esta instância como ativa
    _isInstanceActive = true;

    WidgetsBinding.instance.addObserver(this);

    // Iniciar timer de inatividade
    _resetInactivityTimer();

    // Tentar inicializar a câmera com delay para garantir que a UI esteja pronta
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _initializeCameraWithRetry();
      }
    });
  }

  // Criar um método para mostrar erros
  void _showError(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red.shade800,
      ),
    );
  }

  // Timer para auto-fechamento por inatividade
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(seconds: 60), () {
      // Fechar automaticamente após 60 segundos de inatividade
      if (mounted) {
        debugPrint('🕒 Fechando câmera por inatividade');
        Navigator.of(context).pop();
      }
    });
  }

  // Nova implementação de inicialização com tentativas
  Future<void> _initializeCameraWithRetry() async {
    if (!mounted) return;

    _initAttempts++;
    if (_initAttempts > _maxInitAttempts) {
      debugPrint('❌ Excedido número máximo de tentativas de inicialização');
      setState(() {
        _hasCameraError = true;
        _isProcessing = false;
      });
      _showError(
          'Não foi possível inicializar a câmera após várias tentativas. Tente reiniciar o aplicativo.');
      return;
    }

    debugPrint(
        '🔄 Inicializando câmera com retentativas automáticas (tentativa $_initAttempts)');
    setState(() => _isProcessing = true);

    try {
      // Verificar se há muitos receivers registrados
      if (Platform.isAndroid) {
        // Capturar o erro de muitos receivers para exibir mensagem apropriada
        try {
          final cameras = await availableCameras().timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              throw TimeoutException('Timeout ao obter câmeras disponíveis');
            },
          );

          if (cameras.isEmpty) {
            throw Exception('Nenhuma câmera disponível');
          }
        } catch (e) {
          if (e.toString().contains('Too many receivers')) {
            _hasTooManyReceiversError = true;
            throw Exception(
                'Muitos receptores registrados. Reinicie o aplicativo para usar a câmera.');
          } else {
            // Rethrow para tratamento normal
            rethrow;
          }
        }
      }

      // Verificar permissões primeiro
      await _checkCameraPermissions();

      // Liberar recursos antes de tentar novamente
      await _safeDisposeControllersCompletely();

      // Tentar inicializar a câmera normal primeiro
      await _initializeCamera(forceActivateStream: true);

      if (_isCameraInitialized) {
        debugPrint(
            '✅ Câmera inicializada com sucesso na tentativa $_initAttempts');

        setState(() {
          _isProcessing = false;
          _previewReady = true;
          _hasCameraError = false;
        });

        // Garantir que o preview seja visível
        _ensurePreviewIsVisible();
      } else {
        throw Exception('Falha ao inicializar câmera');
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Erro ao inicializar câmera: $e');

      // Registrar no Logger em vez do Sentry diretamente
      await Logger.captureException(
        e,
        stackTrace: stackTrace,
        category: 'camera_init',
        extra: {'init_attempts': _initAttempts},
      );

      // Verificar se é um erro de Too many receivers
      if (_hasTooManyReceiversError ||
          e.toString().contains('Too many receivers')) {
        setState(() {
          _hasCameraError = true;
          _isProcessing = false;
          _hasTooManyReceiversError = true;
        });

        _showError(
            'O aplicativo precisa ser reiniciado para usar a câmera. Feche e abra o aplicativo novamente.');
      } else {
        setState(() {
          _hasCameraError = true;
          _isProcessing = false;
        });

        // Tentar novamente após um atraso se não for um erro de receivers
        if (_initAttempts < _maxInitAttempts && mounted) {
          Future.delayed(Duration(milliseconds: 800 * _initAttempts), () {
            if (mounted) {
              _initializeCameraWithRetry();
            }
          });
        } else {
          _showError(
              'Não foi possível inicializar a câmera. Tente novamente mais tarde.');
        }
      }
    }
  }

  // Método para inicializar a câmera com detecção e tratamento do erro de Too many receivers
  Future<void> _initializeCamera({bool forceActivateStream = false}) async {
    if (!mounted) return;

    debugPrint('🔍 Inicializando câmera');

    try {
      // Verificar se estamos no Android e se precisamos forçar a limpeza de receivers
      if (Platform.isAndroid) {
        // Forçar liberação de receivers antigos através de GC
        try {
          await SystemChannels.platform
              .invokeMethod<void>('SystemNavigator.routeUpdated');
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          debugPrint('⚠️ Aviso ao tentar liberar recursos do sistema: $e');
        }
      }

      // Verificar permissões de câmera
      final status = await Permission.camera.status;
      if (!status.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          throw Exception('Permissão de câmera negada pelo usuário');
        }
      }

      // Obter câmeras disponíveis com timeout
      _cameras = await availableCameras().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException('Timeout ao obter câmeras disponíveis');
        },
      );

      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('Nenhuma câmera disponível no dispositivo');
      }

      // Encontrar câmera traseira (preferida)
      int cameraIndex =
          0; // Se não encontrar a traseira, usa a primeira disponível

      // Tentar encontrar a câmera traseira
      for (int i = 0; i < _cameras!.length; i++) {
        if (_cameras![i].lensDirection == preferredCameraDirection) {
          cameraIndex = i;
          break;
        }
      }

      // Criar controlador da câmera com configurações otimizadas
      final ResolutionPreset resolutionPreset = ResolutionPreset.medium;

      // Verificação de segurança para evitar Too many receivers
      if (_cameras!.length <= cameraIndex) {
        cameraIndex = 0; // Usar a primeira câmera se o índice for inválido
      }

      // Criação segura do controlador
      try {
        // Verificar se o índice é válido
        if (_cameras!.isEmpty) {
          throw Exception('Lista de câmeras vazia');
        }

        // Criar controlador
        _cameraController = CameraController(
          _cameras![cameraIndex],
          resolutionPreset,
          enableAudio:
              false, // Desativar áudio para reduzir consumo de recursos
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.yuv420
              : ImageFormatGroup.bgra8888,
        );

        // Inicializar com timeout
        await _cameraController!.initialize().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw TimeoutException('Timeout ao inicializar câmera');
          },
        );

        // Configurações adicionais após inicialização bem-sucedida
        if (_cameraController!.value.isInitialized) {
          // Configurar foco e exposição para melhor detecção de QR
          await _cameraController!.setFocusMode(FocusMode.auto);
          await _cameraController!.setExposureMode(ExposureMode.auto);

          // Forçar um frame para garantir que o stream está ativo
          if (forceActivateStream) {
            try {
              // Tirar uma foto "fantasma" para ativar o stream
              await _cameraController!.takePicture();
            } catch (e) {
              debugPrint('⚠️ Erro ao ativar stream (esperado): $e');
              // Ignorar erro aqui, pois é apenas para ativar o stream
            }
          }

          // Sinalizar que a câmera está inicializada
          _isCameraInitialized = true;

          debugPrint('✅ Câmera inicializada com sucesso');
          return;
        } else {
          throw Exception('Câmera não inicializada corretamente');
        }
      } catch (e) {
        // Verificar especificamente por erro de Too many receivers
        if (e.toString().contains('Too many receivers')) {
          _hasTooManyReceiversError = true;
          debugPrint('🚨 Erro de Too many receivers detectado');

          // Forçar limpeza imediata de recursos
          await _forceCameraInitialization();

          throw Exception(
              'Muitos receptores registrados. Reinicie o aplicativo para usar a câmera.');
        }

        debugPrint('❌ Erro ao criar controlador da câmera: $e');
        throw e; // Repassar erro para tratamento na função chamadora
      }
    } catch (e) {
      debugPrint('❌ Erro durante inicialização da câmera: $e');

      // Verificar por erro de Too many receivers em qualquer ponto
      if (e.toString().contains('Too many receivers')) {
        _hasTooManyReceiversError = true;
      }

      // Limpar recursos em caso de falha
      try {
        await _safeDisposeControllersCompletely();
      } catch (disposeError) {
        debugPrint('⚠️ Erro ao liberar recursos após falha: $disposeError');
      }

      // Repassar erro
      throw e;
    }
  }

  // Método para forçar reinicialização da câmera em caso de problemas
  Future<void> _forceCameraInitialization() async {
    debugPrint('🔄 Forçando reinicialização da câmera');

    try {
      // 1. Liberar todos os recursos
      await _safeDisposeControllersCompletely();

      // 2. Forçar coleta de lixo
      await SystemChannels.platform
          .invokeMethod<void>('SystemNavigator.routeUpdated');

      // 3. Pequena pausa para dar tempo ao sistema
      await Future.delayed(const Duration(milliseconds: 500));

      // 4. Usar método alternativo para inicializar câmera (apenas no Android)
      if (Platform.isAndroid) {
        try {
          // Tentar usar método alternativo para obter câmeras
          final tempController = CameraController(
            const CameraDescription(
              name: '0',
              lensDirection: CameraLensDirection.back,
              sensorOrientation: 90,
            ),
            ResolutionPreset.low,
            enableAudio: false,
          );

          // Inicializar e depois liberar imediatamente
          try {
            await tempController.initialize().timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                throw TimeoutException('Timeout na inicialização forçada');
              },
            );
          } catch (e) {
            debugPrint('⚠️ Erro esperado na inicialização forçada: $e');
          } finally {
            await tempController.dispose();
          }
        } catch (e) {
          debugPrint('⚠️ Erro no método alternativo (esperado): $e');
        }
      }

      // 5. Outra pausa para garantir
      await Future.delayed(const Duration(milliseconds: 200));

      debugPrint('✅ Reinicialização forçada concluída');
    } catch (e) {
      debugPrint('⚠️ Erro durante reinicialização forçada: $e');
    }
  }

  // Dispose completo de todos os controladores e recursos
  Future<void> _safeDisposeControllersCompletely() async {
    debugPrint('🧹 Limpando completamente todos os recursos da câmera');

    try {
      // 1. Limpar controlador QR
      if (_qrController != null) {
        final tempQR = _qrController;
        _qrController = null;
        try {
          await tempQR?.stop();
          await tempQR?.dispose();
        } catch (e) {
          debugPrint('⚠️ Erro ao limpar controlador QR: $e');
        }
      }

      // 2. Limpar controlador da câmera
      if (_cameraController != null) {
        final tempCamera = _cameraController;
        _cameraController = null;
        try {
          if (tempCamera!.value.isInitialized) {
            await tempCamera.dispose();
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao limpar controlador da câmera: $e');
        }
      }

      // 3. Limpar outras referências
      _cameras = null;

      // Redefinir flags
      _isQRScannerReady = false;
      _isCameraInitialized = false;
      _previewReady = false;

      // 4. Pequeno delay para garantir que tudo foi limpo
      await Future.delayed(const Duration(milliseconds: 300));

      // 5. Forçar chamada ao garbage collector
      await SystemChannels.platform
          .invokeMethod<void>('SystemNavigator.routeUpdated');

      debugPrint('✅ Todos os recursos foram liberados');
    } catch (e) {
      debugPrint('⚠️ Erro durante limpeza completa: $e');
    }
  }

  @override
  void dispose() {
    debugPrint('🔄 Dispose do widget');
    // Marcar esta instância como não mais ativa
    _isInstanceActive = false;

    // Cancelar timer de inatividade
    _inactivityTimer?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    // Usar a versão segura do dispose
    _safeDisposeControllersCompletely();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 Estado do ciclo de vida mudou para: $state');

    // Se o app for minimizado ou pausado, fechar automaticamente a câmera
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Liberar recursos imediatamente
      _safeDisposeControllersCompletely();

      // Se o app for minimizado, fechar tela da câmera
      if (mounted &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.detached)) {
        debugPrint(
            '📱 App minimizado ou desanexado - fechando câmera automaticamente');
        // Fechar a tela após um curto atraso
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resetar timer de inatividade sempre que o usuário interagir
    _resetInactivityTimer();

    return WillPopScope(
      // Interceptar o botão de voltar para garantir a limpeza de recursos
      onWillPop: () async {
        // Limpar recursos antes de sair
        await _safeDisposeControllersCompletely();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(_hasTooManyReceiversError
              ? 'Erro - Reinicie o Aplicativo'
              : 'Tirar Foto'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              // Limpar recursos antes de sair
              await _safeDisposeControllersCompletely();
              Navigator.pop(context);
            },
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  // Método para construir o corpo baseado no estado atual
  Widget _buildBody() {
    // Verificar se há erro de excesso de receivers
    if (_hasTooManyReceiversError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 60),
              const SizedBox(height: 20),
              const Text(
                'Limite de recursos excedido',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              const Text(
                'O aplicativo precisa ser reiniciado para usar a câmera. '
                'Por favor, feche completamente o aplicativo e abra-o novamente.',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Fechar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      );
    }

    // Verificar se há erro genérico de câmera
    if (_hasCameraError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 60),
              const SizedBox(height: 20),
              const Text(
                'Erro ao inicializar câmera',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              const Text(
                'Não foi possível inicializar a câmera. Verifique se outra aplicação '
                'está usando a câmera ou tente reiniciar o aplicativo.',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tentar Novamente'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                    onPressed: () {
                      setState(() {
                        _hasCameraError = false;
                        _initAttempts = 0;
                      });
                      _initializeCameraWithRetry();
                    },
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Fechar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[400],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Verificar se está processando
    if (_isProcessing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text(
              'Inicializando câmera...',
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Construir visualização da câmera quando estiver pronta
    if (_isCameraInitialized && _cameraController != null) {
      return Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                key: _cameraPreviewKey,
                child: CameraPreview(_cameraController!),
              ),
            ),
          ),
          // Botão para tirar foto
          Container(
            padding: const EdgeInsets.all(20),
            color: Colors.black,
            child: Center(
              child: GestureDetector(
                onTap: _takePicture,
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.camera_alt,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Caso padrão quando ainda não está pronto
    return const Center(
      child: Text(
        'Inicializando câmera...',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  // Captura uma foto
  Future<void> _takePicture() async {
    if (_isProcessing || !_isCameraInitialized || _cameraController == null) {
      _showError('A câmera não está pronta para tirar fotos.');
      return;
    }

    setState(() => _isProcessing = true);
    String? imagePath;

    try {
      // Feedback tátil
      HapticFeedback.mediumImpact();

      // Capturar foto
      final XFile photo = await _cameraController!.takePicture();
      imagePath = photo.path;

      debugPrint('📸 Foto capturada: $imagePath');

      // Analisar QR code na imagem
      String? qrCode;
      try {
        final analyzeController = MobileScannerController();
        final barcodes = await analyzeController.analyzeImage(imagePath);
        await analyzeController.dispose();

        if (barcodes?.barcodes.isNotEmpty ?? false) {
          qrCode = barcodes?.barcodes.first.rawValue;
          debugPrint('✅ QR code detectado: $qrCode');
        }
      } catch (e) {
        debugPrint('❌ Erro ao analisar QR code: $e');
      }

      // Fechar tela e retornar resultado
      if (mounted) {
        if (qrCode != null) {
          Navigator.pop(context,
              {'type': 'qrcode', 'data': qrCode, 'imagePath': imagePath});
        } else {
          Navigator.pop(context, {'type': 'photo', 'data': imagePath});
        }
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Erro ao capturar foto: $e');

      // Registrar no Logger em vez do Sentry diretamente
      await Logger.captureException(
        e,
        stackTrace: stackTrace,
        category: 'photo_capture',
        extra: {'image_path': imagePath},
      );

      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Erro ao capturar foto: ${e.toString().split('\n').first}');
      }
    }
  }

  // Verificar permissões da câmera
  Future<void> _checkCameraPermissions() async {
    try {
      final status = await Permission.camera.status;
      if (!status.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          throw Exception('Permissão da câmera negada');
        }
      }
    } catch (e) {
      debugPrint('❌ Erro ao verificar permissões: $e');
      rethrow;
    }
  }

  // Verificar e garantir que o preview seja exibido corretamente
  Future<void> _ensurePreviewIsVisible() async {
    if (!mounted || _previewReady || _attemptingPreviewFix) return;

    debugPrint('🔍 Verificando visibilidade do preview da câmera');

    // Se a câmera está inicializada mas o preview não está visível
    if (_isCameraInitialized &&
        _cameraController != null &&
        _cameraController!.value.isInitialized &&
        !_isQRMode) {
      // Tentar forçar uma atualização do preview
      await Future.delayed(const Duration(milliseconds: 200));

      if (mounted) {
        // Forçar rebuild da UI
        setState(() {
          _previewReady = true;
        });

        // Para ter certeza, realiza uma segunda atualização após um curto atraso
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {});

            // Verificar se precisa "cutucar" na câmera para ativar o stream
            if (_cameraController != null &&
                _cameraController!.value.isInitialized) {
              // Em vez de usar setResolutionPreset que não existe, vamos usar métodos válidos
              try {
                // Alternar modos de foco e exposição pode ajudar a ativar o stream
                _cameraController!.setFocusMode(FocusMode.auto).then((_) {
                  _cameraController!.setExposureMode(ExposureMode.auto);

                  // Para garantir que o stream está ativo, fazer mais uma atualização
                  if (mounted) setState(() {});
                });
              } catch (e) {
                debugPrint('⚠️ Erro ao ajustar configurações da câmera: $e');
              }
            }
          }
        });
      }
    } else {
      // Se ainda não está pronto, tentar novamente após um atraso
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_previewReady && !_attemptingPreviewFix) {
          _ensurePreviewIsVisible();
        }
      });
    }
  }
}
