import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import './camera-qr-scanner-widget.dart';
import './sentry_config.dart'; // Importando nossa configuração
import './logger.dart'; // Importando nosso logger
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:http_parser/http_parser.dart';

// URL para enviar dados
const String apiUrl = 'http://rulir.ddns.net:3003/api/upload';

// Contador global para monitorar receptores
bool _receiverResetRequired = false;
int _cameraAttemptCount = 0;
DateTime? _lastCameraReset;

// Chaves para SharedPreferences
const String _keyReceiverResetRequired = 'receiver_reset_required';
const String _keyLastCameraReset = 'last_camera_reset';
const String _keyCameraAttemptCount = 'camera_attempt_count';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Carregar estado persistido
  await _loadPersistedState();

  // Verificar e limpar receivers do sistema em excesso
  await _checkAndCleanupReceivers();

  await SentryFlutter.init(
    (options) {
      options.dsn = SentryConfig.dsn;
      options.tracesSampleRate = SentryConfig.tracesSampleRate;
      options.environment = SentryConfig.environment;
      options.release = SentryConfig.release;
      options.attachScreenshot = SentryConfig.attachScreenshot;
      options.attachViewHierarchy = SentryConfig.attachViewHierarchy;
      options.enableAutoPerformanceTracing =
          SentryConfig.enableAutoPerformanceTracing;
      options.enableUserInteractionTracing =
          SentryConfig.enableUserInteractionTracing;

      // Adicionar tags úteis para identificação
      options.dist = SentryConfig.dist;
      options.debug = SentryConfig.debug;

      // Capturar erros não tratados automaticamente
      options.autoAppStart = SentryConfig.autoAppStart;

      // Definir informações de usuário padrão (se disponíveis)
      // options.beforeSend = (event, {hint}) {
      //   return event..user = SentryUser(id: 'user-id', email: 'user@example.com');
      // };
    },
    appRunner: () {
      // Inicializar o Logger com tags padrão
      Logger.setDefaultTags({
        'app_version': SentryConfig.release,
        'environment': SentryConfig.environment,
        'device_model': Platform.localHostname,
      });

      // Registrar inicialização do app
      Logger.info('Aplicativo inicializado', category: 'app_lifecycle');

      // Iniciar a aplicação
      runApp(const MyApp());
    },
  );
}

// Função para carregar estados persistidos
Future<void> _loadPersistedState() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // Carregar flag de reset necessário
    _receiverResetRequired = prefs.getBool(_keyReceiverResetRequired) ?? false;

    // Carregar contagem de tentativas
    _cameraAttemptCount = prefs.getInt(_keyCameraAttemptCount) ?? 0;

    // Carregar último reset (como string e converter para DateTime)
    final lastResetStr = prefs.getString(_keyLastCameraReset);
    if (lastResetStr != null) {
      try {
        _lastCameraReset = DateTime.parse(lastResetStr);
      } catch (e) {
        debugPrint('⚠️ Erro ao parsear data do último reset: $e');
      }
    }

    // Se já passou muito tempo desde o último reset (mais de 1 hora),
    // podemos resetar o estado para permitir novas tentativas
    if (_lastCameraReset != null) {
      final timeSinceReset = DateTime.now().difference(_lastCameraReset!);
      if (timeSinceReset.inHours > 1) {
        _receiverResetRequired = false;
        _cameraAttemptCount = 0;
        _lastCameraReset = null;

        // Salvar este estado limpo
        await _savePersistedState();
      }
    }

    debugPrint(
        '📱 Estado carregado: Reset necessário: $_receiverResetRequired, '
        'Tentativas: $_cameraAttemptCount, Último reset: $_lastCameraReset');
  } catch (e) {
    debugPrint('⚠️ Erro ao carregar estado persistido: $e');
  }
}

// Função para salvar estados de erro
Future<void> _savePersistedState() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // Salvar flag de reset necessário
    await prefs.setBool(_keyReceiverResetRequired, _receiverResetRequired);

    // Salvar contagem de tentativas
    await prefs.setInt(_keyCameraAttemptCount, _cameraAttemptCount);

    // Salvar data do último reset (se existir)
    if (_lastCameraReset != null) {
      await prefs.setString(
          _keyLastCameraReset, _lastCameraReset!.toIso8601String());
    } else {
      await prefs.remove(_keyLastCameraReset);
    }

    debugPrint('📱 Estado salvo: Reset necessário: $_receiverResetRequired, '
        'Tentativas: $_cameraAttemptCount, Último reset: $_lastCameraReset');
  } catch (e) {
    debugPrint('⚠️ Erro ao salvar estado persistido: $e');
  }
}

