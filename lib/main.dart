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
import './camera-qr-scanner-widget.dart'; // Import the CameraWithQRScanner widget
import 'dart:io';
import 'dart:convert';
import 'dart:async';

// URL para enviar dados
const String apiUrl = 'http://192.168.31.194:3000/api/upload';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SentryFlutter.init(
    (options) {
      options.dsn =
          'https://5573f26d70d7e90910b448932b8d0626@o4508931864330240.ingest.us.sentry.io/4508931871866880';
      options.tracesSampleRate = 1.0; // Capture 100% dos traces
    },
    appRunner: () => runApp(const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter WebView Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const WebViewDemo(),
      navigatorObservers: [SentryNavigatorObserver()],
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

  String option = 'A';
  bool showFrame = false;

  late final WebViewController _webViewController;
  Timer? _healthCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Solicita permissões primeiro
    _requestPermissions().then((_) {
      // Inicializa o WebView após obter permissões
      _initializeWebView();

      // Carrega a página inicial após um pequeno atraso para garantir que tudo está pronto
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          // Carrega uma página HTML inicial simples
          _loadHtmlContent();

          // Configura verificação periódica de saúde
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
            body { background-color: white; color: black; font-family: Arial, sans-serif; }
          </style>
          <script>
            // Escutar evento de imagem selecionada
            window.addEventListener('imageSelected', function(e) {
              console.log('Evento imageSelected recebido');
              const imageData = e.detail;
              displayImage(imageData);
            });
            
            function displayImage(imageData) {
              // Cria container para imagem
              const container = document.querySelector('.container');
              if (!container) return;
              
              // Limpa conteúdo atual
              container.innerHTML = '';
              
              // Cria elemento de imagem
              const img = document.createElement('img');
              img.src = imageData;
              img.style.maxWidth = '100%';
              img.style.borderRadius = '8px';
              img.style.boxShadow = '0 4px 8px rgba(0,0,0,0.1)';
              
              // Adiciona imagem ao container
              container.appendChild(img);
              
              console.log('Imagem exibida no DOM');
            }
          </script>
        </head>
        <body>
          <div style="padding: 20px; text-align: center;">
            <h3>WebView inicializado</h3>
            <p>Insira uma URL ou escaneie um código QR para começar.</p>
          </div>
        </body>
      </html>
    ''');
  }

  void _logError(String message) {
    Sentry.captureMessage(message, level: SentryLevel.error);
    debugPrint('ERROR: $message');
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
      // Injetar e executar scripts de diagnóstico
      final result = await _webViewController.runJavaScriptReturningResult('''
        (function() {
          const diagnostics = {
            url: window.location.href,
            userAgent: navigator.userAgent,
            cookiesEnabled: navigator.cookieEnabled,
            localStorage: !!window.localStorage,
            sessionStorage: !!window.sessionStorage,
            indexedDB: !!window.indexedDB,
            cacheAPI: !!window.caches,
            serviceWorker: !!navigator.serviceWorker,
            network: navigator.onLine,
            webViewRendering: document.body !== null,
            domContentLoaded: document.readyState
          };
          
          return JSON.stringify(diagnostics);
        })();
      ''');

      // Processar e registrar resultados
      if (result != null) {
        final String jsonResult = result.toString();
        debugPrint('Diagnóstico WebView: $jsonResult');

        // Podemos enviar esses diagnósticos para o Sentry também
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'webview.diagnostics',
            message: 'WebView health check',
            data: jsonDecode(jsonResult),
            level: SentryLevel.info,
          ),
        );
      }
    } catch (e, stackTrace) {
      _logError('Erro ao realizar diagnóstico do WebView: $e');
      await Sentry.captureException(e, stackTrace: stackTrace);
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
      // Converter para base64
      final String base64Image =
          base64Encode(await File(imagePath).readAsBytes());

      // Tentar detectar QR code na imagem de forma transparente
      String? qrCode;
      try {
        final MobileScannerController controller = MobileScannerController();
        final barcodes = await controller.analyzeImage(imagePath);
        if (barcodes?.barcodes.isNotEmpty ?? false) {
          qrCode = barcodes?.barcodes.first.rawValue;
        }
        await controller.dispose();
      } catch (e) {
        debugPrint('Erro ao tentar detectar QR code: $e');
      }

      // Preparar objeto de dados no formato especificado
      final Map<String, String> resultData = {
        'image': 'base64:$base64Image',
        if (qrCode != null) 'qrcode': qrCode,
      };

      // Injetar dados de volta ao elemento de input do formulário
      await _webViewController.runJavaScript('''
        (function() {
          // Encontrar o elemento de input
          const input = document.getElementById('$inputId') || document.querySelector('input[type="file"]');
          if (!input) {
            console.error('Input element not found: $inputId');
            return;
          }
          
          // Criar um objeto File a partir do base64
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
          
          // Criar um objeto DataTransfer
          const dataTransfer = new DataTransfer();
          dataTransfer.items.add(file);
          
          // Definir os arquivos do input
          input.files = dataTransfer.files;
          
          // Disparar evento change para notificar o formulário
          const event = new Event('change', { bubbles: true });
          input.dispatchEvent(event);
          
          // Disparar evento customizado com os dados completos
          const customEvent = new CustomEvent('imageProcessed', { 
            detail: ${jsonEncode(resultData)}
          });
          document.dispatchEvent(customEvent);
          
          // Também disponibilizar os dados como variável global para o PWA acessar
          window.processedImageData = ${jsonEncode(resultData)};
          
          console.log('Arquivo processado e injetado:', ${jsonEncode(resultData)});
        })();
      ''');

      // Enviar dados para o servidor no formato correto
      final uri = Uri.parse(apiUrl);
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(resultData),
      );

      if (response.statusCode == 200) {
        debugPrint('Dados enviados com sucesso');
      } else {
        _logError('Erro ao enviar dados: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao processar imagem: $e');
    }
  }

  Future<void> _scanQRCodeOrTakePicture({String inputId = ''}) async {
    try {
      bool hasPermission = await _checkPermissions();
      if (!hasPermission) return;

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

      // Se não houver resultado, o usuário cancelou
      if (result == null) return;

      // Processar o resultado após o modal ser fechado
      if (result['type'] == 'qrcode') {
        final String code = result['data'];

        // Processar o código QR
        setState(() {
          _urlController.text = code;
          showFrame = true;
        });

        // Registrar URL escaneada
        await _sendQrData(code);

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

        try {
          // Se foi chamado de um input file, enviar para o elemento
          if (inputId.isNotEmpty) {
            await _processSelectedImage(imagePath, inputId);
          } else {
            // Processar a foto
            await _uploadFile(imagePath, 'image');

            // Garantir que o WebView esteja visível
            if (mounted) {
              setState(() {
                showFrame = true;
                // Carregar uma página em branco para garantir que o WebView esteja ativo
                _loadHtmlContent();
              });
            }

            // Pequeno atraso para permitir que o WebView seja inicializado
            await Future.delayed(const Duration(milliseconds: 500));

            // Informar a WebView sobre a imagem usando JavaScript
            final String base64Image =
                base64Encode(await File(imagePath).readAsBytes());

            // Injeta JavaScript com pequeno atraso para garantir que a WebView esteja pronta
            await _webViewController.runJavaScript(
                'window.dispatchEvent(new CustomEvent("imageSelected", {detail: "data:image/jpeg;base64,$base64Image"}));');

            // Para debug - Verifica se a WebView está respondendo
            await _webViewController.runJavaScript(
                'console.log("WebView recebeu imagem com tamanho: " + "${base64Image.length}");');

            // Força uma atualização visual
            if (mounted) {
              setState(() {});
            }
          }
        } catch (e) {
          _logError('Erro ao processar imagem: $e');
          _showError('Erro ao processar imagem: $e');
        }
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
      _showError('Erro ao tirar foto ou escanear QR Code: $e');
    }
  }

  // Função auxiliar para carregar URLs com segurança
  Future<void> _loadUrlSafely(String url) async {
    try {
      await _webViewController.loadRequest(Uri.parse(url));

      // Verificar se a página carregou corretamente depois de um curto intervalo
      await Future.delayed(const Duration(seconds: 1));
      await _webViewController.runJavaScript('''
        if (document.body) {
          document.body.style.backgroundColor = "white";
          console.log("Página carregada e cor de fundo definida");
        } else {
          console.error("Corpo do documento não encontrado");
        }
      ''');
    } catch (e) {
      _logError('Erro ao carregar URL: $e');

      // Tenta recarregar a página em caso de erro
      try {
        await _webViewController.reload();
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
              display: flex;
              justify-content: center;
              align-items: center;
              height: 100vh;
              margin: 0;
            }
            .container {
              text-align: center;
              padding: 20px;
            }
          </style>
          <script>
            // Escutar evento de imagem selecionada
            window.addEventListener('imageSelected', function(e) {
              console.log('Evento imageSelected recebido');
              const imageData = e.detail;
              displayImage(imageData);
            });
            
            function displayImage(imageData) {
              // Cria container para imagem
              const container = document.querySelector('.container');
              if (!container) return;
              
              // Limpa conteúdo atual
              container.innerHTML = '';
              
              // Cria elemento de imagem
              const img = document.createElement('img');
              img.src = imageData;
              img.style.maxWidth = '100%';
              img.style.borderRadius = '8px';
              img.style.boxShadow = '0 4px 8px rgba(0,0,0,0.1)';
              
              // Adiciona imagem ao container
              container.appendChild(img);
              
              console.log('Imagem exibida no DOM');
            }
          </script>
        </head>
        <body>
          <div class="container">
            <h3>Imagem sendo processada...</h3>
            <p>Aguarde um momento.</p>
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
      final uri = Uri.parse(apiUrl);

      // Se for uma imagem com QR code, enviar como um único objeto JSON
      if (type == 'image' && qrCode != null) {
        // Criar objeto no formato especificado
        final Map<String, dynamic> data = {
          'type': 'combined_data',
          'qrcode': qrCode,
          'image': 'base64:${base64Encode(await File(filePath).readAsBytes())}'
        };

        // Enviar como JSON
        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data),
        );

        if (response.statusCode == 200) {
          debugPrint('Dados combinados enviados com sucesso');
        } else {
          _logError('Erro ao enviar dados combinados: ${response.statusCode}');
        }
      } else {
        // Método original para outros tipos de upload
        final request = http.MultipartRequest('POST', uri);
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
        request.fields['type'] = type;
        if (qrCode != null) {
          request.fields['qrcode'] = qrCode;
        }

        final response = await request.send();

        if (response.statusCode == 200) {
          debugPrint('Arquivo enviado com sucesso');
        } else {
          _logError('Erro ao enviar arquivo: ${response.statusCode}');
        }
      }
    } catch (e, stackTrace) {
      await Sentry.captureException(e, stackTrace: stackTrace);
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

      switch (option) {
        case 'A':
          // Abrir na mesma página
          _webViewController.loadRequest(Uri.parse(url));
          setState(() {
            showFrame = true;
          });
          break;
        case 'B':
          // Abrir em uma nova página
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => Scaffold(
                appBar: AppBar(
                  title: const Text('WebView em Nova Página'),
                ),
                body: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onNavigationRequest: (NavigationRequest request) {
                          if (request.url != url) {
                            return NavigationDecision.prevent;
                          }
                          return NavigationDecision.navigate;
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ),
          );
          break;
        case 'C':
          // Abrir em um modal
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              content: SizedBox(
                height: 400,
                child: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onNavigationRequest: (NavigationRequest request) {
                          if (request.url != url) {
                            return NavigationDecision.prevent;
                          }
                          return NavigationDecision.navigate;
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ),
          );
          break;
        case 'D':
          // Abrir em um popup redimensionável
          showDialog(
            context: context,
            builder: (context) => StatefulBuilder(
              builder: (context, setState) {
                double dialogHeight = MediaQuery.of(context).size.height * 0.8;
                double dialogWidth = MediaQuery.of(context).size.width * 0.8;

                return Dialog(
                  insetPadding: const EdgeInsets.all(10),
                  backgroundColor: Colors.white,
                  child: Container(
                    height: dialogHeight,
                    width: dialogWidth,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: WebViewWidget(
                        controller: WebViewController()
                          ..setJavaScriptMode(JavaScriptMode.unrestricted)
                          ..setNavigationDelegate(
                            NavigationDelegate(
                              onNavigationRequest: (NavigationRequest request) {
                                if (request.url != url) {
                                  return NavigationDecision.prevent;
                                }
                                return NavigationDecision.navigate;
                              },
                            ),
                          )
                          ..loadRequest(Uri.parse(url)),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
          break;
        case 'E':
          // Abrir em um navegador externo
          if (await canLaunchUrl(Uri.parse(url))) {
            await launchUrl(Uri.parse(url));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Não foi possível abrir o navegador externo.')),
            );
          }
          break;
        case 'F':
          // Carrega a URL no controlador existente da WebView
          _webViewController.loadRequest(Uri.parse(url));

          // Atualiza o estado para exibir o conteúdo em tela cheia
          setState(() {
            showFrame = true;
          });
          break;
      }
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
      appBar: AppBar(
        title: const Text('Flutter WebView Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'URL',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                ),
                validator: _validateUrl,
              ),
              const SizedBox(height: 16.0),
              Column(
                children: ['A', 'B', 'C', 'D', 'E', 'F'].map((opt) {
                  return Row(
                    children: [
                      Radio(
                        value: opt,
                        groupValue: option,
                        onChanged: (value) {
                          setState(() {
                            option = value!;
                          });
                        },
                      ),
                      Text('Opção $opt'),
                    ],
                  );
                }).toList(),
              ),
              const SizedBox(height: 16.0),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      if (_formKey.currentState!.validate()) {
                        bool permissionsGranted = await _checkPermissions();
                        if (permissionsGranted) {
                          _openUrl();
                        }
                      }
                    },
                    child: const Text('Executar'),
                  ),
                  ElevatedButton(
                    onPressed: _scanQRCodeOrTakePicture,
                    child: const Icon(Icons.camera_alt),
                  ),
                ],
              ),
              if (showFrame && _urlController.text.isNotEmpty)
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        // WebView renderizado
                        WebViewWidget(
                          controller: _webViewController,
                        ),
                        // Indicador de carregamento simples
                        FutureBuilder<bool>(
                          future: Future.delayed(
                              const Duration(milliseconds: 500), () => true),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return Container(
                                color: Colors.white.withOpacity(0.7),
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
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
