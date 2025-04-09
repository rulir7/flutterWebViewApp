import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
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
import './ios_utils.dart'; // Importando utilitários para iOS

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
  const AppResetRequiredScreen({super.key});

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
  final int _maxFailedHealthChecks = 3;
  DateTime? _lastReload;
  bool _isOrientationShown = true;
  bool _isProcessCompleted = false;
  File? _capturedImage;
  bool _isShowingImageCapture = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions().then((_) {
      _initializeWebView();
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _loadHtmlContent();
          _startPeriodicHealthCheck();
        }
      });
    });
  }

  void _initializeWebView() {
    // Cria e configura o WebView com persistência
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    // Configuração específica para Android
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);

      // Configurar para persistir dados entre sessões
      (controller.platform as AndroidWebViewController)
          .setOnPlatformPermissionRequest(
              (PlatformWebViewPermissionRequest request) => request.grant());
    }

    // Configuração específica para iOS (WebKit)
    if (controller.platform is WebKitWebViewController) {
      (controller.platform as WebKitWebViewController)
          .setAllowsBackForwardNavigationGestures(true);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            debugPrint('Navegação iniciada: $url');
          },
          onPageFinished: (String url) {
            debugPrint('Navegação finalizada: $url');
            // Verifica se o WebView está realmente pronto
            controller.runJavaScript(
                'document.body.style.backgroundColor = "white";');

            // Script para verificar e ativar cache do ServiceWorker para PWA
            controller.runJavaScript('''
              // Implementar estratégia de cache para PWA
              try {
                // Verificar se o PWA tem um service worker e ativar
                if ('serviceWorker' in navigator) {
                  navigator.serviceWorker.register('/service-worker.js')
                    .catch(function(err) {
                      console.log('ServiceWorker registration failed: ', err);
                    });
                }
                
                // Configurar cache para assets
                if ('caches' in window) {
                  // Criar um cache específico para o app
                  caches.open('pwa-assets-cache').then(function(cache) {
                    // Cache de recursos principais
                    const cacheUrls = [
                      '/index.html',
                      '/styles.css',
                      '/script.js',
                      '/images/logo.png'
                    ];
                    
                    // Tenta fazer cache dos recursos principais
                    cache.addAll(cacheUrls).catch(e => console.log('Cache falhou:', e));
                    
                    // Lista de assets críticos caso o PWA informe algum
                    if (window.PWA_ASSETS && Array.isArray(window.PWA_ASSETS)) {
                      cache.addAll(window.PWA_ASSETS).catch(e => console.log('Cache de PWA_ASSETS falhou:', e));
                    }
                  });
                }
                
                // Configurar localStorage para armazenar informação de cache
                localStorage.setItem('cache_last_updated', new Date().toISOString());
                localStorage.setItem('cache_enabled', 'true');
                
                console.log('Estratégia de cache configurada com sucesso');
              } catch (e) {
                console.error('Erro ao configurar cache:', e);
              }
            ''');
          },
          onWebResourceError: (WebResourceError error) {
            _logError('WebView error: ${error.description}');
          },
          onNavigationRequest: (NavigationRequest request) {
            // Remove a restrição de navegação que pode estar causando problemas
            // Quando um QR code é escaneado, queremos permitir a navegação para essa URL
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('Mensagem do JavaScript: ${message.message}');
        },
      )
      // Configurar para persistência de cookies e localStorage
      ..setOnConsoleMessage((JavaScriptConsoleMessage message) {
        debugPrint('Console: ${message.message}');
      })
      // Define configurações para persistência
      ..enableZoom(true)
      ..setBackgroundColor(Colors.white) // Garante fundo branco
      ..setUserAgent('Mozilla/5.0 Flutter WebView')
      // Habilita armazenamento local (localStorage) e cookies
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    // Injetar um script para monitorar eventos relacionados a problemas de renderização
    controller.runJavaScript('''
      // Configurar detecção de problemas de renderização
      document.addEventListener('DOMContentLoaded', function() {
        console.log('DOM carregado completamente');
        document.body.style.backgroundColor = 'white';
        
        // Interceptar elementos de input file
        interceptFileInputs();
      });
      
      // Monitorar erros de renderização
      window.addEventListener('error', function(e) {
        console.error('Erro de renderização:', e.message);
        window.Flutter.postMessage('Erro: ' + e.message);
      });
      
      // Configurar cookies via JavaScript
      document.cookie = "session_persistent=true; domain=.example.com; path=/; expires=${DateTime.now().add(const Duration(days: 365)).toUtc()}";
      localStorage.setItem('app_initialized', 'true');
      
      // Função para interceptar elementos input file
      function interceptFileInputs() {
        console.log('Configurando interceptação de inputs file');
        
        // Observador de mutação para detectar novos elementos input adicionados ao DOM
        const observer = new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            if (mutation.addedNodes) {
              mutation.addedNodes.forEach(function(node) {
                if (node.nodeType === 1) { // Elemento
                  const inputs = node.querySelectorAll('input[type="file"]');
                  if (inputs.length) {
                    inputs.forEach(setupFileInputInterceptor);
                  }
                  
                  // Se o próprio nó for um input file
                  if (node.tagName === 'INPUT' && node.type === 'file') {
                    setupFileInputInterceptor(node);
                  }
                }
              });
            }
          });
        });
        
        // Iniciar observador
        observer.observe(document.documentElement, { 
          childList: true, 
          subtree: true 
        });
        
        // Configurar inputs já existentes
        document.querySelectorAll('input[type="file"]').forEach(setupFileInputInterceptor);
        
        // Função para configurar interceptação em um input específico
        function setupFileInputInterceptor(input) {
          console.log('Interceptando input file:', input);
          
          // Armazenar elementos originais
          const originalClick = input.onclick;
          
          // Substituir o evento de clique
          input.onclick = function(event) {
            console.log('Clique em input file interceptado');
            event.preventDefault();
            
            // Notificar Flutter sobre a interceptação
            window.Flutter.postMessage(JSON.stringify({
              type: 'fileInputIntercepted',
              inputId: input.id,
              capture: input.getAttribute('capture'),
              accept: input.accept
            }));
            
            return false;
          };
        }
      }
    ''');

    // Adicionar canal JavaScript para comunicação bidirecional
    controller.addJavaScriptChannel(
      'Flutter',
      onMessageReceived: (JavaScriptMessage message) {
        debugPrint('Mensagem do JavaScript: ${message.message}');
        _processJavaScriptMessage(message.message);
      },
    );

    _webViewController = controller;

    // Carregue uma página em branco para inicializar o WebView
    _webViewController.loadHtmlString('''
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { 
              background-color: white; 
              color: black; 
              font-family: Arial, sans-serif; 
            }
          </style>
        </head>
        <body>
          <div style="padding: 20px;">
            <h3>Escaneie um código QR para começar</h3>
          </div>
        </body>
      </html>
    ''');
  }

  void _logError(String message) {
    // Usando o Logger ao invés do Sentry diretamente
    Logger.error(message, category: 'webview');
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      debugPrint('App minimizado');
      // Salvar estado da webview quando o app é minimizado
      _saveWebViewState(isClosing: false);
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('App retomado');
      // Restaurar estado da webview quando o app volta ao primeiro plano
      _restoreWebViewState();

      // Verificar saúde do WebView após retomada
      _performWebViewHealthCheck();
    } else if (state == AppLifecycleState.detached) {
      // App sendo fechado/destruído
      _saveWebViewState(isClosing: true);
    }
  }

  // Função para salvar o estado atual do WebView
  Future<void> _saveWebViewState({bool isClosing = false}) async {
    try {
      // Captura estado atual via JavaScript
      await _webViewController.runJavaScript('''
        try {
          // Salvar timestamp para verificação de validade do cache
          localStorage.setItem('webview_last_state_timestamp', '${DateTime.now().millisecondsSinceEpoch}');
          
          // Salvar URL atual
          localStorage.setItem('webview_last_url', window.location.href);
          
          // Salvar scroll position
          localStorage.setItem('webview_scroll_position', window.scrollY.toString());
          
          // Informar ao PWA que o app está sendo minimizado/fechado
          localStorage.setItem('webview_app_state', '${isClosing ? "closed" : "paused"}');
          
          // Criar evento para o PWA saber que deve salvar seu estado
          window.dispatchEvent(new CustomEvent('appStateChange', {
            detail: { state: '${isClosing ? "closed" : "paused"}' }
          }));
          
          console.log('Estado do WebView salvo com sucesso');
        } catch (e) {
          console.error('Erro ao salvar estado:', e);
        }
      ''');
    } catch (e) {
      _logError('Erro ao salvar estado do WebView: $e');
    }
  }

  // Função para restaurar o estado do WebView
  Future<void> _restoreWebViewState() async {
    try {
      // Restaura estado via JavaScript
      await _webViewController.runJavaScript('''
        try {
          // Verificar se há um estado salvo
          const lastTimestamp = localStorage.getItem('webview_last_state_timestamp');
          const lastUrl = localStorage.getItem('webview_last_url');
          
          if (lastTimestamp && lastUrl) {
            const now = ${DateTime.now().millisecondsSinceEpoch};
            const lastTime = parseInt(lastTimestamp);
            
            // Verificar se o estado salvo é recente (menos de 30 minutos)
            if (now - lastTime < 30 * 60 * 1000) {
              // Restaurar scroll após carregar
              const scrollPos = localStorage.getItem('webview_scroll_position');
              if (scrollPos) {
                window.scrollTo(0, parseInt(scrollPos));
              }
              
              // Notificar o PWA que o app foi restaurado
              localStorage.setItem('webview_app_state', 'resumed');
              
              // Criar evento para o PWA saber que deve restaurar seu estado
              window.dispatchEvent(new CustomEvent('appStateChange', {
                detail: { state: 'resumed' }
              }));
              
              console.log('Estado do WebView restaurado com sucesso');
            }
          }
        } catch (e) {
          console.error('Erro ao restaurar estado:', e);
        }
      ''');

      // Verificar conexão
      _checkConnectivity();
    } catch (e) {
      _logError('Erro ao restaurar estado do WebView: $e');
    }
  }

  // Verificar conexão com a internet
  Future<void> _checkConnectivity() async {
    try {
      await _webViewController.runJavaScript('''
        // Verificar conexão
        function checkOnlineStatus() {
          if (navigator.onLine) {
            console.log('Dispositivo online');
            document.body.classList.remove('offline-mode');
            
            // Tentar recarregar recursos offline se necessário
            if (window.PWA_NEEDS_RELOAD === true) {
              console.log('Recarregando recursos após reconexão');
              window.location.reload();
            }
          } else {
            console.log('Dispositivo offline');
            document.body.classList.add('offline-mode');
            
            // Marcar para recarregar quando estiver online
            window.PWA_NEEDS_RELOAD = true;
            
            // Mostrar aviso de offline
            if (!document.getElementById('offline-message')) {
              const div = document.createElement('div');
              div.id = 'offline-message';
              div.style.position = 'fixed';
              div.style.bottom = '10px';
              div.style.left = '10px';
              div.style.right = '10px';
              div.style.backgroundColor = 'rgba(0,0,0,0.7)';
              div.style.color = 'white';
              div.style.padding = '10px';
              div.style.borderRadius = '5px';
              div.style.zIndex = '9999';
              div.style.textAlign = 'center';
              div.innerHTML = 'Você está offline. Algumas funcionalidades podem não estar disponíveis.';
              document.body.appendChild(div);
            }
          }
        }
        
        // Verificar status inicial
        checkOnlineStatus();
        
        // Configurar listeners para mudanças de conectividade
        window.addEventListener('online', checkOnlineStatus);
        window.addEventListener('offline', checkOnlineStatus);
      ''');
    } catch (e) {
      _logError('Erro ao verificar conectividade: $e');
    }
  }

  // Função para realizar teste de integridade do WebView
  Future<void> _performWebViewHealthCheck() async {
    try {
      // Verificar se os diagnósticos estão desativados na página atual
      // Usamos toString() == 'true' para lidar com diferentes tipos de retorno
      try {
        final disableCheck =
            await _webViewController.runJavaScriptReturningResult('''
          (function() {
            try {
              return (window.disableDiagnostics === true).toString();
            } catch(e) {
              return 'false';
            }
          })();
        ''');

        final String disableResult =
            disableCheck.toString().toLowerCase().trim();
        if (disableResult == 'true') {
          debugPrint(
              'Diagnóstico do WebView ignorado: diagnósticos desativados na página atual');
          return;
        }
      } catch (e) {
        debugPrint('Erro ao verificar flag disableDiagnostics: $e');
        // Se não conseguimos verificar, desistimos da verificação de saúde
        return;
      }

      // Verificar o URL atual para determinar se estamos em about:blank ou data:
      String currentUrl = '';
      try {
        currentUrl = await _webViewController.currentUrl() ?? '';
      } catch (e) {
        debugPrint('Erro ao obter URL atual: $e');
        // Se não podemos obter URL, desistimos da verificação
        return;
      }

      // Se estivermos em about:blank ou em uma URL de data (como uma imagem base64),
      // ou em uma URL vazia, não executamos diagnósticos
      final bool isEmptyPage = currentUrl.isEmpty ||
          currentUrl == 'about:blank' ||
          currentUrl.startsWith('data:');

      if (isEmptyPage) {
        debugPrint(
            'Diagnóstico do WebView ignorado: página vazia ou about:blank');
        return;
      }

      // Criamos um diagnóstico básico que funciona em qualquer página
      final basicScript = '''
        (function() {
          try {
            return JSON.stringify({
              url: document.location.href || '',
              userAgent: navigator.userAgent || '',
              pageTitle: document.title || '',
              domState: document.readyState || '',
              timestamp: new Date().toISOString(),
              isSecure: window.location.protocol === 'https:',
              screenWidth: window.innerWidth,
              screenHeight: window.innerHeight
            });
          } catch (e) {
            return JSON.stringify({
              error: e.toString(),
              errorType: 'basic_diagnostics_error'
            });
          }
        })();
      ''';

      // Se não estivermos em uma página vazia, adicione verificações avançadas
      final advancedScript = '''
        (function() {
          try {
            var hasLocalStorage = false;
            var hasSessionStorage = false;
            var hasCookies = false;
            var hasIndexedDB = false;
            
            try { 
              hasLocalStorage = !!window.localStorage; 
            } catch(e) {}
            
            try { 
              hasSessionStorage = !!window.sessionStorage; 
            } catch(e) {}
            
            try { 
              hasCookies = navigator.cookieEnabled; 
            } catch(e) {}
            
            try { 
              hasIndexedDB = !!window.indexedDB; 
            } catch(e) {}
            
            return JSON.stringify({
              hasLocalStorage: hasLocalStorage,
              hasSessionStorage: hasSessionStorage,
              hasCookies: hasCookies,
              hasIndexedDB: hasIndexedDB,
              isOnline: navigator.onLine,
              hasServiceWorker: 'serviceWorker' in navigator
            });
          } catch (e) {
            return JSON.stringify({
              error: e.toString(),
              errorType: 'advanced_diagnostics_error'
            });
          }
        })();
      ''';

      // Executar diagnóstico básico
      Map<String, dynamic> diagnostics = {};
      try {
        final basicResult =
            await _webViewController.runJavaScriptReturningResult(basicScript);

        // Processar resultado básico
        final String basicJson = basicResult.toString();

        if (basicJson != "null" && basicJson.isNotEmpty) {
          try {
            diagnostics = Map<String, dynamic>.from(jsonDecode(basicJson));
            debugPrint('Diagnóstico básico WebView: $basicJson');
          } catch (e) {
            debugPrint('Erro ao decodificar diagnóstico básico: $e');
            // Se não conseguimos processar o básico, desistimos
            return;
          }
        }
            } catch (e) {
        debugPrint('Erro ao executar diagnóstico básico: $e');
        return;
      }

      // Se diagnostics está vazio, não continuar
      if (diagnostics.isEmpty) {
        Logger.warning('Não foi possível obter diagnósticos básicos do WebView',
            category: 'webview.diagnostics');
        return;
      }

      // Se não estamos em about:blank, executar diagnóstico avançado
      try {
        final advancedResult = await _webViewController
            .runJavaScriptReturningResult(advancedScript);

        final String advancedJson = advancedResult.toString();

        if (advancedJson != "null" && advancedJson.isNotEmpty) {
          try {
            final Map<String, dynamic> advancedData =
                Map<String, dynamic>.from(jsonDecode(advancedJson));

            // Mesclar dados avançados com o diagnóstico básico
            diagnostics.addAll(advancedData);
            debugPrint('Diagnóstico avançado WebView: $advancedJson');
          } catch (e) {
            debugPrint('Erro ao decodificar diagnóstico avançado: $e');
            // Podemos continuar apenas com o básico
          }
        }
            } catch (e) {
        debugPrint('Erro ao executar diagnóstico avançado: $e');
        // Podemos continuar apenas com o básico
      }

      // Adicionar informações sobre a página
      diagnostics['isEmptyPage'] = isEmptyPage;
      diagnostics['pageType'] = isEmptyPage ? 'empty' : 'content';

      // Log de sucesso - enviar sem try/catch para não mascarar erros de diagnóstico
      // que estamos tentando consertar
      Logger.info('Diagnóstico do WebView concluído',
          category: 'webview.diagnostics', extra: diagnostics);
    } catch (e) {
      // Evitar enviar exceção para o Sentry para não criar loop
      debugPrint('⚠️ Erro ao realizar diagnóstico do WebView: $e');

      // Apenas registrar como warning, sem tentar capturar exceção
      Logger.warning('Erro ao realizar diagnóstico do WebView: $e',
          category: 'webview', extra: {'errorDetails': e.toString()});
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.storage,
    ].request();
  }

  Future<bool> _checkPermissions() async {
    var cameraStatus = await Permission.camera.status;

    if (!cameraStatus.isGranted) {
      var results = [
        Permission.camera.request(),
      ];

      if ((await Future.wait(results)).every((status) => status.isGranted)) {
        return true;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Permissões de câmera são necessárias.')),
        );
        return false;
      }
    }
    return true;
  }

  // Função para processar mensagens recebidas do JavaScript
  void _processJavaScriptMessage(String message) {
    try {
      // Tenta interpretar a mensagem como JSON
      final Map<String, dynamic> data = jsonDecode(message);

      // Verificar se é uma interceptação de input file
      if (data['type'] == 'fileInputIntercepted') {
        _handleFileInputIntercepted(data);
      } else {
        debugPrint('Mensagem não reconhecida: $message');
      }
    } catch (e) {
      // Se não for JSON, trata como mensagem de texto simples
      debugPrint('Mensagem de texto do JavaScript: $message');
    }
  }

  // Manipula a interceptação de um input file
  void _handleFileInputIntercepted(Map<String, dynamic> data) {
    debugPrint('Input file interceptado: $data');

    // Obter informações do input
    final String inputId = data['inputId'] ?? '';
    final String accept = data['accept'] ?? '*/*';
    final String capture = data['capture'] ?? '';

    // Verificar se deve usar a câmera com base no atributo "capture"
    final bool useCamera = capture == 'environment' || capture == 'camera';

    // Verificar se o accept inclui imagens
    final bool acceptImages = accept.contains('image') || accept == '*/*';

    if (acceptImages && useCamera) {
      // Abrir câmera para captura de foto ou QR code
      _scanQRCodeOrTakePicture(inputId: inputId);
    } else {
      // Opção para escolher arquivo da galeria
      _pickFileFromGallery(inputId: inputId);
    }
  }

  // Função para selecionar arquivo da galeria
  Future<void> _pickFileFromGallery({required String inputId}) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        // Processar a imagem selecionada
        await _processSelectedImage(image.path, inputId);
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao selecionar imagem: $e');
    }
  }

  // Função para processar uma imagem selecionada
  Future<void> _processSelectedImage(String imagePath, String inputId) async {
    try {
      debugPrint('Processando imagem: $imagePath');

      // Cancelar qualquer verificação de saúde atual para evitar diagnósticos durante o processamento
      _healthCheckTimer?.cancel();

      // Verificar se o arquivo existe
      final file = File(imagePath);
      if (!await file.exists()) {
        debugPrint('Arquivo de imagem não existe: $imagePath');
        throw Exception('Arquivo de imagem não encontrado');
      }

      // Otimizações específicas para iOS
      bool isIOS = Platform.isIOS;
      if (isIOS) {
        // Em dispositivos iOS, podemos enfrentar problemas de memória com imagens grandes
        try {
          // Verificar o tamanho do arquivo
          final fileSize = await file.length();
          final fileSizeMB = fileSize / (1024 * 1024);
          debugPrint(
              '📊 Tamanho do arquivo iOS: ${fileSizeMB.toStringAsFixed(2)} MB');

          // Se o arquivo for muito grande, comprimir antes de processar
          if (fileSizeMB > 5.0) {
            // Mais de 5MB
            debugPrint(
                '⚠️ Arquivo grande detectado no iOS, aplicando otimizações...');

            // Comprimir a imagem antes de converter para base64
            final compressedBytes =
                await compressAndResizeImage(file, forceHighCompression: true);

            // Converter para base64 usando a imagem comprimida
            final base64Image = base64Encode(compressedBytes);

            // Liberar recursos de memória no iOS
            await IOSUtils.releaseSystemResources();

            // Continuar o processamento com a imagem otimizada
            await _continuarProcessamentoImagem(
                base64Image, imagePath, inputId);
            return;
          }
        } catch (e) {
          debugPrint('⚠️ Erro durante otimização iOS: $e');
          // Continuar com o fluxo normal se a otimização falhar
        }
      }

      // Converter para base64 - fluxo normal para arquivos de tamanho razoável
      List<int> imageBytes;

      // Se não for iOS ou for um arquivo pequeno, tentar comprimir levemente para melhorar desempenho
      if (isIOS) {
        try {
          final compressedBytes = await compressAndResizeImage(file);
          imageBytes = compressedBytes;
          debugPrint(
              '✅ Imagem comprimida para iOS: ${(imageBytes.length / 1024).toStringAsFixed(2)} KB');
        } catch (e) {
          debugPrint('⚠️ Compressão leve falhou, usando original: $e');
          imageBytes = await file.readAsBytes();
        }
      } else {
        imageBytes = await file.readAsBytes();
      }

      final String base64Image = base64Encode(imageBytes);

      // Após processamento em iOS, liberar recursos
      if (isIOS) {
        await IOSUtils.releaseSystemResources();
      }

      await _continuarProcessamentoImagem(base64Image, imagePath, inputId);
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao processar imagem: $e');
    }
  }

  // Método auxiliar para continuar o processamento da imagem após otimizações
  Future<void> _continuarProcessamentoImagem(
      String base64Image, String imagePath, String inputId) async {
    try {
      // Tentar detectar QR code na imagem de forma transparente
      String? qrCode;
      try {
        final MobileScannerController controller = MobileScannerController();
        try {
          final barcodes = await controller.analyzeImage(imagePath);
          if (barcodes?.barcodes.isNotEmpty ?? false) {
            qrCode = barcodes?.barcodes.first.rawValue;
            debugPrint('✅ QR code detectado na imagem: $qrCode');
          } else {
            debugPrint('ℹ️ Nenhum QR code detectado na imagem');
          }
        } finally {
          await controller.dispose();
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao tentar detectar QR code: $e');
      }

      // O código HTML para exibir a imagem
      final String photoHtml = '''
        <!DOCTYPE html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Foto Capturada</title>
            <script>
              // Garantir que diagnósticos estão desativados (definido antes do corpo da página)
              window.disableDiagnostics = true;
              
              // Informe à página pai que os diagnósticos devem ser desativados
              try {
                if (window.parent) {
                  window.parent.disableDiagnostics = true;
                }
              } catch(e) {}
            </script>
            <style>
              body { 
                margin: 0; 
                padding: 20px;
                background-color: white;
                font-family: Arial, sans-serif;
                display: flex;
                flex-direction: column;
                align-items: center;
              }
              .preview-container {
                width: 100%;
                max-width: 400px;
                margin: 0 auto;
                text-align: center;
              }
              .preview-image {
                width: 100%;
                max-height: 300px;
                object-fit: contain;
                border-radius: 8px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
              }
              h3 {
                color: #333;
                margin-bottom: 20px;
              }
              .qr-info {
                margin-top: 20px;
                padding: 15px;
                background-color: #e3f2fd;
                border-radius: 8px;
                border-left: 4px solid #2196F3;
                display: ${qrCode != null ? 'block' : 'none'};
              }
            </style>
          </head>
          <body>
            <div class="preview-container">
              <h3>Foto Capturada</h3>
              <img src="data:image/jpeg;base64,$base64Image" class="preview-image" alt="Preview">
              <div class="qr-info">
                <h4>QR Code detectado:</h4>
                <p>${qrCode ?? ''}</p>
              </div>
            </div>
            <script>
              // Desabilitar diagnósticos novamente para ter certeza
              window.disableDiagnostics = true;
              
              // Bloqueamos explicitamente diagnósticos
              window.addEventListener('load', function() {
                // Garantir que diagnósticos estão desativados mesmo após carregamento
                window.disableDiagnostics = true;
                
                // Se tiver QR code com URL, redirecionar após 1 segundo
                ${qrCode != null && (qrCode.startsWith('http://') || qrCode.startsWith('https://')) ? '''
                  setTimeout(function() {
                    window.location.href = "$qrCode";
                  }, 1000);
                ''' : ''}
              });
            </script>
          </body>
        </html>
      ''';

      // Assegurar que diagnósticos estão realmente desabilitados
      await _webViewController
          .runJavaScript("window.disableDiagnostics = true;");

      // Sempre mostrar a imagem capturada em uma página HTML
      await _webViewController.loadHtmlString(photoHtml);

      // Verificar novamente para garantir que a flag está ativa
      await Future.delayed(const Duration(milliseconds: 500));
      await _webViewController
          .runJavaScript("window.disableDiagnostics = true;");

      // Desabilitar temporariamente o health check quando mostramos uma imagem sem QR code
      if (qrCode == null) {
        // Cancelar o timer de health check atual
        _healthCheckTimer?.cancel();

        // Reativar o timer após tempo suficiente (aumentado para 10 segundos) após a página estar completamente carregada
        Future.delayed(const Duration(seconds: 10), () {
          if (mounted) {
            _startPeriodicHealthCheck();
          }
        });
      }

      // Se foi detectado um QR code com URL, carregar a URL no WebView após mostrar a prévia
      if (qrCode != null &&
          (qrCode.startsWith('http://') || qrCode.startsWith('https://'))) {
        await Future.delayed(const Duration(seconds: 1));
        await _loadUrlSafely(qrCode);
      }

      // Se foi chamado de um input file, processar para o elemento
      if (inputId.isNotEmpty) {
        await _webViewController.runJavaScript('''
          (function() {
            try {
              // Garantir que diagnósticos estão desativados
              window.disableDiagnostics = true;
              
              const input = document.getElementById('$inputId') || document.querySelector('input[type="file"]');
              if (!input) {
                console.error('Input element not found: $inputId');
                return;
              }
              
              const byteString = atob('$base64Image');
              const mimeType = 'image/jpeg';
              const ab = new ArrayBuffer(byteString.length);
              const ia = new Uint8Array(ab);
              
              for (let i = 0; i < byteString.length; i++) {
                ia[i] = byteString.charCodeAt(i);
              }
              
              const blob = new Blob([ab], {type: mimeType});
              const fileName = 'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
              const file = new File([blob], fileName, {type: mimeType});
              
              const dataTransfer = new DataTransfer();
              dataTransfer.items.add(file);
              input.files = dataTransfer.files;
              
              const event = new Event('change', { bubbles: true });
              input.dispatchEvent(event);
              
              if ('$qrCode' !== 'null') {
                document.dispatchEvent(new CustomEvent('qrCodeDetected', { 
                  detail: { qrcode: '$qrCode' }
                }));
              }
            } catch (error) {
              console.error('❌ Erro ao processar arquivo:', error);
            }
          })();
        ''');
      }

      // Enviar dados para o servidor
      try {
        await _uploadFile(imagePath, 'image', qrCode: qrCode);
      } catch (uploadError, uploadStack) {
        debugPrint('⚠️ Erro ao enviar arquivo para o servidor: $uploadError');
        await Sentry.captureException(
          uploadError,
          stackTrace: uploadStack,
          hint: {'info': 'Erro ao fazer upload após processamento de imagem'}
              as Hint,
        );
        _showError(
            'O arquivo foi processado, mas houve um erro no envio ao servidor: $uploadError');
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao processar imagem: $e');

      // Em caso de erro no iOS, tentar liberar recursos
      if (Platform.isIOS) {
        await IOSUtils.releaseSystemResources();
      }
    }
  }

  Future<void> _scanQRCodeOrTakePicture({String inputId = ''}) async {
    try {
      bool hasPermission = await _checkPermissions();
      if (!hasPermission) return;

      // Desativar diagnósticos e cancelar health check
      _healthCheckTimer?.cancel();
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint('Erro ao desabilitar diagnósticos antes da câmera: $e');
      }

      // Abre um modal customizado com câmera que permite escanear QR code ou tirar foto
      final result = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
          height: MediaQuery.of(context).size.height * 0.9,
          decoration: const BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: CameraWithQRScanner(
            onQRCodeDetected: (String code) {
              // Retornar resultado em vez de fechar o modal diretamente
              Navigator.pop(context, {'type': 'qrcode', 'data': code});
            },
            onPhotoTaken: (String imagePath) {
              // Retornar resultado em vez de fechar o modal diretamente
              Navigator.pop(context, {'type': 'photo', 'data': imagePath});
            },
          ),
        ),
      );

      // Assegurar que diagnósticos estão desabilitados após fechar o modal
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint('Erro ao desabilitar diagnósticos após câmera: $e');
      }

      // Se não houver resultado, o usuário cancelou
      if (result == null) {
        // Reativar health check após 10 segundos
        Future.delayed(const Duration(seconds: 10), () {
          if (mounted) {
            _startPeriodicHealthCheck();
          }
        });
        return;
      }

      // Processar o resultado após o modal ser fechado - manter diagnósticos desativados
      if (result['type'] == 'qrcode') {
        final String code = result['data'];
        final String? imagePath = result['imagePath']
            as String?; // Verificar se temos uma imagem junto com o QR code

        // Processar o código QR
        setState(() {
          _urlController.text = code;
          showFrame = true;
        });

        // Se temos uma imagem junto com o QR code, processar a imagem e o QR code
        if (imagePath != null) {
          // Processar a imagem com o QR code
          if (inputId.isNotEmpty) {
            // Se foi chamado de um input file, enviar para o elemento
            await _processSelectedImage(imagePath, inputId);
          } else {
            // Processar a foto e o QR code juntos
            await _uploadFile(imagePath, 'image', qrCode: code);
          }
        } else {
          // Apenas o QR code foi detectado (sem imagem)
          // Registrar URL escaneada
          await _sendQrData(code);
        }

        // Se foi chamado de um input file, injetar os dados no elemento
        if (inputId.isNotEmpty) {
          // Salvar QR code detectado no JavaScript para uso posterior
          await _webViewController.runJavaScript('''
            window.lastDetectedQRCode = "$code";
            
            // Disparar evento para notificar o PWA
            document.dispatchEvent(new CustomEvent('qrCodeDetected', { 
              detail: { qrcode: "$code" }
            }));
          ''');
        } else {
          // Carregar URL na WebView - Garante que a WebView seja completamente recarregada
          await _loadUrlSafely(code);

          // Assegura que o estado está atualizado após a detecção do QR
          if (mounted) {
            setState(() {
              showFrame = true;
            });
          }
        }
      } else if (result['type'] == 'photo') {
        final String imagePath = result['data'];
        final String? qrCode = result['qrCode']
            as String?; // Verificar se temos um QR code detectado na foto

        try {
          // Se foi chamado de um input file, enviar para o elemento
          if (inputId.isNotEmpty) {
            await _processSelectedImage(imagePath, inputId);
          } else {
            // Processar a foto, incluindo QR code se detectado
            await _uploadFile(imagePath, 'image', qrCode: qrCode);

            // Garantir que o WebView esteja visível
            if (mounted) {
              setState(() {
                showFrame = true;
              });
            }

            // Converter a imagem para base64 - diagnósticos continuam desabilitados
            final String base64Image =
                base64Encode(await File(imagePath).readAsBytes());

            // Certificar que diagnósticos estão desativados
            await _webViewController
                .runJavaScript("window.disableDiagnostics = true;");

            // Carregar uma página HTML com a foto
            final String photoHtml = '''
              <!DOCTYPE html>
              <html>
                <head>
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <title>Foto Capturada</title>
                  <script>
                    // Desabilitar diagnósticos antes que a página carregue
                    window.disableDiagnostics = true;
                  </script>
                  <style>
                    body { 
                      margin: 0; 
                      padding: 20px;
                      background-color: white;
                      font-family: Arial, sans-serif;
                    }
                    .preview-container {
                      max-width: 100%;
                      margin: 0 auto;
                      text-align: center;
                    }
                    .preview-image {
                      max-width: 100%;
                      max-height: 80vh;
                      border-radius: 8px;
                      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                    }
                    h3 {
                      color: #333;
                      margin-bottom: 20px;
                    }
                  </style>
                </head>
                <body>
                  <div class="preview-container">
                    <h3>Foto Capturada</h3>
                    <img src="data:image/jpeg;base64,$base64Image" class="preview-image" alt="Preview">
                  </div>
                  <script>
                    // Garantir que diagnósticos permanecem desativados
                    window.disableDiagnostics = true;
                  </script>
                </body>
              </html>
            ''';

            await _webViewController.loadHtmlString(photoHtml);

            // Verificar novamente para garantir que a flag está ativa
            await Future.delayed(const Duration(milliseconds: 500));
            await _webViewController
                .runJavaScript("window.disableDiagnostics = true;");
          }
        } catch (e) {
          _logError('Erro ao processar imagem: $e');
          _showError('Erro ao processar imagem: $e');
        }
      }

      // Manter diagnósticos desativados por um tempo razoável
      await Future.delayed(const Duration(seconds: 2));
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint('Erro ao desabilitar diagnósticos no final: $e');
      }

      // Reativar health check após um tempo suficiente
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          _startPeriodicHealthCheck();
        }
      });
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao tirar foto ou escanear QR Code: $e');

      // Reativar health check após erro, mas com delay
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted) {
          _startPeriodicHealthCheck();
        }
      });
    }
  }

  // Função auxiliar para carregar URLs com segurança
  Future<void> _loadUrlSafely(String url) async {
    try {
      // Desabilitar temporariamente o health check durante a navegação
      _healthCheckTimer?.cancel();

      // Injetar script para desabilitar diagnósticos durante a navegação
      await _webViewController
          .runJavaScript("window.disableDiagnostics = true;");

      // Carregar a URL
      await _webViewController.loadRequest(Uri.parse(url));

      // Verificar se a página carregou corretamente depois de um curto intervalo
      await Future.delayed(const Duration(seconds: 1));
      await _webViewController.runJavaScript('''
        if (document.body) {
          document.body.style.backgroundColor = "white";
          console.log("Página carregada e cor de fundo definida");
          
          // Ativar diagnósticos quando a página estiver carregada corretamente
          window.disableDiagnostics = false;
        } else {
          console.error("Corpo do documento não encontrado");
        }
      ''');

      // Reativar o health check após um tempo adequado para a página carregar completamente
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          _startPeriodicHealthCheck();
        }
      });
    } catch (e) {
      _logError('Erro ao carregar URL: $e');

      // Tenta recarregar a página em caso de erro
      try {
        await _webViewController.reload();

        // Reativar diagnósticos após erro
        await Future.delayed(const Duration(seconds: 1));
        await _webViewController
            .runJavaScript("window.disableDiagnostics = false;");

        // Reativar health check
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            _startPeriodicHealthCheck();
          }
        });
      } catch (reloadError) {
        _logError('Erro ao tentar recarregar: $reloadError');
      }
    }
  }

  // Carrega HTML base para garantir que o WebView está funcionando
  void _loadHtmlContent() {
    _webViewController.loadHtmlString('''
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body { 
              background-color: white; 
              color: black; 
              font-family: Arial, sans-serif; 
            }
          </style>
        </head>
        <body>
          <div style="padding: 20px;">
            <h3>Escaneie um código QR para começar</h3>
          </div>
        </body>
      </html>
    ''');
  }

  // Função para enviar dados do QR Code para o servidor
  Future<void> _sendQrData(String qrData) async {
    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'qr_code', 'data': qrData}),
      );

      if (response.statusCode == 200) {
        debugPrint('QR Code enviado com sucesso');
      } else {
        _logError('Erro ao enviar QR Code: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _logError('Exceção ao enviar QR Code: $e');
    }
  }

  // Função para enviar arquivos para o servidor
  Future<void> _uploadFile(String filePath, String type,
      {String? qrCode}) async {
    try {
      debugPrint(
          'Enviando arquivo: $filePath | Tipo: $type | QR Code: $qrCode');

      // Comprimir e redimensionar a imagem
      final File imageFile = File(filePath);
      final Uint8List compressedImage = await compressAndResizeImage(imageFile);

      // SERVIDOR ATUAL - Manteremos usando este por enquanto
      final uri = Uri.parse(apiUrl);

      // Criar um request multipart
      final request = http.MultipartRequest('POST', uri);

      // Adicionar o arquivo como um arquivo multipart
      request.files.add(http.MultipartFile.fromBytes('file', compressedImage,
          filename: 'photo.jpg', contentType: MediaType('image', 'jpeg')));

      // Adicionar outros campos
      request.fields['type'] = type;

      // Se houver QR code, adicionar como campo separado
      if (qrCode != null) {
        request.fields['qrcode'] = qrCode;
        debugPrint('Enviando QR code junto com a imagem: $qrCode');
      }

      /* 
      // NOVO SERVIDOR E ENDPOINT - Comentado até termos as informações completas
      // Construir a URL completa com o endpoint correto
      // final baseUrl = "https://seuservidor.com"; // Substituir pelo servidor correto
      // final uri = Uri.parse('$baseUrl/mkt/promotion/hash/upload-qrcode-photo');
      
      // // Criar um request multipart
      // final request = http.MultipartRequest('POST', uri);
      
      // // Adicionar a imagem comprimida como um arquivo multipart
      // request.files.add(
      //   http.MultipartFile.fromBytes(
      //     'photo', 
      //     compressedImage,
      //     filename: 'photo.jpg',
      //     contentType: MediaType('image', 'jpeg')
      //   )
      // );
      
      // // Se houver QR code, adicionar como campo separado
      // if (qrCode != null) {
      //   request.files.add(
      //     http.MultipartFile.fromString(
      //       'qrcode', 
      //       qrCode,
      //       filename: 'qrcode.txt',
      //       contentType: MediaType('text', 'plain')
      //     )
      //   );
      // }
      */

      // Enviar o request e obter a resposta
      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200) {
        Logger.info('Arquivo enviado com sucesso!',
            extra: {'qrCode': qrCode != null, 'size': compressedImage.length},
            category: 'upload');
        debugPrint(
            'Arquivo enviado com sucesso! ${qrCode != null ? "Com QR code" : "Sem QR code"}');
      } else {
        Logger.error('Erro ao enviar arquivo: ${streamedResponse.statusCode}',
            extra: {'response': responseBody}, category: 'upload');
        _logError('Erro ao enviar arquivo: ${streamedResponse.statusCode}');
        _logError('Resposta: $responseBody');
      }
    } catch (e, stackTrace) {
      Logger.captureException(e,
          stackTrace: stackTrace,
          category: 'upload',
          extra: {'filePath': filePath, 'type': type});
      _logError('Exceção ao enviar arquivo: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openUrl() async {
    if (_formKey.currentState!.validate()) {
      String url = _urlController.text;

      // Opção para carregar página de teste de upload
      if (url.toLowerCase() == 'test' || url.toLowerCase() == 'teste') {
        _loadTestPage();
        setState(() {
          showFrame = true;
        });
        return;
      }

      // Carregar URL na WebView
      await _loadUrlSafely(url);
      setState(() {
        showFrame = true;
      });
    }
  }

  String? _validateUrl(String? value) {
    if (value == null || value.isEmpty) {
      return 'Por favor, insira uma URL';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return 'Insira uma URL válida com http:// ou https://';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      // No iOS, aplicar padding adicional para evitar colisão com a barra de status
      body: SafeArea(
        // iOS tem bottom safe area diferente (especialmente no iPhone X+)
        bottom: Platform.isIOS,
        top: true,
        child: Column(
          children: [
            // Barra de título com gradiente
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.blue.shade700, Colors.blue.shade900],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Bemall promoções',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed: () => _reloadWebView(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.camera_alt, color: Colors.white),
                        onPressed: () => _showCameraModal(),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        onSelected: (String value) {
                          if (value == 'test_sentry') {
                            _testSentryCapture();
                          }
                        },
                        itemBuilder: (BuildContext context) => [
                          const PopupMenuItem<String>(
                            value: 'test_sentry',
                            child: Row(
                              children: [
                                Icon(Icons.bug_report),
                                SizedBox(width: 8),
                                Text('Testar Sentry'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Conteúdo principal
            Expanded(
              child: _isOrientationShown
                  ? OrientationView(
                      onOrientationComplete: () {
                        setState(() {
                          _isOrientationShown = false;
                        });
                        _startQRCodeReadingWithTimeout();
                      },
                    )
                  : _isProcessCompleted
                      ? CompletionView(
                          isShowingImageCapture: (bool show) {
                            setState(() {
                              _isShowingImageCapture = show;
                            });
                          },
                          capturedImage: _capturedImage,
                          onImageCaptured: (File image) {
                            setState(() {
                              _capturedImage = image;
                            });
                          },
                          onSendComplete: () {
                            setState(() {
                              _isProcessCompleted = true;
                            });
                          },
                        )
                      : WebViewWidget(controller: _webViewController),
            ),
          ],
        ),
      ),
    );
  }

  // Carrega uma página de teste para demonstrar a interceptação de upload
  void _loadTestPage() {
    _webViewController.loadHtmlString('''
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Teste de Upload</title>
          <style>
            body {
              font-family: Arial, sans-serif;
              margin: 0;
              padding: 20px;
              background-color: #f5f5f5;
            }
            .container {
              background-color: white;
              border-radius: 10px;
              padding: 20px;
              box-shadow: 0 2px 10px rgba(0,0,0,0.1);
              max-width: 500px;
              margin: 0 auto;
            }
            h1 {
              color: #333;
              font-size: 24px;
              margin-top: 0;
            }
            .form-group {
              margin-bottom: 20px;
            }
            label {
              display: block;
              margin-bottom: 8px;
              font-weight: bold;
              color: #555;
            }
            .file-input {
              background-color: #f9f9f9;
              border: 2px dashed #ccc;
              padding: 30px;
              text-align: center;
              cursor: pointer;
              border-radius: 5px;
              transition: all 0.3s;
            }
            .file-input:hover {
              border-color: #2196F3;
              background-color: #e3f2fd;
            }
            .button {
              background-color: #4CAF50;
              color: white;
              border: none;
              padding: 10px 20px;
              border-radius: 5px;
              cursor: pointer;
              font-size: 16px;
              transition: background-color 0.3s;
            }
            .button:hover {
              background-color: #45a049;
            }
            .preview {
              margin-top: 20px;
              text-align: center;
            }
            .preview img {
              max-width: 100%;
              max-height: 300px;
              border-radius: 5px;
              box-shadow: 0 2px 5px rgba(0,0,0,0.2);
            }
            .qr-data {
              margin-top: 20px;
              padding: 15px;
              background-color: #e8f5e9;
              border-radius: 5px;
              border-left: 4px solid #4CAF50;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Teste de Captura e Upload</h1>
            
            <div class="form-group">
              <label for="camera-input">Tirar foto / Escanear QR Code:</label>
              <div class="file-input" id="camera-container">
                <input 
                  type="file" 
                  id="camera-input" 
                  accept="image/*" 
                  capture="environment"
                  style="display: none;"
                >
                <p>Clique aqui para abrir a câmera</p>
              </div>
            </div>
            
            <div class="form-group">
              <label for="file-input">Selecionar da galeria:</label>
              <div class="file-input" id="file-container">
                <input 
                  type="file" 
                  id="file-input" 
                  accept="image/*"
                  style="display: none;"
                >
                <p>Clique aqui para selecionar uma imagem</p>
              </div>
            </div>
            
            <div class="preview" id="image-preview">
              <!-- Imagem será exibida aqui -->
            </div>
            
            <div class="qr-data" id="qr-data" style="display: none;">
              <h3>QR Code detectado:</h3>
              <p id="qr-content"></p>
            </div>
          </div>
          
          <script>
            // Configurar os containers para abrir o file input quando clicados
            document.getElementById('camera-container').addEventListener('click', function() {
              document.getElementById('camera-input').click();
            });
            
            document.getElementById('file-container').addEventListener('click', function() {
              document.getElementById('file-input').click();
            });
            
            // Exibir a imagem selecionada na prévia
            function handleFileSelect(event) {
              const file = event.target.files[0];
              if (file) {
                const reader = new FileReader();
                reader.onload = function(e) {
                  const preview = document.getElementById('image-preview');
                  preview.innerHTML = '<img src="' + e.target.result + '" alt="Preview">';
                };
                reader.readAsDataURL(file);
              }
            }
            
            // Ouvir o evento de seleção de arquivo
            document.getElementById('camera-input').addEventListener('change', handleFileSelect);
            document.getElementById('file-input').addEventListener('change', handleFileSelect);
            
            // Ouvir evento customizado de QR code detectado
            document.addEventListener('qrCodeDetected', function(e) {
              if (e.detail && e.detail.qrcode) {
                const qrData = document.getElementById('qr-data');
                const qrContent = document.getElementById('qr-content');
                qrContent.textContent = e.detail.qrcode;
                qrData.style.display = 'block';
                
                console.log('QR Code detectado:', e.detail.qrcode);
              }
            });
          </script>
        </body>
      </html>
    ''');
  }

  // Inicia verificação periódica de saúde do WebView
  void _startPeriodicHealthCheck() {
    // Cancela timer existente, se houver
    _healthCheckTimer?.cancel();

    // Configura novo timer para verificar a cada 5 minutos
    _healthCheckTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      if (mounted) {
        _performWebViewHealthCheck();
      } else {
        timer.cancel();
      }
    });
  }

  // Função para mostrar a câmera
  Future<void> _showCameraModal() async {
    try {
      debugPrint('Iniciando processo de abertura da câmera...');

      // Verificar primeiro se temos permissão
      final PermissionStatus cameraPermissionStatus =
          await Permission.camera.request();
      debugPrint('Status da permissão da câmera: $cameraPermissionStatus');

      if (!cameraPermissionStatus.isGranted) {
        _logError('Permissão de câmera negada pelo usuário');
        _showError(
            'É necessário permitir o acesso à câmera para usar esta função.');
        return;
      }

      // Verificar se é seguro abrir a câmera
      bool isSafeToOpenCamera = await _checkIfSafeToProceedWithCamera();
      debugPrint('É seguro abrir a câmera? $isSafeToOpenCamera');

      if (!isSafeToOpenCamera) {
        return;
      }

      // Desabilitar health check durante o uso da câmera
      _healthCheckTimer?.cancel();

      // Desabilitar diagnósticos na página atual
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint('Erro ao desabilitar diagnósticos: $e');
      }

      // Limpar recursos e estado antes de abrir a câmera
      await _disposeResourcesBeforeCamera();
      debugPrint('Recursos limpos, preparando para abrir câmera...');

      // Pequeno atraso para garantir limpeza de recursos
      await Future.delayed(const Duration(milliseconds: 300));

      // Se muitos receptores foram registrados, mostrar erro e não abrir câmera
      if (_receiverResetRequired) {
        _showError(
            'O aplicativo precisa ser reiniciado para usar a câmera. Por favor, feche completamente o aplicativo e abra-o novamente.');
        return;
      }

      debugPrint('Abrindo modal da câmera...');
      final result = await showModalBottomSheet<Map<String, dynamic>>(
        context: _scaffoldKey.currentContext!,
        isScrollControlled: true,
        isDismissible: true,
        backgroundColor: Colors.transparent,
        builder: (BuildContext context) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.9,
            decoration: const BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
              child: CameraWithQRScanner(
                onQRCodeDetected: (String qrCode) {
                  debugPrint('QR code detectado: $qrCode');
                  Navigator.pop(context, {'type': 'qrcode', 'data': qrCode});
                },
                onPhotoTaken: (String imagePath) {
                  debugPrint('Foto tirada: $imagePath');
                  Navigator.pop(context, {'type': 'photo', 'data': imagePath});
                },
              ),
            ),
          );
        },
      );

      debugPrint('Resultado do modal da câmera: $result');

      // Restaurar WebView e recursos após fechar a câmera
      await _restoreResourcesAfterCamera();

      // Controle de erro - se não conseguiu abrir a câmera
      if (result == null) {
        debugPrint('Modal da câmera fechado sem resultado');
        // Verificar por erro de Too many receivers
        final cameraErrorOccurred =
            await _webViewController.runJavaScriptReturningResult('''
          (function() {
            return localStorage.getItem('camera_error_count') > '2';
          })();
        ''');

        if (cameraErrorOccurred.toString() == 'true') {
          _markReceiverResetRequired();
        }

        // Reativar health check com delay para garantir que a página está estável
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            try {
              _webViewController
                  .runJavaScript("window.disableDiagnostics = false;");
              _startPeriodicHealthCheck();
            } catch (e) {
              debugPrint('Erro ao reativar diagnósticos: $e');
            }
          }
        });

        return;
      }

      final String type = result['type'];
      final String data = result['data'];

      debugPrint('Processando resultado: tipo=$type, data=$data');

      // Manter diagnósticos desabilitados durante o processamento
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint(
            'Erro ao desabilitar diagnósticos durante processamento: $e');
      }

      if (type == 'qrcode') {
        // Processar QR code detectado
        await _processQRCode(data);

        // Se o QR veio com uma imagem, processar a imagem também
        if (result.containsKey('imagePath')) {
          await _processSelectedImage(result['imagePath'], 'camera_file_input');
        }
      } else if (type == 'photo') {
        // Processar foto tirada
        await _processSelectedImage(data, 'camera_file_input');
      }

      // Os diagnósticos serão reativados dentro de _processSelectedImage ou _loadUrlSafely
    } catch (e, stackTrace) {
      debugPrint('Erro ao mostrar câmera: $e');
      _logError('Erro ao mostrar câmera: $e');

      // Verificar se o erro está relacionado a Too many receivers
      if (e.toString().contains('receivers')) {
        _markReceiverResetRequired();
        _showError(
            'O aplicativo atingiu o limite de recursos. Por favor, reinicie o aplicativo.');
      } else {
        await Sentry.captureException(e, stackTrace: stackTrace);
        _showError('Não foi possível acessar a câmera: $e');
      }

      // Reativar health check após erro
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          try {
            _webViewController
                .runJavaScript("window.disableDiagnostics = false;");
            _startPeriodicHealthCheck();
          } catch (e) {
            debugPrint('Erro ao reativar diagnósticos após erro: $e');
          }
        }
      });
    }
  }

  // Novo método para verificar se é seguro abrir a câmera (Android)
  Future<bool> _checkIfSafeToProceedWithCamera() async {
    try {
      // Verificar usando a função global
      final isSafe = await _isSafeToOpenCamera();
      if (!isSafe) {
        // Se não for seguro, verificar se precisa reiniciar
        if (_receiverResetRequired) {
          _showError(
              'O aplicativo precisa ser reiniciado para usar a câmera. Por favor, feche e abra o aplicativo novamente.');
        } else {
          _showError(
              'Muitas tentativas de acessar a câmera. Aguarde alguns minutos e tente novamente.');
        }
        return false;
      }

      // Verificar se houve erros de câmera armazenados
      final hasPreviousCameraError =
          await _webViewController.runJavaScriptReturningResult('''
        (function() {
          // Verificar se houve erros de câmera armazenados
          const cameraErrorCount = localStorage.getItem('camera_error_count') || '0';
          const lastCameraError = localStorage.getItem('last_camera_error_time');
          const now = Date.now();
          
          // Se houve erro recente (nos últimos 5 minutos)
          if (lastCameraError && (now - parseInt(lastCameraError)) < 300000) {
            const count = parseInt(cameraErrorCount);
            // Se tivemos mais de 3 erros consecutivos, sugerir reiniciar o app
            if (count > 3) {
              return true; // Não é seguro abrir a câmera
            }
          } else if (lastCameraError) {
            // Se o último erro foi há mais de 5 minutos, resetar o contador
            localStorage.setItem('camera_error_count', '0');
          }
          
          return false; // É seguro abrir a câmera
        })();
      ''');

      final bool shouldAvoid = hasPreviousCameraError.toString() == 'true';

      if (shouldAvoid) {
        _logError(
            'Detectado excesso de erros de câmera, evitando abrir câmera');
        _markReceiverResetRequired(); // Marcar que precisa reiniciar
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('Erro ao verificar segurança da câmera: $e');
      // Em caso de erro na verificação, permitir o uso da câmera
      return true;
    }
  }

  // Novo método para limpar memória antes de usar a câmera
  Future<void> _clearMemoryBeforeCameraUse() async {
    try {
      debugPrint('🧹 Limpando memória do sistema antes de usar a câmera');

      // Forçar coleta de lixo via SystemChannels
      await SystemChannels.platform
          .invokeMethod<void>('SystemNavigator.routeUpdated');

      // Pequeno delay para dar tempo à limpeza
      await Future.delayed(const Duration(milliseconds: 300));

      // Se estamos no Android, tentar abordagens adicionais
      if (Platform.isAndroid) {
        try {
          // Solicitar minimização e restauração rápida para liberar recursos
          await SystemChannels.platform
              .invokeMethod<void>('SystemNavigator.handlePopRoute');
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          debugPrint('⚠️ Erro ao tentar minimizar app: $e');
        }
      }

      debugPrint('✅ Limpeza de memória concluída');
    } catch (e) {
      debugPrint('⚠️ Erro ao limpar memória: $e');
    }
  }

  // Processa QR code detectado
  Future<void> _processQRCode(String qrData) async {
    try {
      debugPrint('Processando QR code: $qrData');

      // Desabilitar diagnósticos durante o processamento do QR code
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = true;");
      } catch (e) {
        debugPrint(
            'Erro ao desabilitar diagnósticos durante processamento QR: $e');
      }

      // Enviar para o servidor
      final uri = Uri.parse(apiUrl);
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'qr_code',
          'data': qrData,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('QR code enviado com sucesso para o servidor');
      } else {
        _logError('Erro ao enviar QR code: ${response.statusCode}');
      }

      // Verificar se o QR code é uma URL válida
      if (qrData.startsWith('http://') || qrData.startsWith('https://')) {
        // Carregar a URL diretamente no WebView
        await _loadUrlSafely(qrData);
      } else {
        // Se não for uma URL, apenas notificar o WebView
        await _webViewController.runJavaScript('''
          (function() {
            // Disparar evento com dados do QR code
            const event = new CustomEvent('qrCodeScanned', {
              detail: {
                data: '$qrData'
              }
            });
            document.dispatchEvent(event);
            
            // Também disponibilizar como variável global
            window.lastScannedQRCode = '$qrData';
            
            console.log('QR code processado e enviado para o WebView: $qrData');
            
            // Reativar diagnósticos após processamento
            window.disableDiagnostics = false;
          })();
        ''');

        // Reativar health check
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            _startPeriodicHealthCheck();
          }
        });
      }
    } catch (e, stackTrace) {
      _logError('Erro ao processar QR code: $e');
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao processar QR code: $e');

      // Reativar diagnósticos após erro
      try {
        await _webViewController
            .runJavaScript("window.disableDiagnostics = false;");

        // Reativar health check
        if (mounted) {
          _startPeriodicHealthCheck();
        }
      } catch (e) {
        debugPrint('Erro ao reativar diagnósticos após erro: $e');
      }
    }
  }

  // Restaura recursos após fechar a câmera
  Future<void> _restoreResourcesAfterCamera() async {
    try {
      // Pequeno atraso para garantir que a câmera foi fechada completamente
      await Future.delayed(const Duration(milliseconds: 500));

      debugPrint('Restaurando WebView após uso da câmera');

      // Recarregar completamente a WebView para garantir liberação de todos os receptores
      await _webViewController.reload();

      // Ou injetar JavaScript para retomar mídias se necessário
      await _webViewController.runJavaScript('''
        (function() {
          console.log('WebView restaurado após uso da câmera');
        })();
      ''');
        } catch (e) {
      debugPrint('Erro ao restaurar recursos após câmera: $e');
    }
  }

  // Força o reload do WebView
  Future<void> _reloadWebView() async {
    setState(() {
      _isLoading = true;
    });
    try {
      await _webViewController.reload();
      _lastReload = DateTime.now();
      _healthCheckFailCount = 0;
      setState(() {
        _hasConnectionError = false;
        _isOffline = false;
      });
    } catch (e, stackTrace) {
      _logError('Erro ao recarregar WebView: $e');
      await Sentry.captureException(e, stackTrace: stackTrace);
      setState(() {
        _hasConnectionError = true;
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Libera recursos antes de abrir a câmera para evitar conflitos
  Future<void> _disposeResourcesBeforeCamera() async {
    try {
      // Pausar o WebView para evitar conflitos com a câmera
      debugPrint('Pausando WebView temporariamente');
      // Injetar JavaScript para pausar mídias e liberar recursos
      await _webViewController.runJavaScript('''
        (function() {
          try {
            // Pausar todos os vídeos
            document.querySelectorAll('video').forEach(function(video) {
              if (!video.paused) video.pause();
            });
            
            // Pausar todos os áudios
            document.querySelectorAll('audio').forEach(function(audio) {
              if (!audio.paused) audio.pause();
            });
            
            // Pausar elementos com API de mídia que possam estar usando a câmera
            try {
              if (window._mediaStreamTracks) {
                window._mediaStreamTracks.forEach(function(track) {
                  track.stop();
                });
              }
              
              // Limpar qualquer receptor de eventos que possa estar em uso
              if (window._eventListeners) {
                window._eventListeners.forEach(function(listener) {
                  if (listener.element && listener.type && listener.handler) {
                    listener.element.removeEventListener(listener.type, listener.handler);
                  }
                });
                window._eventListeners = [];
              }
              
              // Forçar coleta de lixo nos navegadores que suportam
              if (window.gc) {
                window.gc();
              }
            } catch(e) {
              console.error("Erro ao parar media tracks:", e);
            }
            
            console.log('Recursos da web pausados temporariamente');
          } catch(e) {
            console.error('Erro ao liberar recursos web:', e);
          }
        })();
      ''');
    
      // Pequena pausa para garantir que recursos sejam liberados
      await Future.delayed(const Duration(milliseconds: 300));

      // Usar a nova função de limpeza de memória
      await _clearMemoryBeforeCameraUse();
    } catch (e) {
      debugPrint('Erro ao liberar recursos antes da câmera: $e');
    }
  }

  // Registrar erro de câmera para controle
  Future<void> _registerCameraError(String errorMessage) async {
    try {
      await _webViewController.runJavaScript('''
        (function() {
          const currentCount = parseInt(localStorage.getItem('camera_error_count') || '0');
          localStorage.setItem('camera_error_count', (currentCount + 1).toString());
          localStorage.setItem('last_camera_error_time', Date.now().toString());
          localStorage.setItem('last_camera_error', "${errorMessage.replaceAll('"', '\\"')}");
          console.error('Erro de câmera registrado: ${errorMessage.replaceAll('"', '\\"')}');
        })();
      ''');

      // Depois de vários erros, marcar que precisa reiniciar
      final errorCount = int.tryParse(await _webViewController
              .runJavaScriptReturningResult(
                  'localStorage.getItem("camera_error_count") || "0"')
              .then((value) => value.toString())) ??
          0;

      if (errorCount > 3) {
        _markReceiverResetRequired();
      }
    } catch (e) {
      debugPrint('Erro ao registrar erro de câmera: $e');
    }
  }

  Future<bool> _testApiConnection() async {
    try {
      final response = await http.get(
        Uri.parse('http://seu-dominio-ddns.com:3000/api/test'),
      );

      if (response.statusCode == 200) {
        debugPrint('API está online: ${response.body}');
        return true;
      } else {
        debugPrint('API retornou erro: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Erro ao conectar na API: $e');
      return false;
    }
  }

  void _startQRCodeReadingWithTimeout() async {
    await _resetCameraState(); // Resetar o estado da câmera antes de abrir

    // Desabilitar health check durante o uso da câmera
    _healthCheckTimer?.cancel();

    // Desabilitar diagnósticos na página atual
    try {
      await _webViewController
          .runJavaScript("window.disableDiagnostics = true;");
    } catch (e) {
      debugPrint('Erro ao desabilitar diagnósticos: $e');
    }

    await _showCameraModal();

    // Reativar health check após uso da câmera (com delay para garantir que a página está carregada)
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        try {
          _webViewController
              .runJavaScript("window.disableDiagnostics = false;");
          _startPeriodicHealthCheck();
        } catch (e) {
          debugPrint('Erro ao reativar diagnósticos: $e');
        }
      }
    });
  }

  // Adicionar função para testar o Sentry
  Future<void> _testSentryCapture() async {
    try {
      // Criar um evento de teste usando o Logger
      Logger.info(
        'Teste manual do Logger/Sentry',
        extra: {'source': 'manual_test'},
        category: 'test',
      );

      // Mostrar mensagem de sucesso
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Evento de teste enviado para o Sentry com sucesso!'),
          backgroundColor: Colors.green,
        ),
      );

      // Simular um erro para testar captura de exceções
      // Comentado para não criar erros acidentais durante uso normal
      // throw Exception('Exceção de teste para o Sentry');
    } catch (e, stackTrace) {
      // Capturar exceção com stack trace usando o Logger
      await Logger.captureException(
        e,
        stackTrace: stackTrace,
        category: 'test',
      );

      // Mostrar mensagem de erro capturado
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Erro de teste capturado e enviado para o Sentry!'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }
}

class OrientationView extends StatelessWidget {
  final VoidCallback onOrientationComplete;

  const OrientationView({
    super.key,
    required this.onOrientationComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.screen_rotation,
            size: 80,
            color: Colors.blue,
          ),
          const SizedBox(height: 20),
          const Text(
            'Gire o dispositivo para o modo paisagem',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: onOrientationComplete,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 32,
                vertical: 16,
              ),
            ),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }
}