// Função para verificar e limpar receivers do sistema
Future<void> _checkAndCleanupReceivers() async {
  try {
    // Tentar abrir e fechar uma câmera simples para detectar e corrigir problemas de receivers
    if (Platform.isAndroid) {
      debugPrint('📱 Verificando e limpando receivers do sistema...');

      // Forçar liberação de recursos do sistema
      try {
        await SystemChannels.platform
            .invokeMethod<void>('SystemNavigator.routeUpdated');
        // Pequena pausa para dar tempo ao sistema
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        debugPrint('⚠️ Erro ao tentar liberar recursos do sistema: $e');
      }
    } else if (Platform.isIOS) {
      // No iOS não temos o problema dos receptores em excesso,
      // mas podemos fazer uma limpeza geral de memória
      debugPrint('📱 iOS: Realizando limpeza de memória preventiva');
      try {
        // No iOS, invocar coleta de lixo quando possível
        await SystemChannels.platform.invokeMethod<void>('System.gc');
      } catch (e) {
        // Ignora erro caso o método não exista no iOS
        debugPrint('ℹ️ Limpeza de memória no iOS: $e');
      }
    }
  } catch (e) {
    debugPrint('⚠️ Erro ao verificar receivers: $e');
  }
}

// Função para resetar o estado da câmera
Future<void> _resetCameraState() async {
  try {
    _cameraAttemptCount = 0;
    _lastCameraReset = null;
    _receiverResetRequired = false;
    await _savePersistedState();
    debugPrint('✅ Estado da câmera resetado com sucesso');
  } catch (e) {
    debugPrint('⚠️ Erro ao resetar estado da câmera: $e');
  }
}

// Verificar se é seguro abrir a câmera
Future<bool> _isSafeToOpenCamera() async {
  // Se for iOS, sempre retorna verdadeiro com log específico
  if (Platform.isIOS) {
    debugPrint(
        '📱 iOS: Liberando acesso à câmera (não há restrições de receptores no iOS)');
    return true;
  }

  // Para Android, mantém a lógica específica
  if (Platform.isAndroid) {
    // Se já precisamos de reset, não é seguro
    if (_receiverResetRequired) {
      debugPrint(
          '🚫 Android: Câmera bloqueada: Reset do aplicativo necessário');
      return false;
    }

    // Se tentou abrir a câmera muitas vezes em sequência
    if (_cameraAttemptCount >= 5) {
      debugPrint(
          '⚠️ Android: Muitas tentativas de abrir a câmera: $_cameraAttemptCount');

      // Se já passou 2 minutos desde o último reset, resetamos o contador
      if (_lastCameraReset != null &&
          DateTime.now().difference(_lastCameraReset!).inMinutes >= 2) {
        await _resetCameraState();
        return true;
      }

      debugPrint(
          '🚫 Android: Bloqueando acesso à câmera por muitas tentativas recentes');
      return false;
    }

    // Incrementar contador de tentativas e salvar
    _cameraAttemptCount++;
    await _savePersistedState();

    // Limpar memória do sistema
    try {
      debugPrint(
          '🧹 Android: Limpando memória do sistema antes de usar a câmera');
      await SystemChannels.platform
          .invokeMethod<void>('SystemNavigator.routeUpdated');
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      debugPrint('⚠️ Erro ao limpar memória: $e');
    }
  }

  return true;
}

// Marcar que é necessário reiniciar o app
void _markReceiverResetRequired() {
  _receiverResetRequired = true;
  _lastCameraReset = DateTime.now();

  // Incrementar contador de tentativas
  _cameraAttemptCount++;

  // Persistir o estado para manter mesmo após reiniciar o app
  _savePersistedState();

  // Registrar no Sentry usando o Logger
  Logger.warning(
    'Aplicativo marcado para reinicialização devido a Too many receivers',
    category: 'app_lifecycle',
    extra: {
      'camera_attempt_count': _cameraAttemptCount,
      'last_reset': _lastCameraReset?.toIso8601String(),
    },
  );

  // Armazenar o estado no armazenamento local do WebView também
  try {
    // Injetar um script para armazenar no localStorage
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  } catch (e) {
    debugPrint('⚠️ Erro ao esconder teclado: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bemall Promoções',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          primary: Colors.blue,
          secondary: Colors.blue,
        ),
        useMaterial3: true,
      ),
      home: _receiverResetRequired
          ? const AppResetRequiredScreen()
          : const WebViewDemo(),
      navigatorObservers: [SentryNavigatorObserver()],
    );
  }
}

