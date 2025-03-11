import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:camera/camera.dart';
import 'dart:typed_data';

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
  bool _isQRMode = true; // Voltar a começar em modo QR para detecção automática
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _hasCameraError = false;
  bool _previewReady = false;
  bool _attemptingPreviewFix = false;
  int _previewRetryCount = 0;
  bool _isQRScannerReady = false;
  bool _initialResetPerformed = false;

  // Key para forçar reconstrução do preview
  final GlobalKey _cameraPreviewKey = GlobalKey();
  final GlobalKey _qrScannerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Inicializar câmeras imediatamente
    _forceCameraInitialization();

    // Adicionar callback post-frame para garantir que o preview seja atualizado
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isQRMode) {
        _ensureQRScannerIsReady();
      } else {
        _ensurePreviewIsVisible();
      }

      // Programar um reset forçado após a inicialização
      Future.delayed(const Duration(milliseconds: 500), () {
        _forceResetAfterInitialization();
      });
    });
  }

  // Força um reset do modo atual para garantir que o preview funcione corretamente
  Future<void> _forceResetAfterInitialization() async {
    if (!mounted || _initialResetPerformed) return;

    debugPrint('🔄 Forçando reset após inicialização para corrigir preview');

    // Marcar que o reset foi realizado para não repetir
    _initialResetPerformed = true;

    try {
      setState(() => _isProcessing = true);

      // Salvar o modo atual
      final currentMode = _isQRMode;

      // Trocar para o modo oposto (para forçar reinicialização)
      await _performModeSwitch(!currentMode);

      // Aguardar um momento para o modo se estabelecer
      await Future.delayed(const Duration(milliseconds: 300));

      // Voltar para o modo original
      await _performModeSwitch(currentMode);

      debugPrint('✅ Reset forçado concluído com sucesso');
    } catch (e) {
      debugPrint('❌ Erro ao forçar reset: $e');
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  // Realiza a troca de modo (usado pelo reset forçado)
  Future<void> _performModeSwitch(bool toQRMode) async {
    debugPrint(
        '🔄 Realizando troca de modo para ${toQRMode ? "QR" : "Câmera"}');

    if (toQRMode) {
      // Trocar para modo QR
      await _initializeQRScanner();
      await _ensureQRScannerIsReady();
    } else {
      // Trocar para modo câmera
      await _initializeCamera(forceActivateStream: true);
      await _ensurePreviewIsVisible();
    }

    // Atualizar o estado do modo
    if (mounted) {
      setState(() {
        _isQRMode = toQRMode;
        _previewReady = toQRMode ? _isQRScannerReady : _isCameraInitialized;
      });
    }
  }

  // Método para garantir que o scanner QR esteja funcionando
  Future<void> _ensureQRScannerIsReady() async {
    if (!mounted || _isQRScannerReady) return;

    debugPrint('🔍 Verificando se o scanner QR está pronto');

    if (_qrController != null) {
      // Garantir que o scanner esteja ativo
      try {
        await _qrController!.start();
        _isQRScannerReady = true;

        // Forçar atualização
        if (mounted) setState(() {});

        debugPrint('✅ Scanner QR iniciado com sucesso');
      } catch (e) {
        debugPrint('⚠️ Erro ao iniciar scanner QR: $e');

        // Tentar reinicializar o scanner
        await _initializeQRScanner();
        if (mounted) setState(() {});
      }
    } else {
      // Se o controlador for nulo, tentar inicializar
      await _initializeQRScanner();
      if (mounted) setState(() {});
    }

    // Verificar novamente após um atraso se ainda não estiver pronto
    if (!_isQRScannerReady) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_isQRScannerReady) {
          _ensureQRScannerIsReady();
        }
      });
    }
  }

  // Método para resetar completamente o preview da câmera
  Future<void> _resetCameraPreview() async {
    debugPrint('🔄 Resetando preview da câmera');

    setState(() {
      _isProcessing = true;
      _attemptingPreviewFix = true;
      _previewRetryCount++;
    });

    try {
      // Liberar recursos atuais
      await _disposeControllers();

      // Pequeno atraso para garantir que tudo foi liberado
      await Future.delayed(const Duration(milliseconds: 300));

      // Reinicializar as câmeras conforme o modo atual
      if (_isQRMode) {
        await _initializeQRScanner();
        _ensureQRScannerIsReady();
      } else {
        // Reinicializar a câmera com força máxima
        await _initializeCamera(forceActivateStream: true);
        _ensurePreviewIsVisible();
      }

      debugPrint('✅ Preview resetado com sucesso');
    } catch (e) {
      debugPrint('❌ Erro ao resetar preview: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _attemptingPreviewFix = false;
        });
      }
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

  // Método forçado para inicializar as câmeras no início
  Future<void> _forceCameraInitialization() async {
    debugPrint('🔄 Forçando inicialização das câmeras');
    setState(() => _isProcessing = true);

    try {
      // Inicializar o scanner de QR primeiro (quando em modo QR)
      if (_isQRMode) {
        await _initializeQRScanner();
        debugPrint('✅ Scanner QR inicializado');
      }

      // Inicializar a câmera (necessário para o modo de foto manual)
      await _initializeCamera(forceActivateStream: !_isQRMode);
      debugPrint('✅ Câmera inicializada');

      debugPrint('✅ Inicialização forçada concluída com sucesso');

      // Garantir que o scanner/preview esteja pronto conforme o modo
      if (_isQRMode) {
        _ensureQRScannerIsReady();
      } else {
        // Garantir que o preview seja atualizado
        _ensurePreviewIsVisible();

        // Como estamos começando em modo câmera, forçar mais uma atualização
        if (!_isQRMode && mounted) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted && !_previewReady) {
              setState(() {}); // Forçar rebuild
            }
          });
        }
      }
    } catch (e) {
      debugPrint('❌ Erro na inicialização forçada: $e');
      _hasCameraError = true;
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 Estado do ciclo de vida mudou para: $state');

    // Gerenciar ciclo de vida da câmera
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeControllers();
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('📱 App resumido - reinicializando câmeras');
      _forceCameraInitialization();

      // Garantir que o preview funcione após retomar o app
      Future.delayed(const Duration(milliseconds: 500), () {
        _forceResetAfterInitialization();
      });
    }
  }

  // Inicializa o scanner de QR code
  Future<void> _initializeQRScanner() async {
    debugPrint('🔄 Inicializando scanner de QR code');

    // Dispose do controller antigo se existir
    await _qrController?.dispose();
    _isQRScannerReady = false;

    _qrController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: [BarcodeFormat.qrCode],
      returnImage: true,
    );

    // Garantir que o scanner está ativo
    try {
      await _qrController!.start();
      _isQRScannerReady = true;
      debugPrint('✅ Scanner de QR code inicializado e iniciado');
    } catch (e) {
      debugPrint('⚠️ Erro ao iniciar scanner QR: $e');
    }
  }

  // Inicializa a câmera para captura com um clique
  Future<void> _initializeCamera({bool forceActivateStream = false}) async {
    debugPrint(
        '🔄 Inicializando câmera padrão (forceActivateStream: $forceActivateStream)');

    try {
      // Dispose do controller antigo se existir
      if (_cameraController != null) {
        await _cameraController!.dispose();
        _cameraController = null;
      }

      // Configurar para não inicializado
      _isCameraInitialized = false;
      _previewReady = false;

      // Obter lista de câmeras disponíveis
      _cameras = await availableCameras();

      if (_cameras == null || _cameras!.isEmpty) {
        debugPrint('❌ Nenhuma câmera disponível');
        _hasCameraError = true;
        return;
      }

      debugPrint('📷 Câmeras disponíveis: ${_cameras!.length}');
      for (var camera in _cameras!) {
        debugPrint(
            '📷 Câmera: ${camera.name} - Direção: ${camera.lensDirection}');
      }

      // Escolher a câmera traseira por padrão
      CameraDescription rearCamera;
      try {
        rearCamera = _cameras!.firstWhere(
          (camera) => camera.lensDirection == preferredCameraDirection,
          orElse: () => _cameras!.first,
        );
        debugPrint('📷 Câmera traseira selecionada: ${rearCamera.name}');
      } catch (e) {
        debugPrint('❌ Erro ao selecionar câmera traseira: $e');
        rearCamera = _cameras!.first;
        debugPrint('📷 Usando primeira câmera disponível: ${rearCamera.name}');
      }

      // Inicializar o controlador da câmera
      _cameraController = CameraController(
        rearCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      debugPrint('🔄 Aguardando inicialização da câmera...');

      // Aguardar a inicialização da câmera
      await _cameraController!.initialize();

      // Verificar se a inicialização funcionou
      debugPrint(
          '📷 Câmera inicializada: ${_cameraController!.value.isInitialized}');
      debugPrint('📷 Câmera em uso: ${_cameraController!.description.name}');
      debugPrint(
          '📷 Direção da câmera: ${_cameraController!.description.lensDirection}');

      if (_cameraController!.value.isInitialized) {
        // Garantir que o stream está ativo
        if (forceActivateStream) {
          debugPrint('🔄 Forçando ativação do stream da câmera');

          // Tentar iniciar o stream da câmera explicitamente
          try {
            // Para "cutucar" a câmera, podemos alternar modos de foco e exposição
            await _cameraController!.setFocusMode(FocusMode.auto);
            await _cameraController!.setExposureMode(ExposureMode.auto);

            // Em alguns casos, tirar uma foto de teste pode ajudar a ativar o stream
            if (!_isQRMode) {
              debugPrint('📸 Tirando foto de teste para ativar stream');
              await _cameraController!.takePicture();
            }
          } catch (e) {
            debugPrint('⚠️ Erro ao forçar ativação do stream: $e');
          }

          // Garante que a UI seja atualizada
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) setState(() => _previewReady = true);
          });
        }

        _isCameraInitialized = true;
        _hasCameraError = false;
      } else {
        _isCameraInitialized = false;
        _hasCameraError = true;
        _previewReady = false;
        debugPrint('❌ Câmera não inicializou corretamente');
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('❌ Erro ao inicializar câmera: $e');
      _hasCameraError = true;
      _isCameraInitialized = false;
      _previewReady = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao inicializar câmera: $e')),
        );
      }
    }
  }

  // Libera os recursos
  Future<void> _disposeControllers() async {
    debugPrint('🔄 Liberando controladores');
    try {
      await _qrController?.dispose();
      await _cameraController?.dispose();
      _qrController = null;
      _cameraController = null;
      _isCameraInitialized = false;
      _previewReady = false;
      debugPrint('✅ Controladores liberados');
    } catch (e) {
      debugPrint('❌ Erro ao liberar controladores: $e');
    }
  }

  @override
  void dispose() {
    debugPrint('🔄 Dispose do widget');
    WidgetsBinding.instance.removeObserver(this);
    _disposeControllers();
    super.dispose();
  }

  // Captura uma foto com apenas um clique
  Future<void> _takePicture() async {
    if (_isProcessing) {
      debugPrint('⚠️ Já está processando, ignorando solicitação');
      return;
    }

    if (!_isCameraInitialized || _cameraController == null) {
      debugPrint('⚠️ Câmera não está pronta, tentando reinicializar');
      await _initializeCamera(forceActivateStream: true);
      if (!_isCameraInitialized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Câmera não está pronta. Tente novamente.')),
          );
        }
        return;
      }
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // Feedback tátil
      HapticFeedback.heavyImpact();

      // Pausa o scanner de QR Code para evitar conflitos
      await _qrController?.stop();

      debugPrint('📸 Capturando foto...');
      // Captura a foto
      final XFile photo = await _cameraController!.takePicture();
      final String imagePath = photo.path;
      debugPrint('📸 Foto capturada: $imagePath');

      // Verifica se tem QR code na imagem
      try {
        debugPrint('🔍 Analisando QR code na imagem');
        final analyzeController = MobileScannerController();
        final barcodes = await analyzeController.analyzeImage(imagePath);
        await analyzeController.dispose();

        if (barcodes?.barcodes.isNotEmpty ?? false) {
          final qrCode = barcodes?.barcodes.first.rawValue;
          debugPrint('✅ QR code detectado: $qrCode');
          if (qrCode != null && mounted) {
            widget.onQRCodeDetected(qrCode);
            return;
          }
        } else {
          debugPrint('ℹ️ Nenhum QR code detectado na imagem');
        }
      } catch (e) {
        debugPrint('❌ Erro ao analisar QR code: $e');
      }

      // Se não encontrou QR code, retorna a imagem
      if (mounted) {
        debugPrint('✅ Retornando imagem capturada');
        widget.onPhotoTaken(imagePath);
      }
    } catch (e) {
      debugPrint('❌ Erro ao capturar foto: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao capturar foto: $e')),
        );
      }
    } finally {
      // Reinicia o scanner de QR Code
      await _qrController?.start();

      // Garante que o estado de processamento seja redefinido
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  // Alterna entre modo QR e modo câmera
  void _toggleMode() async {
    if (_isProcessing) {
      debugPrint('⚠️ Já está processando, ignorando alternância de modo');
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    debugPrint('🔄 Alternando modo: QR=${!_isQRMode}');

    final bool goingToQRMode = !_isQRMode;

    if (goingToQRMode) {
      // Se estiver alternando PARA o modo QR
      await _initializeQRScanner();
      _ensureQRScannerIsReady();
    } else if (!_isCameraInitialized) {
      // Se estiver alternando PARA o modo câmera e ela não estiver inicializada
      debugPrint('🔄 Inicializando câmera para modo câmera');
      await _initializeCamera(forceActivateStream: true);
    }

    setState(() {
      _isQRMode = !_isQRMode;
      _previewReady = _isQRMode ? _isQRScannerReady : _isCameraInitialized;
      _isProcessing = false;
    });

    // Garantir que o preview/scanner esteja funcionando após a troca
    if (goingToQRMode) {
      _ensureQRScannerIsReady();
    } else {
      _ensurePreviewIsVisible();
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
        '🏗️ Build do widget - QR Mode: $_isQRMode, Camera Init: $_isCameraInitialized, QR Scanner Ready: $_isQRScannerReady');

    // Verificar conforme o modo atual
    if (_isQRMode && !_isQRScannerReady && !_isProcessing) {
      debugPrint(
          '⚠️ No modo QR com scanner não pronto, tentando inicializar...');
      Future.microtask(() => _ensureQRScannerIsReady());
    } else if (!_isQRMode && !_isCameraInitialized && !_isProcessing) {
      debugPrint(
          '⚠️ No modo câmera com câmera não inicializada, tentando inicializar...');
      Future.microtask(() async {
        if (mounted) {
          setState(() => _isProcessing = true);
          await _initializeCamera(forceActivateStream: true);
          if (mounted) {
            setState(() {
              _isProcessing = false;
              _previewReady = _isCameraInitialized;
            });
            _ensurePreviewIsVisible();
          }
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(_isQRMode ? 'Escanear QR Code / Tirar Foto' : 'Tirar Foto'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(_isQRMode ? Icons.camera_alt : Icons.qr_code),
            onPressed: _isProcessing ? null : _toggleMode,
          ),
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: _isProcessing
                ? null
                : () {
                    if (_isQRMode) {
                      _qrController?.toggleTorch();
                    } else if (_cameraController != null) {
                      final bool enableTorch =
                          _cameraController!.value.flashMode != FlashMode.torch;
                      _cameraController!.setFlashMode(
                          enableTorch ? FlashMode.torch : FlashMode.off);
                    }
                  },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            onPressed: _isProcessing
                ? null
                : () {
                    if (_isQRMode) {
                      _qrController?.switchCamera();
                    } else {
                      // Implementar troca de câmera para o modo câmera
                      _switchCamera();
                    }
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // Modo QR ou Câmera
                _isQRMode
                    ? Container(
                        key: _qrScannerKey,
                        child: MobileScanner(
                          controller: _qrController,
                          onDetect: _handleQRDetection,
                        ),
                      )
                    : _buildCameraPreview(),

                // Overlay de processamento
                if (_isProcessing)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),

                // Mensagem de erro, se houver
                if (_hasCameraError && !_isProcessing)
                  Container(
                    color: Colors.black87,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.red, size: 48),
                          const SizedBox(height: 16),
                          const Text(
                            'Erro ao inicializar a câmera',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _forceCameraInitialization,
                            child: const Text('Tentar novamente'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Botão para reinicializar se necessário
                if (!_isProcessing &&
                    (_previewRetryCount < 3 ||
                        (_isQRMode && !_isQRScannerReady)))
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.black54,
                      onPressed: _resetCameraPreview,
                      tooltip: 'Corrigir visualização',
                      child: const Icon(Icons.refresh),
                    ),
                  ),
              ],
            ),
          ),
          // Overlay com instruções
          if (_isQRMode)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black.withOpacity(0.5),
              width: double.infinity,
              child: const Text(
                'Posicione o QR Code no centro da tela para escanear automaticamente, ou toque no botão abaixo para tirar uma foto.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          // Botão para tirar foto manualmente
          Container(
            color: Colors.black,
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Botão para voltar
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  color: Colors.white,
                  iconSize: 32,
                  onPressed: () => Navigator.pop(context),
                ),
                // Botão para tirar foto
                GestureDetector(
                  onTap: _isProcessing ? null : _takePicture,
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isProcessing ? Colors.grey : Colors.white,
                        width: 4,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.camera,
                        color: _isProcessing ? Colors.grey : Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                ),
                // Espaço para equilibrar o layout
                const SizedBox(width: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Constrói a visualização da câmera
  Widget _buildCameraPreview() {
    debugPrint(
        '🏗️ Construindo visualização da câmera - Inicializada: $_isCameraInitialized, Preview Ready: $_previewReady');

    if (!_isCameraInitialized || _cameraController == null) {
      // Se a câmera não estiver inicializada, tentar inicializar novamente
      if (!_isProcessing) {
        debugPrint('⚠️ Câmera não inicializada, tentando inicializar...');
        Future.microtask(() async {
          if (mounted) {
            setState(() => _isProcessing = true);
            await _initializeCamera(forceActivateStream: true);
            if (mounted) {
              setState(() {
                _isProcessing = false;
                _previewReady = _isCameraInitialized;
              });
              _ensurePreviewIsVisible();
            }
          }
        });
      }

      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Inicializando câmera...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    // Se a câmera estiver inicializada mas não estiver ativa, reativá-la
    if (!_cameraController!.value.isInitialized) {
      debugPrint(
          '⚠️ Controlador da câmera existe mas não está inicializado, reinicializando...');
      Future.microtask(() async {
        if (mounted) {
          await _initializeCamera(forceActivateStream: true);
          setState(() {
            _previewReady = _isCameraInitialized;
          });
          _ensurePreviewIsVisible();
        }
      });

      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Reativando câmera...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    // Se estiver tentando corrigir o preview, mostrar mensagem
    if (_attemptingPreviewFix) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Corrigindo visualização da câmera...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    debugPrint('✅ Exibindo visualização da câmera');

    // Usar key para forçar reconstrução e atualização do preview
    return Container(
      key: _cameraPreviewKey,
      child: CameraPreview(_cameraController!),
    );
  }

  // Manipula a detecção de QR code
  void _handleQRDetection(BarcodeCapture capture) {
    // Evitar processamento se já estiver processando
    if (!_isQRMode || _isProcessing || capture.barcodes.isEmpty) return;

    final barcode = capture.barcodes.first;
    if (barcode.rawValue == null) return;

    setState(() => _isProcessing = true);

    // Processar QR code
    final qrValue = barcode.rawValue!;
    debugPrint('✅ QR code detectado: $qrValue');

    // Salvar imagem se disponível
    if (capture.image != null) {
      _saveImageAndNotify(capture.image!, qrValue);
    } else {
      // Se não tiver imagem, apenas processa o QR code
      widget.onQRCodeDetected(qrValue);

      // Resetar estado de processamento após um breve atraso
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
      });
    }
  }

  Future<void> _saveImageAndNotify(Uint8List imageBytes, String qrCode) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final imagePath =
          '${tempDir.path}/qr_image_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Converter bytes em arquivo
      await File(imagePath).writeAsBytes(imageBytes);
      debugPrint('✅ Imagem salva: $imagePath');

      // Notificar sobre o QR code
      widget.onQRCodeDetected(qrCode);
    } catch (e) {
      debugPrint('❌ Erro ao salvar imagem: $e');
      // Em caso de erro, ainda notificar sobre o QR code
      widget.onQRCodeDetected(qrCode);
    } finally {
      // Resetar estado de processamento após um breve atraso
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _isProcessing = false);
        }
      });
    }
  }

  // Manipula a troca de câmera
  Future<void> _switchCamera() async {
    if (_cameras == null || _cameras!.length < 2 || _cameraController == null) {
      debugPrint(
          '⚠️ Não é possível trocar de câmera: câmeras insuficientes ou controlador nulo');
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final CameraLensDirection currentDirection =
          _cameraController!.description.lensDirection;

      debugPrint('🔄 Trocando câmera - Direção atual: $currentDirection');

      CameraDescription newCamera;

      if (currentDirection == CameraLensDirection.back) {
        newCamera = _cameras!.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => _cameras!.first,
        );
      } else {
        newCamera = _cameras!.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras!.first,
        );
      }

      debugPrint(
          '🔄 Trocando para câmera: ${newCamera.name} - Direção: ${newCamera.lensDirection}');

      // Liberar o controlador atual
      final prevCameraController = _cameraController;
      _cameraController = null;
      _isCameraInitialized = false;
      _previewReady = false;

      // Aguardar a liberação do controlador anterior
      await prevCameraController?.dispose();

      // Criar novo controlador com a câmera desejada
      _cameraController = CameraController(
        newCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      // Inicializar o controlador
      await _cameraController!.initialize();

      debugPrint(
          '✅ Nova câmera inicializada: ${_cameraController!.description.name}');

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _previewReady = true;
          _isProcessing = false;
        });

        // Garantir que o preview seja atualizado
        _ensurePreviewIsVisible();
      }
    } catch (e) {
      debugPrint('❌ Erro ao trocar câmera: $e');
      // Tentar reinicializar a câmera original em caso de erro
      await _initializeCamera(forceActivateStream: true);
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _previewReady = _isCameraInitialized;
        });
      }
    }
  }
}