class CompletionView extends StatelessWidget {
  final Function(bool) isShowingImageCapture;
  final File? capturedImage;
  final Function(File) onImageCaptured;
  final VoidCallback onSendComplete;

  const CompletionView({
    super.key,
    required this.isShowingImageCapture,
    required this.capturedImage,
    required this.onImageCaptured,
    required this.onSendComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          const Text(
            'Certifique-se de que as seguintes informações estão visíveis:',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: const [
              Text('Valor'),
              Text('Data'),
              Text('Loja'),
            ],
          ),
          const SizedBox(height: 20),
          if (capturedImage != null)
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  capturedImage!,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    isShowingImageCapture(true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.blue,
                    side: const BorderSide(color: Colors.blue),
                  ),
                  child: const Text('Nova Foto'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: onSendComplete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Enviar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class QRViewExample extends StatelessWidget {
  final Function(String) onCodeScanned;

  const QRViewExample({required this.onCodeScanned, super.key});

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

// Função para comprimir e redimensionar a imagem
// Implementa o algoritmo de redimensionamento similar ao fornecido no código TypeScript:
// - Largura máxima de 1280px
// - Mantém a proporção da imagem original
// - Aplica interpolação linear para melhor qualidade
// - Otimizado para iOS com suporte a compressão adicional quando necessário
Future<Uint8List> compressAndResizeImage(File imageFile,
    {bool forceHighCompression = false}) async {
  try {
    // Carregar a imagem
    final Uint8List imageBytes = await imageFile.readAsBytes();

    // Verificar se temos bytes da imagem
    if (imageBytes.isEmpty) {
      throw Exception('Arquivo de imagem vazio');
    }

    // Decodificar a imagem
    final img.Image? image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Não foi possível decodificar a imagem');

    // Calcular nova largura e altura mantendo proporção
    int targetWidth = image.width > 1280 ? 1280 : image.width;
    int targetHeight = (targetWidth * image.height) ~/ image.width;

    // Se forçar alta compressão para iOS, usar dimensões menores
    if (forceHighCompression && Platform.isIOS) {
      targetWidth = targetWidth ~/ 1.5; // Reduz 33% a mais na largura
      targetHeight = targetHeight ~/ 1.5; // Reduz 33% a mais na altura
      debugPrint(
          '📊 Aplicando compressão extra para iOS: ${targetWidth}x$targetHeight');
    }

    Logger.info('Redimensionando imagem:',
        extra: {
          'largura_original': image.width,
          'altura_original': image.height,
          'nova_largura': targetWidth,
          'nova_altura': targetHeight,
          'plataforma': Platform.isIOS ? 'iOS' : 'Android',
          'compressao_extra': forceHighCompression
        },
        category: 'image_processing');

    // Redimensionar a imagem
    final img.Image resizedImage = img.copyResize(image,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear);

    // Converter para JPEG com boa qualidade (WebP não é suportado diretamente)
    // Qualidade de 85% oferece bom equilíbrio entre tamanho e qualidade
    // Em iOS com problemas de memória, usar qualidade mais baixa se necessário
    final quality = (forceHighCompression && Platform.isIOS) ? 70 : 85;
    final compressedBytes = img.encodeJpg(resizedImage, quality: quality);

    // Registrar métricas de compressão
    final compressionRatio = compressedBytes.length * 100 / imageBytes.length;
    final reductionPercent = 100 - compressionRatio;

    Logger.info('Imagem comprimida:',
        extra: {
          'tamanho_bytes_original': imageBytes.length,
          'tamanho_bytes_final': compressedBytes.length,
          'redução': '${reductionPercent.toStringAsFixed(2)}%',
          'plataforma': Platform.isIOS ? 'iOS' : 'Android',
          'qualidade': quality
        },
        category: 'image_processing');

    return Uint8List.fromList(compressedBytes);
  } catch (e) {
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