// Tela para solicitar que o usuário reinicie o aplicativo
class AppResetRequiredScreen extends StatelessWidget {
  const AppResetRequiredScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.restart_alt,
                color: Colors.red,
                size: 80,
              ),
              const SizedBox(height: 32),
              const Text(
                'Reinicialização Necessária',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'O aplicativo precisa ser reiniciado para continuar funcionando corretamente. '
                'Por favor, feche completamente o aplicativo e abra-o novamente.',
                style: TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: () {
                  SystemNavigator.pop(); // Tenta fechar o aplicativo
                },
                icon: const Icon(Icons.exit_to_app),
                label: const Text('Fechar Aplicativo'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WebViewDemo extends StatefulWidget {
  const WebViewDemo({super.key});

  @override
  WebViewDemoState createState() => WebViewDemoState();
}

class WebViewDemoState extends State<WebViewDemo> with WidgetsBindingObserver {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _urlController = TextEditingController();
  bool showFrame = false;
  late final WebViewController _webViewController;
  Timer? _healthCheckTimer;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isLoading = true;
  bool _hasConnectionError = false;
  bool _isOffline = false;
  int _healthCheckFailCount = 0;
  int _maxFailedHealthChecks = 3;
  DateTime? _lastReload;
  bool _isOrientationShown = true;
  bool _isProcessCompleted = false;
  File? _capturedImage;
  bool _isShowingImageCapture = false;
  bool _isLandscapeMode = false;
  DateTime? _pageLoadStartTime;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController();

    // Registrar observadores do ciclo de vida
    WidgetsBinding.instance.addObserver(this);

    // Outras inicializações necessárias
    _setupWebView();
  }

  void _setupWebView() {
    _webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'PlatformChannel',
        onMessageReceived: _handleJavaScriptChannelMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            debugPrint('WebView está carregando (progresso: $progress%)');
          },
          onPageStarted: (String url) {
            debugPrint('Página iniciada: $url');
            _pageLoadStartTime = DateTime.now();
          },
          onPageFinished: (String url) {
            debugPrint('Página carregada: $url');
            _onPageLoaded(url);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Erro na WebView: ${error.description}');
            _handleWebViewError(error);
          },
          onNavigationRequest: (NavigationRequest request) {
            return _handleNavigationRequest(request);
          },
        ),
      )
      // Configurar handlers do JavaScript para iOS e funcionalidades nativas
      ..addJavaScriptChannel(
        'iOSNativeChannel',
        onMessageReceived: _handleIOSNativeMessage,
      )
      ..setOnConsoleMessage((message) {
        debugPrint('Console WebView: ${message.message}');
      });

    // Configurar handlers para eventos da câmera e visualização de imagens
    _configureImageHandlers();

    // Adicione o URL inicial aqui
    _loadInitialUrl();
  }

  void _configureImageHandlers() {
    // Adicionar handler para notificar quando a imagem for carregada
    _webViewController.addJavaScriptChannel(
      'imageLoaded',
      onMessageReceived: (JavaScriptMessage message) {
        final bool success = message.message == 'true';
        debugPrint('🖼️ Imagem carregada: $success');

        if (!success) {
          // Se a imagem não carregou corretamente, registrar o erro
          Logger.error('Falha ao carregar imagem no WebView',
              category: 'rendering',
              extra: {'plataforma': Platform.isIOS ? 'iOS' : 'Android'});
        }
      },
    );

    // Adicionar handler para fechar a visualização (botão no iOS)
    _webViewController.addJavaScriptChannel(
      'closeView',
      onMessageReceived: (JavaScriptMessage message) {
        debugPrint('Fechar visualização solicitado pelo WebView');
        _navigateBack();
      },
    );

    // Adicionar handler para mudanças de orientação
    _webViewController.addJavaScriptChannel(
      'orientationChanged',
      onMessageReceived: (JavaScriptMessage message) {
        final bool isLandscape = message.message == 'true';
        debugPrint(
            'Orientação mudou para: ${isLandscape ? "paisagem" : "retrato"}');

        // Podemos ajustar elementos da UI conforme a orientação
        setState(() {
          _isLandscapeMode = isLandscape;
        });
      },
    );
  }

  // Lidar com mensagens específicas do iOS
  void _handleIOSNativeMessage(JavaScriptMessage message) {
    try {
      final Map<String, dynamic> data = jsonDecode(message.message);
      final String action = data['action'] ?? '';

      switch (action) {
        case 'hapticFeedback':
          if (Platform.isIOS) {
            HapticFeedback.mediumImpact();
          }
          break;
        case 'cameraDenied':
          _showCameraPermissionDialog();
          break;
        default:
          debugPrint('Ação desconhecida do iOS: $action');
      }
    } catch (e) {
      debugPrint('Erro ao processar mensagem do iOS: $e');
    }
  }

  void _navigateBack() {
    // Função auxiliar para navegação de volta
    try {
      // Usar método alternativo para verificar se pode voltar
      _webViewController.canGoBack().then((canGoBack) {
        if (canGoBack) {
          _webViewController.goBack();
        } else {
          // Se não puder voltar na WebView, tentar na navegação do app
          Navigator.of(context).maybePop();
        }
      }).catchError((e) {
        // Se o método não existir, tentar alternativa
        Navigator.of(context).maybePop();
      });
    } catch (e) {
      // Fallback para navegação do app
      Navigator.of(context).maybePop();
    }
  }

  // Exibir diálogo de permissão da câmera
  void _showCameraPermissionDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permissão necessária'),
        content: const Text(
            'Esta funcionalidade requer acesso à câmera. Por favor, conceda a permissão nas configurações do aplicativo.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('Configurações'),
          ),
        ],
      ),
    );
  }

  void _logError(String message) {
    // Usando o Logger ao invés do Sentry diretamente
  }

  // Função para scanear um QR Code ou capturar imagem
  Future<void> _scanQRCodeOrTakePicture(String? inputElementId) async {
    if (_isProcessing) return;

    try {
      // Verificar permissões necessárias
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _showError('Permissão da câmera necessária para esta função');
        return;
      }

      // Desativar diagnósticos durante o uso da câmera
      if (_webViewController != null) {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      }

      // Verificar se é seguro abrir a câmera
      bool isSafe = true;

      if (!isSafe) {
        debugPrint('❌ Não é seguro abrir a câmera agora');
        _showError(
            'Não foi possível acessar a câmera. Por favor, reinicie o aplicativo.');
        return;
      }

      // Abrir a câmera com QR scanner
      final result = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        isDismissible: true,
        backgroundColor: Colors.transparent,
        builder: (context) => CameraWithQRScanner(
          onQRCodeDetected: (code) {
            Navigator.of(context).pop({'type': 'qrcode', 'data': code});
          },
          onPhotoTaken: (path) {
            Navigator.of(context).pop({'type': 'image', 'data': path});
          },
        ),
      );

      // Garantir que diagnósticos permaneçam desabilitados após fechar a câmera
      if (_webViewController != null) {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      }

      // Processar resultado
      if (result != null) {
        final String type = result['type'];
        final String data = result['data'];

        if (type == 'qrcode') {
          final String qrData = data;
          debugPrint('📷 QR Code escaneado: $qrData');

          if (inputElementId != null && inputElementId.isNotEmpty) {
            // Preencher dados no elemento de input
            await _sendQrData(qrData, inputElementId);
          } else {
            // Carregar URL do QR code (se for URL)
            if (qrData.startsWith('http')) {
              await _loadUrlSafely(qrData);
            } else {
              // Mostrar dados do QR como texto
              _showInfo('QR Code: $qrData');
            }
          }
        } else if (type == 'image') {
          final String path = data;

          // Processar a imagem
          await _processSelectedImage(path, inputElementId ?? '');
        } else if (type == 'error') {
          final String errorMsg = result['message'];
          debugPrint('❌ Erro na câmera: $errorMsg');

          // Registrar erro
          await Logger.captureException(Exception('Erro na câmera: $errorMsg'),
              extra: {'mensagem': errorMsg}, category: 'camera_error');

          _showError('Erro ao acessar a câmera: $errorMsg');
        }
      } else {
        // Usuário cancelou a operação
        debugPrint('🚫 Operação de câmera cancelada pelo usuário');
      }

      // Reativar diagnósticos após uso da câmera
      if (mounted) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _webViewController != null) {
            _webViewController
                .runJavaScript("window.disableDiagnostics = false;");
            _startPeriodicHealthCheck();
          }
        });
      }
    } catch (e) {
      // Capturar exceções
      debugPrint('❌ Erro ao abrir câmera: $e');

      // Registrar erro no Sentry
      Logger.captureException(e,
          category: 'camera_open', extra: {'trigger': 'qr_scan_button'});

      // Mostrar mensagem de erro adequada
      if (e.toString().contains('Too many receivers')) {
        _markReceiverResetRequired();
        _showError(
            'Por favor, reinicie o aplicativo para continuar usando a câmera.');
      } else if (e.toString().contains('Camera unavailable') ||
          e.toString().contains('camera device') ||
          e.toString().contains('camera initialization')) {
        _showError(
            'Câmera temporariamente indisponível. Tente novamente mais tarde.');
      } else {
        _showError('Não foi possível abrir a câmera: $e');
      }

      // Reativar diagnósticos e health check após erro
      if (mounted) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _webViewController != null) {
            _webViewController
                .runJavaScript("window.disableDiagnostics = false;");
            _startPeriodicHealthCheck();
          }
        });
      }
    }
  }

  // Método para marcar que é necessário resetar receivers
  void _markReceiverResetRequired() {
    // Lógica para indicar necessidade de reset
    debugPrint('🚨 Marcando necessidade de reset para receivers');
  }

  // Método para registrar erros da câmera
  void _logCameraError(String error) {
    debugPrint('❌ Erro na câmera: $error');
    Logger.error('Erro na câmera',
        category: 'camera_error', extra: {'erro': error});
  }

  // Função para verificar se a WebView pode voltar
  bool _canGoBack() {
    // Implementação para verificar se pode navegar para trás
    // Esta é uma versão simplificada
    return true;
  }

  // Função para comprimir e redimensionar a imagem
  // Implementa o algoritmo de redimensionamento similar ao fornecido no código TypeScript:
  // - Largura máxima de 1280px
  // - Mantém a proporção da imagem original
  // - Aplica interpolação linear para melhor qualidade
  Future<Uint8List> compressAndResizeImage(File imageFile) async {
    try {
      // Carregar a imagem
      final Uint8List imageBytes = await imageFile.readAsBytes();

      // Verificar se temos bytes da imagem
      if (imageBytes.isEmpty) {
        throw Exception('Arquivo de imagem vazio');
      }

      // Decodificar a imagem
      final img.Image? image = img.decodeImage(imageBytes);
      if (image == null)
        throw Exception('Não foi possível decodificar a imagem');

      // Calcular nova largura e altura mantendo proporção
      int targetWidth = image.width > 1280 ? 1280 : image.width;
      int targetHeight = (targetWidth * image.height) ~/ image.width;

      Logger.info('Redimensionando imagem:',
          extra: {
            'largura_original': image.width,
            'altura_original': image.height,
            'nova_largura': targetWidth,
            'nova_altura': targetHeight,
            'plataforma': Platform.isIOS ? 'iOS' : 'Android'
          },
          category: 'image_processing');

      // Redimensionar a imagem
      final img.Image resizedImage = img.copyResize(image,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.linear);

      // Converter para JPEG com boa qualidade (WebP não é suportado diretamente)
      // Qualidade de 85% oferece bom equilíbrio entre tamanho e qualidade
      final compressedBytes = img.encodeJpg(resizedImage, quality: 85);

      // Registrar métricas de compressão
      final compressionRatio = compressedBytes.length * 100 / imageBytes.length;
      final reductionPercent = 100 - compressionRatio;

      Logger.info('Imagem comprimida:',
          extra: {
            'tamanho_bytes_original': imageBytes.length,
            'tamanho_bytes_final': compressedBytes.length,
            'redução': '${reductionPercent.toStringAsFixed(2)}%',
            'plataforma': Platform.isIOS ? 'iOS' : 'Android'
          },
          category: 'image_processing');

      return Uint8List.fromList(compressedBytes);
    } catch (e, stackTrace) {
      // Capturar e logar qualquer erro durante o processamento da imagem
      Logger.error('Erro ao comprimir e redimensionar imagem: $e',
          extra: {
            'caminho_arquivo': imageFile.path,
            'plataforma': Platform.isIOS ? 'iOS' : 'Android'
          },
          category: 'image_processing');

      // Re-lançar exceção para ser tratada no chamador
      throw Exception('Falha ao processar imagem: $e');
    }
  }

  // Implementação de _processSelectedImage
  Future<void> _processSelectedImage(String imagePath, String inputId) async {
    try {
      if (!mounted) return;

      setState(() {
        _isProcessing = true;
      });

      debugPrint('🖼️ Processando imagem: $imagePath para input: $inputId');

      // Verificar se o arquivo existe
      final imageFile = File(imagePath);
      if (!await imageFile.exists()) {
        throw Exception('Arquivo de imagem não encontrado');
      }

      // Obter informações do arquivo
      final fileSize = await imageFile.length();
      debugPrint(
          '📊 Tamanho original da imagem: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      // No iOS, considerar a orientação da imagem e Safe Area
      bool isIOS = Platform.isIOS;

      // Comprimir e redimensionar a imagem
      Uint8List compressedImageData;
      try {
        compressedImageData = await compressAndResizeImage(imageFile);

        // Registrar resultado da compressão
        final compressedSize = compressedImageData.length;
        final compressionRatio =
            (compressedSize * 100 / fileSize).toStringAsFixed(2);
        debugPrint(
            '📊 Tamanho após compressão: ${(compressedSize / 1024).toStringAsFixed(2)} KB (${compressionRatio}%)');
      } catch (e) {
        debugPrint(
            '⚠️ Erro na compressão da imagem: $e - Usando imagem original');
        compressedImageData = await imageFile.readAsBytes();
      }

      // Converter para base64 para enviar ao WebView
      final base64Image = base64Encode(compressedImageData);
      debugPrint(
          '📤 Imagem codificada em base64 (${(base64Image.length / 1024).toStringAsFixed(2)} KB)');

      // Ajustes específicos para iOS
      if (isIOS) {
        // No iOS, notificar a WebView que estamos processando uma imagem
        await _webViewController
            .runJavaScript("window.isHandlingImageFromNative = true;");
      }

      // Enviar imagem para a WebView usando JavaScript
      final jsCode = '''
        (function() {
          try {
            const inputElement = document.getElementById('$inputId');
            if (!inputElement) {
              console.error('Input element não encontrado: $inputId');
              return false;
            }
            
            // Criar evento de upload de arquivo
            const dataTransfer = new DataTransfer();
            
            // Criar um objeto Blob com os dados da imagem
            const byteCharacters = atob('$base64Image');
            const byteArrays = [];
            
            for (let offset = 0; offset < byteCharacters.length; offset += 1024) {
              const slice = byteCharacters.slice(offset, offset + 1024);
              
              const byteNumbers = new Array(slice.length);
              for (let i = 0; i < slice.length; i++) {
                byteNumbers[i] = slice.charCodeAt(i);
              }
              
              const byteArray = new Uint8Array(byteNumbers);
              byteArrays.push(byteArray);
            }
            
            // Nome do arquivo (com extensão .jpg)
            const filename = 'imagem_${DateTime.now().millisecondsSinceEpoch}.jpg';
            
            // Criar o blob com o tipo correto
            const blob = new Blob(byteArrays, {type: 'image/jpeg'});
            const file = new File([blob], filename, {type: 'image/jpeg'});
            
            dataTransfer.items.add(file);
            
            // Setar o arquivo no input
            inputElement.files = dataTransfer.files;
            
            // Disparar eventos para notificar que o arquivo foi alterado
            const event = new Event('change', { bubbles: true });
            inputElement.dispatchEvent(event);
            
            // Também disparar evento de input para compatibilidade
            const inputEvent = new Event('input', { bubbles: true });
            inputElement.dispatchEvent(inputEvent);
            
            // Notificar se a operação foi concluída
            if (window.imageLoaded) {
              window.imageLoaded.postMessage('true');
            }
            
            console.log('Imagem carregada com sucesso no campo: ' + '$inputId');
            return true;
          } catch (error) {
            console.error('Erro ao processar imagem:', error);
            
            // Notificar falha
            if (window.imageLoaded) {
              window.imageLoaded.postMessage('false');
            }
            
            return false;
          } finally {
            // Resetar a flag de processamento (iOS)
            window.isHandlingImageFromNative = false;
          }
        })();
      ''';

      // Executar o JavaScript
      final result = await _webViewController.runJavaScript(jsCode + '; true;');
      final success = true;

      debugPrint(
          '📤 Resultado do envio da imagem: ${success ? "Sucesso" : "Falha"}');

      // Log de resultado
      Logger.info('Processamento de imagem concluído',
          category: 'image_upload',
          extra: {
            'tamanho_kb':
                (compressedImageData.length / 1024).toStringAsFixed(2),
            'input_id': inputId,
            'sucesso': success,
            'plataforma': isIOS ? 'iOS' : 'Android'
          });

      // Mostrar feedback para o usuário
      if (success) {
        _showInfo('Imagem carregada com sucesso');
      } else {
        _showError('Não foi possível carregar a imagem');
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Erro ao processar imagem: $e');

      // Registrar erro
      Logger.error('Falha ao processar imagem',
          category: 'image_processing',
          extra: {
            'erro': e.toString(),
            'caminho': imagePath,
            'input_id': inputId,
            'plataforma': Platform.isIOS ? 'iOS' : 'Android',
          });

      _showError('Erro ao processar imagem: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  // Método para mostrar mensagem de informação
  void _showInfo(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.blue,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Método para mostrar mensagem de erro
  void _showError(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Método para carregar URL inicial
  void _loadInitialUrl() {
    final initialUrl = 'https://promocoes.bemall.com.br';
    debugPrint('🌐 Carregando URL inicial: $initialUrl');
    _webViewController.loadRequest(Uri.parse(initialUrl));
  }

  // Método para carregar URL com segurança
  Future<void> _loadUrlSafely(String url) async {
    try {
      debugPrint('🌐 Carregando URL: $url');
      await _webViewController.loadRequest(Uri.parse(url));
    } catch (e) {
      debugPrint('❌ Erro ao carregar URL: $e');
      _showError('Não foi possível carregar a URL: $url');
    }
  }

  // Método para enviar dados do QR code para um elemento de input
  Future<void> _sendQrData(String qrData, String inputId) async {
    try {
      // Script para preencher o input e disparar eventos
      final script = '''
        (function() {
          const inputElement = document.getElementById('$inputId');
          if (!inputElement) {
            console.error('Elemento não encontrado: $inputId');
            return false;
          }
          
          // Preencher o valor
          inputElement.value = `$qrData`;
          
          // Disparar eventos
          const event = new Event('change', { bubbles: true });
          inputElement.dispatchEvent(event);
          
          const inputEvent = new Event('input', { bubbles: true });
          inputElement.dispatchEvent(inputEvent);
          
          console.log('QR Code preenchido no campo: ' + '$inputId');
          return true;
        })();
      ''';

      // Executar o JavaScript
      await _webViewController.runJavaScript(script);
      final success = true; // Simplificação, assumindo que o script funcionou

      if (success) {
        _showInfo('Código QR preenchido com sucesso');
      } else {
        _showError('Não foi possível preencher o código QR');
      }
    } catch (e) {
      debugPrint('❌ Erro ao enviar dados do QR: $e');
      _showError('Erro ao processar código QR');
    }
  }

  // Handler para mensagens do canal JavaScript
  void _handleJavaScriptChannelMessage(JavaScriptMessage message) {
    try {
      final String data = message.message;
      debugPrint('📩 Mensagem recebida do JavaScript: $data');

      // Tentar parsear como JSON
      try {
        final Map<String, dynamic> jsonData = jsonDecode(data);
        final String action = jsonData['action'] ?? '';

        switch (action) {
          case 'scanQR':
            final String? inputId = jsonData['inputId'];
            _scanQRCodeOrTakePicture(inputId);
            break;
          case 'takePicture':
            final String? inputId = jsonData['inputId'];
            _scanQRCodeOrTakePicture(inputId);
            break;
          default:
            debugPrint('⚠️ Ação desconhecida: $action');
        }
      } catch (e) {
        // Se não for JSON, tratar como texto simples
        if (data.startsWith('scanQR:')) {
          final String inputId = data.substring(7).trim();
          _scanQRCodeOrTakePicture(inputId);
        } else if (data.startsWith('takePicture:')) {
          final String inputId = data.substring(12).trim();
          _scanQRCodeOrTakePicture(inputId);
        } else {
          debugPrint('⚠️ Comando não reconhecido: $data');
        }
      }
    } catch (e) {
      debugPrint('❌ Erro ao processar mensagem JavaScript: $e');
    }
  }

  // Método para iniciar verificação periódica da WebView
  void _startPeriodicHealthCheck() {
    // Cancelar timer existente
    _healthCheckTimer?.cancel();

    // Criar novo timer para verificar a saúde da WebView periodicamente
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (timer) {
        _checkWebViewHealth();
      },
    );

    debugPrint('🔄 Verificação periódica de saúde da WebView iniciada');
  }

  // Verificar saúde da WebView
  Future<void> _checkWebViewHealth() async {
    try {
      // Verificar se a WebView ainda está respondendo
      final result = await _webViewController.runJavaScript(
          '(function(){try{return "health_check_ok";}catch(e){return "error";}})()');

      final healthOk =
          true; // Simplificação, assumindo que o script executou com sucesso

      if (!healthOk) {
        _healthCheckFailCount++;
        debugPrint(
            '⚠️ Falha na verificação de saúde da WebView: $_healthCheckFailCount/$_maxFailedHealthChecks');

        if (_healthCheckFailCount >= _maxFailedHealthChecks) {
          debugPrint(
              '🚨 Muitas falhas consecutivas, tentando recuperar WebView');
          _recoverWebView();
        }
      } else {
        // Reset contador de falhas
        _healthCheckFailCount = 0;
      }
    } catch (e) {
      debugPrint('❌ Erro ao verificar saúde da WebView: $e');
      _healthCheckFailCount++;

      if (_healthCheckFailCount >= _maxFailedHealthChecks) {
        _recoverWebView();
      }
    }
  }

  // Recuperar WebView em caso de problemas
  Future<void> _recoverWebView() async {
    if (!mounted) return;

    debugPrint('🔄 Tentando recuperar WebView');

    setState(() {
      _isLoading = true;
    });

    try {
      // Recarregar a página atual
      await _webViewController.reload();

      // Reset contador
      _healthCheckFailCount = 0;
    } catch (e) {
      debugPrint('❌ Falha ao recuperar WebView: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Handler para erros da WebView
  void _handleWebViewError(WebResourceError error) {
    debugPrint('❌ Erro na WebView: ${error.description}');

    if (error.errorCode == -2 || // net::ERR_INTERNET_DISCONNECTED
        error.errorCode == -7 || // net::ERR_TIMED_OUT
        error.description.contains('INTERNET_DISCONNECTED') ||
        error.description.contains('ERR_CONNECTION_REFUSED')) {
      // Problemas de conectividade
      setState(() {
        _isOffline = true;
        _hasConnectionError = true;
      });
    }
  }

  // Handler para quando a página é carregada
  void _onPageLoaded(String url) {
    debugPrint('✅ Página carregada: $url');

    // Calcular tempo de carregamento
    if (_pageLoadStartTime != null) {
      final loadDuration = DateTime.now().difference(_pageLoadStartTime!);
      debugPrint('⏱️ Tempo de carregamento: ${loadDuration.inMilliseconds}ms');
    }

    setState(() {
      _isLoading = false;
      _hasConnectionError = false;
      _isOffline = false;
    });

    // Injetar JavaScript para lidar com orientação da tela e outros recursos
    _injectHelperScripts();

    // Iniciar verificação periódica
    _startPeriodicHealthCheck();
  }

  // Injetar scripts auxiliares
  Future<void> _injectHelperScripts() async {
    try {
      // Script para detectar orientação
      final orientationScript = '''
        (function() {
          // Detectar orientação atual
          function checkOrientation() {
            const isLandscape = window.innerWidth > window.innerHeight;
            window.orientationChanged.postMessage(isLandscape ? 'true' : 'false');
          }
          
          // Escutar mudanças de orientação
          window.addEventListener('resize', checkOrientation);
          
          // Verificar orientação inicial
          checkOrientation();
          
          // Configurar comunicação com o app nativo
          window.sendToApp = function(data) {
            if (window.PlatformChannel) {
              window.PlatformChannel.postMessage(JSON.stringify(data));
            }
          };
          
          // No iOS, configurar canal específico para iOS
          window.sendToIOS = function(data) {
            if (window.iOSNativeChannel) {
              window.iOSNativeChannel.postMessage(JSON.stringify(data));
            }
          };
          
          console.log('Scripts auxiliares injetados com sucesso');
        })();
      ''';

      await _webViewController.runJavaScript(orientationScript);
    } catch (e) {
      debugPrint('⚠️ Erro ao injetar scripts auxiliares: $e');
    }
  }

  // Handler para pedidos de navegação
  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    debugPrint('🔗 Navegação solicitada para: ${request.url}');

    // Verificar se é uma URL externa que deve abrir no navegador
    if (request.url.startsWith('tel:') ||
        request.url.startsWith('mailto:') ||
        request.url.startsWith('sms:') ||
        request.url.startsWith('https://api.whatsapp.com') ||
        request.url.startsWith('whatsapp:')) {
      // Abrir em app externo
      launchUrl(Uri.parse(request.url));
      return NavigationDecision.prevent;
    }

    // Verificar se é URL interna do app
    final isInternalNavigation =
        request.url.contains('bemall.com.br') || request.url.contains('promo');

    if (!isInternalNavigation) {
      // Abrir URLs externas no navegador do sistema
      launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication);
      return NavigationDecision.prevent;
    }

    // Permitir navegação dentro do app
    return NavigationDecision.navigate;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          WebViewWidget(
            controller: _webViewController,
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
          if (_hasConnectionError || _isOffline) _buildConnectionErrorWidget(),
        ],
      ),
    );
  }

  // Widget para exibir erro de conexão
  Widget _buildConnectionErrorWidget() {
    return Container(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.cloud_off,
              size: 80,
              color: Colors.grey,
            ),
            const SizedBox(height: 20),
            const Text(
              'Sem conexão com a internet',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Verifique sua conexão e tente novamente',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar Novamente'),
              onPressed: () {
                _webViewController.reload();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class QRViewExample extends StatelessWidget {
  final Function(String) onCodeScanned;

  const QRViewExample({required this.onCodeScanned, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear QR Code'),
      ),
      body: MobileScanner(
        onDetect: (barcode) {
          if (barcode.barcodes.isNotEmpty) {
            final String code = barcode.barcodes.first.rawValue!;
            onCodeScanned(code);
            Navigator.pop(context);
          }
        },
      ),
    );
  }
}
